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
///
/// The implementation is split across `TailscaleManager+Health`,
/// `+Connections`, `+Discovery`, and `+Bus`. Stored state those files touch is
/// `internal` (and `state` uses plain `var`) because Swift `private` is
/// file-scoped — by convention only this type mutates it.
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

    var state: State = .stopped
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

    let log = Logger(subsystem: "io.allsunday.motif", category: "Tailscale")
    var node: TailscaleNode?
    var apiClient: LocalAPIClient?
    private var busProcessor: MessageProcessor?
    private var busConsumer: BusConsumer?
    /// True once we've pushed startLoginInteractive for the current node
    /// instance, so an Up()-driven NeedsLogin doesn't ask the user for a
    /// fresh login URL on every bus tick.
    var loginInteractivePushed: Bool = false

    /// Polls `backendStatus()` while we believe the datapath is down so we
    /// can flip `.degraded` back to `.running` once tsnet reconnects. Only
    /// alive during a `.degraded` window — nil otherwise. See `revalidate()`.
    var healthMonitorTask: Task<Void, Never>?
    /// Last `EngineStatus.NumLive` seen on the IPN bus. A >0→0 edge is a
    /// cheap hint that connectivity dropped; we confirm via the LocalAPI
    /// rather than trusting it alone (idle peers fall out of the live set).
    var lastNumLive: Int?

    /// Count of consecutive `backendStatus()` throws. A probe that *succeeds*
    /// (even one reporting the datapath down) resets this. It distinguishes
    /// "datapath flapping but LocalAPI alive" (recovers via polling) from
    /// "LocalAPI listener is dead" — the latter throws ECONNREFUSED on lo0
    /// after a long app suspend and never recovers by polling, because the
    /// thing we poll is gone. See `checkHealthOnce` / `restartNode`.
    var consecutiveProbeFailures = 0
    /// Re-entrancy guard for `restartNode`: `checkHealthOnce` can fire from
    /// the monitor loop, the NumLive edge, and foreground revalidate.
    var isRestarting = false
    /// Consecutive probe throws that mean the LocalAPI is gone (not a one-off
    /// blip) and we should rebuild the node rather than keep polling.
    static let probeFailureRestartThreshold = 3

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

    func teardown() async {
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
    func refreshAddresses() async {
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
}
