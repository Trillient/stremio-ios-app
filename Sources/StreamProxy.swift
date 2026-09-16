import Foundation
import Network

/// Loopback HTTP proxy on 127.0.0.1 with two jobs:
///
/// 1. **Streams** — VLC can't send the site's SSO cookie, so it fetches from
///    localhost and we forward to the origin with the cookie, relaying Range/206.
/// 2. **Web mirror (built-in mode)** — Stremio's web app is served from
///    `http://127.0.0.1:<port>/` by mirroring web.stremio.com. WebKit blocks an
///    https page from calling the in-app server at http://127.0.0.1:11470
///    (mixed content); from a localhost origin that call is allowed, and
///    localhost still counts as a secure context.
final class StreamProxy {
    static let shared = StreamProxy()
    static let mirrorOrigin = URL(string: "https://web.stremio.com")!

    private struct Route { let origin: URL; let cookie: String?; let isBase: Bool }
    /// Content-Type the origin reported for a token's first response (for cast decisions).
    private var contentTypes: [String: String] = [:]
    private var routes: [String: Route] = [:]
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "dev.woolston.stremio.proxy")
    private let lock = NSLock()

    /// Base URL of the mirrored Stremio web app.
    var mirrorBaseURL: URL {
        startIfNeeded()
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    /// Returns the loopback URL VLC should open for `origin`.
    func register(origin: URL, cookie: String?) -> URL {
        _ = registerToken(origin: origin, cookie: cookie, isBase: false)
        return URL(string: "http://127.0.0.1:\(port)/\(lastToken)")!
    }

    private(set) var lastToken = ""

    /// Registers a route. `isBase` routes forward `/<token>/<rest>` to `rest`
    /// resolved against `origin` — needed for HLS playlists whose segments are
    /// relative paths (a Chromecast fetches those through us).
    @discardableResult
    func registerToken(origin: URL, cookie: String?, isBase: Bool) -> String {
        startIfNeeded()
        let token = UUID().uuidString
        lock.lock(); routes[token] = Route(origin: origin, cookie: cookie, isBase: isBase); lastToken = token; lock.unlock()
        return token
    }

    func contentType(forToken token: String) -> String? { lock.lock(); defer { lock.unlock() }; return contentTypes[token] }
    func remember(contentType: String, forToken token: String) { lock.lock(); contentTypes[token] = contentType; lock.unlock() }

    /// The phone's Wi-Fi IPv4, so devices on the LAN (a Chromecast) can reach the proxy.
    static func lanIPv4() -> String? {
        var addr: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard ifa.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ifa.ifa_addr, socklen_t(ifa.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") { addr = ip; if name == "en0" { break } }
            }
        }
        return addr
    }

    /// URL a LAN device should use for a token (HLS gets a file-like suffix so
    /// relative playlist references resolve under the token).
    func lanURL(forToken token: String, hls: Bool) -> URL? {
        guard let ip = Self.lanIPv4() else { return nil }
        return URL(string: "http://\(ip):\(port)/\(token)\(hls ? "/master.m3u8" : "")")
    }

    /// Where the last successful listen happened, so the next launch can reuse it.
    private static let portDefaultsKey = "dev.woolston.stremio.proxyPort"
    /// First choice of port. 11470 belongs to the in-app streaming server.
    private static let preferredPort: UInt16 = 11471

    private func startIfNeeded() {
        guard listener == nil else { return }
        // In built-in mode the web app is served from http://127.0.0.1:<port>, and
        // a web origin includes its port. Listening on a fresh ephemeral port each
        // launch therefore pointed Stremio at a different origin every time, so it
        // found an empty localStorage and presented itself as logged out. Keep the
        // port stable across launches, remembering whichever one actually worked.
        let saved = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
        let preferred = (saved > 0 && saved <= 65535) ? UInt16(saved) : Self.preferredPort
        if listen(on: preferred) { return }
        NSLog("[STREMIOAPP][proxy] port %d unavailable — using an ephemeral port; the built-in web app starts a fresh session this launch",
              Int(preferred))
        _ = listen(on: nil)
    }

    /// Binds the listener, to `desired` when given and to any free port otherwise.
    private func listen(on desired: UInt16?) -> Bool {
        let params = NWParameters.tcp
        let wanted = desired.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: wanted)
        guard let l = try? NWListener(using: params) else {
            NSLog("[STREMIOAPP][proxy] failed to create listener"); return false
        }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let err): NSLog("[STREMIOAPP][proxy] listener failed: %@", err.localizedDescription); ready.signal()
            case .cancelled: ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)

        guard case .ready = l.state, let bound = l.port?.rawValue else {
            l.cancel()
            return false
        }
        listener = l
        port = bound
        UserDefaults.standard.set(Int(bound), forKey: Self.portDefaultsKey)
        NSLog("[STREMIOAPP][proxy] listening on 127.0.0.1:%d", Int(bound))
        return true
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                self.serve(conn, head: String(decoding: buf[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    private func serve(_ conn: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { conn.cancel(); return }
        let method = String(parts[0])
        let target = String(parts[1])                                   // path + query
        let firstComponent = target.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let token = firstComponent.split(separator: "?").first.map(String.init) ?? ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        lock.lock(); let route = routes[token]; lock.unlock()

        let req: URLRequest
        let relay: Relay
        if let route {
            // Stream relay (cookie-authenticated, retry on cold torrent).
            var r = URLRequest(url: route.origin)
            r.httpMethod = (method == "HEAD") ? "HEAD" : "GET"
            if let range = headers["range"] { r.setValue(range, forHTTPHeaderField: "Range") }
            if let cookie = route.cookie { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
            r.setValue("StremioApp/1.0", forHTTPHeaderField: "User-Agent")
            NSLog("[STREMIOAPP][proxy] %@ range=%@", method, headers["range"] ?? "-")
            req = r
            relay = Relay(conn: conn, request: r, followRedirects: false, maxAttempts: 45)
            relay.onContentType = { [weak self] ct in self?.remember(contentType: ct, forToken: token) }
        } else {
            // Web mirror: same path/query on web.stremio.com.
            guard let url = URL(string: target, relativeTo: Self.mirrorOrigin)?.absoluteURL else { conn.cancel(); return }
            var r = URLRequest(url: url)
            r.httpMethod = (method == "HEAD") ? "HEAD" : "GET"
            for key in ["accept", "accept-language", "range", "if-none-match", "if-modified-since", "user-agent"] {
                if let v = headers[key] { r.setValue(v, forHTTPHeaderField: key) }
            }
            req = r
            relay = Relay(conn: conn, request: r, followRedirects: true, maxAttempts: 1)
        }
        _ = req
        relay.start()
    }
}

/// Streams one origin response back over one client connection.
///
/// Cold torrents: the streaming server can't answer until it has the first
/// pieces and the edge returns 504 meanwhile. Rather than surfacing that to VLC
/// (which gives up after 3 tries), hold the client connection and keep re-asking
/// the origin until it produces data. Simple backpressure suspends the origin
/// task when the client falls behind.
///
/// Mid-stream breaks get the same treatment. A two-hour film is one long origin
/// response, and anything that interrupts it — the torrent starving for more
/// than the 90 s request timeout, a dropped tunnel, a restarted server — used to
/// end the client connection, which VLC reported as a playback error well into
/// the film and which lost the viewer's position. Once the head is written the
/// body is instead continued with `Range: bytes=<delivered>-` on a fresh leg, so
/// the break never reaches VLC.
private final class Relay: NSObject, URLSessionDataDelegate {
    private let conn: NWConnection
    private let request: URLRequest
    private let followRedirects: Bool
    private let maxAttempts: Int
    private var task: URLSessionDataTask?

    private let lock = NSLock()
    private var inflight = 0
    private var suspended = false
    private var headWritten = false
    private var retrying = false
    private var attempts = 0
    var onContentType: ((String) -> Void)?
    private let retryDelay: TimeInterval = 3

    /// Byte offset the client asked us to start at (0 unless VLC sent a Range).
    private let rangeStart: Int64
    /// Body bytes handed to the client so far, across all legs.
    private var delivered: Int64 = 0
    /// Body bytes the client is expecting in total, when the origin told us.
    private var expectedBody: Int64?
    /// Resumes since data last flowed; reset on every byte received.
    private var resumeAttempts = 0
    /// Set once the client connection is gone, to stop resuming into nothing.
    private var clientGone = false
    private var finished = false
    private let maxResumeAttempts = 60
    private let resumeDelay: TimeInterval = 2

    init(conn: NWConnection, request: URLRequest, followRedirects: Bool, maxAttempts: Int) {
        self.conn = conn
        self.request = request
        self.followRedirects = followRedirects
        self.maxAttempts = maxAttempts
        self.rangeStart = Relay.parseRangeStart(request.value(forHTTPHeaderField: "Range"))
        super.init()
    }

    /// First byte offset of a `bytes=N-...` request header.
    private static func parseRangeStart(_ header: String?) -> Int64 {
        guard let header, let eq = header.firstIndex(of: "=") else { return 0 }
        let spec = header[header.index(after: eq)...]
        return Int64(spec.prefix(while: { $0.isNumber })) ?? 0
    }

    /// The origin request for the current leg: the original one, or a Range
    /// request continuing from where the previous leg stopped.
    private func currentRequest() -> URLRequest {
        lock.lock(); let sent = delivered; lock.unlock()
        guard sent > 0 else { return request }
        var r = request
        r.setValue("bytes=\(rangeStart + sent)-", forHTTPHeaderField: "Range")
        return r
    }

    func start() {
        attempts += 1
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 24 * 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session.dataTask(with: currentRequest())
        task?.resume()
    }

    private func scheduleRetry(reason: String) {
        NSLog("[STREMIOAPP][proxy] origin not ready (%@) — retry %d/%d in %.0fs", reason, attempts, maxAttempts, retryDelay)
        retrying = true
        DispatchQueue.global().asyncAfter(deadline: .now() + retryDelay) { [weak self] in
            self?.retrying = false
            self?.start()
        }
    }

    private func fail(_ status: Int, _ reason: String) {
        NSLog("[STREMIOAPP][proxy] giving up: %@", reason)
        let head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    /// The origin died part-way through a file VLC is still reading. The client
    /// has already had a 200/206 head, so we cannot report an error to it — VLC
    /// would surface a truncated stream as a playback failure and the viewer
    /// would lose their place. Instead, re-ask the origin from the next byte we
    /// owe and keep writing into the same client connection. A torrent stalling
    /// for longer than the 90 s request timeout, a dropped tunnel or a restarted
    /// server all end up here and recover without VLC noticing.
    private func scheduleResume(reason: String) {
        lock.lock()
        resumeAttempts += 1
        let attempt = resumeAttempts
        let gone = clientGone
        let offset = rangeStart + delivered
        lock.unlock()

        guard !gone, attempt <= maxResumeAttempts else {
            NSLog("[STREMIOAPP][proxy] resume exhausted after %d tries (%@)", attempt, reason)
            finish()
            return
        }
        NSLog("[STREMIOAPP][proxy] mid-stream break at %lld (%@) — resuming %d/%d in %.0fs",
              offset, reason, attempt, maxResumeAttempts, resumeDelay)
        retrying = true
        DispatchQueue.global().asyncAfter(deadline: .now() + resumeDelay) { [weak self] in
            guard let self else { return }
            self.retrying = false
            self.start()
        }
    }

    /// Closes the client connection once, after the body is complete or
    /// unrecoverable.
    private func finish() {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        lock.unlock()
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [conn] _ in conn.cancel() })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if followRedirects { completionHandler(request); return }
        NSLog("[STREMIOAPP][proxy] origin redirected %d -> %@", response.statusCode, request.url?.absoluteString ?? "")
        completionHandler(nil)   // a login bounce is a failure we want to see, not follow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }

        // Any response arriving after the head was written belongs to a resumed
        // leg: the client is mid-body and must receive only the missing bytes.
        // This has to be decided before the 502 handling below, because writing a
        // second set of headers into the middle of the body would corrupt it.
        // Only a 206 continues the file; a 200 would restart it from byte zero
        // and a redirect means the login bounced, so both are retried instead.
        if headWritten {
            guard http.statusCode == 206 else {
                completionHandler(.cancel)
                if http.statusCode == 416 || delivered == expectedBody {
                    NSLog("[STREMIOAPP][proxy] origin reports range past EOF — body already complete")
                    finish()
                } else {
                    scheduleResume(reason: "resume got HTTP \(http.statusCode), wanted 206")
                }
                return
            }
            NSLog("[STREMIOAPP][proxy] resumed at %lld (%@)", rangeStart + delivered,
                  http.value(forHTTPHeaderField: "Content-Range") ?? "-")
            completionHandler(.allow)
            return
        }

        if (502...504).contains(http.statusCode) && attempts < maxAttempts {
            completionHandler(.cancel)
            scheduleRetry(reason: "HTTP \(http.statusCode)")
            return
        }

        let reason: String
        switch http.statusCode {
        case 200: reason = "OK"; case 206: reason = "Partial Content"; case 304: reason = "Not Modified"
        case 404: reason = "Not Found"; default: reason = "Status"
        }
        var head = "HTTP/1.1 \(http.statusCode) \(reason)\r\n"
        // URLSession already decompressed the body, so a Content-Length from an
        // encoded response would be wrong; let EOF (Connection: close) delimit it.
        let encoded = http.value(forHTTPHeaderField: "Content-Encoding") != nil
        let passthrough: Set<String> = ["content-type", "content-range", "accept-ranges", "last-modified", "etag", "cache-control"]
        for (k, v) in http.allHeaderFields {
            let key = "\(k)"; let lk = key.lowercased()
            if passthrough.contains(lk) || (lk == "content-length" && !encoded) { head += "\(key): \(v)\r\n" }
        }
        head += "Connection: close\r\n\r\n"
        if !followRedirects {
            NSLog("[STREMIOAPP][proxy] origin %d type=%@ range=%@ len=%@ (attempt %d)",
                  http.statusCode, http.value(forHTTPHeaderField: "Content-Type") ?? "-",
                  http.value(forHTTPHeaderField: "Content-Range") ?? "-",
                  http.value(forHTTPHeaderField: "Content-Length") ?? "-", attempts)
        }
        headWritten = true
        // Body bytes this response promised, so a silent truncation can be told
        // apart from a genuine end of file. For a 206 this is the length of the
        // range, which is exactly what the client is owed.
        if !encoded && http.expectedContentLength > 0 {
            expectedBody = http.expectedContentLength
        }
        if let ct = http.value(forHTTPHeaderField: "Content-Type") { onContentType?(ct) }
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        inflight += data.count
        // Bytes are counted as owed the moment they are queued, so a resume
        // after a failed send cannot ask the origin for them twice.
        delivered += Int64(data.count)
        resumeAttempts = 0                     // real progress: spend the budget again if needed
        if inflight > 8_000_000 && !suspended { suspended = true; dataTask.suspend() }
        lock.unlock()
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.lock.lock(); self.clientGone = true; self.lock.unlock()
                dataTask.cancel(); self.conn.cancel(); return
            }
            self.lock.lock()
            self.inflight -= data.count
            if self.suspended && self.inflight < 2_000_000 { self.suspended = false; dataTask.resume() }
            self.lock.unlock()
        })
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { session.finishTasksAndInvalidate() }
        if retrying { return }
        if !headWritten {
            if let error, attempts < maxAttempts { scheduleRetry(reason: error.localizedDescription); return }
            fail(502, error == nil ? "Stream did not start" : "Upstream error")
            return
        }
        lock.lock()
        let gone = clientGone
        let sent = delivered
        lock.unlock()
        if gone { finish(); return }

        // A clean EOF short of the promised length is a truncation, not an end
        // of file, so it is resumed like an explicit error.
        if let expected = expectedBody, sent < expected {
            scheduleResume(reason: error?.localizedDescription
                           ?? "origin closed at \(sent)/\(expected) bytes")
            return
        }
        if expectedBody == nil, let error {
            scheduleResume(reason: error.localizedDescription)
            return
        }
        finish()
    }
}
