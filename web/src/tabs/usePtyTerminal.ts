// Single xterm.js instance per PTY tab. Replaces the FloatTerm + BlockTerm
// duo: one Terminal whose DOM root (`hostEl`) gets re-parented between two
// slots in PtyTab — the float slot at the bottom while idle, and the live
// slot inside `.pty-stack` while a command is running.
//
// Lifecycle:
//   - First hook call for a ptyId creates the Terminal + addons, the
//     detached `hostEl` <div>, and attaches once to ptyBuffers via
//     `attachPty` (single listener, all bytes flow in arrival order).
//   - Re-mounts of any PtyTab using this hook return the same instance
//     from the module-global map — StrictMode double-mount and tab-switch
//     are no-ops at the terminal level.
//   - `disposePtyTerminal(ptyId)` is called from Workspace's `pty.exited`
//     path: tears down listeners, removes `hostEl` from the DOM, and
//     `term.dispose()`s.
//
// Mode transitions:
//   - `beginRunning(blockId)`: drains pending writes, serializes the
//     current visible area as `prompt_html`, then `clear()+reset()`s the
//     grid and registers the body start marker. Caller (PtyTab) then
//     re-parents `hostEl` into the live slot and triggers a resize.
//   - `endRunning(...)`: drains pending writes, serializes `startMarker
//     → cursor` as `html_body` (or marks `kind: "alt"` if alt-screen was
//     seen), and dispatches `finalizeRunningBlock` to the store. The
//     subsequent re-render flips `runningBlock` to null; the layout
//     effect then re-parents `hostEl` back to the float slot and
//     `clear()+reset()`s for the next prompt cycle.
//
// Sizing: a single `scheduleResize` consults `mode` to pick the formula.
//   idle:     gridRows = FLOAT_MAX_ROWS, visible = wantRows
//   running:  gridRows = protoRows (full stack viewport)
//             visible  = min(protoRows, lastUsedAbs+1) for normal output,
//                        protoRows for alt-screen apps
// Width comes from `fit.proposeDimensions().cols`. applyResize itself
// drives `pty.resize` (de-duped on inst.lastSent{Cols,Rows}); we don't
// rely on `term.onResize` because that callback isn't reliable for
// cols-only changes.

import { useEffect, useState } from "react";
import { Terminal, type IMarker } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { SerializeAddon } from "@xterm/addon-serialize";
import "@xterm/xterm/css/xterm.css";

import { useApp } from "../store/store";
import { attachPty } from "../store/ptyBuffers";
import type { BlockId } from "../proto/types";

const SCROLLBACK_ROWS = 5000;
const FLOAT_MIN_ROWS  = 1;
/** Max grid rows reserved for the float pane. Has to be tall enough to
 *  contain fish's completion pager (which renders rows BELOW the cursor
 *  while the cursor stays on the cmdline) without scrolling. Visual
 *  height never reaches this — it tracks the bottom-most used row. */
const FLOAT_MAX_ROWS  = 24;

/** Font settings shared between the live xterm and the headless xterm in
 *  serializeBlock. SerializeAddon writes both into the generated HTML's
 *  wrapper `<div>` style; if the two terminals disagree, finalized live
 *  blocks and backfilled blocks will render with different glyph metrics
 *  (xterm's default is `courier-new, courier, monospace` 15px). */
export const TERM_FONT_FAMILY = "ui-monospace, Menlo, Consolas, monospace";
export const TERM_FONT_SIZE   = 13;

const DEBUG = true;
function dlog(tag: string, msg: string, data?: Record<string, unknown>) {
  if (!DEBUG) return;
  if (data) console.log(`[term:${tag}] ${msg}`, data);
  else      console.log(`[term:${tag}] ${msg}`);
}

type Mode = "idle" | "running";

interface PtyTermInst {
  term:        Terminal;
  fit:         FitAddon;
  serialize:   SerializeAddon;
  hostEl:      HTMLDivElement;

  /** True once `term.open(hostEl)` has run. Deferred until `hostEl` is
   *  inside the live DOM tree (xterm needs measurable dimensions). */
  opened:      boolean;
  mode:        Mode;
  /** id of the running block while in `running` mode; null otherwise. */
  runningId:   BlockId | null;
  /** Anchor for body serialize at finalize. Re-registered at line 0
   *  immediately after `clear()+reset()` in `beginRunning`. */
  startMarker: IMarker | null;
  /** Latched true if alt-screen ever toggled during the running block.
   *  Reset at `endRunning`. */
  altSeen:     boolean;

