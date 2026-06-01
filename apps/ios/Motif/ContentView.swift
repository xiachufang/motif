import SwiftUI
import TalkerCommonLogging

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if appState.servers.activeServer == nil {
                WelcomeView()
            } else {
                NativeRoot()
                    .id(appState.nativeReloadKey)
                    .environment(appState.motif)
            }
        }
        .overlay(alignment: .top) {
            // Live (foreground) notification banner — the in-app counterpart to
            // the APNs push that fires only when backgrounded. Observes
            // MotifClient.latestNotification (set by the "notification" event)
            // and surfaces it; tap deep-links to the originating session.
            LiveNotificationBanner(client: appState.motif) { notif in
                if let name = notif.sessionName, !name.isEmpty {
                    appState.pendingDeepLink = PushDeepLink(instanceID: nil, sessionName: name)
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
            get: { appState.isShowingSettings },
            set: { appState.isShowingSettings = $0 }
        )) {
            SettingsView().environment(appState)
        }
        .task {
            // Wire push deep-link delivery to this AppState, then ask for
            // notification authorization + register for remote notifications.
            // Safe/no-op when the user declines or push is unconfigured.
            PushManager.shared.appState = appState
            await PushManager.shared.requestAuthorizationAndRegister()

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
            infoLog("[Tailscale] scenePhase \(String(describing: old)) -> \(String(describing: phase))")
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

/// Top-anchored, auto-dismissing banner for live in-app notifications.
/// Consumes `client.latestNotification` so the same notification re-triggers
/// cleanly; auto-hides after a few seconds, or on tap / swipe-up.
private struct LiveNotificationBanner: View {
    let client: MotifClient
    var onTap: (MotifNotification) -> Void

    @State private var shown: MotifNotification?
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        VStack {
            if let n = shown {
                card(n)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: shown)
        .onChange(of: client.latestNotification) { _, new in
            guard let new else { return }
            shown = new
            // Consume so a later identical-text notification re-fires onChange.
            client.latestNotification = nil
            scheduleDismiss()
        }
    }

    private func card(_ n: MotifNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "bell.badge.fill")
                .foregroundStyle(.tint)
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if !n.body.isEmpty {
                    Text(n.body).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if let n = shown { onTap(n) }
            dismiss()
        }
        .gesture(
            DragGesture(minimumDistance: 12).onEnded { v in
                if v.translation.height < -8 { dismiss() }
            }
        )
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { dismiss() }
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        withAnimation { shown = nil }
    }
}

#Preview {
    ContentView().environment(AppState())
}
