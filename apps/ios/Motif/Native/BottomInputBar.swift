import SwiftUI
import UIKit
import OSLog
import DoubaoASR
import GhosttyTerminal

/// Sticky-modifier lifecycle for Ctrl / Alt on the QuickCommandRow.
/// Mirrors libghostty's `TerminalPublicStickyActivation` — that's the
/// source of truth (per `UITerminalView`); we re-declare it locally so
/// the row UI doesn't have to import GhosttyTerminal types.
enum StickyState: Sendable { case inactive, armed, locked }

enum ModifierKind: Sendable { case ctrl, alt }

private extension StickyState {
    init(_ ghostty: TerminalPublicStickyActivation) {
        switch ghostty {
        case .inactive: self = .inactive
        case .armed:    self = .armed
        case .locked:   self = .locked
        }
    }
}

private extension ModifierKind {
    var ghostty: TerminalPublicStickyModifier {
        switch self {
        case .ctrl: return .ctrl
        case .alt:  return .alt
        }
    }
}

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
    @State private var showingCd: Bool = false

    private let log = Logger(subsystem: "io.allsunday.motif", category: "BottomInputBar")

    /// Gate every outbound action on a live link: while disconnected the
    /// terminal stays on screen for reading scrollback, but typing / quick
    /// commands / voice would silently no-op against a dead socket, so we
    /// disable them and surface "reconnecting…" in the composer instead.
    private var canDispatch: Bool { activePtyID != nil && motif.isLive }

    /// Active `UITerminalView` for the focused PTY tab, if any. Used as
    /// the sticky-modifier authority — libghostty owns the per-key
    /// transform for typed input, so BottomInputBar must drive its
    /// state machine rather than running its own.
    private var activeTerminal: UITerminalView? {
        appState.terminals.view(for: activePtyID)
    }

    /// cwd of the PTY the bar writes to — used to root the cd picker.
    private var activeCwd: String? {
        motif.ptys.first(where: { $0.id == activePtyID })?.cwd
    }

    /// Command currently running in the active PTY (per shell-integration),
    /// or nil at the prompt. Drives which quick-command set the bar shows:
    /// a per-program override if one exists, else the global list.
    private var runningCommand: String? {
        guard let id = activePtyID else { return nil }
        return motif.runningCommand[id]
    }

    private var ctrlState: StickyState {
        guard let tv = activeTerminal else { return .inactive }
        return StickyState(tv.stickyActivation(for: .ctrl))
    }

    private var altState: StickyState {
        guard let tv = activeTerminal else { return .inactive }
        return StickyState(tv.stickyActivation(for: .alt))
    }

    var body: some View {
        // Hoisted out of the computed properties so SwiftUI's @Observable
        // tracker definitely sees the read during body evaluation. Without
        // this, the chip pill doesn't redraw when libghostty consumes
        // armed state from a typed terminal keystroke. No `return` so
        // SwiftUI's @ViewBuilder semantics on `body` stay intact —
        // explicit return silently changes how the view tree is wrapped
        // and `.onChange(of: buffer)` was getting dropped from the chain.
        let _ = appState.terminals.stickyVersion
        VStack(spacing: 0) {
            QuickCommandRow(
                commands: appState.commands.resolved(forRunning: runningCommand),
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
            QuickCommandEditor(
                scope: appState.commands.effectiveScope(forRunning: runningCommand),
                runningProgram: QuickCommandStore.programKey(runningCommand)
            )
            .environment(appState)
        }
        .sheet(isPresented: $showingCd) {
            if let cwd = activeCwd, !cwd.isEmpty {
                ChangeDirectoryPanel(initialPath: cwd) { target in
                    guard let id = activePtyID else { return }
                    Task { await motif.changeDirectory(ptyID: id, path: target) }
                }
                .environment(motif)
            } else {
                Text("No active working directory.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
        .onChange(of: buffer) { oldValue, newValue in
            // Sticky-modifier interception for the composer TextField.
            // libghostty handles `UITerminalView.insertText` directly, but
            // this SwiftUI TextField is a separate input surface — without
            // a hook here, tapping Ctrl in our chip pill then typing into
            // the composer would just deposit the raw letter into the
            // buffer. Single character appended at the end + non-newline
            // + not an ASR programmatic write = treat as a key press with
            // current Ctrl/Alt, send transformed bytes to the active PTY,
            // and roll the buffer back. Multi-char inserts (paste, IME
            // commits) pass through unmodified.
            let ctrl = ctrlState
            let alt  = altState
            if (ctrl != .inactive || alt != .inactive),
               canDispatch,
               !newValue.contains("\n"),
               newValue != expectedBuffer,
               newValue.count == oldValue.count + 1,
               newValue.hasPrefix(oldValue),
               let last = newValue.last
            {
                buffer = oldValue
                expectedBuffer = oldValue
                sendModifiedCharacter(last, ctrlWas: ctrl, altWas: alt)
                return
            }
            // Multi-line TextField turns Return into a literal "\n" rather
            // than firing onSubmit. Treat any inserted newline as the
            // user's "send" intent: bail out of ASR if needed and dispatch.
            if newValue.contains("\n") {
                submitBuffer()
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
        .onDisappear {
            stopASRSync()
            // Ghostty's sticky state lives per UITerminalView; resetting
            // it here also clears any latch the user left on before the
            // session view tore down.
            activeTerminal?.resetStickyModifiers()
        }
    }

    // MARK: - Input row

    private var inputRow: some View {
        HStack(spacing: 10) {
            inputPill
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Capsule-shaped composer. Houses the TextField and a live waveform
    /// indicator on the trailing edge while recording. Visual target is
    /// the iMessage gray-fill pill.
    private var inputPill: some View {
        HStack(spacing: 8) {
            TextField(motif.isLive ? "type or speak…" : "reconnecting…", text: $buffer, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.return)
                .focused($focused)
                .disabled(!motif.isLive)
            micButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 22)
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
                    .font(.title3)
                    .tint(.primary)
            }
        }
        .frame(width: 30, height: 28)
        .contentShape(Rectangle())
        .disabled(!canDispatch)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    private var sendButton: some View {
        Button("Send", systemImage: "arrow.up") {
            submitBuffer()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .labelStyle(.iconOnly)
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    private var canSend: Bool {
        canDispatch && !buffer.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Send / quick dispatch

    private func submitBuffer() {
        if isRecording {
            ignoreFinalTranscript = true
            stopASR()
        }
        Task { await send() }
    }

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
        // Snapshot before we send: needed both for `applyModifiers` and
        // to know which armed states to consume afterwards. Locked states
        // are preserved across the consume.
        let ctrl = ctrlState
        let alt  = altState
        switch cmd.kind {
        case .paste:
            // Read clipboard at tap time; empty / non-string clipboards no-op.
            // Wrap in xterm bracketed-paste so fish/zsh treat it as a paste
            // (no autosuggest fight, no per-line history pollution).
            guard let s = UIPasteboard.general.string, !s.isEmpty else {
                consumeArmedOnTerminal(ctrlWas: ctrl, altWas: alt)
                return
            }
            var data = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])           // ESC [ 200 ~
            data.append(Data(s.utf8))
            data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])   // ESC [ 201 ~
            Task { await motif.write(ptyID: id, data: data) }
            consumeArmedOnTerminal(ctrlWas: ctrl, altWas: alt)
        case .bytes where cmd.sendImmediately:
            let out = applyModifiers(
                payload: cmd.payload,
                ctrl: ctrl != .inactive,
                alt:  alt  != .inactive
            )
            Task { await motif.write(ptyID: id, data: out) }
            consumeArmedOnTerminal(ctrlWas: ctrl, altWas: alt)
        case .bytes:
            // Insert decoded payload into the buffer. v1: append at end;
            // SwiftUI's TextField doesn't expose a stable cursor position
            // for arbitrary insertion without UIViewRepresentable. The
            // resulting `buffer` mutation flows through `onChange(of:
            // buffer)`, which — if a recording is in flight — bails us
            // out of ASR exactly the same way as user typing would.
            //
            // Modifiers are intentionally NOT consumed here: a snippet
            // insert isn't a "key press" in the modifier sense.
            if let s = String(data: cmd.payload, encoding: .utf8) {
                buffer.append(s)
                focusComposer()
            }
        case .ctrl:
            // Modifier kinds are rendered as StickyModifierButton and toggle
            // through `onToggleModifier`, so they don't normally reach here.
            toggleModifier(.ctrl)
        case .alt:
            toggleModifier(.alt)
        case .cd:
            showingCd = true
        }
    }

    // MARK: - Sticky modifiers

    /// Forward the tap into libghostty's per-view state machine.
    /// Cycles inactive → armed → locked → inactive. The change handler
    /// installed by `TerminalRegistry` will bump `stickyVersion`, which
    /// re-renders this view's modifier UI.
    private func toggleModifier(_ kind: ModifierKind) {
        activeTerminal?.toggleStickyModifier(kind.ghostty)
    }

    /// TextField composer's modifier interception. The same `applyModifiers`
    /// transform the QuickCommand byte path uses, then armed consume via
    /// libghostty's per-view state machine.
    private func sendModifiedCharacter(_ char: Character, ctrlWas ctrl: StickyState, altWas alt: StickyState) {
        guard let id = activePtyID else { return }
        let payload = Data(String(char).utf8)
        let out = applyModifiers(
            payload: payload,
            ctrl: ctrl != .inactive,
            alt:  alt  != .inactive
        )
        Task { await motif.write(ptyID: id, data: out) }
        consumeArmedOnTerminal(ctrlWas: ctrl, altWas: alt)
    }

    /// Consume armed modifiers in libghostty after a QuickCommand byte
    /// send. The public API only exposes `toggle` and `resetStickyModifiers`
    /// (no `consumeForNextKey`), so we reset all and re-toggle to put
    /// previously-locked states back. Has no effect when nothing was armed.
    private func consumeArmedOnTerminal(ctrlWas ctrl: StickyState, altWas alt: StickyState) {
        guard ctrl == .armed || alt == .armed else { return }
        guard let tv = activeTerminal else { return }
        tv.resetStickyModifiers()
        if ctrl == .locked {
            // inactive → armed → locked
            tv.toggleStickyModifier(.ctrl)
            tv.toggleStickyModifier(.ctrl)
        }
        if alt == .locked {
            tv.toggleStickyModifier(.alt)
            tv.toggleStickyModifier(.alt)
        }
    }

    /// Apply Ctrl / Alt modifiers to a QuickCommand payload. Handles the
    /// common cases — ASCII letters & `[\]^_` for Ctrl, ESC-prefix for Alt,
    /// xterm CSI modifier form (`ESC [ 1 ; mod X`) for arrows + Home/End,
    /// and readline-style word-jump (`ESC b` / `ESC f`) for Alt-only +
    /// Left/Right since bash/zsh bind those by default but ignore the CSI form.
    /// Unrecognized payloads pass through; Alt-only still prepends ESC.
    private func applyModifiers(payload: Data, ctrl: Bool, alt: Bool) -> Data {
        guard ctrl || alt else { return payload }

        if payload.count == 1 {
            var byte = payload[0]
            if ctrl {
                switch byte {
                case 0x61...0x7A, 0x41...0x5A, 0x5B...0x5F:
                    byte &= 0x1F
                default:
                    break
                }
            }
            return alt ? Data([0x1B, byte]) : Data([byte])
        }

        // 3-byte CSI: ESC [ X where X is arrow (0x41..0x44), Home (0x48), End (0x46).
        if payload.count == 3, payload[0] == 0x1B, payload[1] == 0x5B {
            let finalByte = payload[2]
            let isModifiable = (0x41...0x44).contains(finalByte) || finalByte == 0x48 || finalByte == 0x46
            if isModifiable {
                if alt && !ctrl {
                    if finalByte == 0x44 { return Data([0x1B, 0x62]) }  // Alt+Left  → ESC b
                    if finalByte == 0x43 { return Data([0x1B, 0x66]) }  // Alt+Right → ESC f
                }
                let mod: UInt8 = 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0)
                return Data([0x1B, 0x5B, 0x31, 0x3B, 0x30 + mod, finalByte])
            }
        }

        // Multi-byte non-CSI (PgUp/PgDn etc.): Alt-only prepends ESC.
        if alt && !ctrl { return Data([0x1B]) + payload }
        return payload
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

    private func stopASR() {
        guard let a = asr else { return }
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

/// Uniform content height for every quick-command strip button so icon-only
/// and text buttons (which have different intrinsic heights) end up the same
/// capsule height. Padding is added around this on top — together they make a
/// comfortably tappable (~44pt) target.
private let qcContentHeight: CGFloat = 22

private struct QuickCommandRow: View {
    let commands: [QuickCommand]
    let disabled: Bool
    let ctrlState: StickyState
    let altState: StickyState
    let onTap: (QuickCommand) -> Void
    let onToggleModifier: (ModifierKind) -> Void
    let onEdit: () -> Void

    var body: some View {
        // Ctrl / Alt are ordinary list entries now (kind .ctrl / .alt),
        // rendered as sticky-modifier buttons wherever the user placed them.
        // Everything else is a normal quick-command capsule.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(commands) { cmd in
                    switch cmd.kind {
                    case .ctrl:
                        StickyModifierButton(label: cmd.label, symbol: cmd.symbol ?? "control", state: ctrlState) {
                            onToggleModifier(.ctrl)
                        }
                        .disabled(disabled)
                    case .alt:
                        StickyModifierButton(label: cmd.label, symbol: cmd.symbol ?? "option", state: altState) {
                            onToggleModifier(.alt)
                        }
                        .disabled(disabled)
                    default:
                        Button {
                            onTap(cmd)
                        } label: {
                            label(for: cmd)
                        }
                        .buttonStyle(QuickCommandButtonStyle())
                        .disabled(disabled)
                    }
                }
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.callout)
                        .frame(height: qcContentHeight)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .contentShape(Capsule())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func label(for cmd: QuickCommand) -> some View {
        // Symbol-only when a glyph is set; fall back to the text label for
        // commands without one (Esc, ^C, snippets, …).
        if let symbol = cmd.symbol, !symbol.isEmpty {
            Image(systemName: symbol)
                .font(.callout)
                .frame(height: qcContentHeight)
                .accessibilityLabel(cmd.label)
        } else {
            Text(cmd.label)
                .font(.callout.monospaced())
                .lineLimit(1)
                .frame(height: qcContentHeight)
        }
    }
}

private struct QuickCommandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(
                    Color(configuration.isPressed
                        ? .secondarySystemFill
                        : .tertiarySystemFill)
                )
            )
            .foregroundStyle(.primary)
            .contentShape(Capsule())
    }
}

/// Sticky Ctrl / Alt button. Inactive blends with the regular QuickCommand
/// strip; armed shows an accent stroke; locked is an accent fill with a
/// small dot below to disambiguate "armed once" from "latched on".
private struct StickyModifierButton: View {
    let label: String
    let symbol: String
    let state: StickyState
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: symbol)
                .font(.callout)
                .frame(height: qcContentHeight)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            .background(background)
            .foregroundStyle(foreground)
            .overlay(alignment: .bottom) {
                if state == .locked {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 3)
                        .offset(y: 3)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(accessibilityValue)
    }

    @ViewBuilder
    private var background: some View {
        switch state {
        case .inactive:
            Capsule().fill(Color(.tertiarySystemFill))
        case .armed:
            Capsule()
                .fill(Color.accentColor.opacity(0.18))
                .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1.2))
        case .locked:
            Capsule().fill(Color.accentColor)
        }
    }

    private var foreground: Color {
        state == .locked ? .white : .primary
    }

    private var accessibilityValue: String {
        switch state {
        case .inactive: return "off"
        case .armed:    return "armed"
        case .locked:   return "locked"
        }
    }
}
