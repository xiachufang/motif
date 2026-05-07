import { useRef, useState } from "react";
import type { PtyInfo, ViewInfo } from "../proto/types";
import { useApp } from "../store/store";

interface Props {
  onNewPty: () => void;
}

export default function TabBar({ onNewPty }: Props) {
  const views      = useApp(s => s.views);
  const activeView = useApp(s => s.activeView);
  const client     = useApp(s => s.client);
  const ptyInfos   = useApp(s => s.ptyInfos);
  const applyViewMoved = useApp(s => s.applyViewMoved);

  // Drag-to-reorder state. We keep the drag id and the index the cursor is
  // currently hovering over so we can render an insertion line.
  const dragIdRef = useRef<string | null>(null);
  const [dragId, setDragId] = useState<string | null>(null);
  const [overIdx, setOverIdx] = useState<number | null>(null);

  function activate(id: string) {
    client?.call("view.activate", { view_id: id }).catch(() => { /* idempotent */ });
  }
  function close(id: string) {
    client?.call("view.close",    { view_id: id }).catch(() => { /* idempotent */ });
  }

  function onDragStart(e: React.DragEvent<HTMLDivElement>, id: string) {
    dragIdRef.current = id;
    setDragId(id);
    e.dataTransfer.effectAllowed = "move";
    // Some browsers require text/plain to actually start a drag.
    try { e.dataTransfer.setData("text/plain", id); } catch { /* ignore */ }
  }
  function onDragOver(e: React.DragEvent<HTMLDivElement>, idx: number) {
    if (!dragIdRef.current) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    // Insert before this tab if pointer is on its left half, after if right.
    const rect = (e.currentTarget as HTMLElement).getBoundingClientRect();
    const before = (e.clientX - rect.left) < rect.width / 2;
    const targetIdx = before ? idx : idx + 1;
    if (overIdx !== targetIdx) setOverIdx(targetIdx);
  }
  function onDragEnd() {
    dragIdRef.current = null;
    setDragId(null);
    setOverIdx(null);
  }
  function onDrop(e: React.DragEvent<HTMLDivElement>) {
    e.preventDefault();
    const id = dragIdRef.current;
    const target = overIdx;
    onDragEnd();
    if (!id || target == null) return;
    const from = views.findIndex(v => v.id === id);
    if (from < 0) return;
    // Adjust target when removing from before the insertion point.
    let to = target;
    if (from < to) to -= 1;
    if (to === from) return;

    // Optimistic local reorder so the tab snaps immediately. The server
    // will echo `view.moved` with the same order, which is a no-op apply.
    const next = views.slice();
    const [v] = next.splice(from, 1);
    next.splice(to, 0, v);
    applyViewMoved(next.map(v => v.id));

    client?.call("view.move", { view_id: id, to_index: to }).catch(() => {
      // On failure the next view.moved (or absence of one) keeps the local
      // state from drifting too far; if needed we could re-sync from
      // session.attach. Keep this simple for now.
    });
  }

  // PTY tabs renumber 1..N by current position so closing tab 2 makes the
  // next one slide up to 2 instead of leaving a "sh-7" gap from the server's
  // monotonic id. The ordinal is only used as a fallback label when neither
  // cwd nor fg_name is known yet.
  let ptySeen = 0;
  return (
    <div className="tab-bar" onDragOver={(e) => { if (dragIdRef.current) e.preventDefault(); }} onDrop={onDrop}>
      {views.map((v, i) => {
        const isActive = v.id === activeView;
        const ptyInfo = v.spec.kind === "pty" ? ptyInfos.get(v.spec.pty_id) ?? null : null;
        const ptyOrdinal = v.spec.kind === "pty" ? ++ptySeen : null;
        const isDragging = dragId === v.id;
        // Suppress the indicator on the slot the dragged tab already occupies
        // (its own position and the slot immediately after it both produce a
        // no-op move).
        const fromIdx = dragId ? views.findIndex(x => x.id === dragId) : -1;
        const isNoopSlot = dragId != null && (overIdx === fromIdx || overIdx === fromIdx + 1);
        const insertionBefore = overIdx === i && !isNoopSlot;
        return (
          <div
            key={v.id}
            className={
              "tab"
              + (isActive ? " active" : "")
              + (isDragging ? " dragging" : "")
              + (insertionBefore ? " drop-before" : "")
            }
            draggable
            onDragStart={(e) => onDragStart(e, v.id)}
            onDragOver={(e) => onDragOver(e, i)}
            onDragEnd={onDragEnd}
            onClick={() => activate(v.id)}
            onAuxClick={(e) => { if (e.button === 1) { e.preventDefault(); close(v.id); } }}
            title={describe(v, ptyOrdinal, ptyInfo)}
          >
            <span className="tab-kind">{glyph(v)}</span>
            <span className="tab-label">{label(v, ptyOrdinal, ptyInfo)}</span>
            <button
              type="button"
              className="tab-close"
              onClick={(e) => { e.stopPropagation(); close(v.id); }}
              aria-label="close tab"
            >×</button>
          </div>
        );
      })}
      <div
        className={
          "tab-trailing-drop"
          + (overIdx === views.length && dragId !== null
             && views.findIndex(x => x.id === dragId) !== views.length - 1
              ? " drop-before" : "")
        }
        onDragOver={(e) => {
          if (!dragIdRef.current) return;
          e.preventDefault();
          if (overIdx !== views.length) setOverIdx(views.length);
        }}
      />
      <button
        type="button"
        className="tab-new"
        onClick={onNewPty}
        title="new pty"
        aria-label="new pty"
      >+</button>
    </div>
  );
}