  /** Latest cell height measured from the rendered xterm DOM. Recomputed
   *  on every resize since theme/font changes can shift it. */
  cellHeight:  number;
  /** Latest stack viewport element (PtyTab updates via `setStackEl`). */
  stackEl:     HTMLElement | null;
  /** Latest live-slot header element (PtyTab updates via `setHeaderEl`). */
  headerEl:    HTMLElement | null;

  rafSize:     number | null;
  /** Observer attached to whichever slot currently hosts us. Re-created
   *  on every `attachToSlot` call. */
  slotObserver: ResizeObserver | null;

  /** Last cols/rows we sent to the PTY. De-dupes pty.resize calls so
   *  fish doesn't get a flood of identical SIGWINCH events. */
  lastSentCols: number;
  lastSentRows: number;

  /** PtyId is needed by applyResize (which lives outside the hook
   *  closure) to dispatch pty.resize. Stored on the instance so the
   *  module-level helper can read it. */
  ptyId:       string;

  /** Listeners attached at creation; freed by `disposePtyTerminal`. */
  disposers:   Array<() => void>;
}

const instances = new Map<string, PtyTermInst>();
/** Per-instance subscribers for alt-state changes. React components opt
 *  in via `useEffect` and we fire all of them on every buffer-type flip. */
const altSubs   = new Map<string, Set<(alt: boolean) => void>>();

function getOrCreate(ptyId: string): PtyTermInst {
  const existing = instances.get(ptyId);
  if (existing) return existing;

  const term = new Terminal({
    fontFamily: TERM_FONT_FAMILY,
    fontSize:   TERM_FONT_SIZE,
    cursorBlink: true,
    scrollback: SCROLLBACK_ROWS,
    theme: { background: "#0e0e0e", foreground: "#e6e6e6" },
    allowProposedApi: true,
  });
  const fit       = new FitAddon();
  const serialize = new SerializeAddon();
  term.loadAddon(fit);
  term.loadAddon(new WebLinksAddon());
  term.loadAddon(serialize);

  const hostEl = document.createElement("div");
  hostEl.className = "pty-host";

  const inst: PtyTermInst = {
    term, fit, serialize, hostEl,
    opened:      false,
    mode:        "idle",
    runningId:   null,
    startMarker: null,
    altSeen:     false,
    cellHeight:  16,
    stackEl:     null,
    headerEl:    null,
    rafSize:     null,
    slotObserver: null,
    lastSentCols: 0,
    lastSentRows: 0,
    ptyId,
    disposers:   [],
  };
  instances.set(ptyId, inst);

  // ─── listeners that live for the terminal's whole lifetime ───
  inst.disposers.push(term.onData(data => {
    const c = useApp.getState().client;
    if (!c) return;
    const u8 = new TextEncoder().encode(data);
    let bin = "";
    for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
    c.call("pty.write", { pty_id: ptyId, data_b64: btoa(bin) }).catch(() => { /* ignore */ });
  }).dispose);

  // pty.resize is driven from applyResize (sendPtyResize helper), not
  // from term.onResize — that callback wasn't firing reliably for
  // cols-only changes. applyResize calls sendPtyResize after every
  // term.resize, with de-duping via inst.lastSent{Cols,Rows}.

  inst.disposers.push(term.onCursorMove(() => scheduleResize(inst)).dispose);
  inst.disposers.push(term.onScroll(()     => scheduleResize(inst)).dispose);
  inst.disposers.push(term.onLineFeed(()   => scheduleResize(inst)).dispose);

  inst.disposers.push(term.buffer.onBufferChange(() => {
    const isAlt = term.buffer.active.type === "alternate";
    if (isAlt) inst.altSeen = true;
    if (isAlt) requestAnimationFrame(() => term.focus());
    const subs = altSubs.get(ptyId);
    if (subs) subs.forEach(s => { try { s(isAlt); } catch { /* ignore */ } });
    scheduleResize(inst);
  }).dispose);

  // ─── attach to ptyBuffers (single listener, all bytes) ───
  const att = attachPty(ptyId, {
    data: chunk => {
      try {
        if (DEBUG) {
          // Decode the first few bytes for visibility (escape ESC/CR/LF).
          const len = chunk.length;
          let preview = "";
          for (let i = 0; i < Math.min(len, 80); i++) {
            const b = chunk[i];
            if (b === 0x1b) preview += "\\e";
            else if (b === 0x0d) preview += "\\r";
            else if (b === 0x0a) preview += "\\n";
            else if (b === 0x07) preview += "\\a";
            else if (b < 0x20) preview += `\\x${b.toString(16).padStart(2, "0")}`;
            else preview += String.fromCharCode(b);
          }
          if (len > 80) preview += `…(${len} bytes)`;
          dlog("data", `chunk len=${len}`, { preview });
        }
        term.write(chunk, () => {
          if (DEBUG) {
            const buf = term.buffer.active;
            dlog("data", "write done", {
              cursorY: buf.cursorY,
              viewportY: buf.viewportY,
              cursorX: buf.cursorX,
              lastUsed: findLastUsedRow(term),
            });
          }
          scheduleResize(inst);
        });
      } catch { /* ignore */ }
    },
    boundary: () => {
      try {
        dlog("boundary", "fired");
        term.write("", () => {
          if (inst.mode === "running") {
            dlog("boundary", "skip clear (running mode)");
            return;
          }
          dlog("boundary", "clearing buffer");
          term.clear();
          term.reset();
        });
      } catch { /* ignore */ }
    },
  });
  // Replay any pre-attach bytes — should be empty in practice (the hook
  // attaches at PtyTab first render, before the user can produce output)
  // but covers the corner where ws events landed before component mount.
  for (const c of att.initial) {
    try { term.write(c); } catch { /* ignore */ }
  }
  inst.disposers.push(att.detach);

  return inst;
}

