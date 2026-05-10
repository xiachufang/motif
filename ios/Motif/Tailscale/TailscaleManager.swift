import Foundation
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
            let node = try TailscaleNode(config: config, logger: nil)
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

            // For interactive (no auth-key) flow, explicitly kick off the
            // login state machine. Without this the bus stays quiet because
            // tsnet has no reason to start the auth dance — it'll only do so
            // on the first listen/dial call.
            if authKey == nil {
                do {
                    try await api.startLoginInteractive()
                    log.notice("startLoginInteractive ok")
                } catch {
                    log.error("startLoginInteractive: \(String(describing: error), privacy: .public)")
                    // Not fatal — the bus may still surface a URL once tsnet
                    // realises it needs login on its own.
                }
            }

            // Run `up()` in the background — it blocks until the node is
            // usable (which for interactive flow means the user has finished
            // signing in). Don't make `start()` await on it; the bus is the
            // primary state driver and we want the UI to reflect .needsAuth
            // / .running as the bus reports them.
            Task { [weak self] in
                do {
                    try await node.up()
                    await self?.refreshAddresses()
                    await self?.log.notice("node.up returned (connected)")
                } catch {
                    await self?.log.error("node.up: \(String(describing: error), privacy: .public)")
                    await self?.handleUpFailure(error)
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

    enum DialError: Error, CustomStringConvertible {
        case notRunning
        var description: String { "Tailscale node not running" }
    }

    // MARK: - Bus consumer

    /// Internal callback path: BusConsumer is an actor so it can implement
    /// the TailscaleKit MessageConsumer protocol. It hops back to MainActor
    /// to mutate `state` on the manager.
    fileprivate func busDidReceive(notify: Ipn.Notify) {
        // tsnet emits NeedsLogin and BrowseToURL as separate Notify messages
        // and the order between them is not guaranteed: sometimes the State
        // change lands first, sometimes the URL does. We handle whichever
        // arrives, and stay in `.starting` until BrowseToURL surfaces a real
        // URL — never transition to `.failed` purely on NeedsLogin, because
        // the URL is still on its way and erasing the state would also drop
        // any URL that comes after.
        if let urlString = notify.BrowseToURL, let url = URL(string: urlString) {
            log.notice("BrowseToURL: \(urlString, privacy: .public)")
            state = .needsAuth(url: url)
        }
        if let ipnState = notify.State {
            log.notice("ipn state: \(String(describing: ipnState), privacy: .public)")
            switch ipnState {
            case .Running:
                Task { await self.refreshAddresses() }
            case .NeedsLogin:
                // Stay in .starting / .needsAuth; BrowseToURL drives the UI.
                break
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

// MARK: - SilentLogger

/// LogSink that drops everything. (BlackholeLogger has an internal-only init,
/// so we ship our own equivalent.)
private struct SilentLogger: LogSink {
    var logFileHandle: Int32? { nil }
    func log(_ message: String) {}
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
