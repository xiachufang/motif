import SwiftUI
import OSLog

private let settingsLog = Logger(subsystem: "io.allsunday.motif", category: "ConnectionView")

/// Connection management — Tailscale + the motifd server list.
/// Reached by tapping the active server name in the home screen's
/// top bar (when in a session) or via the Welcome screen on first run.
/// Doesn't include version/about info; that's its own sheet.
struct ConnectionView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var showingError: String?
    @State private var serverEditTarget: ServerEdit?

    var body: some View {
        NavigationStack {
            Form {
                Section("Tailscale") {
                    TailscaleEntry()
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

            }
            .navigationTitle("Connection")
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
        }
    }
}

// MARK: - Server list row + edit sheet

struct ServerRow: View {
    @Environment(AppState.self) private var appState
    let server: MotifServer
    let isActive: Bool
    let onTap: () -> Void
    let onEdit: () -> Void
    @State private var pingIndicator: ServerPingIndicator = .idle

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
                        Image(systemName: server.kind == .tailscale ? "network" : "globe")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Text(server.name)
                            .foregroundStyle(.primary)
                    }
                    HStack(spacing: 8) {
                        Text(server.endpoint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if server.kind == .tailscale {
                            ServerPingBadge(indicator: pingIndicator)
                        }
                    }
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
        .task(id: serverPingTaskKey) {
            await refreshPingIndicator()
        }
    }

    private var serverPingTaskKey: String {
        "\(server.id.uuidString)|\(server.host)|\(server.port)|\(server.kind.rawValue)|\(tailscaleReady ? "up" : "down")"
    }

    private var tailscaleReady: Bool {
        if case .running = appState.tailscale.state { return true }
        return false
    }

    private func refreshPingIndicator() async {
        guard server.kind == .tailscale else {
            pingIndicator = .notApplicable
            return
        }
        guard tailscaleReady else {
            pingIndicator = .unavailable(message: "Tailscale off")
            return
        }

        pingIndicator = .checking
        let result = await appState.tailscale.pingMotifServer(host: server.host, port: server.port)
        guard !Task.isCancelled else { return }
        pingIndicator = ServerPingIndicator(result)
    }
}

private enum ServerPingIndicator: Equatable {
    case idle
    case checking
    case reachable(version: String)
    case unreachable(message: String)
    case unavailable(message: String)
    case notApplicable

    init(_ result: TailscaleManager.MotifPingResult) {
        switch result {
        case .reachable(let version):
            self = .reachable(version: version)
        case .unreachable(let message):
            self = .unreachable(message: message)
        }
    }

    var label: String {
        switch self {
        case .idle, .checking:
            return "Checking"
        case .reachable:
            return "Reachable"
        case .unreachable:
            return "No ping"
        case .unavailable(let message):
            return message
        case .notApplicable:
            return ""
        }
    }

    var systemImage: String {
        switch self {
        case .reachable:
            return "checkmark.circle.fill"
        case .unreachable:
            return "xmark.circle.fill"
        case .unavailable:
            return "minus.circle.fill"
        case .idle, .checking, .notApplicable:
            return "circle"
        }
    }

    var tint: Color {
        switch self {
        case .reachable:
            return .green
        case .unreachable:
            return .red
        case .unavailable:
            return .secondary
        case .idle, .checking, .notApplicable:
            return .secondary
        }
    }

    var accessibilityValue: String {
        switch self {
        case .reachable(let version):
            return "motifd \(version)"
        case .unreachable(let message):
            return message
        default:
            return label
        }
    }
}

private struct ServerPingBadge: View {
    let indicator: ServerPingIndicator

    var body: some View {
        if indicator != .notApplicable {
            HStack(spacing: 4) {
                if indicator == .checking || indicator == .idle {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: indicator.systemImage)
                        .font(.caption2)
                }
                Text(indicator.label)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(indicator.tint)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tailscale ping")
            .accessibilityValue(indicator.accessibilityValue)
        }
    }
}

private struct ServerPingDot: View {
    let indicator: ServerPingIndicator

