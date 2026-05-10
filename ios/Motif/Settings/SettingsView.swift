import SwiftUI
import UIKit
import OSLog

private let settingsLog = Logger(subsystem: "io.allsunday.motif", category: "SettingsView")

/// Open a Tailscale login URL in the system browser. Tailscale's auth flow
/// doesn't redirect back to a custom scheme, so `ASWebAuthenticationSession`
/// (which waits for a callback URL) is the wrong API — we just use
/// `UIApplication.open`. tsnet completes the login on its own once the user
/// finishes signing in; the IPN bus surfaces State == .Running and the
/// manager updates UI accordingly.
@MainActor
private func openTailscaleLoginURL(_ url: URL) async {
    let opened = await UIApplication.shared.open(url)
    if !opened {
        settingsLog.error("UIApplication.open(\(url.absoluteString, privacy: .public)) returned false")
    }
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var authKey: String = ""
    @State private var motifdAddressDraft: String = ""
    @State private var showingError: String?
    /// The auth URL we've already auto-opened in the browser, so a second
    /// re-render or repeated Notify doesn't repeatedly bounce out to Safari.
    @State private var openedAuthURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Tailscale") {
                    TailscaleStatusRow(state: appState.tailscale.state)
                    if !isRunning {
                        SecureField("Auth key (tskey-…)", text: $authKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Connect with auth key") { connectWithAuthKey() }
                            .disabled(authKey.isEmpty || isStarting)
                        Button("Use web auth instead") { connectInteractively() }
                            .disabled(isStarting)
                    } else {
                        Button("Disconnect", role: .destructive) {
                            Task { await appState.tailscale.stop() }
                        }
                    }
                }

                Section("motifd 地址") {
                    TextField("hostname:port", text: $motifdAddressDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit { commitMotifdAddress() }
                    Button("Save") { commitMotifdAddress() }
                        .disabled(motifdAddressDraft == appState.motifdAddress)
                    if !appState.motifdAddress.isEmpty {
                        Text("当前：\(appState.motifdAddress)").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("App") {
                    LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "?")
                    LabeledContent("Version") {
                        Text("\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    }
                    if case .running(let port) = appState.serverState {
                        LabeledContent("Local server", value: "127.0.0.1:\(port)")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Error", isPresented: .constant(showingError != nil), presenting: showingError) { _ in
                Button("OK") { showingError = nil }
            } message: { msg in Text(msg) }
            .onAppear {
                motifdAddressDraft = appState.motifdAddress
            }
            .onChange(of: appState.tailscale.state) { _, newState in
                // Auto-open the browser as soon as Tailscale publishes a
                // login URL on the bus. We only auto-open each URL once;
                // user can manually re-open via the button below.
                if case .needsAuth(let url) = newState, openedAuthURL != url {
                    openedAuthURL = url
                    Task { await openTailscaleLoginURL(url) }
                }
                if case .running = newState {
                    openedAuthURL = nil
                }
            }
        }
    }

    private var isRunning: Bool {
        if case .running = appState.tailscale.state { return true }
        return false
    }

    private var isStarting: Bool {
        if case .starting = appState.tailscale.state { return true }
        return false
    }

    private func connectWithAuthKey() {
        let key = authKey
        Task {
            await appState.tailscale.start(authKey: key)
            authKey = ""
        }
    }

    private func connectInteractively() {
        Task {
            await appState.tailscale.start(authKey: nil)
            // The manager will publish state = .needsAuth(url) when the
            // BrowseToURL notification arrives. We pick that up below.
        }
    }

    private func commitMotifdAddress() {
        appState.motifdAddress = motifdAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TailscaleStatusRow: View {
    let state: TailscaleManager.State
    @State private var isAuthing: Bool = false

    var body: some View {
        Group {
            switch state {
            case .stopped:
                LabeledContent("Status", value: "Stopped")
            case .starting:
                LabeledContent("Status") {
                    HStack { ProgressView().controlSize(.small); Text("Starting…") }
                }
            case .needsAuth(let url):
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Status", value: "Needs login")
                    AuthLinkButton(url: url, isLoading: $isAuthing)
                }
            case .running(let v4, let v6):
                LabeledContent("Status", value: "Connected")
                if let v4 { LabeledContent("IPv4", value: v4) }
                if let v6 { LabeledContent("IPv6", value: v6) }
            case .failed(let m):
                LabeledContent("Status", value: "Failed").foregroundStyle(.red)
                Text(m).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct AuthLinkButton: View {
    let url: URL
    @Binding var isLoading: Bool

    var body: some View {
        Button {
            Task {
                isLoading = true
                defer { isLoading = false }
                await openTailscaleLoginURL(url)
            }
        } label: {
            HStack {
                if isLoading { ProgressView().controlSize(.small) }
                Text("Reopen Tailscale login")
            }
        }
    }
}
