import SwiftUI
import UIKit

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

    func handleQuickTap(_ cmd: QuickCommand) {
        bailOutOfASR()
        guard canDispatch, let id = activePtyID else { return }
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
            let out = applyModifiers(
                payload: cmd.payload,
                ctrl:  ctrl  != .inactive,
                alt:   alt   != .inactive,
                shift: shift != .inactive
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

    // MARK: - Sticky modifiers

    /// Forward the tap into libghostty's per-view state machine.
    /// Cycles inactive → armed → locked → inactive. The change handler
    /// installed by `TerminalRegistry` will bump `stickyVersion`, which
    /// re-renders this view's modifier UI.
    func toggleModifier(_ kind: ModifierKind) {
        bailOutOfASR()
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
