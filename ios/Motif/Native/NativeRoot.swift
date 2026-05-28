import SwiftUI
import TalkerCommonRouter

/// Top-level native router after a server is configured. Owns the
/// MotifClient lifecycle: connect → list/attach a session → present the
/// terminal. Uses CmRouter from TalkerCommon for navigation; connection
/// state (.connecting / .failed) shadows the router with overlays.
struct NativeRoot: View {
    @Environment(MotifClient.self) private var motif
    @Environment(AppState.self) private var appState
    @State private var routerDelegate: AttachDetachDelegate?
    /// Backoff retry handle for the auto-reconnect loop. Spawned by
    /// `onStateChange` on `.failed`, cancelled by the next `.connected`
    /// or by a connectKey-change refire of the initial `.task`. Keeping
    /// it in @State (instead of a free Task that re-spawns itself) lets
    /// the view's lifecycle clean it up automatically and prevents a
    /// runaway retry storm if the user backs out mid-cycle.
    @State private var retryTask: Task<Void, Never>?
    /// Failed-connect counter feeding the backoff schedule. Resets on a
    /// successful `.connected`/`.attached` or on a connectKey change.
    @State private var retryAttempt: Int = 0
    /// Whether the *current server* has connected at least once. Gates two
    /// things: (1) auto-retry — on first launch a blind retry would hide the
    /// real failure page behind "Connecting…"; (2) the full-screen overlay —
    /// once we've shown the terminal, a later drop must NOT take over the
    /// screen (status moves to the nav-bar chip and content stays usable).
    /// Reset only when the server identity changes — deliberately NOT on a
    /// Tailscale flap (which re-keys `connectKey`), so a tsnet drop after a
    /// successful connect doesn't resurrect the takeover.
    @State private var hasConnectedThisServer: Bool = false

    /// Re-key the connection .task whenever the active server changes,
    /// its kind flips, OR tsnet flips to .running. The tsnet flag matters
    /// only for `.tailscale` servers — its loopback proxy refuses CONNECT
    /// (HTTP 403) until the node has actually joined the tailnet, so
    /// attempting motifd's WS upgrade before that gives "network
    /// connection lost" with no useful message. Including `kind.rawValue`
    /// here is what makes an in-place kind edit (same UUID via
    /// MotifServerStore.update) re-fire the task.
    private var connectKey: String {
        let id = appState.servers.activeServer?.id.uuidString ?? ""
        let kind = appState.servers.activeServer?.kind.rawValue ?? ""
        let ts = isTailscaleRunning ? "up" : "wait"
        return "\(id)|\(kind)|\(ts)"
    }

    private var isTailscaleRunning: Bool {
        if case .running = appState.tailscale.state { return true }
        return false
    }

    /// True only when the active server is a `.tailscale` target — i.e.
    /// when tsnet must be up before we can dial. `.direct` servers don't
    /// care about tsnet state, so the UI/connect flow shouldn't wait.
    private var requiresTailscale: Bool {
        appState.servers.activeServer?.kind == .tailscale
    }

    /// Single gate consumed by both the view switch and the connect task.
    private var blocked: Bool { requiresTailscale && !isTailscaleRunning }

