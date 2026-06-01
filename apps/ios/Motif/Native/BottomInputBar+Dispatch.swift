import SwiftUI
import UIKit
import PhotosUI
import TalkerCommonLogging

/// Centralized haptic feedback. All calls must be on the main thread (the
/// generators require it); every call site here is already MainActor-isolated.
enum Haptics {
    /// Discrete "key pressed" tick — quick-command taps and modifier toggles.
    @MainActor static func key() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    /// Recording started.
    @MainActor static func recordStart() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    /// Recording stopped.
    @MainActor static func recordStop() {
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
    }
    /// A completed action — e.g. an image successfully pasted into the PTY.
    @MainActor static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// Send / quick-command dispatch + sticky-modifier transforms for
// `BottomInputBar`. Entry points called from the core view (`submitBuffer`,
// `handleQuickTap`, `toggleModifier`, `sendModifiedCharacter`) are `internal`.
extension BottomInputBar {
    // MARK: - Send / quick dispatch

    func submitBuffer() {
        bailOutOfASR()
        Task { await send() }
    }

    private func send() async {
        guard let id = activePtyID else { return }
        // Strip the TextField's literal "\n" — that was the Enter that got us
        // here. A stray newline alone (no real content) isn't a send: clear it
        // so the field doesn't look dirty and bail before showing the spinner.
        let text = buffer.replacingOccurrences(of: "\n", with: "")
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            buffer = ""
            expectedBuffer = ""
            return
        }
        // Hold the text in the field while the write is in flight and flip the
        // send button to its "sending" spinner. Only a confirmed write clears
        // the composer — a failed send leaves the user's text intact to retry.
        guard !isSending else { return }
        isSending = true
        defer { isSending = false }
        var data = Data(text.utf8)
        data.append(0x0D) // CR = PTY "Enter"
        let ok = await motif.write(ptyID: id, data: data)
        if ok {
            buffer = ""
            expectedBuffer = ""
        }
    }

