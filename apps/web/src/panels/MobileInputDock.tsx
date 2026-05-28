// Mobile-friendly bottom dock for an active PTY view. iOS-parity feature set:
//
//   - Horizontally-scrollable quick-command chips with five kinds:
//       bytes (preset key / text snippet), paste (bracketed paste from
//       clipboard), ctrl / alt (sticky modifier toggles), cd (open the
//       directory picker).
//   - Three-state sticky Ctrl / Alt: tap cycles inactive → armed → locked.
//     The same sticky state applies to xterm-typed keys (see PtyTab's
//     `attachCustomKeyEventHandler`) and to composer-typed letters here.
//   - Per-program quick-command sets: when the active PTY's running
//     command's basename matches a set's `matches[]`, that set's commands
//     replace the global list. The pencil button opens the editor scoped
//     to whichever list is currently effective.
//   - Connection-aware: when the WS is reconnecting the textarea + chips
//     disable and the placeholder becomes "reconnecting…".
//   - Composer is a textarea (1..5 rows). Enter sends (matches iOS:
//     literal "\n" in the buffer is the submit intent); Shift+Enter
//     inserts a newline.

import { Suspense, lazy, useCallback, useMemo, useRef, useState } from "react";
import { useApp } from "../store/store";
import {
  payloadBytes, programKey, resolvedQuickCommands, effectiveScope,
  useQuickCommandStore,
  type QuickCommand,
} from "../store/quickCommands";
import {
  consumeArmed, toggleSticky, useSticky, type StickyState,
} from "../store/stickyModifiers";
import {
  applyModifiers, BRACKETED_PASTE_END, BRACKETED_PASTE_START,
  bytesToB64, concatBytes,
} from "../util/applyModifiers";

const QuickCommandEditor   = lazy(() => import("./QuickCommandEditor"));
const ChangeDirectoryPanel = lazy(() => import("./ChangeDirectoryPanel"));

interface Props { ptyId: string }

