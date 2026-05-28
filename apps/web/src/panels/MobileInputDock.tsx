// Mobile-friendly bottom dock for an active PTY view. Provides:
//   - a horizontally-scrollable, customizable quick-command chip bar
//   - a text input with a Send button that writes to the PTY via the same
//     `pty.write` RPC xterm uses, so server-side state stays the source
//     of truth
//
// The dock is rendered by Workspace only when the active view is a PTY,
// and gated by a topbar visibility toggle so desktop users can hide it.

import { Fragment, useCallback, useEffect, useRef, useState } from "react";
import { useApp } from "../store/store";
import {
  addQuickCommand, decodeEscapes, deleteQuickCommand,
  resetQuickCommands, setQuickCommands, updateQuickCommand,
  useQuickCommands, type QuickCommand,
} from "../store/quickCommands";

interface Props { ptyId: string }

function encodeToB64(s: string): string {
  const u8 = new TextEncoder().encode(s);
  let bin = "";
  for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
  return btoa(bin);
}

export default function MobileInputDock({ ptyId }: Props) {
  const client    = useApp(s => s.client);
  const commands  = useQuickCommands();

  const [text, setText]   = useState("");
  const [showMgr, setMgr] = useState(false);

  const inputRef = useRef<HTMLInputElement | null>(null);

  const send = useCallback((bytes: string) => {
    if (!client || !bytes) return;
    client.call("pty.write", { pty_id: ptyId, data_b64: encodeToB64(bytes) })
      .catch(() => { /* ignore — pty may have exited */ });
  }, [client, ptyId]);

  const onSendInput = useCallback(() => {
    const value = text;
    if (!value) return;
    // Use CR — this is what xterm sends for the Enter key, and the PTY's
    // ICRNL line discipline translates it to NL for the shell. Sending a
    // bare NL bypasses that path and some shells don't execute on it.
    send(value + "\r");
    setText("");
    // Keep focus so the user can keep typing without re-tapping.
    inputRef.current?.focus();
  }, [text, send]);

  /** Insert a quick command into the input. If `appendNewline` is set we
   *  send-and-clear straight away — that's the natural read of "tap `ls`
   *  to run ls". Otherwise we just inject the bytes at the caret so the
   *  user can build up a command (e.g. an arrow key plus Enter). */
  const onTapCommand = useCallback((c: QuickCommand) => {
    const decoded = decodeEscapes(c.value);
    if (c.appendNewline) {
      send(decoded + "\r");
      return;
    }
    const el = inputRef.current;
    if (!el) {
      setText(prev => prev + decoded);
      return;
    }
    const start = el.selectionStart ?? el.value.length;
    const end   = el.selectionEnd   ?? el.value.length;
    const next  = el.value.slice(0, start) + decoded + el.value.slice(end);
    setText(next);
    // Position caret after the inserted text on the next tick so React
    // commits the new value first.
    requestAnimationFrame(() => {
      const pos = start + decoded.length;
      try { el.setSelectionRange(pos, pos); el.focus(); } catch { /* ignore */ }
    });
  }, [send]);

  const onKeyDown = useCallback((e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      onSendInput();
    }
  }, [onSendInput]);

  return (
    <>
      <div className="mdock" role="region" aria-label="Mobile input dock">
        <div className="mdock-cmds" role="toolbar" aria-label="Quick commands">
          <div className="mdock-cmds-scroll">
            {commands.length === 0 && (
              <span className="muted small">no quick commands — tap ⚙ to add</span>
            )}
            {commands.map(c => (
              <button
                key={c.id}
                className="mdock-chip"
                onClick={(e) => { onTapCommand(c); e.currentTarget.blur(); }}
                title={c.appendNewline ? `${c.value} ↵` : c.value}
              >
                {c.label}
              </button>
            ))}
          </div>
          <button
            className="ghost small mdock-mgr-btn"
            onClick={() => setMgr(true)}
            title="Manage quick commands"
            aria-label="Manage quick commands"
          >
            ⚙
          </button>
        </div>

        <div className="mdock-input">
          <input
            ref={inputRef}
            className="mdock-text"
            type="text"
            value={text}
            placeholder="type a command — Enter to send"
            onChange={e => setText(e.target.value)}
            onKeyDown={onKeyDown}
            autoCapitalize="off"
            autoCorrect="off"
            autoComplete="off"
            spellCheck={false}
            // Keep the mobile keyboard's submit button labeled "send".
            enterKeyHint="send"
          />
          <button
            className="mdock-send"
            onClick={onSendInput}
            disabled={!text}
            title="Send (Enter)"
          >
            Send
          </button>
        </div>
      </div>

      {showMgr && (
        <QuickCommandsManager onClose={() => setMgr(false)} />
      )}
    </>
  );
}

