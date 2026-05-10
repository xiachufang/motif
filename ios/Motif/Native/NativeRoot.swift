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

    /// The active server we're connecting to. Connection re-runs whenever
    /// the user switches servers or reloads — we tag the .task with this id.
    private var activeServerID: String {
        appState.servers.activeServer?.id.uuidString ?? ""
    }

    var body: some View {
        Group {
            switch motif.state {
            case .disconnected, .connecting:
                connectingView
            case .failed(let m):
                failedView(message: m)
            case .connected, .attached:
                routerView
            }
        }
        .task(id: activeServerID) {
            guard let server = appState.servers.activeServer else { return }
            await motif.connect(server: server, tailscale: appState.tailscale)
        }
    }

    private var routerView: some View {
        let delegate = ensureDelegate()
        return CmRouterView(delegate: delegate) {
            SessionListView()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { rootToolbar() }
        } destView: { (path: String, query: [String: String]) in
            switch path {
            case "/session":
                SessionView()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { sessionToolbar(sessionName: query["name"] ?? "") }
            default:
                Text("unknown route: \(path)")
                    .foregroundStyle(.red)
            }
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

    /// Toolbar for the /session route — system back chevron is provided
    /// by NavigationStack automatically; CmRouter's afterPop fires
    /// motif.detach() when the user backs out.
    @ToolbarContentBuilder
    private func sessionToolbar(sessionName: String) -> some ToolbarContent {
        principalServerButton(sessionName: sessionName)
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