    func handleQuickTap(_ cmd: QuickCommand) {
        bailOutOfASR()
        guard canDispatch, let id = activePtyID else { return }
        Haptics.key()
        // Snapshot before we send: needed both for `applyModifiers` and
        // to know which armed states to consume afterwards. Locked states
        // are preserved across the consume.
        let ctrl  = ctrlState
        let alt   = altState
        let shift = shiftState
        switch cmd.kind {
        case .paste:
            // Read clipboard at tap time; empty / non-string clipboards no-op.
            // Wrap in xterm bracketed-paste so fish/zsh treat it as a paste
            // (no autosuggest fight, no per-line history pollution).
            guard let s = UIPasteboard.general.string, !s.isEmpty else {
                consumeArmedOnTerminal(ctrlWas: ctrl, altWas: alt, shiftWas: shift)
                return
            }
            var data = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])           // ESC [ 200 ~
            data.append(Data(s.utf8))
            data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])   // ESC [ 201 ~
            Task { await motif.write(ptyID: id, data: data) }
            consumeArmedOnTerminal(ctrlWas: ctrl, altWas: alt, shiftWas: shift)
        case .bytes where cmd.sendImmediately:
            // Baked-in modifiers (cmd.modifiers) OR the sticky armed/locked
            // state, so a "Ctrl+Alt+Del" button fires its modifiers on every
            // tap and still composes with anything the user armed first.
            let out = applyModifiers(
                payload: cmd.payload,
                ctrl:  ctrl  != .inactive || cmd.modifiers.contains(.ctrl),
                alt:   alt   != .inactive || cmd.modifiers.contains(.alt),
                shift: shift != .inactive || cmd.modifiers.contains(.shift)
            )
            Task { await motif.write(ptyID: id, data: out) }
            consumeArmedOnTerminal(ctrlWas: ctrl, altWas: alt, shiftWas: shift)
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
        case .shift:
            toggleModifier(.shift)
        case .cd:
            showingCd = true
        }
    }

    // MARK: - Image attach (PhotosPicker → fs.write → bracketed-paste path)

    /// Upload picked images to the server, then bracketed-paste each one's
    /// absolute path into the active PTY so claude attaches them as
    /// `[Image #N]`. This mirrors clipssh: there's no way to push image bytes
    /// over a remote PTY (claude's Ctrl+V reads the *server's* clipboard via
    /// osascript), so we land the file on the server and hand claude the path,
    /// which its paste handler reads off disk and attaches.
    func attachPickedImages(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, let id = activePtyID else { return }
        bailOutOfASR()
        uploadTask?.cancel()
        isUploading = true
        uploadTotal = items.count
        uploadDone = 0
        uploadTask = Task {
            defer {
                isUploading = false
                uploadTask = nil
            }
            for (idx, item) in items.enumerated() {
                if Task.isCancelled { break }
                guard let raw = try? await item.loadTransferable(type: Data.self) else {
                    if Task.isCancelled { break }
                    infoLog("[ImageAttach] load failed for item \(idx)")
                    continue
                }
                guard let (bytes, ext) = Self.encodeForClaude(raw) else {
                    infoLog("[ImageAttach] encode failed for item \(idx) (\(raw.count) bytes)")
                    continue
                }
                // UUID filename → no spaces to escape, no collisions. /tmp is
                // world-writable and on the server's filesystem, so claude's
                // existsSync(path) succeeds when it processes the paste.
                let path = "/tmp/motif-\(UUID().uuidString).\(ext)"
                do {
                    _ = try await motif.writeFile(path: path, data: bytes)
                    if Task.isCancelled { break }
                    // Trailing space matches a real terminal drag/paste (claude
                    // trims it). Each image is its own bracketed paste so
                    // claude's debounce flushes them as separate [Image #N].
                    await motif.bracketedPaste(ptyID: id, text: path + " ")
                    uploadDone += 1
                    Haptics.success()
                    infoLog("[ImageAttach] attached \(path) (\(bytes.count) bytes)")
                    if idx < items.count - 1 {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                } catch {
                    if Task.isCancelled { break }
                    infoLog("[ImageAttach] fs.write failed: \(String(describing: error))")
                }
            }
            // Intentionally NOT calling focusComposer(): the pasted [Image #N]
            // lands in claude's PTY; stealing keyboard focus to the composer
            // here would pop the keyboard unexpectedly after an upload.
        }
    }

    /// Abort an in-flight upload. Images already pasted into claude stay; the
    /// rest of the queue is dropped. Cooperative — the loop checks
    /// `Task.isCancelled` between each step.
    func cancelUpload() {
        uploadTask?.cancel()
        isUploading = false
        infoLog("[ImageAttach] upload cancelled by user")
    }

    /// Re-encode arbitrary picker data into a small, claude-friendly upload.
    ///
    /// Anthropic's vision pipeline downsamples to ≤1568 px on the long edge
    /// regardless, so sending anything larger just wastes tailnet bandwidth
    /// (and times out `fs.write` on slow links). We therefore downscale to
    /// 1568 px and JPEG-encode — typical photos land at a few hundred KB.
    ///
    /// Fast path: already-supported images that are *already* small (animated
    /// GIFs, tiny PNGs/screenshots, WebP) pass through untouched so we don't
    /// flatten animation or re-compress crisp text needlessly.
    static func encodeForClaude(_ data: Data) -> (bytes: Data, ext: String)? {
        let passthroughMax = 400_000   // already small enough to send as-is
        let maxBytes = 5_000_000       // claude's hard per-image limit
        if data.count <= passthroughMax, let ext = supportedImageExt(data) {
            return (data, ext)
        }
        guard var image = UIImage(data: data) else {
            // Undecodable but already a supported, in-limit blob — send as-is.
            if data.count <= maxBytes, let ext = supportedImageExt(data) {
                return (data, ext)
            }
            return nil
        }
        if let scaled = image.downscaled(toLongEdge: 1568) { image = scaled }
        for q in [0.8, 0.65, 0.5, 0.4] as [CGFloat] {
            if let d = image.jpegData(compressionQuality: q), d.count <= maxBytes {
                return (d, "jpg")
            }
        }
        return nil
    }

    /// Sniff magic bytes for the four formats claude accepts (PNG/JPEG/GIF/WebP).
    private static func supportedImageExt(_ data: Data) -> String? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 4 {
            if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return "png" }
            if b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return "jpg" }
            if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46, b[3] == 0x38 { return "gif" }
        }
        if b.count >= 12,
           b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,   // "RIFF"
           b[8] == 0x57, b[9] == 0x45, b[10] == 0x42, b[11] == 0x50 { // "WEBP"
            return "webp"
        }
        return nil
    }

    // MARK: - Sticky modifiers

    /// Forward the tap into libghostty's per-view state machine.
    /// Cycles inactive → armed → locked → inactive. The change handler
    /// installed by `TerminalRegistry` will bump `stickyVersion`, which
    /// re-renders this view's modifier UI.
    func toggleModifier(_ kind: ModifierKind) {
        bailOutOfASR()
        Haptics.key()
        activeTerminal?.toggleStickyModifier(kind.ghostty)
    }

    /// TextField composer's modifier interception. The same `applyModifiers`
    /// transform the QuickCommand byte path uses, then armed consume via
    /// libghostty's per-view state machine.
    func sendModifiedCharacter(_ char: Character, ctrlWas ctrl: StickyState, altWas alt: StickyState, shiftWas shift: StickyState) {
        guard let id = activePtyID else { return }
        let payload = Data(String(char).utf8)
        let out = applyModifiers(
            payload: payload,
            ctrl:  ctrl  != .inactive,
            alt:   alt   != .inactive,
            shift: shift != .inactive
        )
        Task { await motif.write(ptyID: id, data: out) }
        consumeArmedOnTerminal(ctrlWas: ctrl, altWas: alt, shiftWas: shift)
    }

    /// Consume armed modifiers in libghostty after a QuickCommand byte
    /// send. The public API only exposes `toggle` and `resetStickyModifiers`
    /// (no `consumeForNextKey`), so we reset all and re-toggle to put
    /// previously-locked states back. Has no effect when nothing was armed.
    private func consumeArmedOnTerminal(ctrlWas ctrl: StickyState, altWas alt: StickyState, shiftWas shift: StickyState) {
        guard ctrl == .armed || alt == .armed || shift == .armed else { return }
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
        if shift == .locked {
            tv.toggleStickyModifier(.shift)
            tv.toggleStickyModifier(.shift)
        }
    }

    /// Apply Ctrl / Alt / Shift modifiers to a QuickCommand payload. Handles
    /// the common cases — ASCII letters & `[\]^_` for Ctrl, ESC-prefix for Alt,
    /// back-tab (`ESC [ Z`) for Shift+Tab, xterm CSI modifier form
    /// (`ESC [ 1 ; mod X`) for arrows + Home/End, and readline-style word-jump
    /// (`ESC b` / `ESC f`) for Alt-only + Left/Right since bash/zsh bind those
    /// by default but ignore the CSI form. Shift on a fixed printable byte is a
    /// no-op (the payload already is the literal byte). Unrecognized payloads
    /// pass through; Alt-only still prepends ESC.
    private func applyModifiers(payload: Data, ctrl: Bool, alt: Bool, shift: Bool) -> Data {
        guard ctrl || alt || shift else { return payload }

        if payload.count == 1 {
            var byte = payload[0]
            // Shift+Tab → back-tab (ESC [ Z). Common in TUIs / readline for
            // reverse completion cycling; plain Tab has no CSI modifier form.
            if shift && !ctrl && byte == 0x09 {
                return Data([0x1B, 0x5B, 0x5A])
            }
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
                if alt && !ctrl && !shift {
                    if finalByte == 0x44 { return Data([0x1B, 0x62]) }  // Alt+Left  → ESC b
                    if finalByte == 0x43 { return Data([0x1B, 0x66]) }  // Alt+Right → ESC f
                }
                // xterm modifier param: 1 + shift(1) + alt(2) + ctrl(4).
                let mod: UInt8 = 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (ctrl ? 4 : 0)
                return Data([0x1B, 0x5B, 0x31, 0x3B, 0x30 + mod, finalByte])
            }
        }

        // Multi-byte non-CSI (PgUp/PgDn etc.): Alt-only prepends ESC.
        if alt && !ctrl { return Data([0x1B]) + payload }
        return payload
    }
}

private extension UIImage {
    /// Aspect-preserving downscale so the long edge is ≤ `edge` points (at
    /// scale 1, so output pixel dims == point dims). Returns self when already
    /// within bounds. Used to keep re-encoded uploads under claude's limits.
    func downscaled(toLongEdge edge: CGFloat) -> UIImage? {
        let long = max(size.width, size.height)
        guard long > edge else { return self }
        let factor = edge / long
        let target = CGSize(width: size.width * factor, height: size.height * factor)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }
}
