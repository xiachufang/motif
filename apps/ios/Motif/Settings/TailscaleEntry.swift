import SwiftUI
import UIKit
import SafariServices

/// Identifiable wrapper so a URL can drive `.sheet(item:)`.
struct AuthURL: Identifiable, Equatable { let id: URL }

/// SFSafariViewController in a SwiftUI sheet. Tailscale's BrowseToURL
/// sign-in flow runs inside the app instead of bouncing to system Safari.
struct SafariSheet: UIViewControllerRepresentable {
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

/// Single-row entry point that becomes a "Setup Tailscale" CTA when the
/// node isn't running, and a connection-status row (with chevron) once it
/// is. Tapping picks the right modal: Setup or Details.
struct TailscaleEntry: View {
    @Environment(AppState.self) private var appState
    @State private var showingSetup: Bool = false
    @State private var showingDetails: Bool = false

    var body: some View {
        Button {
            switch appState.tailscale.state {
            case .running, .degraded:
                showingDetails = true
            default:
                showingSetup = true
            }
        } label: {
            label
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingSetup) {
            TailscaleSetupSheet().environment(appState)
        }
        .sheet(isPresented: $showingDetails) {
            TailscaleDetailsSheet().environment(appState)
        }
    }

    @ViewBuilder
    private var label: some View {
        switch appState.tailscale.state {
        case .stopped:
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup Tailscale").bold()
                    Text("Sign in so motif can reach your servers")
                        .font(MotifTheme.Typography.footnote)
                        .foregroundStyle(MotifTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(MotifTheme.Typography.footnote)
                    .foregroundStyle(MotifTheme.textSecondary)
            }
        case .starting:
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text("Connecting Tailscale…").foregroundStyle(MotifTheme.textSecondary)
                Spacer()
            }
        case .needsAuth:
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailscale needs login").bold()
                    Text("Tap to finish signing in")
                        .font(MotifTheme.Typography.footnote)
                        .foregroundStyle(MotifTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(MotifTheme.Typography.footnote)
                    .foregroundStyle(MotifTheme.textSecondary)
            }
        case .running(let v4, _):
            HStack(spacing: 12) {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailscale connected")
                    if let v4 {
                        Text(v4)
                            .font(.footnote.monospaced())
                            .foregroundStyle(MotifTheme.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(MotifTheme.Typography.footnote)
                    .foregroundStyle(MotifTheme.textSecondary)
            }
        case .degraded(let reason):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailscale reconnecting…").bold()
                    Text(reason)
                        .font(MotifTheme.Typography.footnote)
                        .foregroundStyle(MotifTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(MotifTheme.Typography.footnote)
                    .foregroundStyle(MotifTheme.textSecondary)
            }
        case .failed(let m):
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(MotifTheme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailscale failed").bold()
                    Text(m)
                        .font(MotifTheme.Typography.footnote)
                        .foregroundStyle(MotifTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(MotifTheme.Typography.footnote)
                    .foregroundStyle(MotifTheme.textSecondary)
            }
        }
    }
}

// MARK: - Setup sheet

struct TailscaleSetupSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var authKey: String = ""
    @State private var openedAuthURL: URL?
    @State private var safariURL: AuthURL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    TailscaleStatusRow(state: appState.tailscale.state)
                }

                Section {
                    Button {
                        Task { await appState.tailscale.start(authKey: nil) }
                    } label: {
                        Label("Sign in with browser", systemImage: "globe")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(isStarting)
                } header: {
                    Text("Web auth")
                } footer: {
                    Text("Opens Tailscale's sign-in page in an in-app browser. Supports SSO / MFA.")
                        .font(MotifTheme.Typography.caption2)
                }

                Section {
                    SecureField("tskey-…", text: $authKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let key = authKey
                        Task {
                            await appState.tailscale.start(authKey: key)
                            authKey = ""
                        }
                    } label: {
                        Label("Connect with auth key", systemImage: "key.fill")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(authKey.isEmpty || isStarting)
                } header: {
                    Text("Auth key")
                } footer: {
                    Text("Pre-shared key from your Tailscale admin console. Headless — no browser needed.")
                        .font(MotifTheme.Typography.caption2)
                }
            }
            .navigationTitle("Setup Tailscale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: appState.tailscale.state) { _, newState in
                // Auto-pop the sign-in browser once tsnet emits a URL.
                if case .needsAuth(let url) = newState, openedAuthURL != url {
                    openedAuthURL = url
                    safariURL = AuthURL(id: url)
                }
                // Setup successful — close this sheet so the home screen
                // updates to the connected status row.
                if case .running = newState {
                    dismiss()
                }
            }
            .sheet(item: $safariURL) { auth in
                SafariSheet(url: auth.id).ignoresSafeArea()
            }
        }
    }

    private var isStarting: Bool {
        if case .starting = appState.tailscale.state { return true }
        return false
    }
}

// MARK: - Details sheet

struct TailscaleDetailsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TailscaleStatusRow(state: appState.tailscale.state)
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            await appState.tailscale.stop()
                            dismiss()
                        }
                    } label: {
                        Label("Disconnect", systemImage: "power")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // iOS Form quirk: destructive role colors the text
                            // red but the icon inherits the env `.tint`. Force
                            // both to danger so text + icon stay one color.
                            .foregroundStyle(MotifTheme.danger)
                    }
                } footer: {
                    Text("Disconnect drops the tsnet session. Cached credentials stay on device — sign in again to resume.")
                        .font(MotifTheme.Typography.caption2)
                }
            }
            .navigationTitle("Tailscale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: appState.tailscale.state) { _, newState in
                // If tsnet drops out (stopped / failed) auto-close so the
                // home screen's CTA flips back to Setup.
                switch newState {
                case .stopped, .failed:
                    dismiss()
                default:
                    break
                }
            }
        }
    }
}
