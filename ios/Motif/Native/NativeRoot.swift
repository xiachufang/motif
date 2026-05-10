import SwiftUI

/// Top-level native router after a server is configured. Owns the
/// MotifClient lifecycle: connect → list/attach a session → present the
/// terminal. Replaces the WKWebView path entirely.
struct NativeRoot: View {
    @Environment(MotifClient.self) private var motif
    let localPort: UInt16
    @State private var connectError: String?

    var body: some View {
        Group {
            switch motif.state {
            case .disconnected, .connecting:
                connectingView
            case .failed(let m):
                failedView(message: m)
            case .connected:
                NavigationStack {
                    SessionListView()
                        .navigationTitle("motif")
                }
            case .attached:
                NavigationStack {
                    SessionView()
                        .navigationTitle(sessionTitle)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button {
                                    Task { await motif.disconnect() }
                                } label: {
                                    Image(systemName: "rectangle.portrait.and.arrow.right")
                                }
                            }
                        }
                }
            }
        }
        .task(id: localPort) {
            await motif.connect(localPort: localPort)
        }
    }

    private var sessionTitle: String {
        if case .attached(let name) = motif.state { return name }
        return "motif"
    }

    private var connectingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Connecting…").foregroundStyle(.secondary)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.yellow)
            Text("Connection failed").font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Retry") {
                Task { await motif.connect(localPort: localPort) }
            }
        }
    }
}
