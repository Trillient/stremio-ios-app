import Foundation
import Network

/// Loopback HTTP proxy for native playback.
///
/// libvlc in this build cannot be made to send the site's SSO cookie, so VLC
/// fetches from 127.0.0.1 instead and we forward each request to the origin
/// with the cookie attached, relaying status, Range/206 and the body so seeking
/// works exactly as it would against the origin.
final class StreamProxy {
    static let shared = StreamProxy()

    private struct Route { let origin: URL; let cookie: String? }
    private var routes: [String: Route] = [:]
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "dev.woolston.stremio.proxy")
    private let lock = NSLock()

    /// Returns the loopback URL VLC should open for `origin`.
    func register(origin: URL, cookie: String?) -> URL {
        startIfNeeded()
        let token = UUID().uuidString
        lock.lock(); routes[token] = Route(origin: origin, cookie: cookie); lock.unlock()
        return URL(string: "http://127.0.0.1:\(port)/\(token)")!
    }

    private func startIfNeeded() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let l = try? NWListener(using: params) else {
            NSLog("[STREMIOAPP][proxy] failed to create listener"); return
        }
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = l.port?.rawValue ?? 0
                ready.signal()
            case .failed(let err):
                NSLog("[STREMIOAPP][proxy] listener failed: %@", err.localizedDescription)
                ready.signal()
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
        let token = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        lock.lock(); let route = routes[token]; lock.unlock()
        guard let route else {
            conn.send(content: Data("HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8),
                      completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        var req = URLRequest(url: route.origin)
        req.httpMethod = (method == "HEAD") ? "HEAD" : "GET"
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "range" { req.setValue(value, forHTTPHeaderField: "Range") }
        }
        if let cookie = route.cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        req.setValue("StremioApp/1.0", forHTTPHeaderField: "User-Agent")
        NSLog("[STREMIOAPP][proxy] %@ range=%@", method, req.value(forHTTPHeaderField: "Range") ?? "-")

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 24 * 3600
        let relay = Relay(conn: conn, request: req, config: config)
        relay.start()
    }
}

/// Streams one origin response back over one client connection.
///
/// Cold torrents: the streaming server can't answer until it has the first
/// pieces, and the edge returns 504 meanwhile. Rather than surfacing that to
/// VLC (which gives up after 3 tries), hold the client connection and keep
/// re-asking the origin until it produces data — so a slow start looks like
/// buffering, not a dead stream. Simple backpressure suspends the origin task
/// when VLC falls behind.
private final class Relay: NSObject, URLSessionDataDelegate {
    private let conn: NWConnection
    private let request: URLRequest
    private let session: URLSession
    private var task: URLSessionDataTask?

    private let lock = NSLock()
    private var inflight = 0
    private var suspended = false
    private var headWritten = false
    private var retrying = false
    private var attempts = 0
    private let maxAttempts = 45          // ~2.5 min at 3 s spacing
    private let retryDelay: TimeInterval = 3

    init(conn: NWConnection, request: URLRequest, config: URLSessionConfiguration) {
        self.conn = conn
        self.request = request
        self.session = URLSession(configuration: config, delegate: nil, delegateQueue: nil)
        super.init()
    }

    func start() {
        attempts += 1
        // A fresh session per attempt keeps delegate callbacks unambiguous.
        let s = URLSession(configuration: session.configuration, delegate: self, delegateQueue: nil)
        task = s.dataTask(with: request)
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
        switch http.statusCode { case 200: reason = "OK"; case 206: reason = "Partial Content"; default: reason = "Status" }
        var head = "HTTP/1.1 \(http.statusCode) \(reason)\r\n"
        let passthrough: Set<String> = ["content-type", "content-length", "content-range", "accept-ranges", "last-modified", "etag"]
        for (k, v) in http.allHeaderFields {
            let key = "\(k)"
            if passthrough.contains(key.lowercased()) { head += "\(key): \(v)\r\n" }
        }
        head += "Connection: close\r\n\r\n"
        NSLog("[STREMIOAPP][proxy] origin %d type=%@ range=%@ len=%@ (attempt %d)",
              http.statusCode,
              http.value(forHTTPHeaderField: "Content-Type") ?? "-",
              http.value(forHTTPHeaderField: "Content-Range") ?? "-",
              http.value(forHTTPHeaderField: "Content-Length") ?? "-", attempts)
        headWritten = true
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
        if retrying { return }                          // we cancelled it ourselves; retry is scheduled
        if !headWritten {
            if let error, attempts < maxAttempts {      // timeout / transport hiccup before any data
                scheduleRetry(reason: error.localizedDescription)
                return
            }
            fail(504, "Stream did not start")
            return
        }
        if let error { NSLog("[STREMIOAPP][proxy] origin ended: %@", error.localizedDescription) }
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                  completion: .contentProcessed { [conn] _ in conn.cancel() })
    }
}
