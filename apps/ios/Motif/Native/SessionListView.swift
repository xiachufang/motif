import SwiftUI
import UIKit
import OSLog
import TalkerCommonRouter

/// Browse / create / attach to motif sessions. After attach, push the
/// /session route so SessionView takes over.
struct SessionListView: View {
    @Environment(MotifClient.self) private var motif
    @Environment(AppState.self) private var appState
    @Environment(CmRouter.self) private var router

    @State private var loading: Bool = false
    @State private var error: String?
    @State private var attaching: String?
    @State private var creatingSheet: Bool = false
    /// Name of the session the user has asked to destroy. Drives the
    /// confirmation alert; non-nil means "alert is visible". Cleared in
    /// both the OK and Cancel branches.
    @State private var destroyTarget: String?

    var body: some View {
        // Always render a List so `.refreshable` is available across
        // every state (loading, empty, populated). The variants are
        // expressed as Section contents inside.
        List {
            if let error {
                Section {
                    HStack(alignment: .top, spacing: MotifTheme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(MotifTheme.danger)
                        Text(error)
                            .font(MotifTheme.Typography.footnote)
                            .foregroundStyle(MotifTheme.danger)
                    }
                }
            }
            if motif.sessions.isEmpty && loading {
                Section {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            } else if motif.sessions.isEmpty {
                Section {
                    emptyStateRow
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            } else {
                Section {
                    ForEach(motif.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await refresh() }
        .task { await refresh() }
        .onChange(of: motif.state) { _, newState in
            // After a transparent reconnect (failed → connecting → connected)
            // the existing .task fired only on first appear, so the list
            // would keep showing whatever sessions were cached pre-drop.
            // Re-fetch whenever we land back on .connected.
            if case .connected = newState {
                Task { await refresh() }
            }
            // A connect (possibly after switching servers for a deep link) is
            // also when a pending notification tap can finally route.
            consumeDeepLinkIfReady()
        }
        .onChange(of: appState.pendingDeepLink) { _, _ in
            consumeDeepLinkIfReady()
        }
        .toolbar {
            // Leading slot — NativeRoot's `rootToolbar` already owns the
            // `.principal` (server picker) and `.topBarTrailing` (info)
            // placements, so put the create CTA on the opposite side
            // instead of fighting for trailing space.
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    creatingSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(attaching != nil)
            }
        }
        .sheet(isPresented: $creatingSheet) {
            CreateSessionSheet { name, workdir in
                creatingSheet = false
                await createAndAttach(name: name, workdir: workdir)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert("Destroy session?",
               isPresented: Binding(
                   get: { destroyTarget != nil },
                   set: { if !$0 { destroyTarget = nil } })) {
            Button("Destroy", role: .destructive) {
                if let name = destroyTarget {
                    Task { await destroy(name) }
                }
            }
            Button("Cancel", role: .cancel) { destroyTarget = nil }
        } message: {
            if let name = destroyTarget {
                Text("This will kill all PTYs in '\(name)' and disconnect any clients still attached. The action cannot be undone.")
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func sessionRow(_ session: MotifProto.SessionInfo) -> some View {
        Button {
            Task { await attach(session.name) }
        } label: {
            HStack(alignment: .center, spacing: MotifTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: MotifTheme.Spacing.xs) {
                    Text(session.name)
                        .font(MotifTheme.Typography.body)
                        .foregroundStyle(MotifTheme.textPrimary)
                        .lineLimit(1)
                    if let wd = session.workdir, !wd.isEmpty {
                        Label {
                            Text(wd)
                                .font(MotifTheme.Typography.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "folder")
                                .font(MotifTheme.Typography.caption2)
                        }
                        .foregroundStyle(MotifTheme.textSecondary)
                    }
                    HStack(spacing: 10) {
                        if let count = session.client_count, count > 0 {
                            Label("\(count) attached", systemImage: "person.2.fill")
                                .labelStyle(.titleAndIcon)
                                .font(MotifTheme.Typography.caption2)
                                .foregroundStyle(.tint)
                        }
                        if let ms = session.created_at, ms > 0 {
                            Text(relativeTime(unixMs: ms))
                                .font(MotifTheme.Typography.caption2)
                                .foregroundStyle(MotifTheme.textTertiary)
                        }
                    }
                }
                Spacer(minLength: MotifTheme.Spacing.sm)
                if attaching == session.name {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(MotifTheme.Typography.footnote.weight(.semibold))
                        .foregroundStyle(MotifTheme.textTertiary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, MotifTheme.Spacing.xs)
        }
        .buttonStyle(.plain)
        .disabled(attaching != nil)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                destroyTarget = session.name
            } label: {
                Label("Destroy", systemImage: "trash")
            }
            .disabled(attaching != nil)
        }
    }

    // MARK: - Empty state

    /// Hosted inside a List row so `.refreshable` still fires when the
    /// user pulls down from this state. The error string also lives in
    /// its own list section above, but we mirror it here too so users
    /// reading the empty-state copy don't miss it.
    private var emptyStateRow: some View {
        VStack(spacing: MotifTheme.Spacing.lg) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(MotifTheme.Typography.symbol(size: 44, weight: .light))
                .foregroundStyle(MotifTheme.textTertiary)
            VStack(spacing: MotifTheme.Spacing.xs) {
                Text("No sessions yet")
                    .font(MotifTheme.Typography.headline)
                Text("Create one to attach a workspace on this server.")
                    .font(MotifTheme.Typography.footnote)
                    .foregroundStyle(MotifTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                creatingSheet = true
            } label: {
                Label("Create session", systemImage: "plus.circle.fill")
            }
            .buttonStyle(MotifButtonStyle(role: .filled, size: .medium))
        }
        .padding(.vertical, MotifTheme.Spacing.xxl)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func refresh() async {
        loading = true
        error = nil
        await motif.refreshSessions()
        loading = false
    }

    /// Route a tapped push notification to its session, once we're connected to
    /// the right server. If the link maps to a different configured server,
    /// switch to it first (this re-keys NativeRoot's connect task); the
    /// motif.state change after reconnect re-invokes this and completes the nav.
    private func consumeDeepLinkIfReady() {
        guard let link = appState.pendingDeepLink, let name = link.sessionName, !name.isEmpty else {
            return
        }
        // If the link names a server we know and it isn't active, switch first.
        if let inst = link.instanceID,
           let sid = PushManager.shared.server(forInstance: inst),
           let target = UUID(uuidString: sid),
           appState.servers.activeServer?.id != target
        {
            appState.servers.setActive(id: target)
            return // wait for the reconnect; re-entered via onChange(of: motif.state)
        }
        // Need a live connection on the (now-correct) server before attaching.
        switch motif.state {
        case .connected, .attached: break
        default: return
        }
        appState.pendingDeepLink = nil // clear before awaiting to avoid re-entry
        Task { await attach(name) }
    }

    private func attach(_ name: String) async {
        attaching = name
        defer { attaching = nil }
        do {
            try await motif.attach(sessionName: name)
            let (path, query) = SessionView.route(name: name)
            router.push(CmRouterPath(path, query))
        } catch {
            self.error = "attach \(name): \(error)"
        }
    }

    private func createAndAttach(name: String, workdir: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let workdir = workdir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !workdir.isEmpty else { return }
        attaching = name
        defer { attaching = nil }
        do {
            _ = try await motif.createSession(name: name, workdir: workdir)
            try await motif.attach(sessionName: name)
            let (path, query) = SessionView.route(name: name)
            router.push(CmRouterPath(path, query))
        } catch {
            self.error = "create \(name): \(error)"
        }
    }

    private func destroy(_ name: String) async {
        destroyTarget = nil
        do {
            try await motif.destroySession(name: name)
            await refresh()
        } catch {
            self.error = "destroy \(name): \(error)"
        }
    }

    /// "2h ago", "Just now", etc. Lazy formatter — kept around so we
    /// don't re-allocate one per row repaint when the list scrolls.
    private func relativeTime(unixMs: UInt64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000)
        return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// Modal create-session form. Lifted out of the list so the parent screen
/// stays scroll-only — entering "name + workdir" used to push the list
/// down out of view on smaller iPhones whenever the keyboard came up.
private struct CreateSessionSheet: View {
    let onCreate: (_ name: String, _ workdir: String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var workdir: String = "~"
    @State private var submitting: Bool = false
    @FocusState private var focused: Field?
    private enum Field { case name, workdir }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focused, equals: .name)
                        .onSubmit { focused = .workdir }
                    TextField("Working directory", text: $workdir)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.go)
                        .focused($focused, equals: .workdir)
                        .onSubmit { if isValid { submit() } }
                } footer: {
                    Text("Working directory must exist on the server. ~ expands to the motifd user's home.")
                }
            }
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Create") { submit() }
                            .disabled(!isValid)
                    }
                }
            }
            .onAppear { focused = .name }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !workdir.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        submitting = true
        Task {
            await onCreate(name, workdir)
            submitting = false
        }
    }
}
