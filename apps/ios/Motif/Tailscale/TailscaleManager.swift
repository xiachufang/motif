import Darwin
import Foundation
import Network
import Observation
import OSLog
import TalkerCommonLogging
@preconcurrency import TailscaleKit

/// Owns the lifecycle of a single TailscaleNode + its IPN bus subscription.
///
/// Public surface:
///   - `state` (observable) — UI watches this
///   - `start(authKey:)` — bring the node up; pass an auth-key for headless
///     login, or nil to use interactive web auth (we'll surface the URL via
///     `state = .needsAuth(url:)`).
///   - `stop()` — bring the node down
///   - `dial(host:port:)` — open a TCP connection to a peer on the tailnet
@MainActor
@Observable
final class TailscaleManager {
    enum State: Equatable {
        case stopped
        case starting
        case needsAuth(url: URL)
        case running(ipv4: String?, ipv6: String?)
        /// Node is up from tsnet's point of view but the tailnet datapath
        /// is currently unusable (control-plane offline / health warning).
        /// Distinct from `.running` so the dial gate and UI can react, and
        /// distinct from `.failed` because tsnet is still trying and we
        /// expect to recover without a fresh `start()`. See `revalidate()`.
        case degraded(reason: String)
        case failed(message: String)
    }

    private(set) var state: State = .stopped
    private(set) var hostName: String

    /// User-chosen control plane. Empty → Tailscale SaaS (`kDefaultControlURL`).
    /// A tsnet node joins exactly one control plane, so this is an app-global
    /// setting (not per-server). Persisted in UserDefaults; read at init and
    /// applied on the next `start()`.
    private(set) var controlURL: String
    /// The control plane the live / in-flight node was started against
    /// (resolved, never empty). Lets `start()` notice a plane change while a
    /// node is already running and rebuild against the new one.
    private var activeControlURL: String?
    private static let controlURLDefaultsKey = "tailscaleControlURL"

    private let log = Logger(subsystem: "io.allsunday.motif", category: "Tailscale")
    private var node: TailscaleNode?
    private var apiClient: LocalAPIClient?
    private var busProcessor: MessageProcessor?
    private var busConsumer: BusConsumer?
    /// True once we've pushed startLoginInteractive for the current node
    /// instance, so an Up()-driven NeedsLogin doesn't ask the user for a
    /// fresh login URL on every bus tick.
    private var loginInteractivePushed: Bool = false

    /// Polls `backendStatus()` while we believe the datapath is down so we
    /// can flip `.degraded` back to `.running` once tsnet reconnects. Only
    /// alive during a `.degraded` window — nil otherwise. See `revalidate()`.
    private var healthMonitorTask: Task<Void, Never>?
    /// Last `EngineStatus.NumLive` seen on the IPN bus. A >0→0 edge is a
    /// cheap hint that connectivity dropped; we confirm via the LocalAPI
    /// rather than trusting it alone (idle peers fall out of the live set).
    private var lastNumLive: Int?

    /// Count of consecutive `backendStatus()` throws. A probe that *succeeds*
    /// (even one reporting the datapath down) resets this. It distinguishes
    /// "datapath flapping but LocalAPI alive" (recovers via polling) from
    /// "LocalAPI listener is dead" — the latter throws ECONNREFUSED on lo0
    /// after a long app suspend and never recovers by polling, because the
    /// thing we poll is gone. See `checkHealthOnce` / `restartNode`.
    private var consecutiveProbeFailures = 0
    /// Re-entrancy guard for `restartNode`: `checkHealthOnce` can fire from
    /// the monitor loop, the NumLive edge, and foreground revalidate.
    private var isRestarting = false
    /// Consecutive probe throws that mean the LocalAPI is gone (not a one-off
    /// blip) and we should rebuild the node rather than keep polling.
    private static let probeFailureRestartThreshold = 3

    init(hostName: String = "motif-ios") {
        self.hostName = hostName
        self.controlURL = UserDefaults.standard.string(forKey: Self.controlURLDefaultsKey) ?? ""
    }

