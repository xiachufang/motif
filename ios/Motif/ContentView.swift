import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch appState.serverState {
            case .starting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting local server…")
                        .foregroundStyle(.secondary)
                }
            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.yellow)
                    Text("Local server failed")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
            case .running(let port):
                WebViewContainer(url: URL(string: "http://127.0.0.1:\(port)/index.html")!)
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        appState.isShowingSettings.toggle()
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(8)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .padding(.trailing, 12)
                    .padding(.top, 6)
                }
                Spacer()
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        .sheet(isPresented: Binding(
            get: { appState.isShowingSettings },
            set: { appState.isShowingSettings = $0 }
        )) {
            SettingsView()
                .environment(appState)
        }
        .task {
            await appState.startServerIfNeeded()
        }
    }
}

#Preview {
    ContentView().environment(AppState())
}
