// Bottom-pinned input pane for a PTY tab. Renders only the prompt zone:
// PS1, the user's typed command, and any PS2 continuation lines.
//
// Routing & lifecycle (driven by ptyBuffers.attachPrompt):
//   - prompt + command-zone bytes flow in via the `data` callback and
//     are written straight to xterm.
//   - PromptStarted edges fire the `boundary` callback synchronously,
//     which `term.clear() + term.reset()`s the grid so the next PS1
//     paints fresh.
//   - output-zone bytes never reach this terminal; they're filtered by
//     ptyBuffers and routed to the running BlockTerm instead.
//   - prompt_html capture is BlockTerm's job (it sees the same prompt
//     bytes via attachBlock.promptInitial and serializes them itself);
//     FloatTerm is a pure renderer.
//
// Sizing dimensions:
//   - **Visual height** of this pane: cursorY+1 rows, capped at FLOAT_MAX_ROWS
//     so a long PS2 paste doesn't eat the tab. With phase-driven reset the
//     buffer is never polluted with stale rows, so cursorY alone is enough —
//     no need to add viewportY.
//   - **PTY protocol rows**: the stack viewport minus the running block's
//     sticky header (when present). The shell needs this so alt-screen
//     apps in BlockTerm get a real-sized canvas; FloatTerm is the only
//     component that always exists, so it owns the resize call.

import { useEffect, useRef } from "react";
import { Terminal } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import "@xterm/xterm/css/xterm.css";

import { useApp } from "../store/store";
import { attachPrompt } from "../store/ptyBuffers";

const FLOAT_MIN_ROWS = 1;
const FLOAT_MAX_ROWS = 12;

interface Props {
  ptyId:           string;
  active:          boolean;
  /** True while a BlockTerm exists for this PTY (i.e. a command is
   *  executing). When set, FloatTerm yields focus so BlockTerm owns
   *  input, and CSS collapses our height to 0. We take focus back when
   *  it flips false. */
  running:         boolean;
  /** PtyTab-owned ref to the .pty-stack element. We read its
   *  `clientHeight` to compute the PTY protocol rows so alt-screen apps
   *  in BlockTerm get a real canvas size. */
  stackElRef:      React.MutableRefObject<HTMLDivElement | null>;
  /** Whenever fit() picks a new cols, we publish it so the running
   *  BlockTerm can mirror — they must agree on width or the stack
   *  will look misaligned. */
  onColsChange:    (cols: number) => void;
}

