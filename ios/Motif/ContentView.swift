import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch appState.serverState {
            case .starting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting local server…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.yellow)
                    Text("Local server failed")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            case .running(let port):
                if appState.servers.activeServer == nil {
                    WelcomeView()
                } else {
                    NativeRoot(localPort: port)
                        .id(appState.webViewReloadKey)
                        .environment(appState.motif)
                }
            }

        }
        .sheet(isPresented: Binding(
            get: { appState.isShowingConnection },
            set: { appState.isShowingConnection = $0 }
        )) {
            ConnectionView().environment(appState)
        }
        .sheet(isPresented: Binding(
            get: { appState.isShowingAbout },
            set: { appState.isShowingAbout = $0 }
        )) {
            AboutView().environment(appState)
        }
        .task {
            await appState.startServerIfNeeded()
            // Auto-resume Tailscale if a cached login is present. tsnet
            // reads the state dir on its own; if creds are still valid
            // we go straight to .running with no UI prompt. If they're
            // not, busDidReceive will push the login URL via
            // startLoginInteractive, which surfaces as a Safari sheet
            // in Settings (which the user can keep closed for now).
            await appState.tailscale.start(authKey: nil)
        }
    }
}

#Preview {
    ContentView().environment(AppState())
}
