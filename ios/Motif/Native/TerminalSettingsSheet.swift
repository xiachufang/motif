import SwiftUI

/// Terminal appearance settings: font size + light/dark theme. Edits write
/// straight through to `appState.terminalSettings`; the SessionView observes
/// those and pushes them live to every open terminal.
struct TerminalSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = appState.terminalSettings
        NavigationStack {
            Form {
                Section("Font") {
                    Stepper(
                        value: $settings.fontSize,
                        in: TerminalSettingsStore.minFontSize...TerminalSettingsStore.maxFontSize,
                        step: 1
                    ) {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text("\(Int(settings.fontSize)) pt")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                Section {
                    Picker("Appearance", selection: $settings.theme) {
                        ForEach(TerminalThemeSetting.allCases, id: \.self) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Theme")
                } footer: {
                    Text("Applies to all terminals immediately. System follows your iOS appearance.")
                }
            }
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