export default function FloatTerm({ ptyId, active, running, stackElRef, onColsChange }: Props) {
  const client        = useApp(s => s.client);

  const wrapRef       = useRef<HTMLDivElement | null>(null);
  const termRef       = useRef<Terminal | null>(null);
  const fitRef        = useRef<FitAddon | null>(null);
  const disposedRef   = useRef<boolean>(false);
  const cellHeightRef = useRef<number>(16);
  const rafSizeRef    = useRef<number | null>(null);

  // ─────────────────────── mount ───────────────────────
  useEffect(() => {
    if (!wrapRef.current) return;
    disposedRef.current = false;
    const wrap = wrapRef.current;
    const term = new Terminal({
      fontFamily: "ui-monospace, Menlo, Consolas, monospace",
      fontSize:   13,
      cursorBlink: true,
      scrollback: 200,
      theme: { background: "#0e0e0e", foreground: "#e6e6e6" },
      allowProposedApi: true,
    });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.loadAddon(new WebLinksAddon());
    term.open(wrap);
    termRef.current = term;
    fitRef.current  = fit;

    // Compute PTY protocol rows from the stack viewport minus the running
    // block's sticky header height (when present) — alt-screen apps in
    // BlockTerm need the full *renderable* viewport, not the raw stack
    // height. With multi-line PS1 the header can occupy 2-3 rows; without
    // this subtraction the shell would think it has more rows than
    // BlockTerm actually paints, and bottom rows would be clipped.
    // alt-active flips the header to display:none, so offsetHeight is 0
    // and vim/htop get the full stack — same behavior as before.
    const measureViewportRows = (): number => {
      const cellH = cellHeightRef.current || 16;
      const stackEl = stackElRef.current;
      const stackPx = stackEl?.clientHeight ?? 480;
      const headerEl = stackEl?.querySelector(".block-running-header") as HTMLElement | null;
      const headerPx = headerEl?.offsetHeight ?? 0;
      return Math.max(8, Math.floor((stackPx - headerPx) / cellH));
    };

    const updateLiveSize = () => {
      rafSizeRef.current = null;
      if (disposedRef.current) return;
      const t = termRef.current;
      if (!t) return;
      const dims = fit.proposeDimensions();
      if (!dims || !dims.cols) return;
      // Keep the xterm grid pinned at FLOAT_MAX_ROWS so multi-line PS1
      // (e.g. starship two-line prompts) has room to render without
      // scrolling content off the top — shrinking the grid to cursorY+1
      // rows would force \r\n in the PS1 stream to scroll the upper rows
      // out before they're ever displayed. The visible height of the
      // pane is the wrap's inline `height`; `.pty-float-host` has
      // `overflow: hidden`, so unused trailing rows of the grid are
      // simply clipped.
      const buf = t.buffer.active;
      const wantRows = Math.max(FLOAT_MIN_ROWS, Math.min(FLOAT_MAX_ROWS, buf.cursorY + 1));

      if (t.cols !== dims.cols || t.rows !== FLOAT_MAX_ROWS) {
        try { t.resize(dims.cols, FLOAT_MAX_ROWS); } catch { /* ignore */ }
      }
      const cellH = cellHeightRef.current;
      wrap.style.height = `${wantRows * cellH}px`;
    };
    const scheduleLiveSize = () => {
      if (rafSizeRef.current != null) return;
      rafSizeRef.current = requestAnimationFrame(updateLiveSize);
    };

    // PromptStarted boundary: clear+reset the grid so the next PS1 paints
    // fresh. Runs synchronously from the ws dispatcher.
    const onBoundary = () => {
      const t = termRef.current;
      if (disposedRef.current) return;
      if (!t) return;
      t.write("", () => {
        const live = termRef.current;
        if (!live) return;
        live.clear();
        live.reset();
        scheduleLiveSize();
      });
    };

    let detachBuffer: (() => void) | null = null;
    let started = false;
    const start = () => {
      if (started) return;
      if (disposedRef.current) return;
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
        data:     chunk => {
          if (disposedRef.current) return;
          term.write(chunk, () => {
            if (!disposedRef.current) scheduleLiveSize();
          });
        },
        boundary: onBoundary,
      });
      for (const c of att.initial) {
        term.write(c, () => {
          if (!disposedRef.current) scheduleLiveSize();
        });
      }
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
      if (disposedRef.current) return;
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
      disposedRef.current = true;
      if (rafSizeRef.current != null) cancelAnimationFrame(rafSizeRef.current);
      rafSizeRef.current = null;
      ro.disconnect();
      offCursor.dispose();
      offScroll.dispose();
      offLineFeed.dispose();
      offData.dispose();
      offResize.dispose();
      detachBuffer?.();
      termRef.current = null;
      fitRef.current  = null;
      requestAnimationFrame(() => {
        try { term.dispose(); } catch { /* ignore */ }
      });
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ptyId]);

  // Refocus on becoming active or when a running command finishes.
  // While `running`, BlockTerm holds focus and we are visually
  // collapsed (height 0).
  useEffect(() => {
    if (!active) return;
    if (running) return;
    const id = requestAnimationFrame(() => termRef.current?.focus());
    return () => cancelAnimationFrame(id);
  }, [active, running]);

  return <div className="pty-float-host" ref={wrapRef} />;
}