/** Return the bottom-most viewport row index (0-based, relative to
 *  viewport top) that contains any non-blank glyph. Used by the idle
 *  resize formula so fish's completion pager — rendered BELOW the
 *  cmdline cursor — gets enough visual height to be visible. Returns
 *  `-1` for a fully blank viewport. O(rows) but `rows ≤ FLOAT_MAX_ROWS`
 *  so cheap. */
function findLastUsedRow(term: Terminal): number {
  const buf = term.buffer.active;
  for (let y = term.rows - 1; y >= 0; y--) {
    const line = buf.getLine(buf.viewportY + y);
    if (!line) continue;
    if (line.translateToString(true).length > 0) return y;
  }
  return -1;
}

/** Snapshot the current viewport's rows for debugging. Returns each row's
 *  trimmed text (truncated to 60 chars) so it's readable in the console. */
function snapshotRows(term: Terminal): string[] {
  const buf = term.buffer.active;
  const out: string[] = [];
  for (let y = 0; y < term.rows; y++) {
    const line = buf.getLine(buf.viewportY + y);
    if (!line) { out.push(`(null)`); continue; }
    const text = line.translateToString(true);
    out.push(text.length > 60 ? text.slice(0, 60) + "…" : text);
  }
  return out;
}

/** Pick rows for the PTY protocol from the current mode + DOM measurements. */
function computeProtocolRows(inst: PtyTermInst): number {
  const cellH   = inst.cellHeight || 16;
  const stackPx = inst.stackEl?.clientHeight ?? 480;
  const headerPx = inst.headerEl?.offsetHeight ?? 0;
  return Math.max(8, Math.floor((stackPx - headerPx) / cellH));
}

/** Recompute and apply the visual height + xterm grid dims. Coalesced
 *  via rAF — multiple events in the same frame collapse into one call. */
function scheduleResize(inst: PtyTermInst): void {
  if (inst.rafSize != null) return;
  inst.rafSize = requestAnimationFrame(() => {
    inst.rafSize = null;
    if (!inst.opened) return;
    applyResize(inst);
  });
}

