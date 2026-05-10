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
            // Auto-resume Tailscale. With cached creds tsnet skips the
            // user prompt entirely; otherwise busDidReceive surfaces a
            // BrowseToURL via the setup sheet. In DEBUG we wedge a
            // hardcoded auth-key in so first-run iteration doesn't go
            // through the browser login each time.
            #if DEBUG
            await appState.tailscale.start(authKey: Self.debugAuthKey)
            #else
            await appState.tailscale.start(authKey: nil)
            #endif
        }
    }

    #if DEBUG
    /// Dev-only Tailscale auth key. tsnet uses this only when there are
    /// no usable cached credentials in `Documents/tailscale/`; otherwise
    /// it's ignored and we resume from cache.
    private static let debugAuthKey = "tskey-auth-kwzJU9EMHu11CNTRL-VAKoHNUdme4FfZz4Mcjge4oTtzjy1d8re"
    #endif
}

#Preview {
    ContentView().environment(AppState())
}