// ── manager modal ───────────────────────────────────────────────────

function QuickCommandsManager({ onClose }: { onClose: () => void }) {
  const commands = useQuickCommands();
  const [draftLabel, setDraftLabel] = useState("");
  const [draftValue, setDraftValue] = useState("");
  const [draftNl,    setDraftNl]    = useState(true);

  // Pointer-based drag-and-drop reorder. PointerEvents covers mouse, pen,
  // and touch in one path; HTML5 dnd doesn't fire on iOS touch.
  const listRef = useRef<HTMLUListElement | null>(null);
  const [drag, setDrag] = useState<{ id: string; toIdx: number } | null>(null);

  const findDropIdx = useCallback((clientY: number): number => {
    const ul = listRef.current;
    if (!ul) return commands.length;
    const rows = ul.querySelectorAll<HTMLLIElement>("[data-cmd-id]");
    for (let i = 0; i < rows.length; i++) {
      const r = rows[i].getBoundingClientRect();
      if (clientY < r.top + r.height / 2) return i;
    }
    return rows.length;
  }, [commands.length]);

  const onHandleDown = useCallback((e: React.PointerEvent<HTMLElement>, id: string) => {
    e.preventDefault();
    e.stopPropagation();
    try { e.currentTarget.setPointerCapture(e.pointerId); } catch { /* ignore */ }
    setDrag({ id, toIdx: commands.findIndex(c => c.id === id) });
  }, [commands]);

  const onHandleMove = useCallback((e: React.PointerEvent<HTMLElement>) => {
    setDrag(d => {
      if (!d) return d;
      const idx = findDropIdx(e.clientY);
      return idx === d.toIdx ? d : { ...d, toIdx: idx };
    });
  }, [findDropIdx]);

  const onHandleUp = useCallback((e: React.PointerEvent<HTMLElement>) => {
    try { e.currentTarget.releasePointerCapture(e.pointerId); } catch { /* ignore */ }
    setDrag(d => {
      if (!d) return null;
      const fIdx = commands.findIndex(c => c.id === d.id);
      let tIdx = d.toIdx;
      // toIdx == fIdx or fIdx+1 means "drop where it already is" — no-op.
      if (fIdx >= 0 && tIdx !== fIdx && tIdx !== fIdx + 1) {
        const next = commands.slice();
        const [item] = next.splice(fIdx, 1);
        if (tIdx > fIdx) tIdx -= 1;
        tIdx = Math.max(0, Math.min(tIdx, next.length));
        next.splice(tIdx, 0, item);
        setQuickCommands(next);
      }
      return null;
    });
  }, [commands]);

  const fromIdx = drag ? commands.findIndex(c => c.id === drag.id) : -1;
  const showDropLine = drag != null
    && drag.toIdx !== fromIdx
    && drag.toIdx !== fromIdx + 1;

  const onAdd = useCallback(() => {
    const label = draftLabel.trim();
    const value = draftValue;
    if (!label || !value) return;
    addQuickCommand({ label, value, appendNewline: draftNl });
    setDraftLabel("");
    setDraftValue("");
    setDraftNl(true);
  }, [draftLabel, draftValue, draftNl]);

  return (
    <div className="mdock-modal-backdrop" onClick={onClose}>
      <div className="mdock-modal" onClick={e => e.stopPropagation()} role="dialog" aria-label="Quick commands">
        <header className="row" style={{ justifyContent: "space-between" }}>
          <strong>Quick commands</strong>
          <button className="ghost small" onClick={onClose}>✕</button>
        </header>

        <ul ref={listRef} className="mdock-mgr-list">
          {commands.map((c, i) => (
            <Fragment key={c.id}>
              {showDropLine && drag!.toIdx === i && <li className="mdock-drop-line" aria-hidden />}
              <ManagerRow
                cmd={c}
                isDragging={drag?.id === c.id}
                onHandlePointerDown={(e) => onHandleDown(e, c.id)}
                onHandlePointerMove={onHandleMove}
                onHandlePointerUp={onHandleUp}
              />
            </Fragment>
          ))}
          {showDropLine && drag!.toIdx === commands.length && (
            <li className="mdock-drop-line" aria-hidden />
          )}
          {commands.length === 0 && <li className="muted small" style={{ padding: "0.5em" }}>no commands yet</li>}
        </ul>

        <fieldset className="mdock-mgr-add">
          <legend className="small muted">Add new</legend>
          <div className="row tight">
            <input
              type="text"
              placeholder="label (e.g. ls)"
              value={draftLabel}
              onChange={e => setDraftLabel(e.target.value)}
              style={{ flex: "1 1 8em" }}
            />
            <input
              type="text"
              placeholder="value (e.g. ls -al, \\x03 for ^C)"
              value={draftValue}
              onChange={e => setDraftValue(e.target.value)}
              style={{ flex: "2 1 12em" }}
            />
          </div>
          <label className="row tight small" style={{ marginTop: "0.4em" }}>
            <input
              type="checkbox"
              checked={draftNl}
              onChange={e => setDraftNl(e.target.checked)}
            />
            run on tap (append newline)
          </label>
          <div className="row tight" style={{ marginTop: "0.5em", justifyContent: "flex-end" }}>
            <button className="small" onClick={onAdd} disabled={!draftLabel.trim() || !draftValue}>
              Add
            </button>
          </div>
        </fieldset>

        <footer className="row" style={{ justifyContent: "space-between", marginTop: "0.4em" }}>
          <button
            className="ghost small"
            onClick={() => {
              if (confirm("Reset quick commands to defaults?")) resetQuickCommands();
            }}
          >
            reset to defaults
          </button>
          <button className="small" onClick={onClose}>Done</button>
        </footer>
      </div>
    </div>
  );
}

