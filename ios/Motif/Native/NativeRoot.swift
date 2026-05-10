import SwiftUI
import TalkerCommonRouter
import TalkerMacro

/// Top-level native router after a server is configured. Owns the
/// MotifClient lifecycle: connect → list/attach a session → present the
/// terminal. Uses CmRouter from TalkerCommon for navigation; connection
/// state (.connecting / .failed) shadows the router with overlays.
struct NativeRoot: View {
    @Environment(MotifClient.self) private var motif
    @Environment(AppState.self) private var appState
    @State private var routerDelegate: AttachDetachDelegate?

    /// Generates `view(_ path: String, query: [String: String]) -> some View`
    /// at compile time: a switch on `SessionView.path` that calls the
    /// `init?(_:)` peer the `@Routable` macro added on each registered
    /// view. Adding a new destination = adding a `@Routable("/x")` view
    /// here, no manual switch maintenance.
    #routeViews(SessionView.self, GitDiffPanel.self)

    /// Re-key the connection .task whenever the active server changes OR
    /// tsnet flips to .running. The latter is critical: tsnet's loopback
    /// proxy refuses CONNECT (HTTP 403) until the node has actually joined
    /// the tailnet, so attempting motifd's WS upgrade before that gives a
    /// "network connection lost" with no useful message.
    private var connectKey: String {
        let id = appState.servers.activeServer?.id.uuidString ?? ""
        let ts = isTailscaleRunning ? "up" : "wait"
        return "\(id)|\(ts)"
    }

    private var isTailscaleRunning: Bool {
        if case .running = appState.tailscale.state { return true }
        return false
    }

    var body: some View {
        Group {
            if !isTailscaleRunning {
                waitingForTailscaleView
            } else {
                switch motif.state {
                case .disconnected, .connecting:
                    connectingView
                case .failed(let m):
                    failedView(message: m)
                case .connected, .attached:
                    routerView
                }
            }
        }
        .task(id: connectKey) {
            guard isTailscaleRunning else { return }
            guard let server = appState.servers.activeServer else { return }
            await motif.connect(server: server, tailscale: appState.tailscale)
        }
    }

    private var waitingForTailscaleView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Waiting for Tailscale…").foregroundStyle(.secondary)
            Text(tailscaleStatusHint).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var tailscaleStatusHint: String {
        switch appState.tailscale.state {
        case .stopped:           return "tsnet stopped"
        case .starting:          return "joining tailnet…"
        case .needsAuth:         return "needs login (open Settings)"
        case .running:           return ""
        case .failed(let m):     return m
        }
    }

    private var routerView: some View {
        let delegate = ensureDelegate()
        return CmRouterView(delegate: delegate) {
            SessionListView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { rootToolbar() }
        } destView: { (path: String, query: [String: String]) in
            view(path, query: query)
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func ensureDelegate() -> AttachDetachDelegate {
        if let d = routerDelegate { return d }
        let d = AttachDetachDelegate(motif: motif)
        // Stash so the same delegate is reused across re-renders (CmRouterView
        // takes a non-Sendable weak ref under the hood).
        DispatchQueue.main.async { self.routerDelegate = d }
        return d
    }

    /// Toolbar for the root route (session picker).
    @ToolbarContentBuilder
    private func rootToolbar() -> some ToolbarContent {
        principalServerButton()
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

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting…").foregroundStyle(.secondary)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.yellow)
            Text("Connection failed").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task {
                    guard let server = appState.servers.activeServer else { return }
                    await motif.connect(server: server, tailscale: appState.tailscale)
                }
            }
        }
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
