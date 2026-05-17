import SwiftUI
import UIKit
import OSLog
import DoubaoASR

/// Sticky-modifier lifecycle for Ctrl / Alt on the QuickCommandRow.
/// `inactive` is dormant; `armed` applies on the next QuickCommand tap and
/// then auto-resets; `locked` persists across taps until toggled off.
enum StickyState: Sendable { case inactive, armed, locked }

enum ModifierKind: Sendable { case ctrl, alt }

/// Bottom input fixture that sits below `paneArea` in `SessionView`.
/// Two stacked rows:
///
///   1. `QuickCommandRow` — horizontal scrollable strip of user-defined
///      buffer/key buttons. Tap → either send the payload directly to
///      the active PTY, or insert it into the TextField buffer (per the
///      `QuickCommand.sendImmediately` flag). Trailing `pencil` button
///      opens the editor sheet.
///   2. `inputRow` — iMessage-style composer pill (TextField on a
///      `quaternarySystemFill` capsule with a live waveform on the right
///      while recording) + standalone mic + send buttons.
///
/// Voice flow (Messages-style implicit handoff):
///   - Tap mic: start ASR AND focus the field (keyboard rises, partials
///     are immediately visible).
///   - Partials flow into the field via `mergePartial(partialBase, text)`.
///     `expectedBuffer` tracks the last programmatic write so the
///     `buffer.onChange` watcher can distinguish "ASR wrote that" from
///     "user typed".
///   - User starts typing → recording stops, the final transcript is
///     discarded (would otherwise overwrite the typing).
///   - Field loses focus → recording stops AND the final transcript is
///     merged in (the user dismissed the keyboard, no edit conflict).
///   - Second tap on mic → manual stop, final merged.
struct BottomInputBar: View {
    let activePtyID: String?

    @Environment(MotifClient.self) private var motif
    @Environment(AppState.self) private var appState

    @FocusState private var focused: Bool
    @State private var buffer: String = ""
    @State private var isRecording: Bool = false
    @State private var asr: DoubaoASR?
    @State private var asrError: String?
    @State private var audioLevel: Float = 0
    /// Buffer contents captured at start of recording, so partials/final get
    /// appended rather than replacing prior typed text.
    @State private var partialBase: String = ""
    /// Last value the ASR pipeline programmatically wrote into `buffer`.
    /// The `buffer.onChange` watcher uses this to tell "I (ASR) wrote that"
    /// from "user typed". When they diverge during a recording, that's
    /// our signal to bail out of ASR and let the user take over.
    @State private var expectedBuffer: String = ""
    /// Set when the user starts typing mid-recording. Tells `stopASR`'s
    /// completion handler NOT to merge the final transcript on top of
    /// the user's edit. Cleared after every stop.
    @State private var ignoreFinalTranscript: Bool = false
    @State private var editingCommands: Bool = false
    @State private var ctrlState: StickyState = .inactive
    @State private var altState: StickyState = .inactive

    private let log = Logger(subsystem: "io.allsunday.motif", category: "BottomInputBar")

    private var canDispatch: Bool { activePtyID != nil }

