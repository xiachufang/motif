import SwiftUI

/// Bare info pane — bundle id, version, debug local-server port. No
/// connection or server management here; that's `ConnectionView`.
struct AboutView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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
                Section("Debug") {
                    if case .running(let port) = appState.serverState {
                        LabeledContent("Local server", value: "127.0.0.1:\(port)")
                    } else {
                        LabeledContent("Local server", value: "not running")
                    }
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
