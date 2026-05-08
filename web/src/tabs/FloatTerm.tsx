// Bottom-pinned input pane for a PTY tab. Renders only the prompt zone:
// PS1, the user's typed command, and any PS2 continuation lines.
//
// Routing & lifecycle (driven by ptyBuffers.attachPrompt):
//   - prompt + compose-zone bytes flow in via the `data` callback and
//     are written straight to xterm.
//   - PromptStarted edges fire the `boundary` callback synchronously.
//     We use that edge to (a) capture the just-finished PS1+typed-cmd
//     row as `prompt_html` for the running BlockCard header, and
//     (b) `term.clear() + term.reset()` so the next PS1 paints on a
//     fresh grid. Doing this inline in the dispatcher (not a React
//     effect) sidesteps the previous race where post-output bytes
//     leaked into the xterm before reset ran.
//   - output-zone bytes never reach this terminal; they're filtered by
//     ptyBuffers and routed to the running BlockTerm instead.
//
// Sizing dimensions:
//   - **Visual height** of this pane: cursorY+1 rows, capped at FLOAT_MAX_ROWS
//     so a long PS2 paste doesn't eat the tab. With phase-driven reset the
//     buffer is never polluted with stale rows, so cursorY alone is enough —
//     no need to add viewportY.
//   - **PTY protocol rows**: the FULL stack viewport (read from stackHeightRef).
//     The shell needs this so alt-screen apps in BlockTerm get a real-sized
//     canvas; we only resize the PTY here because FloatTerm is the only
//     component that always exists.

import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { SerializeAddon } from "@xterm/addon-serialize";
import "@xterm/xterm/css/xterm.css";

import { useApp } from "../store/store";
import { attachPrompt } from "../store/ptyBuffers";

const FLOAT_MIN_ROWS = 1;
const FLOAT_MAX_ROWS = 12;

interface Props {
  ptyId:           string;
  active:          boolean;
  /** PtyTab-owned ref to the .pty-stack element. We read its
   *  `clientHeight` to compute the PTY protocol rows so alt-screen apps
   *  in BlockTerm get a real canvas size. */
  stackElRef:      React.MutableRefObject<HTMLDivElement | null>;
  /** Whenever fit() picks a new cols, we publish it so the running
   *  BlockTerm can mirror — they must agree on width or the stack
   *  will look misaligned. */
  onColsChange:    (cols: number) => void;
}