function applyResize(inst: PtyTermInst): void {
  const { term, fit, hostEl } = inst;
  if (!hostEl.isConnected) {
    dlog("resize", "skip: hostEl not connected");
    return;
  }
  const dims = fit.proposeDimensions();
  if (!dims || !dims.cols) {
    dlog("resize", "skip: no dims from fit", { dims });
    return;
  }

  // Re-measure cell height from the rendered xterm rows.
  const screen = hostEl.querySelector(".xterm-rows") as HTMLElement | null;
  const firstRow = screen?.firstElementChild as HTMLElement | null;
  if (firstRow && firstRow.clientHeight > 0) {
    inst.cellHeight = firstRow.clientHeight;
  }
  const cellH = inst.cellHeight;

  const buf   = term.buffer.active;
  const isAlt = buf.type === "alternate";

  let gridRows: number;
  let visiblePx: number;
  let formula = "";
  if (inst.mode === "running") {
    const protoRows = computeProtocolRows(inst);
    // Grid is always full viewport — programs see a stable terminal
    // size and don't get a SIGWINCH stream as output streams in. Visual
    // size is decoupled and tracks the bottom-most content row.
    gridRows = protoRows;
    if (isAlt) {
      visiblePx = protoRows * cellH;
      formula = `running/alt: protoRows=${protoRows}`;
    } else {
      const lastUsedAbs = buf.viewportY + buf.cursorY;
      const visibleRows = Math.max(1, Math.min(protoRows, lastUsedAbs + 1));
      visiblePx = visibleRows * cellH;
      formula = `running: lastUsedAbs=${lastUsedAbs} protoRows=${protoRows} visibleRows=${visibleRows}`;
    }
  } else {
    const lastUsed = findLastUsedRow(term);
    const wantRows = Math.max(buf.cursorY + 1, lastUsed + 1);
    gridRows  = FLOAT_MAX_ROWS;
    visiblePx = Math.max(FLOAT_MIN_ROWS, Math.min(FLOAT_MAX_ROWS, wantRows)) * cellH;
    formula = `idle: cursorY=${buf.cursorY} lastUsed=${lastUsed} wantRows=${wantRows}`;
  }

  const before = {
    termCols: term.cols, termRows: term.rows,
    bufCursorY: buf.cursorY, bufViewportY: buf.viewportY, bufLength: buf.length,
    hostHeight: hostEl.clientHeight,
    hostStyleHeight: hostEl.style.height,
    cellH,
    isAlt,
    mode: inst.mode,
  };

  let resized = false;
  if (term.cols !== dims.cols || term.rows !== gridRows) {
    try {
      term.resize(dims.cols, gridRows);
      resized = true;
    } catch (e) {
      dlog("resize", "term.resize threw", { err: String(e) });
    }
  }
  hostEl.style.height = `${visiblePx}px`;

  // Push the new dims to the PTY ourselves — `term.onResize` was not
  // firing reliably for cols-only changes. fish's pager paginates by
  // these rows, so sending the wrong value (e.g. stale 53 when grid
  // is 24) causes the pager to write past the grid and scroll PS1
  // into scrollback. De-dupe so fish doesn't get a SIGWINCH storm
  // from the rAF resize loop.
  if (inst.lastSentCols !== dims.cols || inst.lastSentRows !== gridRows) {
    inst.lastSentCols = dims.cols;
    inst.lastSentRows = gridRows;
    const c = useApp.getState().client;
    if (c) {
      dlog("ptyResize", `cols=${dims.cols} rows=${gridRows}`);
      c.call("pty.resize", { pty_id: inst.ptyId, cols: dims.cols, rows: gridRows })
        .catch(() => { /* ignore */ });
    } else {
      dlog("ptyResize", `skip: no client (cols=${dims.cols} rows=${gridRows})`);
    }
  }

  dlog("resize", formula, {
    proposeCols: dims.cols,
    targetGridRows: gridRows,
    visiblePx,
    resized,
    before,
    after: {
      termCols: term.cols, termRows: term.rows,
      bufCursorY: term.buffer.active.cursorY,
      bufViewportY: term.buffer.active.viewportY,
      bufLength: term.buffer.active.length,
    },
    rowsSnapshot: snapshotRows(term),
  });
}

/** Imperative handle returned by the hook. Plain object — methods bound
 *  to the per-PTY instance via closure. */
