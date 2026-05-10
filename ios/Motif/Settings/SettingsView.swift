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
    @State private var showingError: String?
    @State private var serverEditTarget: ServerEdit?
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

                Section {
                    if appState.servers.servers.isEmpty {
                        Text("No servers configured. Tap + to add one.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.servers.servers) { server in
                            ServerRow(server: server,
                                      isActive: appState.servers.activeID == server.id,
                                      onTap: {
                                          if appState.servers.activeID != server.id {
                                              appState.servers.setActive(id: server.id)
                                              appState.bumpWebViewReload()
                                          }
                                      },
                                      onEdit: {
                                          serverEditTarget = .existing(server)
                                      })
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                let id = appState.servers.servers[idx].id
                                appState.servers.delete(id: id)
                            }
                            appState.bumpWebViewReload()
                        }
                    }
                } header: {
                    HStack {
                        Text("Servers")
                        Spacer()
                        Button {
                            serverEditTarget = .new
                        } label: {
                            Image(systemName: "plus")
                        }
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
            .sheet(item: $serverEditTarget) { target in
                ServerEditSheet(target: target) { updated in
                    switch target {
                    case .new:
                        appState.servers.add(updated)
                        appState.bumpWebViewReload()
                    case .existing:
                        appState.servers.update(updated)
                        if appState.servers.activeID == updated.id {
                            appState.bumpWebViewReload()
                        }
                    }
                }
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
}

// MARK: - Server list row + edit sheet

private struct ServerRow: View {
    let server: MotifServer
    let isActive: Bool
    let onTap: () -> Void
    let onEdit: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }
                        Text(server.name)
                            .foregroundStyle(.primary)
                    }
                    Text(server.endpoint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { onEdit() } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

enum ServerEdit: Identifiable {
    case new
    case existing(MotifServer)

    var id: String {
        switch self {
        case .new: return "__new__"
        case .existing(let s): return s.id.uuidString
        }
    }
}

private struct ServerEditSheet: View {
    let target: ServerEdit
    let onSave: (MotifServer) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portText: String = "7777"
    @State private var token: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Dev box", text: $name)
                        .autocorrectionDisabled()
                }
                Section("motifd address") {
                    TextField("hostname (e.g. dev.tail-xxxx.ts.net)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("port", text: $portText)
                        .keyboardType(.numberPad)
                }
                Section("Token") {
                    SecureField("motifd token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(isNew ? "Add Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
            }
            .onAppear { hydrate() }
        }
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        UInt16(portText) != nil &&
        !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func hydrate() {
        if case .existing(let s) = target {
            name = s.name
            host = s.host
            portText = String(s.port)
            token = s.token
        }
    }

    private func save() {
        guard let port = UInt16(portText) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let server: MotifServer
        switch target {
        case .new:
            server = MotifServer(name: trimmedName, host: trimmedHost, port: port, token: trimmedToken)
        case .existing(let existing):
            server = MotifServer(id: existing.id, name: trimmedName, host: trimmedHost, port: port, token: trimmedToken)
        }
        onSave(server)
        dismiss()
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

