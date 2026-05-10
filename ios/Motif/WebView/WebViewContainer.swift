import SwiftUI
import WebKit
import OSLog

struct WebViewContainer: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.bridge = JSBridge.install(on: webView)
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isInspectable = true
        webView.backgroundColor = .black
        webView.isOpaque = false
        webView.scrollView.backgroundColor = .black

        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let log = Logger(subsystem: "io.allsunday.motif", category: "WebView")
        var bridge: JSBridge?


        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            // Only allow our local origin and ws/wss to it.
            if let host = url.host, host == "127.0.0.1" || host == "localhost" {
                return .allow
            }
            // Block navigations to external HTTP(S); open them via system browser instead.
            if let scheme = url.scheme, ["http", "https"].contains(scheme) {
                let opened = await UIApplication.shared.open(url)
                if !opened {
                    log.error("failed to open external url \(url.absoluteString, privacy: .public)")
                }
                return .cancel
            }
            return .allow
        }
    }
}
