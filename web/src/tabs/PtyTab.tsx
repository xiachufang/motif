// xterm.js-based PTY tab. Output bytes flow in via the module-level
// `ptyBuffers` registry — Workspace populates it from `pty.output` events,
// and we attach() on mount to atomically grab pre-mount bytes + future ones.
//
// v2 shell-integration: when `pty.command_started` lands the
// store gets a new `running` entry and we register an xterm IMarker at
// the current cursor row; on `command_finished` we register a second
// marker. Clicking a row in BlockList then sets `selectedBlock` in the
// store, and the effect below scrolls the viewport + paints a
// background decoration spanning the marked range.

import { useEffect, useRef } from "react";
import { Terminal, type IMarker, type IDecoration } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";

import { useApp } from "../store/store";
import { attach } from "../store/ptyBuffers";

interface Props { ptyId: string; active: boolean }

interface BlockMarkers { start: IMarker; end?: IMarker }

export default function PtyTab({ ptyId, active }: Props) {
  const client  = useApp(s => s.client);
  const ptyInfo = useApp(s => s.ptyInfos.get(ptyId));
  const wrapRef = useRef<HTMLDivElement | null>(null);
  const termRef = useRef<Terminal | null>(null);
  const fitRef  = useRef<FitAddon | null>(null);

  // v2 shell-integration: per-block xterm markers + the active
  // selection's decoration. Refs (not state) — we only mutate them
  // imperatively to drive xterm, never need a re-render off them.
  const markersRef    = useRef<Map<string, BlockMarkers>>(new Map());
  const decorationRef = useRef<IDecoration | null>(null);

  const runningId      = useApp(s => s.ptyBlocks.get(ptyId)?.running?.id ?? null);
  const lastFinishedId = useApp(s => s.ptyBlocks.get(ptyId)?.recent?.[0]?.id ?? null);
  const selectedBlock  = useApp(s => s.selectedBlock);

  // Mount the terminal once and wire it to the byte buffer.
  useEffect(() => {
    if (!wrapRef.current) return;
    const wrap = wrapRef.current;
    const term = new Terminal({
      fontFamily: "ui-monospace, Menlo, Consolas, monospace",
      fontSize: 13,
      cursorBlink: true,
      scrollback: 5000,
      theme: { background: "#0a0a0a", foreground: "#e6e6e6" },
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon());
    term.open(wrap);
    termRef.current = term;
    fitRef.current  = fit;

    // Defer attach()+initial-write until the wrapper actually has a non-zero
    // size, so the first bytes (shell banner, alt-screen apps like less) land
    // on a correctly-sized grid. Writing under xterm's default 80×24 and then
    // resizing leaves stale cells — xterm doesn't reflow already-written rows.
    let detachBuffer: (() => void) | null = null;
    let started = false;
    const start = () => {
      if (started) return;
      if (wrap.clientWidth === 0 || wrap.clientHeight === 0) return;
      try { fit.fit(); } catch { return; }
      started = true;
      const att = attach(ptyId, chunk => term.write(chunk));
      for (const c of att.initial) term.write(c);
      detachBuffer = att.detach;
    };

    const ro = new ResizeObserver(() => {
      if (!started) start();
      else { try { fit.fit(); } catch {} }
    });
    ro.observe(wrap);
    start();

    // Forward keystrokes upstream.
    const offData = term.onData((data) => {
      // utf-8 → base64. Using TextEncoder for proper UTF-8 handling.
      const u8 = new TextEncoder().encode(data);
      let bin = "";
      for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
      const b64 = btoa(bin);
      client?.call("pty.write", { pty_id: ptyId, data_b64: b64 }).catch(() => {});
    });

    // Resize → server.
    const offResize = term.onResize(({ cols, rows }) => {
      client?.call("pty.resize", { pty_id: ptyId, cols, rows }).catch(() => {});
    });

    return () => {
      ro.disconnect();
      offData.dispose();
      offResize.dispose();
      detachBuffer?.();
      term.dispose();
      termRef.current = null;
      fitRef.current  = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ptyId]);

  // ResizeObserver handles fit on visibility transitions; this only refocuses.
  useEffect(() => {
    if (!active) return;
    const id = requestAnimationFrame(() => {
      termRef.current?.focus();
    });
    return () => cancelAnimationFrame(id);
  }, [active]);

  // ── v2 shell-integration: block markers + selected-block highlight ──

  // Register a start marker the first time `running.id` shows up. Idea:
  // by the time `pty.command_started` reaches the store, the `OSC 133;C`
  // marker has been stripped from the byte stream and the cursor sits
  // at the row where the command's output is about to flow in. Marking
  // here pins that row so we can scroll back to it later.
  useEffect(() => {
    const term = termRef.current;
    if (!term || !runningId) return;
    if (markersRef.current.has(runningId)) return;
    const m = term.registerMarker(0);
    if (m) markersRef.current.set(runningId, { start: m });
  }, [runningId]);

  // End marker on the matching `command_finished` (= the head of
  // `recent`). The cursor here is on the row immediately after the
  // command's output, just before the next prompt re-paints.
  useEffect(() => {
    const term = termRef.current;
    if (!term || !lastFinishedId) return;
    const entry = markersRef.current.get(lastFinishedId);
    if (!entry || entry.end) return;
    const m = term.registerMarker(0);
    if (m) entry.end = m;
  }, [lastFinishedId]);

  // Scroll + highlight when the selected block changes. Disposing the
  // previous decoration first guarantees only one is active.
  useEffect(() => {
    const term = termRef.current;
    if (!term) return;
    decorationRef.current?.dispose();
    decorationRef.current = null;
    if (!selectedBlock || selectedBlock.ptyId !== ptyId) return;
    const entry = markersRef.current.get(selectedBlock.blockId);
    if (!entry) return;
    // Pin the start row at the top of the viewport. xterm exposes
    // viewportY (current scroll position in absolute lines), so the
    // delta gets us there in one call.
    const viewportY = term.buffer.active.viewportY;
    const delta = entry.start.line - viewportY;
    if (delta !== 0) term.scrollLines(delta);
    // Decoration height = lines from start to end (inclusive). When
    // the block is still running we don't know its end yet — fall
    // back to a 1-row marker on the start row, which the CSS below
    // styles as a left border.
    const height = entry.end
      ? Math.max(1, entry.end.line - entry.start.line + 1)
      : 1;
    decorationRef.current = term.registerDecoration({
      marker: entry.start,
      height,
      layer: "bottom",
      backgroundColor: "#3a3318",
    }) ?? null;
  }, [selectedBlock, ptyId, lastFinishedId]);

  return (
    <div className="pty-tab">
      <div className="pty-meta muted small">
        {ptyInfo ? `${ptyInfo.cmd} · ${ptyInfo.cols}×${ptyInfo.rows}` : "(loading…)"}
      </div>
      <div className="pty-host" ref={wrapRef} />
    </div>
  );
}
