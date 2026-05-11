import SwiftUI

/// Bare info pane — bundle id + version + terminal backend toggle. No
/// connection or server management here; that's `ConnectionView`.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "?")
                    LabeledContent("Version") {
                        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                        Text("\(v) (\(b))")
                    }
                }
                Section {
                    Picker("Backend", selection: $appState.terminalBackend) {
                        ForEach(TerminalBackend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .pickerStyle(.inline)
                } header: {
                    Text("Terminal")
                } footer: {
                    Text("Switching rebuilds the active PTY view; scrollback is replayed from the ring buffer.")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