export interface PtyTerminalHandle {
  hostEl:        HTMLDivElement;
  /** True iff alt-screen buffer is currently active. Reactive (re-renders
   *  the consumer when it flips). */
  altActive:     boolean;
  /** Re-parent `hostEl` into the given slot (no-op if already there) and
   *  trigger first-time `term.open()` if needed. */
  attachToSlot:  (slot: HTMLElement | null) => void;
  /** Mode flag for sizing. Caller flips when re-parenting. */
  setMode:       (m: Mode) => void;
  /** Update DOM measurements used by the resize formula. */
  setStackEl:    (el: HTMLElement | null) => void;
  setHeaderEl:   (el: HTMLElement | null) => void;
  /** Force a resize recompute (e.g. after slot change or stack resize). */
  resize:        () => void;
  /** Begin a running-block phase: drain → snapshot prompt_html → clear
   *  → register start marker → caller's `done` callback. The `done`
   *  callback is where PtyTab does the slot re-parent + setMode. */
  beginRunning:  (blockId: BlockId, done: () => void) => void;
  /** End a running-block phase: drain → snapshot html_body → dispatch
   *  finalize. PtyTab's layout effect picks up the resulting null
   *  runningBlock and re-parents back to the float slot. */
  endRunning:    (
    blockId: BlockId,
    exit_code: number | null,
    finished_at: number,
  ) => void;
  /** Take keyboard focus. Used by PtyTab to re-grab focus on tab activate
   *  / running-state transition. */
  focus:         () => void;
  /** Current xterm cols. Used by backfill rendering to keep history in
   *  sync with the live grid width. */
  getCols:       () => number;
}

/** React hook: returns a stable handle to the per-PTY xterm. Calling this
 *  from multiple components for the same `ptyId` returns the same
 *  instance (same `hostEl`, same listeners). */