export default function MobileInputDock({ ptyId }: Props) {
  const client     = useApp(s => s.client);
  const isLive     = useApp(s => s.isLive);
  const ptyInfo    = useApp(s => s.ptyInfos.get(ptyId));
  const runningCmd = useApp(s => s.runningCmds.get(ptyId) ?? null);
  const sticky     = useSticky(ptyId);
  // Subscribing to the store ensures the dock re-renders when the user edits
  // commands or switches sets. We use the side-effect of the subscription —
  // the actual resolved list is computed via the helper below so memoization
  // keys it on the relevant inputs only.
  const storeShape = useQuickCommandStore();
  const commands   = useMemo(
    () => resolvedQuickCommands(runningCmd),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [storeShape, runningCmd],
  );

  const [text, setText] = useState("");
  const [showCd,     setShowCd]     = useState(false);
  const [showEditor, setShowEditor] = useState(false);

  const textRef = useRef<HTMLTextAreaElement | null>(null);

  const canDispatch = !!client && isLive;

  // ── send helpers ────────────────────────────────────────────────────

  const sendBytes = useCallback((u8: Uint8Array) => {
    if (!client || u8.length === 0) return;
    client.call("pty.write", { pty_id: ptyId, data_b64: bytesToB64(u8) })
      .catch(() => { /* ignore — pty may have exited */ });
  }, [client, ptyId]);

  const sendText = useCallback((s: string) => {
    if (!s) return;
    sendBytes(new TextEncoder().encode(s));
  }, [sendBytes]);

  // ── chip dispatch ───────────────────────────────────────────────────

  /** Insert decoded payload text into the composer at the caret. Used by
   *  `bytes` commands with `sendImmediately: false`. */
  const insertAtCaret = useCallback((s: string) => {
    const el = textRef.current;
    if (!el) { setText(prev => prev + s); return; }
    const start = el.selectionStart ?? el.value.length;
    const end   = el.selectionEnd   ?? el.value.length;
    const next  = el.value.slice(0, start) + s + el.value.slice(end);
    setText(next);
    requestAnimationFrame(() => {
      const pos = start + s.length;
      try { el.setSelectionRange(pos, pos); el.focus(); } catch { /* ignore */ }
    });
  }, []);

  const onTapCommand = useCallback(async (c: QuickCommand) => {
    if (!canDispatch) return;
    switch (c.kind) {
      case "bytes": {
        const bytes = payloadBytes(c);
        if (c.sendImmediately) {
          const out = applyModifiers(bytes,
            sticky.ctrl !== "inactive",
            sticky.alt  !== "inactive");
          sendBytes(out);
          consumeArmed(ptyId);
        } else {
          // Insert decoded payload as text. Modifier consume is NOT triggered
          // here — a snippet insert isn't a "key press" in the modifier sense.
          try { insertAtCaret(new TextDecoder("utf-8", { fatal: false }).decode(bytes)); }
          catch { /* binary payloads don't make sense to insert; ignore */ }
        }
        break;
      }
      case "paste": {
        let s = "";
        try { s = await navigator.clipboard.readText(); } catch { /* permission denied / unsupported */ }
        if (!s) { consumeArmed(ptyId); break; }
        const utf8 = new TextEncoder().encode(s);
        sendBytes(concatBytes(BRACKETED_PASTE_START, utf8, BRACKETED_PASTE_END));
        consumeArmed(ptyId);
        break;
      }
      case "ctrl":
        toggleSticky(ptyId, "ctrl");
        break;
      case "alt":
        toggleSticky(ptyId, "alt");
        break;
      case "cd":
        setShowCd(true);
        break;
    }
  }, [canDispatch, sticky, sendBytes, insertAtCaret, ptyId]);

  // ── composer ────────────────────────────────────────────────────────

  const submit = useCallback(() => {
    const value = text.replace(/\n/g, "");
    setText("");
    const trimmed = value.trim();
    if (!trimmed) return;
    // Use CR — that's what xterm sends for the Enter key, which the PTY's
    // ICRNL line discipline translates to NL. Sending a bare NL bypasses
    // that path and some shells don't execute on it.
    sendText(value + "\r");
    textRef.current?.focus();
  }, [text, sendText]);

  const onChange = useCallback((e: React.ChangeEvent<HTMLTextAreaElement>) => {
    const next = e.target.value;
    const nativeEvent = e.nativeEvent as InputEvent;
    // Sticky-modifier interception for single-char appends — mirrors iOS.
    // IME composition fires multi-char inserts AND sets isComposing; skip
    // both paths so Chinese / Japanese input survives unmodified.
    if (
      !nativeEvent.isComposing &&
      (sticky.ctrl !== "inactive" || sticky.alt !== "inactive") &&
      canDispatch &&
      !next.includes("\n") &&
      next.length === text.length + 1 &&
      next.startsWith(text)
    ) {
      const last = next.slice(-1);
      const out = applyModifiers(
        new TextEncoder().encode(last),
        sticky.ctrl !== "inactive",
        sticky.alt  !== "inactive",
      );
      sendBytes(out);
      consumeArmed(ptyId);
      return; // do NOT setText — bail out of the keystroke entirely.
    }
    // Multi-line TextField appends "\n" for Enter rather than firing
    // onSubmit. Treat any inserted newline as the user's "send" intent —
    // matches iOS behavior.
    if (next.includes("\n") && !nativeEvent.isComposing) {
      setText(next);
      // submit after state settles so the cleared buffer reflects properly.
      requestAnimationFrame(() => submit());
      return;
    }
    setText(next);
  }, [canDispatch, sticky, text, sendBytes, ptyId, submit]);

  const onKeyDown = useCallback((e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // Capture Enter explicitly too so desktop keyboard users get instant
    // submit; the onChange newline path is a fallback for software
    // keyboards that don't trigger keydown for Enter.
    if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
      e.preventDefault();
      submit();
    }
  }, [submit]);

  const rowsForText = useMemo(() => {
    const lines = text.split("\n").length;
    return Math.max(1, Math.min(5, lines));
  }, [text]);

  // ── cd panel handler ───────────────────────────────────────────────

  const onConfirmCd = useCallback((path: string) => {
    const escaped = path.replace(/'/g, "'\\''");
    sendText(`cd '${escaped}'\r`);
    setShowCd(false);
  }, [sendText]);

  // ── editor wiring ──────────────────────────────────────────────────

  const editorScope     = useMemo(() => effectiveScope(runningCmd), [runningCmd]);
  const editorProgKey   = useMemo(() => programKey(runningCmd),     [runningCmd]);

  const placeholder = isLive ? "type a command — Enter to send" : "reconnecting…";

  return (
    <>
      <div className="mdock" role="region" aria-label="Mobile input dock">
        <div className="mdock-cmds" role="toolbar" aria-label="Quick commands">
          <div className="mdock-cmds-scroll">
            {commands.length === 0 && (
              <span className="muted small">no quick commands — tap ⚙ to add</span>
            )}
            {commands.map(c => (
              <ChipButton
                key={c.id}
                cmd={c}
                sticky={c.kind === "ctrl" ? sticky.ctrl : c.kind === "alt" ? sticky.alt : "inactive"}
                disabled={!canDispatch}
                onTap={() => onTapCommand(c)}
              />
            ))}
          </div>
          <button
            className="ghost small mdock-mgr-btn"
            onClick={() => setShowEditor(true)}
            title="Manage quick commands"
            aria-label="Manage quick commands"
          >
            ⚙
          </button>
        </div>

        <div className="mdock-input">
          <div className="mdock-pill">
            <textarea
              ref={textRef}
              className="mdock-textarea"
              value={text}
              placeholder={placeholder}
              onChange={onChange}
              onKeyDown={onKeyDown}
              rows={rowsForText}
              disabled={!isLive}
              autoCapitalize="off"
              autoCorrect="off"
              autoComplete="off"
              spellCheck={false}
              enterKeyHint="send"
            />
          </div>
          <button
            className="mdock-send-circle"
            onClick={submit}
            disabled={!canDispatch || text.trim().length === 0}
            title="Send (Enter)"
            aria-label="Send"
          >
            ↑
          </button>
        </div>
      </div>

      {showCd && (
        <Suspense fallback={null}>
          <ChangeDirectoryPanel
            initialPath={ptyInfo?.cwd && ptyInfo.cwd !== "" ? ptyInfo.cwd : "/"}
            onConfirm={onConfirmCd}
            onCancel={() => setShowCd(false)}
          />
        </Suspense>
      )}

      {showEditor && (
        <Suspense fallback={null}>
          <QuickCommandEditor
            initialScope={editorScope}
            runningProgram={editorProgKey}
            onClose={() => setShowEditor(false)}
          />
        </Suspense>
      )}
    </>
  );
}

// ─── Chip ──────────────────────────────────────────────────────────

function ChipButton({
  cmd, sticky, disabled, onTap,
}: { cmd: QuickCommand; sticky: StickyState; disabled: boolean; onTap: () => void }) {
  const isModifier = cmd.kind === "ctrl" || cmd.kind === "alt";
  const stateClass = isModifier
    ? (sticky === "armed" ? " sticky-armed" : sticky === "locked" ? " sticky-locked" : "")
    : "";
  const title = cmd.kind === "bytes" && cmd.sendImmediately ? `${cmd.label} ↵` : cmd.label;
  return (
    <button
      className={"mdock-chip" + stateClass}
      onClick={(e) => { onTap(); e.currentTarget.blur(); }}
      disabled={disabled}
      title={title}
      aria-label={cmd.label}
      aria-pressed={isModifier ? sticky !== "inactive" : undefined}
    >
      {cmd.symbol ? <span aria-hidden>{cmd.symbol}</span> : <span>{cmd.label}</span>}
    </button>
  );
}
