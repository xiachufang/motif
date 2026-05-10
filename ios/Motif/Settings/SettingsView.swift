import SwiftUI
import AuthenticationServices
import OSLog

private let settingsLog = Logger(subsystem: "io.allsunday.motif", category: "SettingsView")

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var authKey: String = ""
    @State private var motifdAddressDraft: String = ""
    @State private var showingError: String?

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
    @Environment(\.webAuthenticationSession) private var webAuth

    var body: some View {
        Button {
            Task {
                isLoading = true
                defer { isLoading = false }
                do {
                    _ = try await webAuth.authenticate(
                        using: url,
                        callbackURLScheme: "tailscale-callback"
                    )
                } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
                    settingsLog.debug("ASWebAuthenticationSession cancelled by user")
                } catch {
                    settingsLog.error("ASWebAuthenticationSession failed: \(String(describing: error), privacy: .public)")
                }
            }
        } label: {
            HStack {
                if isLoading { ProgressView().controlSize(.small) }
                Text("Open Tailscale login")
            }
        }
    }
}
