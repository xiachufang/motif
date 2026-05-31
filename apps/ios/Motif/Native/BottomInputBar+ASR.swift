import SwiftUI
import DoubaoASR

// Mic / ASR lifecycle for `BottomInputBar`. Entry points called from the core
// view (`toggleRecording`, `bailOutOfASR`, `handleComposerSelectionChange`,
// `stopASR`, `stopASRSync`, `focusComposer`) are `internal`.
extension BottomInputBar {
    // MARK: - Mic / ASR

    func toggleRecording() {
        if isRecording {
            // Explicit user stop — keep `ignoreFinalTranscript = false`
            // so the final transcript merges in.
            ignoreFinalTranscript = false
            stopASR()
        } else {
            Task { await startASR() }
        }
    }

    /// Any deliberate user action other than a manual mic re-tap (Send,
    /// typed key, quick command tap, sticky-modifier toggle, …) counts as
    /// "I'm done dictating, do this instead." Drop the in-flight final
    /// transcript so it doesn't get merged on top of whatever the action
    /// just produced (typed char, pasted bytes, sent payload, etc.).
    /// No-op when not recording.
    func bailOutOfASR() {
        guard isRecording else { return }
        ignoreFinalTranscript = true
        stopASR()
    }

    /// Fired by ComposerTextView whenever UIKit reports a user-driven
    /// caret/selection change (tap-to-place, magnifier drag, arrow keys,
    /// extend-selection). Programmatic `.text =` writes from ASR partials
    /// don't reach the delegate, so this is the right signal for "user
    /// reached for the field even though the text didn't change."
    func handleComposerSelectionChange() {
        bailOutOfASR()
    }

    private func startASR() async {
        asrError = nil
        if let err = await AudioSessionHelper.prepareForRecording() {
            asrError = "ASR: \(err)"
            return
        }
        partialBase = buffer
        expectedBuffer = buffer
        ignoreFinalTranscript = false
        let a = DoubaoASR()
        asr = a
        isRecording = true
        Haptics.recordStart()
        audioLevel = 0
        // Surface the keyboard + caret so the user can see partials land
        // (and so a stray tap on the field doesn't fight us).
        focusComposer()
        // Arm the global "any-gesture = stop" net. The recognizers run with
        // cancelsTouchesInView=false so buttons / scroll views underneath
        // still receive their normal touches.
        bailMonitor.install(excludedFrame: { micButtonFrame }) { bailOutOfASR() }
        a.start(
            onPartial: { text in
                MainActor.assumeIsolated {
                    // Late partials can land after `stopASR` (e.g. user
                    // tapped Send mid-recording): if we let them write
                    // here, they'd race `send()` clearing the buffer and
                    // leave a stale transcript behind.
                    guard isRecording else { return }
                    let new = mergePartial(base: partialBase, text: text)
                    // Set `expectedBuffer` BEFORE the buffer mutation so
                    // SwiftUI's `onChange(of: buffer)` (which fires
                    // synchronously after the assignment) compares
                    // against the post-write expected value and skips
                    // the "user typed" branch.
                    expectedBuffer = new
                    buffer = new
                }
            },
            onAudioLevel: { level in
                MainActor.assumeIsolated {
                    audioLevel = level
                }
            },
            onError: { error in
                MainActor.assumeIsolated {
                    log.error("asr.start: \(String(describing: error), privacy: .public)")
                    asrError = "ASR: \(error.localizedDescription)"
                    isRecording = false
                    audioLevel = 0
                }
            }
        )
    }

    func stopASR() {
        guard let a = asr else { return }
        Haptics.recordStop()
        // Capture the gate flag now — `ignoreFinalTranscript` is shared
        // state and might be re-set by another trigger before the async
        // completion fires.
        let ignore = ignoreFinalTranscript
        // Flip `isRecording` synchronously so any `onPartial` callbacks
        // still in-flight (DoubaoASR delivers them on the main queue, so
        // they may already be enqueued behind us) are dropped. Otherwise
        // a late partial races `send()` clearing the buffer and the
        // transcript reappears in the field.
        isRecording = false
        // Pull the window-level recognizers off before the async stop —
        // a delayed second tap shouldn't re-enter this same teardown.
        bailMonitor.uninstall()
        a.stop { final in
            Task { @MainActor in
                if !ignore {
                    let merged = mergePartial(base: partialBase, text: final)
                    expectedBuffer = merged
                    buffer = merged
                }
                ignoreFinalTranscript = false
                audioLevel = 0
                AudioSessionHelper.deactivate()
                asr = nil
            }
        }
    }

    /// Best-effort sync stop on view disappear. Completion fires after
    /// the WS teardown — we don't update UI from it since the view is gone.
    func stopASRSync() {
        if let a = asr, isRecording {
            bailMonitor.uninstall()
            a.stop { _ in
                Task {@MainActor in
                    AudioSessionHelper.deactivate()
                }
            }
        }
    }

    private func mergePartial(base: String, text: String) -> String {
        if base.isEmpty { return text }
        if text.isEmpty { return base }
        // Don't double up whitespace when `base` already ends in any
        // whitespace (space / tab / newline). Avoids the classic "ls
        //  directory" gap after typing "ls " before dictating.
        let needsSpace = !(base.last?.isWhitespace ?? false)
        return needsSpace ? base + " " + text : base + text
    }

    func focusComposer() {
        focused = true
    }
}