    /// Update the control plane (empty → Tailscale SaaS). Persisted. Takes
    /// effect on the next `start()`; if a node is already running on a
    /// different plane, `start()` tears it down and rebuilds against this one.
    func setControlURL(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != controlURL else { return }
        controlURL = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.controlURLDefaultsKey)
        log.notice("control URL set (custom=\(trimmed.isEmpty ? "no" : "yes", privacy: .public))")
    }

    /// Persistent state directory for tsnet node keys (survives app restarts).
    ///
    /// The default control plane (Tailscale SaaS) keeps the legacy top-level
    /// `Documents/tailscale` dir so existing installs resume from cached creds
    /// on upgrade. A custom (Headscale) plane gets an isolated subdir keyed by
    /// a stable hash of its URL — creds never collide with SaaS, and switching
    /// back and forth doesn't force a re-login.
    private static func statePath(for controlURL: String) -> String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var dir = docs.appendingPathComponent("tailscale", isDirectory: true)
        if controlURL != kDefaultControlURL {
            dir.appendPathComponent("ctl-\(stableHash(controlURL))", isDirectory: true)
        }
        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Logger(subsystem: "io.allsunday.motif", category: "Tailscale")
                    .error("createDirectory \(dir.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        return dir.path
    }

    /// Deterministic FNV-1a 64-bit hash (hex). `String.hashValue` is salted
    /// per process, so it can't name a directory that must be stable across
    /// launches — this can.
    private static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3
        }
        return String(h, radix: 16)
    }

    /// Start the node. Idempotent — calling while running is a no-op.
    /// `authKey` skips the interactive login round-trip; pass nil to go through
    /// web auth (we'll publish the BrowseToURL we observe on the IPN bus).
    func start(authKey: String? = nil) async {
        let control = controlURL.isEmpty ? kDefaultControlURL : controlURL
        // Already up (or coming up): no-op if it's the same control plane;
        // otherwise the user switched planes (e.g. SaaS → Headscale) — tear the
        // old node down and rebuild against the new one below.
        switch state {
        case .running, .starting:
            if activeControlURL == control { return }
            log.notice("control plane changed; restarting node")
            await teardown()
        default:
            break
        }
        activeControlURL = control
        state = .starting

        let config = Configuration(
            hostName: hostName,
            path: Self.statePath(for: control),
            authKey: authKey,
            controlURL: control,
            ephemeral: false
        )

        do {
            let node = try TailscaleNode(config: config, logger: TsnetFileLogger())
            self.node = node

            // Spawn the IPN bus watcher BEFORE up() so we don't miss the first
            // BrowseToURL notification during web-auth.
            let api = LocalAPIClient(localNode: node, logger: nil)
            self.apiClient = api
            let consumer = BusConsumer(manager: self)
            self.busConsumer = consumer
            self.busProcessor = try await api.watchIPNBus(
                mask: [.initialState, .engineUpdates, .prefs, .netmap, .rateLimitNetmaps],
                consumer: consumer
            )
            log.notice("IPN bus subscribed")
            loginInteractivePushed = false

            // We do NOT eagerly call startLoginInteractive here. tsnet will
            // read the cached state directory (Documents/tailscale) and
            // either transition straight to .Running (cached creds still
            // valid — the common path on app relaunch) or hit .NeedsLogin
            // (fresh install / expired cred). Only in the second case will
            // busDidReceive push startLoginInteractive to surface the URL.
            //
            // Run `up()` in the background. We deliberately DO NOT flip
            // state = .running on its return — empirically `Server.Up`
            // returns once controlplane registers the node, which can be
            // a couple of seconds before the loopback proxy is actually
            // forwarding (tailnet engine still finishing wireguard /
            // DERP setup). The IPN bus `Notify: state=Running` is the
            // authoritative "ready" signal; busDidReceive flips state to
            // .running there.
            Task { [weak self] in
                do {
                    try await node.up()
                    self?.log.notice("node.up returned — waiting for IPN State=Running")
                } catch {
                    self?.log.error("node.up: \(String(describing: error), privacy: .public)")
                    self?.handleUpFailure(error)
                }
            }
            log.notice("Tailscale start kicked off (authKey=\(authKey == nil ? "no" : "yes", privacy: .public))")
        } catch {
            log.error("start failed: \(String(describing: error), privacy: .public)")
            state = .failed(message: String(describing: error))
            await teardown()
        }
    }

    /// Surface a `node.up()` failure as a UI-visible error, but only when we
    /// don't already have something more specific (e.g. needsAuth).
    private func handleUpFailure(_ error: any Error) {
        switch state {
        case .needsAuth, .running:
            // node.up() races with the bus. If the bus already published a
            // useful state, don't clobber it.
            break
        default:
            state = .failed(message: String(describing: error))
        }
    }

    func stop() async {
        await teardown()
        state = .stopped
    }

    private func teardown() async {
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
        lastNumLive = nil
        consecutiveProbeFailures = 0
        if let busProcessor {
            busProcessor.cancel()
        }
        busProcessor = nil
        busConsumer = nil
        apiClient = nil
        if let node {
            do {
                try await node.close()
            } catch {
                log.error("node.close: \(String(describing: error), privacy: .public)")
            }
        }
        node = nil
    }

    /// Refresh assigned IPs from the node and update `state`.
    private func refreshAddresses() async {
        guard let node else { return }
        do {
            let ips = try await node.addrs()
            state = .running(ipv4: ips.ip4, ipv6: ips.ip6)
            infoLog("[Tailscale] running ipv4=\(ips.ip4 ?? "nil") ipv6=\(ips.ip6 ?? "nil")")
        } catch {
            log.error("addrs failed: \(String(describing: error), privacy: .public)")
            infoLog("[Tailscale] addrs failed: \(error)")
        }
    }

    // MARK: - Datapath health

    /// Reconcile `state` with tsnet's actual view of tailnet reachability.
    ///
    /// libtailscale exposes no push event for a dropped datapath (the IPN
    /// `State` stays `.Running` through transient drops, and `Notify` has
    /// no health field), so the only way to notice a connection the system
    /// tore down — e.g. while the app was suspended in the background — is
    /// to ask the LocalAPI. Call this on foreground (`scenePhase` → active)
    /// and on a NumLive drop. No-op unless we believe the node is up.
    func revalidate() async {
        switch state {
        case .running, .degraded: break
        default:
            infoLog("[Tailscale] revalidate: skip (state=\(state))")
            return
        }
        infoLog("[Tailscale] revalidate: begin (state=\(state))")
        await checkHealthOnce()
    }

    /// One `backendStatus()` probe. Healthy → `.running` (with fresh IPs);
    /// unhealthy → `.degraded` and a recovery poll until tsnet comes back.
    private func checkHealthOnce() async {
        if isRestarting { return }
        guard let api = apiClient else {
            infoLog("[Tailscale] health probe: apiClient is nil — cannot probe (state=\(state))")
            return
        }
        let healthy: Bool
        let reason: String
        var probeThrew = false
        do {
            let status = try await api.backendStatus()
            let online = status.SelfStatus?.Online ?? false
            healthy = status.BackendState == "Running" && online
            reason = status.Health?.first ?? "tailnet \(status.BackendState)"
            infoLog(
                "[Tailscale] health probe: backend=\(status.BackendState) online=\(online) "
                + "health=\(status.Health ?? []) numLive=\(lastNumLive.map(String.init) ?? "nil") "
                + "-> \(healthy ? "healthy" : "unhealthy")")
        } catch {
            healthy = false
            probeThrew = true
            reason = "status unavailable"
            infoLog("[Tailscale] health probe failed: \(error)")
        }

        // A successful probe — even one reporting the datapath down — proves
        // the LocalAPI is alive, so reset the dead-listener counter.
        consecutiveProbeFailures = probeThrew ? consecutiveProbeFailures + 1 : 0

        if healthy {
            let wasDegraded: Bool
            if case .running = state { wasDegraded = false } else { wasDegraded = true }
            stopHealthMonitor()
            // Avoid re-emitting `.running` (and its addr fetch) on every
            // healthy poll — only refresh when we're recovering from a
            // non-running state.
            if wasDegraded {
                infoLog("[Tailscale] health recovered (state=\(state)) -> running")
                await refreshAddresses()
            }
            return
        }

        let next = State.degraded(reason: reason)
        if state != next {
            state = next
            infoLog("[Tailscale] degraded: \(reason)")
        }

        // Two flavours of unhealthy:
        //  - LocalAPI reachable but datapath down (probe succeeded, online=
        //    false): tsnet re-establishes the tunnel on its own — keep polling.
        //  - LocalAPI unreachable N times running (probe keeps throwing, e.g.
        //    ECONNREFUSED on lo0 after a long suspend): the tsnet loopback
        //    listener is gone and polling it will never recover. Rebuild.
        if consecutiveProbeFailures >= Self.probeFailureRestartThreshold {
            infoLog(
                "[Tailscale] LocalAPI unreachable \(consecutiveProbeFailures)x — restarting node")
            await restartNode()
        } else {
            startHealthMonitor()
        }
    }

    /// Tear down and re-create the tsnet node in place. Used when the LocalAPI
    /// loopback listener has died (long app suspend) and passive polling can't
    /// recover it. Cached credentials in the state dir let `start()` resume
    /// without a fresh login. Existing tailnet connections drop; upper layers
    /// reconnect on their own.
    private func restartNode() async {
        guard !isRestarting else { return }
        isRestarting = true
        infoLog("[Tailscale] restartNode: tearing down")
        await teardown()  // also resets consecutiveProbeFailures
        infoLog("[Tailscale] restartNode: starting fresh node")
        // teardown() leaves state as-is (.degraded); start() guards only on
        // .running/.starting, so it proceeds and flips state to .starting.
        isRestarting = false
        await start(authKey: nil)
    }

    /// Spawn the recovery poll if it isn't already running. tsnet keeps
    /// trying to re-establish the tunnel on its own while the process is
    /// alive, so polling `backendStatus()` here is purely to observe that
    /// recovery and flip `state` back — no app traffic required.
    private func startHealthMonitor() {
        guard healthMonitorTask == nil else { return }
        infoLog("[Tailscale] health monitor: started (poll every 3s)")
        healthMonitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                tick += 1
                infoLog("[Tailscale] health monitor: poll #\(tick)")
                await self.checkHealthOnce()
            }
            infoLog("[Tailscale] health monitor: loop exited (cancelled)")
        }
    }

    private func stopHealthMonitor() {
        if healthMonitorTask != nil {
            infoLog("[Tailscale] health monitor: stopped")
        }
        healthMonitorTask?.cancel()
        healthMonitorTask = nil
    }

    // MARK: - Outgoing connections

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

    /// Resolve a tailnet hostname (MagicDNS short name or full FQDN) to a
    /// concrete tailnet IP by walking the IPN peer list. iOS's stub
    /// resolver doesn't know `*.ts.net`, and URLSession's SOCKS5 path
    /// resolves hostnames locally before tunnelling — so dialling
    /// `ws://something.ts.net:port` blows up with NSURLErrorNetworkConnectionLost
    /// (-1005) the moment the SOCKS handshake tries to forward the
    /// resolved-but-bogus IP. Pre-resolving here keeps the WS open.
    ///
    /// Inputs that already look like an IP (digits + dots, or a colon)
    /// are returned unchanged. If no peer matches, returns nil — caller
    /// should fall back to the original string.
    func resolveTailnetHost(_ host: String) async -> String? {
        if Self.looksLikeIP(host) { return host }
        let peers = await discoverPeers()
        let normalized = host.lowercased()
        for peer in peers {
            let dns = peer.dnsName.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let shortName = peer.hostname.lowercased()
            if dns == normalized || dns.hasPrefix("\(normalized).") || shortName == normalized {
                if let ip = peer.primaryIP { return ip }
            }
        }
        return nil
    }

    private static func looksLikeIP(_ s: String) -> Bool {
        if s.contains(":") { return true } // very rough IPv6 sniff
        let parts = s.split(separator: ".")
        if parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return true }
        return false
    }

    // MARK: - Discovery

    /// A tailnet peer that looks like a candidate motifd target. Hostnames
    /// matching `motifd*` (motif-server's default) bubble to the top, but
    /// we still surface every online peer so the user can pick a non-default
    /// host they renamed.
    struct DiscoveredPeer: Identifiable, Hashable, Sendable {
        var id: String { dnsName.isEmpty ? hostname : dnsName }
        var hostname: String
        var dnsName: String
        var primaryIP: String?
        var isLikelyMotifd: Bool
        var isOnline: Bool

        /// Best string to put in MotifServer.host: prefer the short MagicDNS
        /// name (without trailing dot), fall back to the v4 IP.
        var preferredAddress: String {
            if !dnsName.isEmpty {
                let trimmed = dnsName.hasSuffix(".") ? String(dnsName.dropLast()) : dnsName
                return trimmed
            }
            return primaryIP ?? hostname
        }
    }

    /// Pull the current tailnet peer list from the local API. Empty when
    /// not connected. Online peers come first, motifd-named hosts come
    /// before anything else within each group.
    func discoverPeers() async -> [DiscoveredPeer] {
        guard let api = apiClient else { return [] }
        let status: IpnState.Status
        do {
            status = try await api.backendStatus()
        } catch {
            log.error("backendStatus: \(String(describing: error), privacy: .public)")
            return []
        }

        var peers: [DiscoveredPeer] = []
        if let me = status.SelfStatus {
            peers.append(Self.toDiscovered(me))
        }
        if let table = status.Peer {
            peers.append(contentsOf: table.values.map(Self.toDiscovered))
        }
        // Sort: online motifd-* > other online > offline. Stable name-sort
        // within each bucket.
        return peers.sorted { a, b in
            if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
            if a.isLikelyMotifd != b.isLikelyMotifd { return a.isLikelyMotifd && !b.isLikelyMotifd }
            return a.hostname.localizedCaseInsensitiveCompare(b.hostname) == .orderedAscending
        }
    }

    private static func toDiscovered(_ p: IpnState.PeerStatus) -> DiscoveredPeer {
        let ipv4 = p.TailscaleIPs?.first(where: { $0.contains(".") })
        // motif-server names itself `motifd-<sanitized hostname>` (or just
        // `motifd`) by default — see default_ts_hostname() in
        // crates/motif-server/src/main.rs. Anything else (including this
        // iOS app's own `motif-ios` hostname) shouldn't surface as a
        // motifd target.
        let lower = p.HostName.lowercased()
        return DiscoveredPeer(
            hostname: p.HostName,
            dnsName: p.DNSName,
            primaryIP: ipv4,
            isLikelyMotifd: lower == "motifd" || lower.hasPrefix("motifd-"),
            isOnline: p.Online
        )
    }

    enum DialError: Error, CustomStringConvertible {
        case notRunning
        var description: String { "Tailscale node not running" }
    }

    // MARK: - Bus consumer

    /// Internal callback path: BusConsumer is an actor so it can implement
    /// the TailscaleKit MessageConsumer protocol. It hops back to MainActor
    /// to mutate `state` on the manager.
    fileprivate func busDidReceive(notify: Ipn.Notify) {
        if let s = notify.State {
            infoLog("[Tailscale] ipn=\(s) self=\(state)")
        }
        // Diagnostic: log every Notify field present so we can see exactly
        // what tsnet on iOS emits during the handshake. Trim down once the
        // login flow is verified working end-to-end.
        // Diagnostic breadcrumb: log just the high-signal fields. Engine
        // notifications fire every ~3s during normal operation so we keep
        // them quiet (the .Engine path below uses .debug).
        if notify.State != nil || notify.BrowseToURL != nil || notify.LoginFinished != nil || notify.ErrMessage != nil {
            var fields: [String] = []
            if let s = notify.State        { fields.append("state=\(s)") }
            if notify.BrowseToURL != nil   { fields.append("BrowseToURL=set") }
            if notify.LoginFinished != nil { fields.append("LoginFinished") }
            if let e = notify.ErrMessage   { fields.append("ErrMessage=\(e)") }
            log.notice("Notify: \(fields.joined(separator: ", "), privacy: .public)")
        }

        if let urlString = notify.BrowseToURL, let url = URL(string: urlString) {
            log.notice("BrowseToURL: \(urlString, privacy: .public)")
            state = .needsAuth(url: url)
        }
        if let ipnState = notify.State {
            switch ipnState {
            case .Running:
                Task { await self.refreshAddresses() }
            case .NeedsLogin:
                // tsnet has confirmed there's no usable cached login. Push
                // the interactive flow once so the bus emits BrowseToURL.
                // (Skip if we've already pushed it for this node — repeated
                // calls would just churn the URL.)
                if !loginInteractivePushed, let api = apiClient {
                    loginInteractivePushed = true
                    Task { [log] in
                        do {
                            try await api.startLoginInteractive()
                            log.notice("startLoginInteractive ok (state=NeedsLogin)")
                        } catch {
                            log.error("startLoginInteractive: \(String(describing: error), privacy: .public)")
                        }
                    }
                }
            case .Stopped:
                state = .stopped
            default:
                break
            }
        }

        // EngineStatus arrives every ~3s. A live-peer count dropping to
        // zero while we think we're running is a cheap early hint that the
        // datapath may be gone; confirm via the LocalAPI before reacting.
        if let engine = notify.Engine {
            let live = engine.NumLive
            let prev = lastNumLive
            lastNumLive = live
            if let prev, prev != live {
                infoLog("[Tailscale] engine NumLive \(prev) -> \(live) (state=\(state))")
            }
            if let prev, prev > 0, live == 0, case .running = state {
                Task { await self.checkHealthOnce() }
            }
        }
    }

    fileprivate func busDidError(_ error: any Error) {
        log.error("IPN bus error: \(String(describing: error), privacy: .public)")
    }
}