export function usePtyTerminal(ptyId: string): PtyTerminalHandle {
  const inst = getOrCreate(ptyId);

  const [altActive, setAltActive] = useState(inst.term.buffer.active.type === "alternate");

  // Subscribe to alt-state changes for THIS component instance.
  useEffect(() => {
    let subs = altSubs.get(ptyId);
    if (!subs) { subs = new Set(); altSubs.set(ptyId, subs); }
    const fn = (alt: boolean) => setAltActive(alt);
    subs.add(fn);
    // Sync once on subscribe in case state already changed before mount.
    setAltActive(inst.term.buffer.active.type === "alternate");
    return () => {
      subs!.delete(fn);
      if (subs!.size === 0) altSubs.delete(ptyId);
    };
  }, [ptyId, inst]);

  const attachToSlot = (slot: HTMLElement | null) => {
    if (!slot) {
      dlog("attach", "skip: null slot");
      return;
    }
    const wasParented = inst.hostEl.parentNode === slot;
    if (!wasParented) {
      dlog("attach", "moving hostEl to slot", {
        slotClass: (slot as HTMLElement).className,
        prevParentClass: (inst.hostEl.parentNode as HTMLElement | null)?.className ?? "(none)",
        slotW: (slot as HTMLElement).clientWidth,
        slotH: (slot as HTMLElement).clientHeight,
      });
      slot.appendChild(inst.hostEl);
    }
    if (!inst.opened) {
      try {
        inst.term.open(inst.hostEl);
        inst.opened = true;
        dlog("attach", "term.open ran", {
          hostW: inst.hostEl.clientWidth,
          hostH: inst.hostEl.clientHeight,
        });
      } catch (e) { dlog("attach", "term.open threw", { err: String(e) }); }
    }
    // Watch the slot's WIDTH (height changes are driven by us via the
    // inline style on `hostEl`). Width is what fit.proposeDimensions
    // reads to derive cols. We deliberately do NOT call fit.fit() here
    // — fit's resize would shrink the grid to match the visible height,
    // pushing PS1 rows into scrollback when the visible area is small.
    // applyResize keeps the grid pinned at FLOAT_MAX_ROWS (idle) or the
    // computed protocol rows (running), independent of what's visible.
    if (inst.slotObserver) inst.slotObserver.disconnect();
    const ro = new ResizeObserver(entries => {
      if (!inst.opened) return;
      if (DEBUG) {
        const e = entries[0];
        dlog("ro", "slot resize", {
          contentBox: e ? { w: e.contentRect.width, h: e.contentRect.height } : null,
          targetClass: (e?.target as HTMLElement | undefined)?.className,
        });
      }
      scheduleResize(inst);
    });
    ro.observe(slot);
    if (inst.stackEl && inst.stackEl !== slot) ro.observe(inst.stackEl);
    inst.slotObserver = ro;
    scheduleResize(inst);
  };

  const setMode = (m: Mode) => {
    if (inst.mode === m) return;
    dlog("mode", `${inst.mode} → ${m}`);
    inst.mode = m;
    scheduleResize(inst);
  };

  const setStackEl = (el: HTMLElement | null) => {
    inst.stackEl = el;
    scheduleResize(inst);
  };

  const setHeaderEl = (el: HTMLElement | null) => {
    inst.headerEl = el;
    scheduleResize(inst);
  };

  const resize = () => scheduleResize(inst);

  const beginRunning: PtyTerminalHandle["beginRunning"] = (blockId, done) => {
    const { term, serialize } = inst;
    inst.runningId = blockId;
    inst.altSeen   = false;
    // Drain queued writes so the buffer reflects fully-rendered prompt.
    term.write("", () => {
      // Snapshot what's currently visible — that's the rendered PS1+cmd.
      const buf = term.buffer.active;
      const endAbs = buf.viewportY + buf.cursorY - 1;
      if (endAbs >= 0) {
        try {
          const html = serialize.serializeAsHTML({
            range: { startLine: 0, endLine: endAbs, startCol: 0 },
            includeGlobalBackground: true,
          });
          if (html) {
            useApp.getState().setRunningPromptHtml(ptyId, blockId, html);
          }
        } catch { /* ignore */ }
      }
      term.clear();
      term.reset();
      // After reset, prior markers are invalid — anchor the body's start
      // line at 0 so the finalize range begins from the cleared top.
      try { inst.startMarker = term.registerMarker(0); } catch { inst.startMarker = null; }
      done();
    });
  };

  const endRunning: PtyTerminalHandle["endRunning"] = (blockId, exit_code, finished_at) => {
    const { term, serialize } = inst;
    if (inst.runningId !== blockId) return;
    term.write("", () => {
      const startMarker = inst.startMarker;
      const endMarker   = term.registerMarker(0);
      const altSeen     = inst.altSeen;

      const finalize = useApp.getState().finalizeRunningBlock;
      let payload: Parameters<typeof finalize>[2];
      if (altSeen) {
        payload = { kind: "alt", exit_code, finished_at };
      } else {
        let html = "";
        if (startMarker && startMarker.line >= 0
            && endMarker && endMarker.line >= 0
            && endMarker.line >= startMarker.line) {
          try {
            html = serialize.serializeAsHTML({
              range: { startLine: startMarker.line, endLine: endMarker.line, startCol: 0 },
              includeGlobalBackground: true,
            });
          } catch { /* serialization failure → empty body */ }
        }
        payload = { kind: "card", html_body: html, exit_code, finished_at };
      }
      try { endMarker?.dispose(); } catch { /* ignore */ }

      // Reset for the next idle cycle. The slot re-parent happens via
      // PtyTab's layout effect once the store flip propagates.
      inst.runningId   = null;
      inst.startMarker = null;
      inst.altSeen     = false;
      try { term.clear(); term.reset(); } catch { /* ignore */ }

      requestAnimationFrame(() => {
        finalize(ptyId, blockId, payload);
      });
    });
  };

  return {
    hostEl:       inst.hostEl,
    altActive,
    attachToSlot,
    setMode,
    setStackEl,
    setHeaderEl,
    resize,
    beginRunning,
    endRunning,
    focus:        () => { try { inst.term.focus(); } catch { /* ignore */ } },
    getCols:      () => inst.term.cols,
  };
}

/** Tear down a per-PTY terminal. Call from the `pty.exited` path. */
export function disposePtyTerminal(ptyId: string): void {
  const inst = instances.get(ptyId);
  if (!inst) return;
  for (const d of inst.disposers) { try { d(); } catch { /* ignore */ } }
  if (inst.rafSize != null) cancelAnimationFrame(inst.rafSize);
  if (inst.slotObserver) { try { inst.slotObserver.disconnect(); } catch { /* ignore */ } }
  try { inst.hostEl.remove(); } catch { /* ignore */ }
  // Defer the actual dispose by one frame so any in-flight write callbacks
  // don't blow up on a torn-down terminal.
  const term = inst.term;
  requestAnimationFrame(() => { try { term.dispose(); } catch { /* ignore */ } });
  instances.delete(ptyId);
  altSubs.delete(ptyId);
}

/** Drop everything. Used on session detach / logout. */
export function disposeAllPtyTerminals(): void {
  for (const id of Array.from(instances.keys())) disposePtyTerminal(id);
}
