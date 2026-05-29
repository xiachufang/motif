import SwiftUI

/// Manage all quick-command sets: the shared **Global** list plus any named
/// sets. Each set has a free display name and a list of programs it matches;
/// tap a row to edit it; "+" creates a new set (seeded from Global); swipe to
/// delete. Pushed onto the quick-command editor's navigation stack (via the
/// "all sets" toolbar button), so it embeds no NavigationStack of its own.
struct QuickCommandSetsView: View {
    /// Program name of whatever is currently running in the active PTY, if
    /// any — offered as a one-tap "customize this" shortcut in the + menu.
    var runningProgram: String? = nil

    @Environment(AppState.self) private var appState

    @State private var promptingNew = false
    @State private var newName = ""
    /// Set after creating a set to programmatically push its editor.
    @State private var navSetID: UUID?

    var body: some View {
        List {
            Section {
                NavigationLink {
                    QuickCommandListEditor(scope: .global)
                } label: {
                    setRow(title: "Global", count: appState.commands.commands.count, systemImage: "globe")
                }
            } footer: {
                Text("Shown whenever no set matches what's running.")
            }

            Section("Sets") {
                if appState.commands.sets.isEmpty {
                    Text("No sets yet.")
                        .foregroundStyle(MotifTheme.textSecondary)
                }
                ForEach(appState.commands.sets) { set in
                    NavigationLink {
                        QuickCommandListEditor(scope: .set(set.id))
                    } label: {
                        setRow(title: set.name,
                               count: set.commands.count,
                               systemImage: "terminal",
                               subtitle: matchesSummary(set))
                    }
                }
                .onDelete { offsets in
                    let snap = appState.commands.sets
                    for i in offsets { appState.commands.removeSet(snap[i].id) }
                }
            }
        }
        .navigationTitle("Command sets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let running = runningProgram,
                       !appState.commands.sets.contains(where: { $0.matches.contains(running) }) {
                        Button {
                            createAndOpen(name: running, matches: [running])
                        } label: { Label("Customize \(running)", systemImage: "wand.and.stars") }
                    }
                    Button {
                        newName = ""
                        promptingNew = true
                    } label: { Label("New set…", systemImage: "plus") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .alert("New set", isPresented: $promptingNew) {
            TextField("Set name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    createAndOpen(name: name, matches: runningProgram.map { [$0] } ?? [])
                }
            }
        } message: {
            Text("Buttons shown while a matched program is running. Seeded from Global.")
        }
        .navigationDestination(item: $navSetID) { id in
            QuickCommandListEditor(scope: .set(id))
        }
    }

    private func createAndOpen(name: String, matches: [String]) {
        navSetID = appState.commands.createSet(name: name, matches: matches)
    }

    private func matchesSummary(_ set: QuickCommandSet) -> String {
        set.matches.isEmpty
            ? "matches nothing yet"
            : "matches: " + set.matches.joined(separator: ", ")
    }

    @ViewBuilder
    private func setRow(title: String, count: Int, systemImage: String,
                        mono: Bool = false, subtitle: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(mono ? .body.monospaced() : .body)
                if let subtitle {
                    Text(subtitle)
                        .font(MotifTheme.Typography.caption)
                        .foregroundStyle(MotifTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Text("\(count)")
                .font(MotifTheme.Typography.caption.monospaced())
                .foregroundStyle(MotifTheme.textSecondary)
        }
    }
}
