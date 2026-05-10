import Foundation
import Network
import OSLog

/// Minimal HTTP/1.1 server bound to 127.0.0.1 on a kernel-assigned port.
///
/// Two routing classes:
///   - Static: anything not under /api, /ws, /blob is served from the bundled
///     web resources at `Bundle.main/web/`.
///   - Proxy slot: /api/*, /ws, /blob* will be forwarded to motifd over the
///     tailnet in P3. For now they return 503 so the WebView surfaces a clean
///     "backend not connected" instead of a confusing failure.
actor LocalHTTPServer {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "LocalHTTPServer")
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "io.allsunday.motif.localhttp")
    private let webRoot: URL
    private let proxy: TailscaleProxy?

    enum ServerError: Error, CustomStringConvertible {
        case missingWebBundle
        case listenerFailed(String)

        var description: String {
            switch self {
            case .missingWebBundle:
                return "web resources missing from app bundle (run scripts/sync-web.sh)"
            case .listenerFailed(let m):
                return "listener failed: \(m)"
            }
        }
    }

    init(proxy: TailscaleProxy? = nil) {
        self.proxy = proxy
        if let url = Bundle.main.url(forResource: "web", withExtension: nil) {
            self.webRoot = url
        } else {
            self.webRoot = Bundle.main.bundleURL.appendingPathComponent("web", isDirectory: true)
        }
    }

    /// Starts the listener. Returns the bound port on success.
    func start() async throws -> UInt16 {
        guard FileManager.default.fileExists(atPath: webRoot.path) else {
            throw ServerError.missingWebBundle
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .init("127.0.0.1"), port: .any
        )

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.handle(connection: connection) }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            // NWListener.stateUpdateHandler is invoked on `queue` (serial), so we
            // can null it out from inside the closure to guarantee the
            // continuation is resumed at most once.
            listener.stateUpdateHandler = { [weak listener] state in
                switch state {
                case .ready:
                    listener?.stateUpdateHandler = nil
                    let port = listener?.port?.rawValue ?? 0
                    cont.resume(returning: port)
                case .failed(let err):
                    listener?.stateUpdateHandler = nil
                    cont.resume(throwing: ServerError.listenerFailed(String(describing: err)))
                case .cancelled:
                    listener?.stateUpdateHandler = nil
                    cont.resume(throwing: ServerError.listenerFailed("cancelled before ready"))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) async {
        connection.start(queue: queue)
        await readRequest(on: connection, accumulated: Data())
    }

    private func readRequest(on connection: NWConnection, accumulated: Data) async {
        // Read up to header terminator. Static GETs have no body so we can stop there.
        let chunk: Data? = await withCheckedContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
                if error != nil { cont.resume(returning: nil); return }
                cont.resume(returning: data)
            }
        }

        guard let chunk, !chunk.isEmpty else {
            connection.cancel()
            return
        }
        var buffer = accumulated
        buffer.append(chunk)

        guard let headerEnd = buffer.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            if buffer.count > 64 * 1024 {
                send(connection: connection, status: 431, statusText: "Request Header Fields Too Large", body: Data())
                return
            }
            await readRequest(on: connection, accumulated: buffer)
            return
        }

        let head = buffer[..<headerEnd.lowerBound]
        guard let headStr = String(data: head, encoding: .utf8) else {
            send(connection: connection, status: 400, statusText: "Bad Request", body: Data())
            return
        }

        let lines = headStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            send(connection: connection, status: 400, statusText: "Bad Request", body: Data())
            return
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            send(connection: connection, status: 400, statusText: "Bad Request", body: Data())
            return
        }
        let method = String(parts[0])
        let target = String(parts[1])

        log.debug("\(method, privacy: .public) \(target, privacy: .public)")

        let path = pathOnly(from: target)
        if isProxyPath(path) {
            if let proxy {
                // Hand the connection off to the tsnet proxy along with the
                // bytes we already read (request head + maybe partial body).
                Task.detached {
                    await proxy.handle(connection: connection, pendingHead: buffer)
                }
            } else {
                sendProxyPlaceholder(connection: connection)
            }
            return
        }

        if method != "GET" && method != "HEAD" {
            send(connection: connection, status: 405, statusText: "Method Not Allowed", body: Data())
            return
        }

        serveStatic(connection: connection, path: path, headOnly: method == "HEAD")
    }

    // MARK: - Routing helpers

    private func pathOnly(from target: String) -> String {
        if let q = target.firstIndex(of: "?") {
            return String(target[..<q])
        }
        return target
    }

    private func isProxyPath(_ path: String) -> Bool {
        return path == "/ws"
            || path.hasPrefix("/ws/")
            || path.hasPrefix("/api/")
            || path == "/blob"
            || path.hasPrefix("/blob/")
            || path.hasPrefix("/blob?")
    }

    private func sendProxyPlaceholder(connection: NWConnection) {
        let body = Data("backend not connected — Tailscale proxy not yet wired up\n".utf8)
        send(
            connection: connection,
            status: 503,
            statusText: "Service Unavailable",
            body: body,
            extraHeaders: ["Content-Type": "text/plain; charset=utf-8"]
        )
    }

    // MARK: - Static file serving

    private func serveStatic(connection: NWConnection, path: String, headOnly: Bool) {
        var rel = path
        if rel == "/" || rel.isEmpty { rel = "/index.html" }

        // Reject directory traversal.
        if rel.contains("..") {
            send(connection: connection, status: 400, statusText: "Bad Request", body: Data())
            return
        }

        let trimmed = rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
        let fileURL = webRoot.appendingPathComponent(trimmed)

        // Ensure resolved path stays under webRoot (defense in depth).
        let resolvedRoot = webRoot.standardizedFileURL.path
        let resolvedFile = fileURL.standardizedFileURL.path
        if !resolvedFile.hasPrefix(resolvedRoot) {
            send(connection: connection, status: 403, statusText: "Forbidden", body: Data())
            return
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedFile, isDirectory: &isDir),
              !isDir.boolValue,
              let data = try? Data(contentsOf: fileURL)
        else {
            // Fall back to index.html for SPA-style deep links — except for asset paths.
            if !trimmed.hasPrefix("assets/") {
                let fallback = webRoot.appendingPathComponent("index.html")
                if let data = try? Data(contentsOf: fallback) {
                    send(
                        connection: connection,
                        status: 200,
                        statusText: "OK",
                        body: headOnly ? Data() : data,
                        extraHeaders: ["Content-Type": "text/html; charset=utf-8"],
                        bodyLength: data.count
                    )
                    return
                }
            }
            send(connection: connection, status: 404, statusText: "Not Found", body: Data())
            return
        }

        let contentType = mimeType(for: fileURL.pathExtension.lowercased())
        send(
            connection: connection,
            status: 200,
            statusText: "OK",
            body: headOnly ? Data() : data,
            extraHeaders: ["Content-Type": contentType],
            bodyLength: data.count
        )
    }

    private func mimeType(for ext: String) -> String {
        switch ext {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs":   return "application/javascript; charset=utf-8"
        case "css":         return "text/css; charset=utf-8"
        case "json":        return "application/json; charset=utf-8"
        case "svg":         return "image/svg+xml"
        case "png":         return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":         return "image/gif"
        case "webp":        return "image/webp"
        case "ico":         return "image/x-icon"
        case "wasm":        return "application/wasm"
        case "woff":        return "font/woff"
        case "woff2":       return "font/woff2"
        case "ttf":         return "font/ttf"
        case "map":         return "application/json"
        case "txt":         return "text/plain; charset=utf-8"
        default:            return "application/octet-stream"
        }
    }

    // MARK: - Response writer

    private func send(
        connection: NWConnection,
        status: Int,
        statusText: String,
        body: Data,
        extraHeaders: [String: String] = [:],
        bodyLength: Int? = nil
    ) {
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Length: \(bodyLength ?? body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: no-store\r\n"
        for (k, v) in extraHeaders {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"

        var packet = Data(head.utf8)
        packet.append(body)

        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
