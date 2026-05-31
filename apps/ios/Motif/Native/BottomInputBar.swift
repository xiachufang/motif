import SwiftUI
import UIKit
import OSLog
import PhotosUI
import DoubaoASR
import GhosttyTerminal

/// Sticky-modifier lifecycle for Ctrl / Alt / Shift on the QuickCommandRow.
/// Mirrors libghostty's `TerminalPublicStickyActivation` — that's the
/// source of truth (per `UITerminalView`); we re-declare it locally so
/// the row UI doesn't have to import GhosttyTerminal types.
enum StickyState: Sendable { case inactive, armed, locked }

enum ModifierKind: Sendable { case ctrl, alt, shift }

extension StickyState {
    init(_ ghostty: TerminalPublicStickyActivation) {
        switch ghostty {
        case .inactive: self = .inactive
        case .armed:    self = .armed
        case .locked:   self = .locked
        }
    }
}

extension ModifierKind {
    var ghostty: TerminalPublicStickyModifier {
        switch self {
        case .ctrl:  return .ctrl
        case .alt:   return .alt
        case .shift: return .shift
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
///
/// Dispatch (send / quick commands / sticky modifiers) lives in
/// `BottomInputBar+Dispatch`; the mic/ASR lifecycle in `BottomInputBar+ASR`.
/// State those files touch is `internal` rather than `private` (Swift
/// `private` is file-scoped).
struct BottomInputBar: View {
    let activePtyID: String?

    @Environment(MotifClient.self) var motif
    @Environment(AppState.self) private var appState

    /// Focus state for the composer text view. Plain `@State` rather than
    /// `@FocusState` because we drive the underlying UIKit responder
    /// ourselves (see `ComposerTextView`) — `@FocusState` only binds to
    /// SwiftUI's built-in TextField, which we replaced to gain access to
    /// `textViewDidChangeSelection`.
    @State var focused: Bool = false
    @State var buffer: String = ""
    /// Intrinsic content height of `ComposerTextView`, reported by its
    /// coordinator each layout pass. The composer frame clamps this to
    /// `[lineHeight, lineHeight * 5]` to reproduce the old SwiftUI
    /// `.lineLimit(1...5)` behaviour.
    @State private var composerHeight: CGFloat = Self.composerSingleLineHeight
    @State var isRecording: Bool = false
    @State var asr: DoubaoASR?
    @State var asrError: String?
    @State var audioLevel: Float = 0
    /// Buffer contents captured at start of recording, so partials/final get
    /// appended rather than replacing prior typed text.
    @State var partialBase: String = ""
    /// Last value the ASR pipeline programmatically wrote into `buffer`.
    /// The `buffer.onChange` watcher uses this to tell "I (ASR) wrote that"
    /// from "user typed". When they diverge during a recording, that's
    /// our signal to bail out of ASR and let the user take over.
    @State var expectedBuffer: String = ""
    /// Set when the user starts typing mid-recording. Tells `stopASR`'s
    /// completion handler NOT to merge the final transcript on top of
    /// the user's edit. Cleared after every stop.
    @State var ignoreFinalTranscript: Bool = false
    @State private var editingCommands: Bool = false
    @State var showingCd: Bool = false
    @State var showingPhotoPicker: Bool = false
    @State var photoItems: [PhotosPickerItem] = []
    @State var isUploading: Bool = false
    @State var uploadDone: Int = 0
    @State var uploadTotal: Int = 0
    @State var uploadTask: Task<Void, Never>?
    /// Window-level gesture monitor armed while recording. Any tap / pan /
    /// long-press anywhere on screen (incl. hardware-keyboard keys, since
    /// those still fire UIKey events that bubble through hit-tested views)
    /// fires `bailOutOfASR`. Lazily initialized so non-recording sessions
    /// pay nothing. See `ASRBailGestureMonitor`.
    @State var bailMonitor = ASRBailGestureMonitor()

    /// Window-space frame of the mic button, fed to `bailMonitor` so a tap on
    /// the mic toggles recording instead of being swallowed as a bail. See
    /// `ASRBailGestureMonitor.excludedFrame`.
    @State var micButtonFrame: CGRect = .zero

    let log = Logger(subsystem: "io.allsunday.motif", category: "BottomInputBar")

    /// Gate every outbound action on a live link: while disconnected the
    /// terminal stays on screen for reading scrollback, but typing / quick
    /// commands / voice would silently no-op against a dead socket, so we
    /// disable them and surface "reconnecting…" in the composer instead.
    var canDispatch: Bool { activePtyID != nil && motif.isLive }

    /// Active `UITerminalView` for the focused PTY tab, if any. Used as
    /// the sticky-modifier authority — libghostty owns the per-key
    /// transform for typed input, so BottomInputBar must drive its
    /// state machine rather than running its own.
    var activeTerminal: UITerminalView? {
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

    var ctrlState: StickyState {
        guard let tv = activeTerminal else { return .inactive }
        return StickyState(tv.stickyActivation(for: .ctrl))
    }

    var altState: StickyState {
        guard let tv = activeTerminal else { return .inactive }
        return StickyState(tv.stickyActivation(for: .alt))
    }

    var shiftState: StickyState {
        guard let tv = activeTerminal else { return .inactive }
        return StickyState(tv.stickyActivation(for: .shift))
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
                shiftState: shiftState,
                onTap: { handleQuickTap($0) },
                onToggleModifier: { toggleModifier($0) },
                onEdit: { editingCommands = true }
            )
            Divider()
            inputRow
            if let asrError {
                Text(asrError)
                    .font(MotifTheme.Typography.caption2)
                    .foregroundStyle(MotifTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, MotifTheme.Spacing.md).padding(.bottom, MotifTheme.Spacing.xs)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: asrError)
        // Bleed the bar's fill into the bottom safe area (home-indicator
        // region) so it doesn't expose the parent's `MotifTheme.background`
        // as a color seam below the composer.
        .background {
            Rectangle()
                .fill(.background)
                .ignoresSafeArea(edges: .bottom)
        }
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
                    .foregroundStyle(MotifTheme.textSecondary)
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
            let ctrl  = ctrlState
            let alt   = altState
            let shift = shiftState
            if (ctrl != .inactive || alt != .inactive || shift != .inactive),
               canDispatch,
               !newValue.contains("\n"),
               newValue != expectedBuffer,
               newValue.count == oldValue.count + 1,
               newValue.hasPrefix(oldValue),
               let last = newValue.last
            {
                buffer = oldValue
                expectedBuffer = oldValue
                sendModifiedCharacter(last, ctrlWas: ctrl, altWas: alt, shiftWas: shift)
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
            bailOutOfASR()
        }
        .onChange(of: focused) { _, newValue in
            if newValue {
                // Focusing the composer to type means the user wants to act on
                // the live prompt — snap the terminal back to the latest output
                // so they see where their input lands. The composer is a
                // separate view, so typing never reaches the surface to
                // auto-pin it; do it explicitly here.
                activeTerminal?.scrollToBottom()
            }
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
            photoButton
            inputPill
            sendButton
        }
        .padding(.horizontal, MotifTheme.Spacing.md)
        .padding(.vertical, 10)
    }

    /// Capsule-shaped composer. Houses the multiline UITextView-backed
    /// editor and a live waveform indicator on the trailing edge while
    /// recording. Visual target is the iMessage gray-fill pill.
    ///
    /// We dropped SwiftUI's `TextField(..., axis: .vertical)` here so we
    /// can observe `textViewDidChangeSelection` — that's the only
    /// notification UIKit gives us when the user moves the caret without
    /// changing the text (tap-to-place, magnifier drag, hardware arrow
    /// keys). Any selection move while recording = "I want to edit, not
    /// dictate", so it routes through `bailOutOfASR()` like a typed key.
    private var inputPill: some View {
        let clampedHeight = min(
            max(composerHeight, Self.composerSingleLineHeight),
            Self.composerSingleLineHeight * 5
        )
        return HStack(alignment: .bottom, spacing: MotifTheme.Spacing.sm) {
            ZStack(alignment: .topLeading) {
                if buffer.isEmpty {
                    Text(motif.isLive ? "type or speak…" : "reconnecting…")
                        .foregroundStyle(MotifTheme.textTertiary)
                        // The placeholder must not intercept taps — touches
                        // need to fall through to the UITextView underneath
                        // so the caret lands on the first tap.
                        .allowsHitTesting(false)
                }
                ComposerTextView(
                    text: $buffer,
                    isEnabled: motif.isLive,
                    isFocused: $focused,
                    contentHeight: $composerHeight,
                    onSelectionChange: { handleComposerSelectionChange() }
                )
                .frame(height: clampedHeight)
            }
            micButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(MotifTheme.Fill.subtle)
        )
        .animation(.easeOut(duration: 0.15), value: isRecording)
    }

    /// One line of UITextView body text, used both for the placeholder
    /// metrics and the composer's min/max clamp. `body` is the SwiftUI
    /// TextField default — keep them aligned so the row doesn't visibly
    /// shift on the switch.
    static let composerSingleLineHeight: CGFloat = UIFont.preferredFont(forTextStyle: .body).lineHeight

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
                    .tint(MotifTheme.textPrimary)
            }
        }
        .frame(width: 30, height: 28)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { micButtonFrame = $0 }
        .disabled(!canDispatch)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    private var sendButton: some View {
        Button("Send", systemImage: "arrow.up") {
            submitBuffer()
        }
        .buttonStyle(MotifIconButtonStyle(role: .filled, size: .large))
        .disabled(!canSend)
        .accessibilityLabel("Send")
    }

    /// Attach photos: pick from the library, upload to the server, and paste
    /// each one's path so claude ingests them as `[Image #N]`. Uses a real
    /// Button + `.photosPicker` modifier (rather than `PhotosPicker` directly)
    /// so it picks up `MotifIconButtonStyle`. PhotosPicker needs no photo-
    /// library permission — it runs out of process.
    @ViewBuilder
    private var photoButton: some View {
        Group {
            if isUploading {
                // Loading state doubles as the cancel control: tap to abort the
                // in-flight upload (already-pasted images stay).
                Button(action: cancelUpload) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(MotifTheme.textSecondary)
                }
                .buttonStyle(MotifIconButtonStyle(role: .bordered, size: .large))
                .accessibilityLabel(uploadTotal > 1
                    ? "Cancel upload (\(uploadDone) of \(uploadTotal))"
                    : "Cancel upload")
            } else {
                Button {
                    showingPhotoPicker = true
                } label: {
                    Image(systemName: "photo")
                }
                .buttonStyle(MotifIconButtonStyle(role: .bordered, size: .large))
                .disabled(!canDispatch)
                .accessibilityLabel("Attach photos")
            }
        }
        .photosPicker(
            isPresented: $showingPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            attachPickedImages(items)
            photoItems = []
        }
    }

    private var canSend: Bool {
        canDispatch && !buffer.trimmingCharacters(in: .whitespaces).isEmpty
    }
}
