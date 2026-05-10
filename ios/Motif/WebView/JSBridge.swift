import Foundation
import WebKit
import OSLog

/// Bridge between the embedded motif-web JS and native Swift.
///
/// Web → Native: `window.webkit.messageHandlers.motif.postMessage({type, ...})`
/// Native → Web: `window.motifNative?.<event>(payload)` via evaluateJavaScript.
///
/// The bridge is intentionally minimal — networking goes through the local
/// HTTP server (and in P3, the Tailscale reverse proxy), so this channel only
/// carries platform features the web has no access to: ASR (mic capture +
/// Doubao recognition) and a small handful of settings hooks.
@MainActor
final class JSBridge: NSObject {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "JSBridge")
    private weak var webView: WKWebView?

    /// Inject a globally-available `motif.*` namespace and the message handler.
    /// Called once from WebViewContainer when the WKWebView is created.
    static func install(on webView: WKWebView) -> JSBridge {
        let bridge = JSBridge()
        bridge.webView = webView

        let userScript = WKUserScript(
            source: Self.bootstrapScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        webView.configuration.userContentController.addUserScript(userScript)
        webView.configuration.userContentController.addScriptMessageHandler(
            bridge, contentWorld: .page, name: "motif"
        )
        return bridge
    }

    /// Push a typed event to the web side. Safe to call from any actor — we
    /// hop to MainActor before touching WKWebView.
    nonisolated func emit(_ event: String, payload: [String: Any]) {
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        let eventLiteral = Self.escapeJSString(event)
        Task { @MainActor in
            guard let webView = self.webView else { return }
            let script = "window.motifNative && window.motifNative.dispatch(\(eventLiteral), \(json));"
            do {
                _ = try await webView.evaluateJavaScript(script)
            } catch {
                self.log.error("emit \(event, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Message dispatch

    /// Override-style handler called by the WKScriptMessageHandlerWithReply impl.
    /// Returns a JSON-serializable value, or throws.
    private func handle(message: [String: Any]) async throws -> Any? {
        guard let type = message["type"] as? String else {
            throw BridgeError.malformed("missing type")
        }
        switch type {
        case "ping":
            return ["pong": true, "ts": Date().timeIntervalSince1970]

        case "platform.info":
            return [
                "platform": "ios",
                "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            ]

        case "asr.start":
            // P5 hookup: start AudioCapture + Doubao session
            log.notice("asr.start (stub)")
            throw BridgeError.notImplemented("asr.start — wired in P5")

        case "asr.stop":
            log.notice("asr.stop (stub)")
            throw BridgeError.notImplemented("asr.stop — wired in P5")

        default:
            throw BridgeError.unknownType(type)
        }
    }

    enum BridgeError: Error, CustomStringConvertible {
        case malformed(String)
        case unknownType(String)
        case notImplemented(String)

        var description: String {
            switch self {
            case .malformed(let m): return "malformed message: \(m)"
            case .unknownType(let t): return "unknown message type: \(t)"
            case .notImplemented(let m): return "not implemented: \(m)"
            }
        }
    }

    // MARK: - Bootstrap script

    /// Injected at document-start. Defines a stable surface for web code:
    ///   - window.motif.invoke(type, params): Promise<any>
    ///   - window.motifNative.dispatch(event, payload): called by Swift via eval
    ///   - window.motifNative.on(event, handler): subscribe
    private static let bootstrapScript: String = #"""
    (function() {
        if (window.motif) return;
        const handlers = new Map(); // event -> Set<fn>

        function invoke(type, params) {
            const msg = Object.assign({ type }, params || {});
            return window.webkit.messageHandlers.motif.postMessage(msg);
        }

        const motifNative = {
            dispatch(event, payload) {
                const set = handlers.get(event);
                if (!set) return;
                for (const fn of Array.from(set)) {
                    try { fn(payload); } catch (e) { console.error("motif handler", event, e); }
                }
            },
            on(event, fn) {
                let set = handlers.get(event);
                if (!set) { set = new Set(); handlers.set(event, set); }
                set.add(fn);
                return () => set.delete(fn);
            },
            // Marker so web code can detect "running inside the iOS App".
            isNative: true,
            platform: "ios"
        };

        window.motif = { invoke };
        window.motifNative = motifNative;
    })();
    """#

    nonisolated private static func escapeJSString(_ s: String) -> String {
        // Use JSONSerialization to get a safely-quoted JS string literal.
        if let data = try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed]),
           let arr = String(data: data, encoding: .utf8),
           arr.count >= 2 {
            // arr is like ["foo"]; strip the brackets
            return String(arr.dropFirst().dropLast())
        }
        return "\"\""
    }
}

extension JSBridge: WKScriptMessageHandlerWithReply {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @Sendable (Any?, String?) -> Void
    ) {
        Task { @MainActor in
            // WKScriptMessage.body is main-actor-isolated in iOS 18 SDK, so we
            // dereference it inside the MainActor context.
            guard let body = message.body as? [String: Any] else {
                replyHandler(nil, "malformed message: not an object")
                return
            }
            do {
                let result = try await self.handle(message: body)
                replyHandler(result, nil)
            } catch {
                replyHandler(nil, String(describing: error))
            }
        }
    }
}
