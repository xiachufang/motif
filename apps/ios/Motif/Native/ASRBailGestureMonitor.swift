import UIKit

/// Window-level gesture net armed while ASR is recording. Any tap, pan,
/// or long-press anywhere on screen invokes `onBail`. The recognizers run
/// with `cancelsTouchesInView=false` and a permissive delegate, so they
/// observe-but-don't-eat the touch: every underlying button / TextField /
/// scroll view still receives its normal events. We fire `onBail` on
/// `.began` only, so a long pan doesn't spam the callback.
///
/// Coverage notes:
/// - Anywhere on the app's own UI (buttons, terminal, lists): tap / pan /
///   long-press are caught here.
/// - Hardware keyboard character keys: still flow through the focused
///   TextField and mutate `buffer`, which the existing `onChange(of:
///   buffer)` watcher converts into a bail.
/// - Soft keyboard taps and the keyboard's own surface live in the
///   *keyboard* UIWindow, which UIKit hides from app-level gesture
///   recognizers. Character keys still go through buffer changes; pure
///   cursor moves (tap-to-place, magnifier drag) inside the focused
///   TextField don't surface a SwiftUI event and are NOT caught here —
///   covering those requires swapping the TextField for a
///   UIViewRepresentable wrapper around UITextView and watching
///   `textViewDidChangeSelection`.
@MainActor
final class ASRBailGestureMonitor: NSObject, UIGestureRecognizerDelegate {
    private var recognizers: [UIGestureRecognizer] = []
    private weak var window: UIWindow?
    private var onBail: (() -> Void)?
    /// Latest window-space rect of the mic button, queried per touch. Touches
    /// inside it are the explicit stop control and must NOT trip the bail net
    /// (otherwise a stop-tap bails on touch-down, the button then sees
    /// `isRecording == false` on touch-up and restarts — recording never
    /// actually stops). Provider closure so we always read the current frame.
    private var excludedFrame: (() -> CGRect)?

    func install(excludedFrame: @escaping () -> CGRect, onBail: @escaping () -> Void) {
        guard window == nil else { return }
        guard let win = Self.activeKeyWindow() else { return }
        self.window = win
        self.onBail = onBail
        self.excludedFrame = excludedFrame

        let tap = UITapGestureRecognizer(target: self, action: #selector(handle(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
        // 0s long-press == "any touch held" — fires on press-and-hold cases
        // that tap alone misses (pressing inside a scroll view without
        // dragging far enough to count as a pan).
        longPress.minimumPressDuration = 0
        let recs: [UIGestureRecognizer] = [tap, pan, longPress]
        for r in recs {
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.delaysTouchesEnded = false
            r.delegate = self
            win.addGestureRecognizer(r)
        }
        recognizers = recs
    }

    func uninstall() {
        if let win = window {
            for r in recognizers { win.removeGestureRecognizer(r) }
        }
        recognizers.removeAll()
        window = nil
        onBail = nil
        excludedFrame = nil
    }

    @objc private func handle(_ rec: UIGestureRecognizer) {
        // Continuous recognizers (pan, longPress) cycle through .began →
        // .changed → .ended. Only fire on the first state transition so a
        // long drag doesn't call the closure on every frame. Tap is
        // discrete and lands in .recognized.
        switch rec.state {
        case .began, .recognized:
            onBail?()
        default:
            break
        }
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ g: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Let the mic button's own tap through untouched — it's the explicit
        // start/stop toggle, not a "user did something else" bail trigger.
        guard let rect = excludedFrame?(), !rect.isEmpty else { return true }
        // `location(in: nil)` is window coordinates, which line up with
        // SwiftUI's `.global` space the frame was captured in.
        return !rect.contains(touch.location(in: nil))
    }

    func gestureRecognizer(
        _ g: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Critical — we're observing, not stealing. Returning true here is
        // what lets tableviews keep scrolling, buttons keep clicking, and
        // the TextField's own selection gestures keep working while our
        // monitor also fires.
        true
    }

    func gestureRecognizer(
        _ g: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    func gestureRecognizer(
        _ g: UIGestureRecognizer,
        shouldBeRequiredToFailBy other: UIGestureRecognizer
    ) -> Bool {
        false
    }

    private static func activeKeyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let active = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        return active?.windows.first(where: \.isKeyWindow) ?? active?.windows.first
    }
}