// MARK: - Loggers

/// LogSink that drops everything. (BlackholeLogger has an internal-only init,
/// so we ship our own equivalent.)
private struct SilentLogger: LogSink {
    var logFileHandle: Int32? { nil }
    func log(_ message: String) {}
}

/// LogSink that routes tsnet's internal Go logs to a file under
/// Documents/logs/. We co-locate this with TalkerCommonLogging's directory
/// so SettingsView's Export Logs picks both up in one zip. stderr from the
/// simulator is unreliable to capture, so we open a real fd and read the
/// file out of band.
private final class TsnetFileLogger: LogSink {
    let logFileHandle: Int32?
    private static let logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("tsnet.log", isDirectory: false)
    }()

    init() {
        // Logs/ might not exist yet if AppState's setupLogger hasn't created
        // it; createDirectory is a no-op if the path is already there.
        try? FileManager.default.createDirectory(
            at: Self.logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        // Truncate previous run, then open for writing.
        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        let path = Self.logURL.path
        let fd = path.withCString { cstr in
            Darwin.open(cstr, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        self.logFileHandle = fd >= 0 ? fd : nil
        Logger(subsystem: "io.allsunday.motif", category: "tsnet")
            .notice("tsnet log file opened at \(path, privacy: .public) fd=\(fd, privacy: .public)")
    }

    func log(_ message: String) {
        Logger(subsystem: "io.allsunday.motif", category: "tsnet").notice("\(message, privacy: .public)")
    }
}

// MARK: - BusConsumer

private actor BusConsumer: MessageConsumer {
    weak var manager: TailscaleManager?

    init(manager: TailscaleManager) {
        self.manager = manager
    }

    func notify(_ notify: Ipn.Notify) {
        Task { @MainActor [weak manager] in
            manager?.busDidReceive(notify: notify)
        }
    }

    func error(_ error: any Error) {
        Task { @MainActor [weak manager] in
            manager?.busDidError(error)
        }
    }
}
