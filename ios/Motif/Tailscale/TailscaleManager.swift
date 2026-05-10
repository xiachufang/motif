import Foundation
import Network
import Observation
import OSLog
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
        case failed(message: String)
    }

    private(set) var state: State = .stopped
    private(set) var hostName: String

    private let log = Logger(subsystem: "io.allsunday.motif", category: "Tailscale")
    private var node: TailscaleNode?
    private var apiClient: LocalAPIClient?
    private var busProcessor: MessageProcessor?
    private var busConsumer: BusConsumer?
    /// True once we've pushed startLoginInteractive for the current node
    /// instance, so an Up()-driven NeedsLogin doesn't ask the user for a
    /// fresh login URL on every bus tick.
    private var loginInteractivePushed: Bool = false

    init(hostName: String = "motif-ios") {
        self.hostName = hostName
    }

    /// Persist the state directory under Documents/tailscale so node keys
    /// survive app restarts.
    private static var statePath: String {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("tailscale", isDirectory: true)
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

    /// Start the node. Idempotent — calling while running is a no-op.
    /// `authKey` skips the interactive login round-trip; pass nil to go through
    /// web auth (we'll publish the BrowseToURL we observe on the IPN bus).
    func start(authKey: String? = nil) async {
        if case .running = state { return }
        if case .starting = state { return }
        state = .starting

        let config = Configuration(
            hostName: hostName,
            path: Self.statePath,
            authKey: authKey,
            controlURL: kDefaultControlURL,
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
            // Run `up()` in the background — it blocks until the node is
            // usable. start() returns once the bus is hooked up and lets
            // bus-driven transitions update UI.
            Task { [weak self] in
                do {
                    try await node.up()
                    await self?.refreshAddresses()
                    self?.log.notice("node.up returned (connected)")
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
    private func handleUpFailure(_ error: Error) {
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
        } catch {
            log.error("addrs failed: \(String(describing: error), privacy: .public)")
        }
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
    /// tsnet node's HTTP CONNECT loopback proxy. tsnet's loopback listener
    /// serves both SOCKS5 and HTTP CONNECT on the same port. Going via
    /// CONNECT (not SOCKS5) means URLSession passes the hostname through to
    /// the proxy instead of resolving it locally — so MagicDNS names like
    /// `*.ts.net` resolve correctly inside tsnet.
    ///
    /// Returns a configuration so the caller can build a URLSession with
    /// its own delegate (URLSession's delegate is read-only after init).
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
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(ipStr),
                                            port: NWEndpoint.Port(rawValue: portU16)!)
        let proxy = ProxyConfiguration(httpCONNECTProxy: endpoint)
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
    }

    fileprivate func busDidError(_ error: Error) {
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

/// LogSink that routes tsnet's internal Go logs to a file under Documents/.
/// stderr from the simulator is unreliable to capture, so we open a real
/// fd and read the file out of band.
private final class TsnetFileLogger: LogSink {
    let logFileHandle: Int32?
    private static let logURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("tsnet.log", isDirectory: false)
    }()

    init() {
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

    func error(_ error: Error) {
        Task { @MainActor [weak manager] in
            manager?.busDidError(error)
        }
    }
}