interface ManagerRowProps {
  cmd:                 QuickCommand;
  isDragging:          boolean;
  onHandlePointerDown: (e: React.PointerEvent<HTMLElement>) => void;
  onHandlePointerMove: (e: React.PointerEvent<HTMLElement>) => void;
  onHandlePointerUp:   (e: React.PointerEvent<HTMLElement>) => void;
}

function ManagerRow({
  cmd, isDragging,
  onHandlePointerDown, onHandlePointerMove, onHandlePointerUp,
}: ManagerRowProps) {
  const [editing, setEditing] = useState(false);
  const [label,   setLabel]   = useState(cmd.label);
  const [value,   setValue]   = useState(cmd.value);
  const [nl,      setNl]      = useState(cmd.appendNewline ?? false);

  // Keep the local editing buffer in sync if the underlying command
  // changes from elsewhere (e.g. reset).
  useEffect(() => { setLabel(cmd.label); setValue(cmd.value); setNl(cmd.appendNewline ?? false); }, [cmd]);

  const save = () => {
    if (!label.trim() || !value) { setEditing(false); return; }
    updateQuickCommand(cmd.id, { label: label.trim(), value, appendNewline: nl });
    setEditing(false);
  };

  return (
    <li
      className={"mdock-mgr-row" + (isDragging ? " dragging" : "")}
      data-cmd-id={cmd.id}
    >
      {editing ? (
        <>
          <input
            type="text"
            value={label}
            onChange={e => setLabel(e.target.value)}
            style={{ flex: "1 1 8em" }}
          />
          <input
            type="text"
            value={value}
            onChange={e => setValue(e.target.value)}
            style={{ flex: "2 1 12em" }}
          />
          <label className="small" title="append newline on tap">
            <input type="checkbox" checked={nl} onChange={e => setNl(e.target.checked)} /> ↵
          </label>
          <button className="small" onClick={save}>save</button>
          <button className="ghost small" onClick={() => setEditing(false)}>cancel</button>
        </>
      ) : (
        <>
          <button
            className="mdock-mgr-handle"
            onPointerDown={onHandlePointerDown}
            onPointerMove={onHandlePointerMove}
            onPointerUp={onHandlePointerUp}
            onPointerCancel={onHandlePointerUp}
            title="Drag to reorder"
            aria-label="Drag to reorder"
          >≡</button>
          <span className="mdock-mgr-label">{cmd.label}</span>
          <code className="mdock-mgr-value">{cmd.value}</code>
          {cmd.appendNewline && <span className="pill small">↵</span>}
          <span style={{ flex: "1 1 auto" }} />
          <button className="ghost small" onClick={() => setEditing(true)}>edit</button>
          <button
            className="ghost small"
            onClick={() => { if (confirm(`Delete "${cmd.label}"?`)) deleteQuickCommand(cmd.id); }}
            title="Delete"
          >✕</button>
        </>
      )}
    </li>
  );
}
