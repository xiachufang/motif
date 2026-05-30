import Darwin
import Foundation
import Network
import OSLog
import TalkerCommonLogging
@preconcurrency import TailscaleKit

// Outgoing connections: dialling peers, building the SOCKS5 URLSession,
// and the motifd /ping + raw-HTTP diagnostic probes.
extension TailscaleManager {
    /// Open a TCP connection to a peer on the tailnet. The caller owns the
    /// returned `OutgoingConnection` and is responsible for closing it.
    func dial(host: String, port: UInt16) async throws -> OutgoingConnection {
        guard let node, let handle = await node.tailscale else {
            throw DialError.notRunning
        }
        let address = "\(host):\(port)"
        let conn = try await OutgoingConnection(
            tailscale: handle,
            to: address,
            proto: .tcp,
            logger: SilentLogger()
        )
        try await conn.connect()
        return conn
    }

    /// Internal helper for TailscaleProxy to grab the C handle for direct
    /// `tailscale_dial` use (we need the raw fd for bidi byte pumping).
    func currentTailscaleHandle() async -> Int32? {
        await node?.tailscale
    }

    /// Build a URLSessionConfiguration that routes all traffic through this
    /// tsnet node's loopback SOCKS5 proxy. URLSession's CONNECT-proxy path
    /// turns out to swallow plain `ws://` targets with no upgrade response
    /// (CONNECT historically tunnels TLS); SOCKS5 has neither restriction.
    /// We pair this with `resolveTailnetHost` so MagicDNS names get
    /// rewritten to a 100.x IP before the SOCKS5 dial — URLSession resolves
    /// hostnames locally for SOCKS5.
    func makeURLSessionConfiguration() async throws -> URLSessionConfiguration {
        guard let node else { throw DialError.notRunning }
        let loopback = try await node.loopback()
        guard let ipStr = loopback.ip,
              let port = loopback.port,
              let portU16 = UInt16(exactly: port) else {
            log.error("loopback returned bad address: \(String(describing: loopback), privacy: .public)")
            throw DialError.notRunning
        }
        log.notice("tsnet loopback proxy at \(ipStr, privacy: .public):\(portU16, privacy: .public) (cred=\(loopback.proxyCredential.prefix(6), privacy: .public)…)")
        infoLog("[Tailscale] loopback socks5 \(ipStr):\(portU16) cred=\(loopback.proxyCredential.prefix(6))…")
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ipStr),
                                            port: NWEndpoint.Port(rawValue: portU16)!)
        let proxy = ProxyConfiguration(socksv5Proxy: endpoint)
        proxy.applyCredential(username: "tsnet", password: loopback.proxyCredential)
        let config = URLSessionConfiguration.default
        config.proxyConfigurations = [proxy]
        return config
    }

    /// Convenience wrapper for callers that don't need a URLSessionDelegate.
    func makeURLSession() async throws -> URLSession {
        let config = try await makeURLSessionConfiguration()
        return URLSession(configuration: config)
    }

    enum MotifPingResult: Equatable, Sendable {
        case reachable(version: String)
        case unreachable(message: String)

        var isReachable: Bool {
            if case .reachable = self { return true }
            return false
        }
    }

    /// Probe motifd's unauthenticated `/ping` endpoint through the same
    /// Tailscale URLSession path the app uses for real connections.
    func pingMotifServer(host: String, port: UInt16, timeout: TimeInterval = 5) async -> MotifPingResult {
        guard case .running = state else {
            return .unreachable(message: "Tailscale off")
        }

        let resolvedHost = await resolveTailnetHost(host) ?? host
        guard let url = URL(string: "http://\(resolvedHost):\(port)/ping") else {
            return .unreachable(message: "Bad address")
        }

        let config: URLSessionConfiguration
        do {
            config = try await makeURLSessionConfiguration()
        } catch {
            return .unreachable(message: "Tailscale off")
        }
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = timeout

        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable(message: "No HTTP response")
            }
            guard (200...299).contains(http.statusCode) else {
                return .unreachable(message: "HTTP \(http.statusCode)")
            }
            let info = try JSONDecoder().decode(MotifProto.PingInfo.self, from: data)
            guard info.isMotifServer else {
                return .unreachable(message: "Not motifd")
            }
            return .reachable(version: info.version)
        } catch {
            return .unreachable(message: Self.pingFailureMessage(error))
        }
    }

    private static func pingFailureMessage(_ error: any Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .timedOut:
                return "No response"
            case .cannotFindHost:
                return "Host not found"
            case .cannotConnectToHost:
                return "Port closed"
            case .networkConnectionLost:
                return "Connection lost"
            case .badURL:
                return "Cannot open /ping"
            default:
                break
            }
        }
        return "Ping failed"
    }

    /// Diagnostic probe: dial host:port via `tailscale_dial` directly (no
    /// URLSession, no SOCKS5), write a minimal HTTP/1.1 `GET <path>`, and
    /// read the first response chunk. Returns the response status line
    /// and total bytes read so we can tell whether the tailnet path can
    /// carry a plain-HTTP request end-to-end. Used to isolate "URLSession
    /// SOCKS5 is wedged" from "the tsnet HTTP path itself is broken".
    struct RawHttpProbeResult: Sendable {
        var statusLine: String?
        var bytesRead: Int
        var elapsedMs: Int
        var error: String?
    }
    func rawHttpProbe(host: String, port: UInt16, path: String = "/", timeoutMs: Int = 10000) async -> RawHttpProbeResult {
        guard let node, let handle = await node.tailscale else {
            return RawHttpProbeResult(statusLine: nil, bytesRead: 0, elapsedMs: 0, error: "tsnet not running")
        }
        let start = Date()
        return await Task.detached(priority: .utility) {
            var conn: tailscale_conn = 0
            let addr = "\(host):\(port)"
            let dialRes = addr.withCString { cAddr in
                "tcp".withCString { cProto in
                    tailscale_dial(handle, cProto, cAddr, &conn)
                }
            }
            if dialRes != 0 {
                var errBuf = [CChar](repeating: 0, count: 256)
                _ = tailscale_errmsg(handle, &errBuf, 256)
                let nulIdx = errBuf.firstIndex(of: 0) ?? errBuf.endIndex
                let msg = String(decoding: errBuf[..<nulIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return RawHttpProbeResult(statusLine: nil, bytesRead: 0, elapsedMs: elapsed,
                                          error: "dial failed: \(msg) (rc=\(dialRes))")
            }
            defer { Darwin.close(conn) }
            // Set a recv timeout so we don't block forever on a wedged socket.
            var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
            _ = setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(conn, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let req = "GET \(path) HTTP/1.1\r\nHost: \(host):\(port)\r\nUser-Agent: motif-probe/1\r\nConnection: close\r\n\r\n"
            let data = Data(req.utf8)
            let w = data.withUnsafeBytes { ptr -> Int in
                Darwin.write(conn, ptr.baseAddress!, data.count)
            }
            if w != data.count {
                let elapsed = Int(Date().timeIntervalSince(start) * 1000)
                return RawHttpProbeResult(statusLine: nil, bytesRead: 0, elapsedMs: elapsed,
                                          error: "short write \(w)/\(data.count) errno=\(errno)")
            }
            let cap = 1024
            var buf = [UInt8](repeating: 0, count: cap)
            var total = 0
            // Read until we have at least one full line or hit timeout/EOF.
            while total < cap {
                let remaining = cap - total
                let offset = total
                let n = buf.withUnsafeMutableBytes { p -> Int in
                    Darwin.read(conn, p.baseAddress!.advanced(by: offset), remaining)
                }
                if n <= 0 { break }
                total += n
                if buf[..<total].contains(UInt8(ascii: "\n")) { break }
            }
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            if total == 0 {
                return RawHttpProbeResult(statusLine: nil, bytesRead: 0, elapsedMs: elapsed,
                                          error: "read returned 0 bytes errno=\(errno)")
            }
            let firstLine: String? = {
                let prefix = Array(buf[..<total])
                if let nlIdx = prefix.firstIndex(of: UInt8(ascii: "\n")) {
                    var line = Array(prefix[..<nlIdx])
                    if line.last == UInt8(ascii: "\r") { line.removeLast() }
                    return String(bytes: line, encoding: .utf8)
                }
                return String(bytes: prefix, encoding: .utf8)
            }()
            return RawHttpProbeResult(statusLine: firstLine, bytesRead: total, elapsedMs: elapsed, error: nil)
        }.value
    }

    enum DialError: Error, CustomStringConvertible {
        case notRunning
        var description: String { "Tailscale node not running" }
    }
}