function glyph(v: ViewInfo): string {
  switch (v.spec.kind) {
    case "pty":     return "▶";
    case "preview": return "📄";
    case "image":   return "🖼";
    case "diff":    return "Δ";
  }
}

function label(v: ViewInfo, ptyOrdinal: number | null, pty: PtyInfo | null): string {
  switch (v.spec.kind) {
    case "pty":     return ptyLabel(pty, ptyOrdinal);
    case "preview": return v.spec.path;
    case "image":   return v.spec.path;
    case "diff": {
      const base = v.spec.staged ? "diff(staged)" : "diff";
      if (v.spec.path) {
        const i = v.spec.path.lastIndexOf("/");
        return `${base}: ${i < 0 ? v.spec.path : v.spec.path.slice(i + 1)}`;
      }
      return base;
    }
  }
}

function describe(v: ViewInfo, ptyOrdinal: number | null, pty: PtyInfo | null): string {
  switch (v.spec.kind) {
    case "pty": {
      const cwd = pty?.cwd ?? "";
      const fg  = pty?.fg_name ?? "";
      const parts = [`pty ${ptyOrdinal} (${v.spec.pty_id})`];
      if (cwd) parts.push(`cwd: ${cwd}`);
      if (fg)  parts.push(`fg:  ${fg}`);
      return parts.join("\n");
    }
    case "preview": return `file: ${v.spec.path}`;
    case "image":   return `image: ${v.spec.path}`;
    case "diff": {
      const scope = v.spec.staged ? "staged" : "working tree";
      return v.spec.path ? `${scope} diff: ${v.spec.path}` : `${scope} diff`;
    }
  }
}

function basename(p: string): string {
  const trimmed = p.replace(/\/+$/, "");
  const i = trimmed.lastIndexOf("/");
  return i < 0 ? trimmed : trimmed.slice(i + 1);
}

function ptyLabel(pty: PtyInfo | null, ordinal: number | null): string {
  const cwdBase = pty?.cwd ? basename(pty.cwd) : "";
  // Prefer the foreground program name when known; fall back to the basename
  // of the spawned `cmd` so the user never sees just the cwd in the brief
  // window before the watcher's first poll resolves.
  const fg = pty?.fg_name || (pty?.cmd ? basename(firstToken(pty.cmd)) : "");
  if (cwdBase && fg) return `${cwdBase} · ${fg}`;
  if (cwdBase)       return cwdBase;
  if (fg)            return fg;
  return ordinal != null ? String(ordinal) : "pty";
}

function firstToken(cmd: string): string {
  const t = cmd.trim();
  const i = t.indexOf(" ");
  return i < 0 ? t : t.slice(0, i);
}
