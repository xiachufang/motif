import SwiftUI

/// Shown on launch when no motifd server is configured. Surfaces Tailscale
/// status (so the user knows whether peer discovery will work) plus the
/// add-server flow front and center, instead of dumping the user into a
/// blank WebView and forcing them to find the gear icon.
struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    @State private var serverEditTarget: ServerEdit?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome to motif")
                            .font(.title2.bold())
                        Text("Add a motifd server to start. The app will connect to it through your tailnet.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    TailscaleEntry()
                } header: {
                    Text("Tailscale")
                } footer: {
                    Text("motifd is reached over the tailnet. Connect first to discover servers automatically.")
                        .font(.caption2)
                }

                Section {
                    if appState.servers.servers.isEmpty {
                        Text("No servers yet.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.servers.servers) { server in
                            ServerRow(
                                server: server,
                                isActive: appState.servers.activeID == server.id,
                                onTap: {
                                    appState.servers.setActive(id: server.id)
                                    appState.bumpWebViewReload()
                                },
                                onEdit: { serverEditTarget = .existing(server) }
                            )
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                let id = appState.servers.servers[idx].id
                                appState.servers.delete(id: id)
                            }
                        }
                    }
                    Button {
                        serverEditTarget = .new
                    } label: {
                        Label("Add Server", systemImage: "plus.circle.fill")
                            .font(.headline)
                    }
                } header: {
                    Text("Servers")
                }
            }
            .navigationTitle("motif")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.isShowingAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(item: $serverEditTarget) { target in
                ServerEditSheet(target: target) { updated in
                    switch target {
                    case .new:
                        appState.servers.add(updated)
                        appState.bumpWebViewReload()
                    case .existing:
                        appState.servers.update(updated)
                    }
                }
                .environment(appState)
            }
        }
    }

}