    var body: some View {
        Circle()
            .fill(indicator.tint)
            .frame(width: 8, height: 8)
        .accessibilityHidden(true)
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

struct ServerEditSheet: View {
    let target: ServerEdit
    let onSave: (MotifServer) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name: String = ""
    @State private var host: String = ""
    @State private var portText: String = "7777"
    @State private var token: String = ""
    @State private var kind: ServerKind = .tailscale
    @State private var discovered: [TailscaleManager.DiscoveredPeer] = []
    @State private var discoveryState: DiscoveryState = .idle
    @State private var showAllPeers: Bool = false
    @State private var peerPing: [String: ServerPingIndicator] = [:]

    enum DiscoveryState: Equatable {
        case idle
        case loading
        case loaded(count: Int)
        case unavailable(reason: String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Reach via") {
                    Picker("Kind", selection: $kind) {
                        Text("Tailscale").tag(ServerKind.tailscale)
                        Text("Direct").tag(ServerKind.direct)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if isNew && kind == .tailscale {
                    discoverySection
                }
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
                Section {
                    SecureField("motifd token (optional)", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Token")
                } footer: {
                    Text("Required only if motifd was started with a non-empty token. Leave blank for an unauthenticated server.")
                        .font(.caption2)
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
            .task(id: isNew) {
                if isNew { await loadDiscovery() }
            }
            .task(id: discoveryPingKey) {
                await refreshVisiblePeerPings()
            }
        }
    }

    /// What we actually render — defaults to "looks like motifd" only,
    /// expanded to all peers when the user flips the toggle.
    private var visiblePeers: [TailscaleManager.DiscoveredPeer] {
        showAllPeers ? discovered : discovered.filter { $0.isLikelyMotifd }
    }

    private var discoveryPingKey: String {
        guard isNew && kind == .tailscale else { return "off" }
        let ids = visiblePeers.map(\.id).joined(separator: "|")
        let ts = tailscaleReady ? "up" : "down"
        return "\(ids)|\(portText)|\(showAllPeers)|\(ts)"
    }

    private var tailscaleReady: Bool {
        if case .running = appState.tailscale.state { return true }
        return false
    }

    @ViewBuilder
    private var discoverySection: some View {
        Section {
            switch discoveryState {
            case .idle, .loading:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning tailnet…").foregroundStyle(.secondary).font(.footnote)
                }
            case .unavailable(let reason):
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            case .loaded(let total):
                if total == 0 {
                    Text("No peers visible on the tailnet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if visiblePeers.isEmpty {
                    // Total > 0 but filter hid them all — surface the toggle
                    // explanation instead of an unhelpful empty state.
                    Text("No motifd-named peers. Toggle “Show all peers” below to pick a non-default host.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(visiblePeers) { peer in
                        Button {
                            apply(peer)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        ServerPingDot(indicator: peerPing[peer.id] ?? .idle)
                                        Text(peer.hostname).foregroundStyle(.primary)
                                        if peer.isLikelyMotifd {
                                            Text("motifd")
                                                .font(.caption2)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.tint.opacity(0.18), in: Capsule())
                                        }
                                        ServerPingBadge(indicator: peerPing[peer.id] ?? .idle)
                                    }
                                    Text(peer.preferredAddress)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.right.circle")
                                    .foregroundStyle(.tint)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } header: {
            HStack(spacing: 12) {
                Text("Discovered on tailnet")
                Spacer()
                Button {
                    showAllPeers.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: showAllPeers ? "checkmark.square.fill" : "square")
                        Text("Show all")
                    }
                    .font(.footnote)
                }
                Button {
                    Task { await loadDiscovery() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.footnote)
                }
            }
        } footer: {
            Text("Tap a peer to fill in the address. Token still has to be entered manually.")
                .font(.caption2)
        }
    }

    private func apply(_ peer: TailscaleManager.DiscoveredPeer) {
        host = peer.preferredAddress
        if name.isEmpty { name = peer.hostname }
    }

    private func loadDiscovery() async {
        discoveryState = .loading
        // If Tailscale isn't connected we can't enumerate — say so cleanly.
        if case .running = appState.tailscale.state {
            // proceed
        } else {
            discoveryState = .unavailable(reason: "Connect Tailscale first to scan the tailnet.")
            return
        }
        let peers = await appState.tailscale.discoverPeers()
        discovered = peers
        peerPing = [:]
        discoveryState = .loaded(count: peers.count)
        await refreshVisiblePeerPings()
    }

    private func refreshVisiblePeerPings() async {
        guard isNew && kind == .tailscale else { return }
        guard case .loaded = discoveryState else { return }
        let peers = visiblePeers
        guard !peers.isEmpty else { return }
        guard tailscaleReady else {
            for peer in peers {
                peerPing[peer.id] = .unavailable(message: "Tailscale off")
            }
            return
        }
        guard let port = UInt16(portText) else { return }

        for peer in peers {
            peerPing[peer.id] = .checking
        }
        for peer in peers {
            let result = await appState.tailscale.pingMotifServer(host: peer.preferredAddress, port: port)
            guard !Task.isCancelled else { return }
            peerPing[peer.id] = ServerPingIndicator(result)
        }
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        UInt16(portText) != nil
    }

    private func hydrate() {
        if case .existing(let s) = target {
            name = s.name
            host = s.host
            portText = String(s.port)
            token = s.token
            kind = s.kind
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
            server = MotifServer(name: trimmedName, host: trimmedHost, port: port, token: trimmedToken, kind: kind)
        case .existing(let existing):
            server = MotifServer(id: existing.id, name: trimmedName, host: trimmedHost, port: port, token: trimmedToken, kind: kind)
        }
        onSave(server)
        dismiss()
    }
}

struct TailscaleStatusRow: View {
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
            case .degraded(let reason):
                LabeledContent("Status", value: "Reconnecting…").foregroundStyle(.orange)
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            case .failed(let m):
                LabeledContent("Status", value: "Failed").foregroundStyle(.red)
                Text(m).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}