    /// Drive the whole native UI's light/dark appearance from the terminal
    /// theme setting so the chrome matches the terminal surface. `.system`
    /// returns nil → follow iOS.
    private var terminalPreferredScheme: ColorScheme? {
        // Inside a session, follow the session-wide theme so the chrome matches
        // every other client (and the terminal surface); otherwise this
        // device's own preference.
        switch appState.motif.sessionTheme {
        case "light": return .light
        case "dark":  return .dark
        default:      break
        }
        switch appState.terminalSettings.theme {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }

    var body: some View {
        routerView
            .preferredColorScheme(terminalPreferredScheme)
            .task(id: connectKey) {
                // A connectKey change means the prereqs for "who/how we
                // dial" have shifted (server swap, kind flip, tsnet flip).
                // Drop any pending backoff so we don't dial a stale target
                // and reset the attempt counter for fresh exponential backoff.
                retryTask?.cancel()
                retryTask = nil
                retryAttempt = 0
                guard !blocked else { return }
                guard let server = appState.servers.activeServer else { return }
                // connectKey changed ⇒ the dial prerequisites moved (server
                // swap, kind flip, or a tsnet up/down that may have rotated
                // the loopback proxy port). Force a fresh dial so we don't
                // keep using a stale URLSession that a `.connected` guard
                // would otherwise preserve.
                await motif.connect(server: server, tailscale: appState.tailscale, force: true)
            }
            .onChange(of: motif.state) { _, newState in
                onStateChange(newState)
            }
            .onChange(of: appState.servers.activeServer?.id) { _, _ in
                // A genuinely different server — forget that we've ever
                // connected so its first connect shows the full-screen
                // setup/failure flow again.
                hasConnectedThisServer = false
            }
    }

    /// Reactive bridge between MotifClient.state and the retry loop.
    /// `.failed` schedules a backoff retry; success cancels any pending
    /// one. The fall-through cases (`.connecting`, `.disconnected`) are
    /// intermediate states — leave the retry handle alone so an in-flight
    /// attempt isn't yanked out from under itself when `connect()`
    /// transitions through `.connecting` on its way to a result.
    private func onStateChange(_ s: MotifClient.State) {
        switch s {
        case .connected, .attached:
            hasConnectedThisServer = true
            retryTask?.cancel()
            retryTask = nil
            retryAttempt = 0
        case .failed:
            guard !blocked else { return }
            guard hasConnectedThisServer else { return }
            scheduleRetry()
        case .connecting, .disconnected:
            break
        }
    }

    /// Exponential backoff: 1s, 2s, 4s, 8s, 15s, 15s, … capped to keep a
    /// permanently-down server from hammering itself awake while still
    /// recovering quickly from common transients (Mac sleep, network blip,
    /// server restart). Re-reads server / tsnet state at fire time so a
    /// user-driven config change between schedule and fire takes effect.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryAttempt += 1
        let attempt = retryAttempt
        let delaySec = min(pow(2.0, Double(attempt - 1)), 15.0)
        retryTask = Task { [motif, appState] in
            try? await Task.sleep(for: .seconds(delaySec))
            guard !Task.isCancelled else { return }
            // Bail if something else already moved us off `.failed` —
            // e.g. user hit the manual Retry, or the connectKey-driven
            // `.task` rebooted the flow.
            guard case .failed = motif.state else { return }
            guard let server = appState.servers.activeServer else { return }
            if server.kind == .tailscale {
                guard case .running = appState.tailscale.state else { return }
            }
            await motif.connect(server: server, tailscale: appState.tailscale)
        }
    }

    private var routerView: some View {
        let delegate = ensureDelegate()
        return CmRouterView(delegate: delegate) {
            SessionListView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { rootToolbar() }
                .overlay { rootConnectionOverlay }
        } destView: { (path: String, query: [String: String]) in
            view(path, query: query)
                .navigationBarTitleDisplayMode(.inline)
                // Same overlay here so /session (and any future pushed
                // route) shows "Connecting…" / "Connection failed" when
                // the WS dies mid-attach, instead of leaving the user
                // staring at a frozen SessionView. The overlay is rendered
                // inside the destination content — NOT around it — so the
                // navigation toolbar (Quit / Files / Diff buttons) stays
                // reachable on top, matching the rationale on the root
                // overlay above.
                .overlay { rootConnectionOverlay }
        }
    }

    @ViewBuilder
    private func view(_ path: String, query: [String: String]) -> some View {
        switch path {
        case SessionView.path:
            if let v = SessionView(query) {
                v
            } else {
                routeNotFound(path, query: query)
            }
        case GitDiffPanel.path:
            if let v = GitDiffPanel(query) {
                v
            } else {
                routeNotFound(path, query: query)
            }
        default:
            routeNotFound(path, query: query)
        }
    }

    private func routeNotFound(_ path: String, query: [String: String]) -> some View {
        Text(verbatim: "Not found: \(path), \(query). Did you forget to register the View.")
    }

