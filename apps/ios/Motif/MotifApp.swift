import SwiftUI

@main
struct MotifApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                // Drive SwiftUI's environment tint from MotifTheme.accent so
                // every `.foregroundStyle(.tint)` and default-tinted control
                // matches the brand instead of system blue. Pairs with the
                // asset-catalog GLOBAL_ACCENT_COLOR_NAME binding.
                .tint(MotifTheme.accent)
        }
    }
}
