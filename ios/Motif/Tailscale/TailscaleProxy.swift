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
    private let addressProvider: @Sendable () -> String

    init(manager: TailscaleManager, addressProvider: @escaping @Sendable () -> String) {
        self.manager = manager
        self.addressProvider = addressProvider
    }

    /// Take ownership of `connection`, dial motifd via tsnet, replay the
    /// bytes already read, then pump bidirectionally until either side EOFs.
    func handle(connection: NWConnection, pendingHead: Data) async {
        let motifdAddress = addressProvider().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !motifdAddress.isEmpty else {
            sendErrorAndClose(connection, status: 503, body: "motifd address not configured (Settings → motifd 地址)")
            return
        }

        guard let handle = await manager?.tailscaleHandle else {
            sendErrorAndClose(connection, status: 503, body: "Tailscale not running (Settings → Tailscale)")
            return
        }

        // tailscale_dial blocks until the conn is established; do it on a
        // background queue so we don't stall the listener queue.
        let fd: Int32
        do {
            fd = try await Self.dial(handle: handle, address: motifdAddress)
        } catch {
            log.error("dial \(motifdAddress, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            sendErrorAndClose(connection, status: 502, body: "tsnet dial failed: \(error)")
            return
        }

        log.notice("proxy: \(motifdAddress, privacy: .public) (fd \(fd, privacy: .public)) — \(pendingHead.count, privacy: .public)B head")

        // Replay the bytes we already read off the inbound connection so
        // motifd sees the full request.
        if !pendingHead.isEmpty {
            if !Self.writeAll(fd: fd, data: pendingHead) {
                log.error("replaying head failed")
                Darwin.close(fd)
                connection.cancel()
                return
            }
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
                    if err != nil { cont.resume(returning: nil); return }
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
        var description: String {
            switch self {
            case .dialFailed(let rc): return "tailscale_dial returned \(rc)"
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
