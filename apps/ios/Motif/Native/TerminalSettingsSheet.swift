import SwiftUI

/// Terminal appearance settings: font size + light/dark theme. Edits write
/// straight through to `appState.terminalSettings`; the SessionView observes
/// those and pushes them live to every open terminal.
struct TerminalSettingsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    /// Currently-attached session name, if any — scopes the per-session toggle.
    private var attachedSession: String? {
        if case .attached(let s) = appState.motif.state { return s }
        return nil
    }

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
                                .foregroundStyle(MotifTheme.textSecondary)
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
                Section {
                    Toggle("Push Notifications", isOn: Binding(
                        get: { PushManager.shared.pushEnabled },
                        set: { PushManager.shared.setPushEnabled($0) }
                    ))
                    if let session = attachedSession {
                        Toggle("Notify for “\(session)”", isOn: Binding(
                            get: { !PushManager.shared.isSessionMuted(session) },
                            set: { PushManager.shared.setSessionMuted(session, muted: !$0) }
                        ))
                        .disabled(!PushManager.shared.pushEnabled)
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Get notified on this device when Claude needs your input or finishes — even when Motif is closed. Turn off the top switch to stop all notifications here; turn off a session to mute just that one.")
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
