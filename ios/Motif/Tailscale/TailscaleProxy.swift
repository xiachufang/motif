import Foundation
import Network
import Darwin
import OSLog
@preconcurrency import TailscaleKit

/// Bidirectional TCP pump from an inbound NWConnection (the WKWebView's
/// HTTP/WS request) to a tsnet TCP socket dialed at the configured motifd
/// address. The two streams are tunneled byte-for-byte, so HTTP/1.1
/// keep-alive, WebSocket upgrades, and arbitrary binary blob fetches all
/// pass through transparently.
///
/// LocalHTTPServer hands off the connection here when a proxy-route path
/// is detected; we own and close it.
actor TailscaleProxy {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "TailscaleProxy")
    private weak var manager: TailscaleManager?
    private let serverProvider: @Sendable () async -> MotifServer?

    init(manager: TailscaleManager, serverProvider: @escaping @Sendable () async -> MotifServer?) {
        self.manager = manager
        self.serverProvider = serverProvider
    }

    /// Take ownership of `connection`, dial the active motifd via tsnet,
    /// inject an `Authorization: Bearer <token>` header into the request
    /// head, send it upstream, then pump bidirectionally until either side
    /// EOFs.
    func handle(connection: NWConnection, pendingHead: Data) async {
        guard let server = await serverProvider() else {
            sendErrorAndClose(connection, status: 503, body: "no active motif server (Settings → Servers)")
            return
        }

        guard let handle = await manager?.tailscaleHandle else {
            sendErrorAndClose(connection, status: 503, body: "Tailscale not running (Settings → Tailscale)")
            return
        }

        // Inject Authorization: Bearer <token> into the inbound HTTP head.
        // motifd verifies this on the WS upgrade — it doesn't accept the
        // motif-web style `auth.login` first-frame, so the iOS WebView
        // (which can't set headers itself) relies on us doing it here.
        let outbound: Data
        do {
            outbound = try Self.injectAuthorization(into: pendingHead, token: server.token)
        } catch {
            log.error("inject Authorization: \(String(describing: error), privacy: .public)")
            sendErrorAndClose(connection, status: 400, body: "malformed request head")
            return
        }

        let address = server.endpoint
        let fd: Int32
        do {
            fd = try await Self.dial(handle: handle, address: address)
        } catch {
            log.error("dial \(address, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            sendErrorAndClose(connection, status: 502, body: "tsnet dial failed: \(error)")
            return
        }

        log.notice("proxy: \(server.name, privacy: .public)@\(address, privacy: .public) (fd \(fd, privacy: .public)) — \(outbound.count, privacy: .public)B head")

        if !Self.writeAll(fd: fd, data: outbound) {
            log.error("replaying head failed")
            Darwin.close(fd)
            connection.cancel()
            return
        }

        // Now pump bidirectionally. NWConnection delivers events on a queue;
        // we drive it from a Task. The fd-side pump runs on a Dispatch queue
        // (blocking read in a background thread).
        let cancelBox = CancelBox()

        // inbound -> fd
        Task.detached { [log] in
            await Self.pumpInboundToFd(connection: connection, fd: fd, cancelBox: cancelBox, log: log)
        }
        // fd -> outbound
        Task.detached { [log] in
            await Self.pumpFdToInbound(fd: fd, connection: connection, cancelBox: cancelBox, log: log)
        }
    }

    // MARK: - Helpers

    private nonisolated func sendErrorAndClose(_ connection: NWConnection, status: Int, body: String) {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(status) Bad Gateway\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Connection: close\r\n\r\n"
        var packet = Data(head.utf8)
        packet.append(bodyData)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Replace (or insert) the `Authorization` header in an HTTP/1.x request
    /// head. The input must contain a complete header section terminated by
    /// `\r\n\r\n`; LocalHTTPServer guarantees this for the bytes it hands us.
    /// Anything after the terminator is preserved as a request body prefix.
    static func injectAuthorization(into pendingHead: Data, token: String) throws -> Data {
        guard let split = pendingHead.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) else {
            throw ProxyError.malformedHead
        }
        let head = pendingHead[..<split.lowerBound]
        let body = pendingHead[split.upperBound...]
        guard let headStr = String(data: head, encoding: .utf8) else {
            throw ProxyError.malformedHead
        }
        var lines = headStr.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw ProxyError.malformedHead }
        // Drop any pre-existing Authorization header (case-insensitive).
        // Keep the request line at index 0 untouched.
        lines = [lines[0]] + lines.dropFirst().filter {
            !$0.lowercased().hasPrefix("authorization:")
        }
        lines.append("Authorization: Bearer \(token)")
        var rebuilt = Data(lines.joined(separator: "\r\n").utf8)
        rebuilt.append(contentsOf: [0x0D, 0x0A, 0x0D, 0x0A])
        rebuilt.append(body)
        return rebuilt
    }

    /// Synchronous tailscale_dial executed off the listener queue.
    private static func dial(handle: Int32, address: String) async throws -> Int32 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var conn: Int32 = 0
                let res = address.withCString { addr in
                    "tcp".withCString { proto in
                        tailscale_dial(handle, proto, addr, &conn)
                    }
                }
                if res == 0 {
                    cont.resume(returning: conn)
                } else {
                    cont.resume(throwing: ProxyError.dialFailed(rc: res))
                }
            }
        }
    }

    private static func writeAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            let total = raw.count
            while off < total {
                let n = Darwin.write(fd, base.advanced(by: off), total - off)
                if n <= 0 {
                    if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                    return false
                }
                off += n
            }
            return true
        }
    }

    private static func pumpInboundToFd(
        connection: NWConnection,
        fd: Int32,
        cancelBox: CancelBox,
        log: Logger
    ) async {
        while await !cancelBox.cancelled {
            let chunk: Data? = await withCheckedContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, isComplete, err in
                    if let err {
                        log.error("inbound recv: \(String(describing: err), privacy: .public)")
                        cont.resume(returning: nil); return
                    }
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(returning: nil)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            guard let chunk else {
                log.debug("inbound EOF")
                await cancelBox.cancel()
                Darwin.shutdown(fd, SHUT_WR)
                connection.cancel()
                return
            }
            if chunk.isEmpty { continue }
            if !writeAll(fd: fd, data: chunk) {
                log.error("write to fd failed: \(String(cString: strerror(errno)), privacy: .public)")
                await cancelBox.cancel()
                Darwin.close(fd)
                connection.cancel()
                return
            }
        }
        Darwin.close(fd)
        connection.cancel()
    }

    private static func pumpFdToInbound(
        fd: Int32,
        connection: NWConnection,
        cancelBox: CancelBox,
        log: Logger
    ) async {
        let bufSize = 32 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 1)
        defer { buf.deallocate() }

        while await !cancelBox.cancelled {
            // Block on read in a global queue so we don't stall actors.
            let n: Int = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let r = Darwin.read(fd, buf, bufSize)
                    cont.resume(returning: r)
                }
            }
            if n < 0 {
                if errno == EINTR { continue }
                log.error("read from fd failed: \(String(cString: strerror(errno)), privacy: .public)")
                await cancelBox.cancel()
                connection.cancel()
                Darwin.close(fd)
                return
            }
            if n == 0 {
                log.debug("upstream EOF")
                await cancelBox.cancel()
                connection.cancel()
                Darwin.close(fd)
                return
            }
            let chunk = Data(bytes: buf, count: n)
            let sent: Bool = await withCheckedContinuation { cont in
                connection.send(content: chunk, completion: .contentProcessed { err in
                    cont.resume(returning: err == nil)
                })
            }
            if !sent {
                log.debug("inbound send failed")
                await cancelBox.cancel()
                connection.cancel()
                Darwin.close(fd)
                return
            }
        }
    }

    enum ProxyError: Error, CustomStringConvertible {
        case dialFailed(rc: Int32)
        case malformedHead
        var description: String {
            switch self {
            case .dialFailed(let rc): return "tailscale_dial returned \(rc)"
            case .malformedHead:      return "malformed HTTP head (no \\r\\n\\r\\n)"
            }
        }
    }
}

/// Tiny actor wrapping a Bool so the two pump tasks can race-safely cancel
/// each other.
actor CancelBox {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

// MARK: - Manager extension

extension TailscaleManager {
    /// Expose the underlying tsnet handle for low-level callers (the
    /// reverse proxy needs it to call `tailscale_dial` directly so it can
    /// own the resulting fd, which OutgoingConnection's API hides).
    var tailscaleHandle: Int32? {
        get async {
            // node is private; expose via a helper.
            return await currentTailscaleHandle()
        }
    }
}
