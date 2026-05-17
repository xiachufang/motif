import SwiftUI

/// Bare info pane — bundle id + version. No connection or server
/// management here; that's `ConnectionView`.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

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