    var body: some View {
        VStack(spacing: 0) {
            QuickCommandRow(
                commands: appState.commands.commands,
                disabled: !canDispatch,
                ctrlState: ctrlState,
                altState: altState,
                onTap: { handleQuickTap($0) },
                onToggleModifier: { toggleModifier($0) },
                onEdit: { editingCommands = true }
            )
            Divider()
            inputRow
            if let asrError {
                Text(asrError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: asrError)
        .background(.background)
        .sheet(isPresented: $editingCommands) {
            QuickCommandEditor().environment(appState)
        }
        .onChange(of: buffer) { _, newValue in
            // Multi-line TextField turns Return into a literal "\n" rather
            // than firing onSubmit. Treat any inserted newline as the
            // user's "send" intent: bail out of ASR if needed and dispatch.
            if newValue.contains("\n") {
                if isRecording {
                    ignoreFinalTranscript = true
                    stopASR()
                }
                Task { await send() }
                return
            }
            // Recording in flight + buffer drifted away from what we
            // last wrote = user is editing. Hand the field back to them
            // and drop the imminent final transcript.
            guard isRecording, newValue != expectedBuffer else { return }
            ignoreFinalTranscript = true
            stopASR()
        }
        .onChange(of: focused) { _, newValue in
            // Focus left the composer (terminal took FR or all resigned)
            // = "I'm done dictating". Let the final transcript merge in.
            if isRecording && !newValue {
                ignoreFinalTranscript = false
                stopASR()
            }
        }
        .task(id: asrError) {
            // Auto-dismiss the error banner so it doesn't camp on screen
            // forever. 4s is long enough to read; if asrError changes
            // mid-wait the new task replaces this one.
            guard asrError != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { asrError = nil }
        }
        .onDisappear { stopASRSync() }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 10) {
            inputPill
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Capsule-shaped composer. Houses the TextField and a live waveform
    /// indicator on the trailing edge while recording. Visual target is
    /// the iMessage gray-fill pill.
    private var inputPill: some View {
        HStack(spacing: 8) {
            TextField("type or speak…", text: $buffer, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.return)
                .focused($focused)
            micButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color(.quaternarySystemFill))
        )
        .animation(.easeOut(duration: 0.15), value: isRecording)
    }

    private var micButton: some View {
        Button {
            toggleRecording()
        } label: {
            if isRecording {
                WaveformIndicator(level: audioLevel)
                    .transition(.opacity.combined(with: .scale))
            } else {
                Image(systemName: "mic.fill")
                    .foregroundStyle(Color.red)
            }
        }
        .frame(height: 24)
        .disabled(!canDispatch)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    private var sendButton: some View {
        Button("Send", systemImage: "arrow.up") {
            Task { await send() }
        }
        .buttonStyle(.borderedProminent)
        .labelStyle(.iconOnly)
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    private var canSend: Bool {
        canDispatch && !buffer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Send / quick dispatch

    private func send() async {
        guard let id = activePtyID else { return }
        // Strip the TextField's literal "\n" — that was the Enter that
        // got us here. Always clear the buffer so a stray newline alone
        // doesn't leave the field looking dirty.
        let text = buffer.replacingOccurrences(of: "\n", with: "")
        buffer = ""
        expectedBuffer = ""
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var data = Data(text.utf8)
        data.append(0x0D) // CR = PTY "Enter"
        await motif.write(ptyID: id, data: data)
    }

    private func handleQuickTap(_ cmd: QuickCommand) {
        guard canDispatch, let id = activePtyID else { return }
        if cmd.sendImmediately {
            Task { await motif.write(ptyID: id, data: cmd.payload) }
        } else {
            // Insert decoded payload into the buffer. v1: append at end;
            // SwiftUI's TextField doesn't expose a stable cursor position
            // for arbitrary insertion without UIViewRepresentable. The
            // resulting `buffer` mutation flows through `onChange(of:
            // buffer)`, which — if a recording is in flight — bails us
            // out of ASR exactly the same way as user typing would.
            if let s = String(data: cmd.payload, encoding: .utf8) {
                buffer.append(s)
                focusComposer()
            }
        }
    }

    // MARK: - Mic / ASR

    private func toggleRecording() {
        if isRecording {
            // Explicit user stop — keep `ignoreFinalTranscript = false`
            // so the final transcript merges in.
            ignoreFinalTranscript = false
            stopASR()
        } else {
            Task { await startASR() }
        }
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
        audioLevel = 0
        // Surface the keyboard + caret so the user can see partials land
        // (and so a stray tap on the field doesn't fight us).
        focusComposer()
        a.start(
            onPartial: { text in
                MainActor.assumeIsolated {
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

    private func stopASR() {
        guard let a = asr else { return }
        // Capture the gate flag now — `ignoreFinalTranscript` is shared
        // state and might be re-set by another trigger before the async
        // completion fires.
        let ignore = ignoreFinalTranscript
        a.stop { final in
            Task { @MainActor in
                if !ignore {
                    let merged = mergePartial(base: partialBase, text: final)
                    expectedBuffer = merged
                    buffer = merged
                }
                ignoreFinalTranscript = false
                isRecording = false
                audioLevel = 0
                AudioSessionHelper.deactivate()
                asr = nil
            }
        }
    }

    /// Best-effort sync stop on view disappear. Completion fires after
    /// the WS teardown — we don't update UI from it since the view is gone.
    private func stopASRSync() {
        if let a = asr, isRecording {
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

    private func focusComposer() {
        focused = true
    }
}

// MARK: - Waveform indicator

/// Three vertical capsules that animate continuously while shown, with
/// the upstream RMS `level` modulating amplitude. The continuous
/// baseline is deliberate: DoubaoASR's `onAudioLevel` is silently 0 in
/// some input-format paths (notably the iOS Simulator's input node,
/// which doesn't expose `floatChannelData`), so a purely level-driven
/// indicator looks frozen even when ASR is actively transcribing.
/// Baseline sine = "I'm listening"; level overlay = "I hear you".
private struct WaveformIndicator: View {
    let level: Float

    var body: some View {
        let clampedLevel = Double(max(0, min(level, 1)))
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                bar(phase: 0.0, t: t, level: clampedLevel)
                bar(phase: 0.7, t: t, level: clampedLevel)
                bar(phase: 1.4, t: t, level: clampedLevel)
            }
        }
        .accessibilityHidden(true)
    }

    private func bar(phase: Double, t: Double, level: Double) -> some View {
        // Baseline ~0.35..0.65 idle pulse; level adds up to 0.35 more
        // with a faster wobble. Clamped to [0.2, 1.0] so the bars never
        // disappear entirely.
        let baseline = 0.5 + 0.15 * sin(t * 3.5 + phase)
        let overlay  = level * (0.5 + 0.5 * sin(t * 11 + phase * 1.7)) * 0.35
        let scale = max(0.2, min(1.0, baseline + overlay))
        return Capsule()
            .fill(Color.accentColor)
            .frame(width: 3)
            .scaleEffect(y: CGFloat(scale), anchor: .center)
    }
}

// MARK: - Symbol effect shim

private extension View {
    /// Apply a pulsing symbol effect on iOS 17+; no-op on older builds.
    /// Gives the mic a "yes I'm hot" subtle breathing while recording
    /// without a `#available` block at every call site.
    @ViewBuilder
    func symbolEffectIfAvailable(pulsing: Bool) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.pulse, options: .repeating, isActive: pulsing)
        } else {
            self
        }
    }
}

// MARK: - Quick command row

private struct QuickCommandRow: View {
    let commands: [QuickCommand]
    let disabled: Bool
    let onTap: (QuickCommand) -> Void
    let onEdit: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commands) { cmd in
                    Button {
                        onTap(cmd)
                    } label: {
                        label(for: cmd)
                    }
                    .buttonStyle(QuickCommandButtonStyle())
                    .disabled(disabled)
                }
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.footnote)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func label(for cmd: QuickCommand) -> some View {
        HStack(spacing: 4) {
            if let symbol = cmd.symbol, !symbol.isEmpty {
                Image(systemName: symbol).font(.footnote)
            }
            Text(cmd.label)
                .font(.footnote.monospaced())
                .lineLimit(1)
        }
    }
}

private struct QuickCommandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    Color(configuration.isPressed
                        ? .secondarySystemFill
                        : .tertiarySystemFill)
                )
            )
            .foregroundStyle(.primary)
    }
}
