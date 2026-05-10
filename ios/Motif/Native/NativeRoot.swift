import SwiftUI

/// Top-level native router after a server is configured. Owns the
/// MotifClient lifecycle: connect → list/attach a session → present the
/// terminal. Replaces the WKWebView path entirely.
struct NativeRoot: View {
    @Environment(MotifClient.self) private var motif
    @Environment(AppState.self) private var appState
    let localPort: UInt16
    @State private var connectError: String?

    var body: some View {
        Group {
            switch motif.state {
            case .disconnected, .connecting:
                connectingView
            case .failed(let m):
                failedView(message: m)
            case .connected:
                NavigationStack {
                    SessionListView()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { commonToolbar(showDisconnect: false) }
                }
            case .attached:
                NavigationStack {
                    SessionView()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { commonToolbar(showDisconnect: true) }
                }
            }
        }
        .task(id: localPort) {
            await motif.connect(localPort: localPort)
        }
    }

    /// Top bar:
    ///   leading  — back-to-session-list (when attached)
    ///   center   — current server name button → ConnectionView sheet
    ///   trailing — info button → AboutView sheet
    @ToolbarContentBuilder
    private func commonToolbar(showDisconnect: Bool) -> some ToolbarContent {
        if showDisconnect {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    // Go back to session picker, not all the way to a
                    // dead WS. detach() keeps the connection alive.
                    Task { await motif.detach() }
                } label: {
                    Image(systemName: "chevron.backward")
                }
            }
        }
        ToolbarItem(placement: .principal) {
            Button {
                appState.isShowingConnection = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "server.rack").font(.footnote)
                    Text(serverLabel)
                        .font(.headline)
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                appState.isShowingAbout = true
            } label: {
                Image(systemName: "info.circle")
            }
        }
    }

    private var serverLabel: String {
        if let s = appState.servers.activeServer {
            if case .attached(let session) = motif.state {
                return "\(s.name) · \(session)"
            }
            return s.name
        }
        return "motif"
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
                Task { await motif.connect(localPort: localPort) }
            }
        }
    }
}