    /// Connection status painted on top of the root SessionListView. The
    /// nav-bar toolbar (server picker + info) is rendered by the
    /// navigation stack and is NOT covered by this overlay, so the user
    /// can always switch servers / open settings — even while we're
    /// waiting on tsnet or retrying a failed WS dial. Order matters:
    /// `blocked` takes precedence over `motif.state == .failed` so a
    /// tailscale drop reads as "Waiting for Tailscale…" instead of a
    /// scary "Connection failed".
    @ViewBuilder
    private var rootConnectionOverlay: some View {
        if hasConnectedThisServer {
            // We've shown the terminal at least once on this server. A later
            // drop (WS death or Tailscale flap) must NOT take over the screen
            // — keep the session list / terminal visible and interactive, and
            // let `ConnectionStatusChip` in the nav bar carry the status.
            EmptyView()
        } else if blocked {
            connectionOverlayContainer {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Waiting for Tailscale…").foregroundStyle(.secondary)
                    Text(tailscaleStatusHint).font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else {
            switch motif.state {
            case .disconnected, .connecting:
                connectionOverlayContainer {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Connecting…").foregroundStyle(.secondary)
                    }
                }
            case .failed(let m):
                connectionOverlayContainer {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.yellow)
                        Text("Can’t connect to motifd").font(.headline)
                        Text(m)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        HStack(spacing: 12) {
                            Button("Retry now") { triggerRetry() }
                                .buttonStyle(.borderedProminent)
                            Button("Server settings") {
                                appState.isShowingConnection = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            case .connected, .attached:
                EmptyView()
            }
        }
    }

    /// Opaque backdrop + centered content. The backdrop absorbs taps so
    /// the list underneath isn't accidentally driven while disconnected.
    private func connectionOverlayContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            content()
        }
    }

    private var tailscaleStatusHint: String {
        switch appState.tailscale.state {
        case .stopped:           return "tsnet stopped"
        case .starting:          return "joining tailnet…"
        case .needsAuth:         return "needs login (open Settings)"
        case .running:           return ""
        case .degraded(let r):   return "reconnecting… (\(r))"
        case .failed(let m):     return m
        }
    }

    /// Tailscale-first retry. For `.tailscale` servers, refuse to dial
    /// the WS while tsnet isn't `.running` — the `.task(id: connectKey)`
    /// watcher will re-fire automatically when the bus reports
    /// `.running`, so there's nothing useful to do here except wait.
    /// The guard mostly handles the race where the user taps Retry the
    /// instant tsnet drops, before the next render swaps in the
    /// "Waiting for Tailscale…" copy.
    private func triggerRetry() {
        guard let server = appState.servers.activeServer else { return }
        if server.kind == .tailscale && !isTailscaleRunning { return }
        Task {
            await motif.connect(server: server, tailscale: appState.tailscale)
        }
    }

    private func ensureDelegate() -> AttachDetachDelegate {
        if let d = routerDelegate { return d }
        let d = AttachDetachDelegate(motif: motif)
        // Stash so the same delegate is reused across re-renders (CmRouterView
        // takes a non-Sendable weak ref under the hood).
        Task {
            self.routerDelegate = d
        }
        return d
    }

    /// Toolbar for the root route (session picker).
    @ToolbarContentBuilder
    private func rootToolbar() -> some ToolbarContent {
        principalServerButton()
        ToolbarItem(placement: .topBarTrailing) {
            ConnectionStatusChip(active: hasConnectedThisServer)
        }
        infoButton()
    }

    @ToolbarContentBuilder
    private func principalServerButton(sessionName: String? = nil) -> some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Button {
                appState.isShowingConnection = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack").font(.footnote)
                    Text(serverLabel(sessionName: sessionName))
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ToolbarContentBuilder
    private func infoButton() -> some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                appState.isShowingAbout = true
            } label: {
                Image(systemName: "info.circle")
            }
        }
    }

    private func serverLabel(sessionName: String?) -> String {
        let serverName = appState.servers.activeServer?.name ?? "motif"
        if let s = sessionName, !s.isEmpty {
            return "\(serverName) · \(s)"
        }
        return serverName
    }

}

/// Bridges CmRouter pop events to MotifClient.detach. Whenever a route is
/// popped (system back gesture, programmatic pop, or "<" tap), we call
/// detach so the WS-level session state matches what the user sees.
@MainActor
final class AttachDetachDelegate: CmRouterDelegateProtocol {
    let motif: MotifClient
    init(motif: MotifClient) { self.motif = motif }

    func afterPush(path: CmRouterPath) {
        // The pushing site (SessionListView) already calls motif.attach
        // before pushing, so nothing to do here.
    }

    func afterPop(path: CmRouterPath) {
        // Any pop of /session means "leave the session". Pops of other
        // routes are no-ops at the connection level.
        if path.path == "/session" {
            Task { await motif.detach() }
        }
    }
}

/// Compact nav-bar status pill shown while reconnecting, replacing the old
/// full-screen takeover. Hidden when the link is healthy. `active` gates it
/// to the post-first-connect phase — before that the full-screen overlay
/// owns the status, so the chip stays out of the way.
struct ConnectionStatusChip: View {
    let active: Bool
    @Environment(MotifClient.self) private var motif
    @Environment(AppState.self) private var appState

    var body: some View {
        if active, let status = statusText {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(status).font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.orange.opacity(0.18)))
            .foregroundStyle(.orange)
            .accessibilityLabel(status)
        }
    }

    /// nil ⇒ healthy ⇒ chip hidden. Tailscale prerequisite takes precedence
    /// for `.tailscale` servers since a dead tailnet is *why* motifd is
    /// unreachable.
    private var statusText: String? {
        if appState.servers.activeServer?.kind == .tailscale {
            switch appState.tailscale.state {
            case .running:             break
            case .degraded, .starting: return "Tailscale…"
            case .needsAuth:           return "Tailscale login"
            case .stopped, .failed:    return "Tailscale off"
            }
        }
        switch motif.state {
        case .connected, .attached, .disconnected: return nil
        case .connecting, .failed:                 return "Reconnecting…"
        }
    }
}
