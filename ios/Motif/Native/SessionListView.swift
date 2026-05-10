import SwiftUI
import TalkerCommonRouter

/// Browse / create / attach to motif sessions. After attach, push the
/// /session route so SessionView takes over.
struct SessionListView: View {
    @Environment(MotifClient.self) private var motif
    @Environment(CmRouter.self) private var router

    @State private var loading: Bool = false
    @State private var error: String?
    @State private var creatingName: String = ""
    @State private var creatingWorkdir: String = "~"
    @State private var attaching: String?

    var body: some View {
        List {
            Section {
                if motif.sessions.isEmpty && !loading {
                    Text("No sessions on this server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(motif.sessions) { session in
                        Button {
                            Task { await attach(session.name) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.name)
                                        .foregroundStyle(.primary)
                                    if let wd = session.workdir {
                                        Text(wd).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if attaching == session.name {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.right.circle")
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(attaching != nil)
                    }
                }
            } header: {
                HStack {
                    Text("Sessions")
                    Spacer()
                    Button {
                        Task { await refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.footnote)
                    }
                }
            }

            Section {
                TextField("name", text: $creatingName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("working directory", text: $creatingWorkdir)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                Button("Create + attach") {
                    Task { await createAndAttach() }
                }
                .disabled(!isCreateValid || attaching != nil)
            } header: {
                Text("New session")
            } footer: {
                Text("Working directory must exist on the server. ~ expands to the motifd user's home.")
                    .font(.caption2)
            }

            if let error {
                Section {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        loading = true
        error = nil
        await motif.refreshSessions()
        loading = false
    }

    private func attach(_ name: String) async {
        attaching = name
        defer { attaching = nil }
        do {
            try await motif.attach(sessionName: name)
            router.push(CmRouterPath("/session", ["name": name]))
        } catch {
            self.error = "attach \(name): \(error)"
        }
    }

    private func createAndAttach() async {
        let name = creatingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let workdir = creatingWorkdir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !workdir.isEmpty else { return }
        attaching = name
        defer { attaching = nil }
        do {
            _ = try await motif.createSession(name: name, workdir: workdir)
            try await motif.attach(sessionName: name)
            creatingName = ""
            creatingWorkdir = "~"
            router.push(CmRouterPath("/session", ["name": name]))
        } catch {
            self.error = "create \(name): \(error)"
        }
    }

    private var isCreateValid: Bool {
        !creatingName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !creatingWorkdir.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// After session.attach succeeds, show the PTY list + the active terminal.
/// Minimal MVP UI: tap a PTY to make it the active terminal; tap "New PTY"
/// to spawn one.
struct SessionView: View {
    @Environment(MotifClient.self) private var motif
    @State private var activePtyID: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            ptyBar
            Divider()
            terminalArea
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .background(Color.black)
        .task {
            // Auto-pick the first PTY (or auto-create one) so the user
            // lands on a working terminal without an extra tap.
            if activePtyID == nil {
                if let first = motif.ptys.first(where: { $0.alive ?? true }) {
                    activePtyID = first.id
                } else {
                    await spawnPty()
                }
            }
        }
    }

    private var ptyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(motif.ptys) { pty in
                    Button {
                        activePtyID = pty.id
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "terminal")
                            Text(String(pty.id.suffix(6)))
                                .font(.caption.monospaced())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(pty.id == activePtyID ? Color.white.opacity(0.15) : Color.white.opacity(0.05),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
                Button {
                    Task { await spawnPty() }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .foregroundStyle(.tint)
            }
            .padding(8)
        }
        .background(Color.black)
    }

    private var terminalArea: some View {
        Group {
            if let id = activePtyID, let info = motif.ptys.first(where: { $0.id == id }) {
                PtyTerminal(
                    ptyID: id,
                    initialCols: info.cols,
                    initialRows: info.rows,
                    client: motif
                )
                .id(id)  // re-instantiate on PTY switch
            } else {
                Text("No active PTY")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
    }

    private func spawnPty() async {
        do {
            let info = try await motif.createPty()
            activePtyID = info.id
        } catch {
            self.error = "pty.create: \(error)"
        }
    }
}
