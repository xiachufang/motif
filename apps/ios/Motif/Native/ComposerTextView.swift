import SwiftUI
import UIKit

/// UIKit-backed multiline editor for the composer pill. We use this in
/// place of SwiftUI's `TextField(..., axis: .vertical)` so the delegate
/// can hand us `textViewDidChangeSelection` — the only signal UIKit
/// emits for "the user touched the caret/selection without changing the
/// text" (tap-to-place, magnifier drag, hardware arrow keys). That's the
/// last piece BottomInputBar's "any user activity ends recording" net
/// needs; the window-level `ASRBailGestureMonitor` covers everything
/// outside the text view.
///
/// Design points:
///
/// - `textContainerInset = .zero` and `lineFragmentPadding = 0` so the
///   placeholder Text overlay in SwiftUI aligns pixel-perfect with the
///   first character.
/// - `isScrollEnabled = true` so multi-page content can scroll instead
///   of getting clipped; height is clamped externally to `1..5` lines
///   via `contentHeight`, which the coordinator reports from
///   `sizeThatFits`.
/// - Programmatic writes (`uiView.text = text`) DON'T trigger the
///   selection-change delegate per UIKit's documented contract, so ASR
///   partials won't accidentally bail themselves out. A coordinator
///   `isApplyingExternalText` flag is kept anyway as a defensive shim
///   in case Apple changes that behaviour in a future release.
/// - Focus syncs both directions: external `isFocused = true` triggers
///   `becomeFirstResponder()`; the delegate's begin/end-editing
///   callbacks write back into the binding so `.onChange(of: focused)`
///   in BottomInputBar still fires when the user dismisses the keyboard.
struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let isEnabled: Bool
    @Binding var isFocused: Bool
    @Binding var contentHeight: CGFloat
    let onSelectionChange: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = UIFont.preferredFont(forTextStyle: .body)
        tv.adjustsFontForContentSizeCategory = true
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        // Allow internal scrolling once the content exceeds the clamp the
        // SwiftUI parent applies. Without this, lines beyond row 5 would
        // simply get clipped behind the capsule.
        tv.isScrollEnabled = true
        // Trim a bit of UITextView's default vertical text inset so a
        // single line lines up with the placeholder overlay.
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            context.coordinator.isApplyingExternalText = true
            uiView.text = text
            context.coordinator.isApplyingExternalText = false
        }
        uiView.isEditable = isEnabled

        if isFocused, !uiView.isFirstResponder, isEnabled {
            uiView.becomeFirstResponder()
        } else if !isFocused, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }

        // Report intrinsic height. `sizeThatFits` ignores `isScrollEnabled`
        // and returns the actual content height for the given width, which
        // is exactly what we want to clamp on the SwiftUI side. Dispatched
        // so we don't mutate a @Binding from inside the SwiftUI update pass.
        let target = uiView.sizeThatFits(
            CGSize(width: max(1, uiView.bounds.width), height: .greatestFiniteMagnitude)
        ).height
        if abs(target - contentHeight) > 0.5 {
            DispatchQueue.main.async {
                contentHeight = target
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        /// True while `updateUIView` is pushing the SwiftUI binding back
        /// into the UITextView. Used as a defensive guard inside the
        /// selection-change delegate: UIKit documents programmatic
        /// `.text =` writes as NOT triggering this delegate, but we'd
        /// rather not bet the recording-stop semantics on undocumented
        /// invariants.
        var isApplyingExternalText: Bool = false

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            // Only mutate the binding when the user actually typed —
            // otherwise the assignment from `updateUIView` would echo
            // back through here and cause an unnecessary SwiftUI pass.
            if parent.text != textView.text {
                parent.text = textView.text
            }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingExternalText else { return }
            parent.onSelectionChange()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isFocused { Task {@MainActor in parent.isFocused = true }}
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isFocused { Task {@MainActor in parent.isFocused = false }}
        }
    }
}