export default function FloatTerm({ ptyId, active, stackElRef, onColsChange }: Props) {
  const client           = useApp(s => s.client);
  const setRunningPrompt = useApp(s => s.setRunningPromptHtml);

  const wrapRef          = useRef<HTMLDivElement | null>(null);
  const termRef          = useRef<Terminal | null>(null);
  const fitRef           = useRef<FitAddon | null>(null);
  const serializeRef     = useRef<SerializeAddon | null>(null);
  const cellHeightRef    = useRef<number>(16);
  const rafSizeRef       = useRef<number | null>(null);

  // ─────────────────────── mount ───────────────────────
  useEffect(() => {
    if (!wrapRef.current) return;
    const wrap = wrapRef.current;
    const term = new Terminal({
      fontFamily: "ui-monospace, Menlo, Consolas, monospace",
      fontSize:   13,
      cursorBlink: true,
      scrollback: 200,
      theme: { background: "#0e0e0e", foreground: "#e6e6e6" },
      allowProposedApi: true,
    });
    const fit       = new FitAddon();
    const serialize = new SerializeAddon();
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon());
    term.loadAddon(serialize);
    term.open(wrap);
    termRef.current      = term;
    fitRef.current       = fit;
    serializeRef.current = serialize;

    // Compute PTY protocol rows from the stack viewport — NOT from this
    // term's visual rows. Alt-screen apps in BlockTerm need the full
    // viewport size to paint correctly.
    const measureViewportRows = (): number => {
      const cellH = cellHeightRef.current || 16;
      const stackEl = stackElRef.current;
      const stackPx = stackEl?.clientHeight ?? 480;
      return Math.max(8, Math.floor(stackPx / cellH));
    };

    const updateLiveSize = () => {
      rafSizeRef.current = null;
      const t = termRef.current;
      if (!t) return;
      const dims = fit.proposeDimensions();
      if (!dims || !dims.cols) return;
      // Phase-driven reset keeps the buffer clean — cursor never
      // overflows into scrollback during steady-state, so cursorY+1
      // is the true content height. Don't add viewportY: that would
      // count any incidental scrollback (e.g. backfilled prompts) into
      // wantRows and trigger xterm to pull them back into view.
      const buf = t.buffer.active;
      const wantRows = Math.max(FLOAT_MIN_ROWS, Math.min(FLOAT_MAX_ROWS, buf.cursorY + 1));

      if (t.cols !== dims.cols || t.rows !== wantRows) {
        try { t.resize(dims.cols, wantRows); } catch { /* ignore */ }
      }
      const cellH = cellHeightRef.current;
      wrap.style.height = `${wantRows * cellH}px`;
    };
    const scheduleLiveSize = () => {
      if (rafSizeRef.current != null) return;
      rafSizeRef.current = requestAnimationFrame(updateLiveSize);
    };

    // PromptStarted boundary handler. Runs synchronously from the
    // ws dispatcher. At this moment the buffer holds the PS1 + user
    // input from the just-submitted command (post-output bytes were
    // dropped by ptyBuffers, so the buffer didn't get polluted between
    // command_finished and prompt_started). We capture that row as
    // prompt_html for the running block, then reset for the next PS1.
    const onBoundary = () => {
      const t = termRef.current;
      if (!t) return;
      // Drain pending writes so cursor sits at its post-Enter resting
      // row before we register the marker.
      t.write("", () => {
        const live = termRef.current;
        const liveSer = serializeRef.current;
        if (!live) return;

        if (liveSer) {
          // Find a trailing running block whose prompt_html hasn't been
          // captured yet. Reading store state here (not via subscription)
          // is intentional: this callback runs synchronously during
          // dispatch, before React commits any pending requestFinalize,
          // so the trailing block is still in `running` state.
          const ui = useApp.getState().ptyBlocks.get(ptyId);
          const last = ui?.blocks[ui.blocks.length - 1];
          const captureFor =
            last && last.kind === "running" && last.prompt_html === ""
              ? last.id
              : null;
          if (captureFor) {
            const m = live.registerMarker(-1);
            if (m && m.line >= 0) {
              try {
                const html = liveSer.serializeAsHTML({
                  range: { startLine: m.line, endLine: m.line, startCol: 0 },
                  includeGlobalBackground: true,
                });
                if (html) setRunningPrompt(ptyId, captureFor, html);
              } catch { /* ignore */ }
              m.dispose();
            }
          }
        }
        live.clear();
        live.reset();
        scheduleLiveSize();
      });
    };

    let detachBuffer: (() => void) | null = null;
    let started = false;
    const start = () => {
      if (started) return;
      if (wrap.clientWidth === 0) return;
      if (wrap.clientHeight === 0) wrap.style.height = "20px";
      try { fit.fit(); } catch { return; }
      const screen = wrap.querySelector(".xterm-rows") as HTMLElement | null;
      const firstRow = screen?.firstElementChild as HTMLElement | null;
      if (firstRow && firstRow.clientHeight > 0) {
        cellHeightRef.current = firstRow.clientHeight;
      }
      started = true;
      const att = attachPrompt(ptyId, {
        data: chunk => { term.write(chunk, () => scheduleLiveSize()); },
        boundary: onBoundary,
      });
      for (const c of att.initial) term.write(c, () => scheduleLiveSize());
      detachBuffer = att.detach;
      scheduleLiveSize();

      // Initial pty.resize so the shell sees the right viewport size from
      // the start — same dims xterm decided on for cols, viewport-derived rows.
      const initialDims = fit.proposeDimensions();
      if (initialDims?.cols) {
        const cols = initialDims.cols;
        onColsChange(cols);
        if (client) {
          const rows = measureViewportRows();
          client.call("pty.resize", { pty_id: ptyId, cols, rows }).catch(() => { /* ignore */ });
        }
      }
    };

    const ro = new ResizeObserver(() => {
      if (!started) {
        start();
      } else {
        scheduleLiveSize();
        // Container resize may also have changed the stack viewport rows
        // even if our cols stayed the same — push the latest size to PTY.
        const t = termRef.current;
        if (t && client) {
          const rows = measureViewportRows();
          client.call("pty.resize", { pty_id: ptyId, cols: t.cols, rows }).catch(() => {});
        }
      }
    });
    ro.observe(wrap);
    if (stackElRef.current) ro.observe(stackElRef.current);
    start();

    const offCursor   = term.onCursorMove(() => scheduleLiveSize());
    const offScroll   = term.onScroll(() => scheduleLiveSize());
    const offLineFeed = term.onLineFeed(() => scheduleLiveSize());

    const offData = term.onData(data => {
      const u8 = new TextEncoder().encode(data);
      let bin = "";
      for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
      const b64 = btoa(bin);
      client?.call("pty.write", { pty_id: ptyId, data_b64: b64 }).catch(() => { /* ignore */ });
    });

    // term.onResize fires when our own resize() runs or fit() picked new
    // cols. Use it as the "cols changed" signal — rows comes from the
    // viewport, not from FloatTerm's visual rows.
    const offResize = term.onResize(({ cols }) => {
      const rows = measureViewportRows();
      client?.call("pty.resize", { pty_id: ptyId, cols, rows }).catch(() => { /* ignore */ });
      onColsChange(cols);
    });

    return () => {
      if (rafSizeRef.current != null) cancelAnimationFrame(rafSizeRef.current);
      rafSizeRef.current = null;
      ro.disconnect();
      offCursor.dispose();
      offScroll.dispose();
      offLineFeed.dispose();
      offData.dispose();
      offResize.dispose();
      detachBuffer?.();
      term.dispose();
      termRef.current      = null;
      fitRef.current       = null;
      serializeRef.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ptyId]);

  // Refocus on becoming active.
  useEffect(() => {
    if (!active) return;
    const id = requestAnimationFrame(() => termRef.current?.focus());
    return () => cancelAnimationFrame(id);
  }, [active]);

  return <div className="pty-float-host" ref={wrapRef} />;
}
