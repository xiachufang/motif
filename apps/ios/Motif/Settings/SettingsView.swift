import SwiftUI
import TalkerCommonLogging
import UIKit

/// App settings sheet — bundle/version info plus diagnostics. Server
/// management lives in `ConnectionView`; this sheet is everything else.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var exportState: ExportState = .idle
    @State private var shareItem: ShareItem?

    private enum ExportState: Equatable {
        case idle
        case packaging
        case failed(String)
    }

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
                } header: {
                    Text("About")
                }

                Section {
                    Button {
                        exportLogs()
                    } label: {
                        HStack {
                            Label("Export Logs", systemImage: "square.and.arrow.up")
                            Spacer()
                            if case .packaging = exportState {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .disabled(exportState == .packaging)

                    if case .failed(let message) = exportState {
                        Text(message)
                            .font(MotifTheme.Typography.footnote)
                            .foregroundStyle(MotifTheme.danger)
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Packages everything under Documents/logs/ (motif rotating log + tsnet.log) into a zip and hands it to the system share sheet.")
                        .font(MotifTheme.Typography.caption2)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityShareView(items: [item.url]) {
                    shareItem = nil
                }
            }
        }
    }

    private func exportLogs() {
        exportState = .packaging
        Task {
            // TalkerCommonLogging.exportLogs() zips Documents/logs/ via
            // ZIPFoundation on a detached task; tsnet.log lives under that
            // same directory so it rides along automatically.
            let url = await TalkerCommonLogging.exportLogs()
            exportState = .idle
            // Present as a child sheet of the Settings sheet via SwiftUI's
            // `.sheet(item:)`. We deliberately do NOT use TalkerCommon's
            // `presentActivityController(items:)` here: that helper grabs
            // the keyWindow's root view controller and presents on it,
            // which UIKit refuses because the root VC is already
            // presenting *this* Settings sheet ("Attempt to present
            // UIActivityViewController on … which is already presenting").
            shareItem = ShareItem(url: url)
        }
    }
}

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Bridges UIActivityViewController into a SwiftUI `.sheet`. Going through
/// SwiftUI's presentation chain lets us stack the share sheet on top of
/// the Settings sheet — `presentActivityController` from TalkerCommon
/// targets the root VC and would collide with the in-flight Settings
/// sheet.
private struct ActivityShareView: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: (() -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in
            onComplete?()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
