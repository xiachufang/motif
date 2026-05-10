import SwiftUI
import UIKit
import SafariServices
import OSLog

private let settingsLog = Logger(subsystem: "io.allsunday.motif", category: "SettingsView")

/// Identifiable wrapper so we can drive a `.sheet(item:)` directly off a URL.
private struct AuthURL: Identifiable, Equatable { let id: URL }

/// SFSafariViewController in a SwiftUI sheet. Stays inside Motif so the user
/// doesn't context-switch out to system Safari for a Tailscale login.
private struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let cfg = SFSafariViewController.Configuration()
        cfg.entersReaderIfAvailable = false
        cfg.barCollapsingEnabled = true
        let vc = SFSafariViewController(url: url, configuration: cfg)
        vc.dismissButtonStyle = .done
        vc.preferredControlTintColor = .systemBlue
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var authKey: String = ""
    @State private var motifdAddressDraft: String = ""
    @State private var showingError: String?
    /// Driving value for the in-app Safari sheet. Setting non-nil shows the
    /// sheet; when the IPN bus reports .running we set it back to nil so
    /// the sheet auto-dismisses.
    @State private var authSheet: AuthURL?
    /// The URL we already auto-opened, so re-renders of the same .needsAuth
    /// state don't keep re-presenting the sheet after the user dismisses it.
    @State private var openedAuthURL: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Tailscale") {
                    TailscaleStatusRow(state: appState.tailscale.state)
                    if case .needsAuth(let url) = appState.tailscale.state {
                        Button("Reopen login") {
                            authSheet = AuthURL(id: url)
                        }
                    }
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
                // Auto-open the in-app Safari sheet on each new login URL.
                // Track which URL we've already opened so the user can
                // dismiss the sheet without us bouncing it back up on the
                // next bus tick.
                if case .needsAuth(let url) = newState, openedAuthURL != url {
                    openedAuthURL = url
                    authSheet = AuthURL(id: url)
                }
                // Login finished — close the sheet and reset the dedupe
                // marker so a future re-auth pops a fresh one.
                if case .running = newState {
                    authSheet = nil
                    openedAuthURL = nil
                }
            }
            .sheet(item: $authSheet) { auth in
                SafariSheet(url: auth.id)
                    .ignoresSafeArea()
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

    var body: some View {
        Group {
            switch state {
            case .stopped:
                LabeledContent("Status", value: "Stopped")
            case .starting:
                LabeledContent("Status") {
                    HStack { ProgressView().controlSize(.small); Text("Starting…") }
                }
            case .needsAuth:
                LabeledContent("Status", value: "Needs login")
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

