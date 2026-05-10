import SwiftUI

@main
struct MotifApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .preferredColorScheme(.dark)
                .ignoresSafeArea(.keyboard, edges: .bottom)
        }
    }
}
