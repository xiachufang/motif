import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if appState.servers.activeServer == nil {
                WelcomeView()
            } else {
                NativeRoot()
                    .id(appState.webViewReloadKey)
                    .environment(appState.motif)
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
        .onChange(of: scenePhase) { old, phase in
            FileLog.note("Tailscale", "scenePhase \(String(describing: old)) -> \(String(describing: phase))")
            // Track foreground so a backgrounded client never claims PTY
            // primary; on return to foreground, reclaim it for our active view.
            appState.motif.isForeground = (phase == .active)
            // Returning to the foreground is the only moment we can notice a
            // tailnet connection the system tore down while we were
            // suspended — tsnet emits no push event for it. Ask it directly.
            if phase == .active {
                Task { await appState.tailscale.revalidate() }
                appState.motif.reclaimPrimary()
            }
        }
    }

    #if DEBUG
    /// Dev-only Tailscale auth key. tsnet uses this only when there are
    /// no usable cached credentials in `Documents/tailscale/`; otherwise
    /// it's ignored and we resume from cache.
    private static let debugAuthKey = "tskey-auth-kgGZLTq6qP11CNTRL-MAm9erG4H263sAaqjM6426aVZU17p8W2"
    #endif
}

#Preview {
    ContentView().environment(AppState())
}
