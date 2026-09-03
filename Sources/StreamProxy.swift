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

    private func startIfNeeded() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "0.0.0.0", port: .any)
        guard let l = try? NWListener(using: params) else {
            NSLog("[STREMIOAPP][proxy] failed to create listener"); return
        }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.port = l.port?.rawValue ?? 0; ready.signal()
            case .failed(let err): NSLog("[STREMIOAPP][proxy] listener failed: %@", err.localizedDescription); ready.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener = l
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        NSLog("[STREMIOAPP][proxy] listening on 127.0.0.1:%d", Int(port))
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

    init(conn: NWConnection, request: URLRequest, followRedirects: Bool, maxAttempts: Int) {
        self.conn = conn
        self.request = request
        self.followRedirects = followRedirects
        self.maxAttempts = maxAttempts
        super.init()
    }

    func start() {
        attempts += 1
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 24 * 3600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session.dataTask(with: request)
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
        if let ct = http.value(forHTTPHeaderField: "Content-Type") { onContentType?(ct) }
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        inflight += data.count
        if inflight > 8_000_000 && !suspended { suspended = true; dataTask.suspend() }
        lock.unlock()
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { dataTask.cancel(); self.conn.cancel(); return }
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
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [conn] _ in conn.cancel() })
    }
}
