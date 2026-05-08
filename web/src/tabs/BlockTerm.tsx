// Per-running-block xterm. Lives inside `.block-running` in the stack
// while a command is executing; receives only that block's bytes
// (server tags `pty.output.block_id`), so streaming output appears in
// place without competing with the FloatTerm's prompt rendering.
//
// On `pty.command_finished` (observed via `pendingFinalize` in the
// store) we drain pending writes, serialize the block's rows to HTML,
// dispatch `finalizeRunningBlock`, drop the buffered bytes, and let
// PtyTab unmount us by no longer rendering this BlockTerm (the trailing
// store entry has flipped from `running` → `card`/`alt`).
//
// Sizing:
//   - normal: rows = (cursorY + 1), capped at the stack viewport
//   - alt-screen (vim/htop/less): full viewport
//
// `cols` is mirrored from FloatTerm via the parent. We do NOT call
// pty.resize from here — FloatTerm owns the protocol resize so there's
// one writer.

import { useEffect, useRef, useState } from "react";
import { Terminal, type IMarker } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { SerializeAddon } from "@xterm/addon-serialize";

import { useApp, type BlockRender } from "../store/store";
import { attachBlock, dropBlockBytes } from "../store/ptyBuffers";
import type { BlockId } from "../proto/types";
import { PromptLine } from "./blockCards";

interface Props {
  ptyId:       string;
  block:       Extract<BlockRender, { kind: "running" }>;
  cols:        number;
  /** Read .clientHeight at any time to compute max rows. */
  stackElRef:  React.MutableRefObject<HTMLDivElement | null>;
  /** Notify parent when the terminal flips into / out of alt-screen
   *  mode so the surrounding layout can collapse chrome (PtyTab uses
   *  this to fullscreen vim/htop). */
  onAltChange?: (alt: boolean) => void;
}

export default function BlockTerm({ ptyId, block, cols, stackElRef, onAltChange }: Props) {
  const pendingFinalize = useApp(s => s.ptyBlocks.get(ptyId)?.pendingFinalize ?? null);
  const finalize        = useApp(s => s.finalizeRunningBlock);

  const wrapRef         = useRef<HTMLDivElement | null>(null);
  const headerRef       = useRef<HTMLElement | null>(null);
  const termRef         = useRef<Terminal | null>(null);
  const fitRef          = useRef<FitAddon | null>(null);
  const serializeRef    = useRef<SerializeAddon | null>(null);
  const startMarkerRef  = useRef<IMarker | null>(null);
  const altSeenRef      = useRef<boolean>(false);
  const altActiveRef    = useRef<boolean>(false);
  const cellHeightRef   = useRef<number>(16);
  const rafSizeRef      = useRef<number | null>(null);
  const finalizingRef   = useRef<boolean>(false);
  const consumedFinalizeRef = useRef<BlockId | null>(null);
  const postFinalizeQueue   = useRef<Uint8Array[]>([]);

  const [altActive, setAltActive] = useState(false);

  // ─────────────────────── mount ───────────────────────
  useEffect(() => {
    if (!wrapRef.current) return;
    const wrap = wrapRef.current;
    const term = new Terminal({
      fontFamily: "ui-monospace, Menlo, Consolas, monospace",
      fontSize:   13,
      cursorBlink: false,
      disableStdin: true,
      scrollback: 5000,
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

    // Anchor a start marker at the top of the buffer for serialization
    // range. line == 0 since we just opened a fresh xterm.
    startMarkerRef.current = term.registerMarker(0);

    const offBuf = term.buffer.onBufferChange(() => {
      const isAlt = term.buffer.active.type === "alternate";
      if (isAlt) altSeenRef.current = true;
      altActiveRef.current = isAlt;
      setAltActive(isAlt);
      onAltChange?.(isAlt);
      scheduleLiveSize();
    });

    const updateLiveSize = () => {
      rafSizeRef.current = null;
      const t = termRef.current;
      if (!t) return;
      const cellH = cellHeightRef.current;
      const stack = stackElRef.current;
      const stackH = stack?.clientHeight ?? 480;
      const headerH = headerRef.current?.offsetHeight ?? 0;
      const maxRows = Math.max(8, Math.floor((stackH - headerH) / cellH));

      let rows: number;
      if (altActiveRef.current) {
        rows = maxRows;
      } else {
        const buf = t.buffer.active;
        const lastUsedAbs = buf.viewportY + buf.cursorY;
        rows = Math.max(1, Math.min(maxRows, lastUsedAbs + 1));
      }

      // Mirror `cols` prop; if it changed, propagate to xterm.
      if (t.cols !== cols || t.rows !== rows) {
        try { t.resize(cols, rows); } catch { /* ignore */ }
      }
      const px = rows * cellH;
      wrap.style.height = `${px}px`;
    };
    const scheduleLiveSize = () => {
      if (rafSizeRef.current != null) return;
      rafSizeRef.current = requestAnimationFrame(updateLiveSize);
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
      // Force initial cols to match prop (fit picks max-fit but we want to
      // match the float's chosen cols).
      try { term.resize(cols, term.rows); } catch { /* ignore */ }
      started = true;
      const att = attachBlock(ptyId, block.id, chunk => {
        if (finalizingRef.current) postFinalizeQueue.current.push(chunk);
        else term.write(chunk, () => scheduleLiveSize());
      });
      for (const c of att.initial) {
        if (finalizingRef.current) postFinalizeQueue.current.push(c);
        else term.write(c, () => scheduleLiveSize());
      }
      detachBuffer = att.detach;
      scheduleLiveSize();
    };

    const ro = new ResizeObserver(() => {
      if (!started) start();
      else scheduleLiveSize();
    });
    ro.observe(wrap);
    if (stackElRef.current) ro.observe(stackElRef.current);
    start();

    const offCursor   = term.onCursorMove(() => scheduleLiveSize());
    const offScroll   = term.onScroll(() => scheduleLiveSize());
    const offLineFeed = term.onLineFeed(() => scheduleLiveSize());

    return () => {
      if (rafSizeRef.current != null) cancelAnimationFrame(rafSizeRef.current);
      rafSizeRef.current = null;
      ro.disconnect();
      offBuf.dispose();
      offCursor.dispose();
      offScroll.dispose();
      offLineFeed.dispose();
      detachBuffer?.();
      term.dispose();
      termRef.current      = null;
      fitRef.current       = null;
      serializeRef.current = null;
      startMarkerRef.current = null;
      // If we go away while in alt mode (block finalize / unmount),
      // clear the parent's alt flag so layout chrome reappears.
      if (altActiveRef.current) onAltChange?.(false);
    };
    // We intentionally don't redo mount on `cols` change — the cols
    // effect below handles in-place resize.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ptyId, block.id]);

  // Mirror cols changes.
  useEffect(() => {
    const t = termRef.current;
    if (!t) return;
    if (t.cols === cols) return;
    try { t.resize(cols, t.rows); } catch { /* ignore */ }
  }, [cols]);

  // ─────────────────────── command_finished ───────────────────────
  // Drain → serialize → finalize → drop bytes. Once finalize commits to
  // the store the trailing block transitions from `running` → `card`/`alt`
  // and PtyTab stops rendering this BlockTerm (component unmounts).
  useEffect(() => {
    if (!pendingFinalize) return;
    if (pendingFinalize.id !== block.id) return;
    if (consumedFinalizeRef.current === pendingFinalize.id) return;
    const term = termRef.current;
    const serialize = serializeRef.current;
    if (!term || !serialize) return;

    consumedFinalizeRef.current = pendingFinalize.id;
    finalizingRef.current = true;

    term.write("", () => {
      const startMarker = startMarkerRef.current;
      const endMarker   = term.registerMarker(0);
      const altSeen     = altSeenRef.current;

      let payload: Parameters<typeof finalize>[2];
      if (altSeen) {
        payload = {
          kind:        "alt",
          exit_code:   pendingFinalize.exit_code,
          finished_at: pendingFinalize.finished_at,
        };
      } else {
        let html = "";
        if (startMarker && startMarker.line >= 0 && endMarker && endMarker.line >= 0
            && endMarker.line >= startMarker.line) {
          try {
            html = serialize.serializeAsHTML({
              range: { startLine: startMarker.line, endLine: endMarker.line, startCol: 0 },
              includeGlobalBackground: true,
            });
          } catch { /* serialization failure → empty body */ }
        }
        payload = {
          kind:        "card",
          html_body:   html,
          exit_code:   pendingFinalize.exit_code,
          finished_at: pendingFinalize.finished_at,
        };
      }

      finalize(ptyId, pendingFinalize.id, payload);
      endMarker?.dispose();
      // Drop this block's buffered bytes — they're now committed in the
      // serialized HTML and won't be re-attached (BlockTerm is about to
      // unmount).
      dropBlockBytes(ptyId, block.id);
      finalizingRef.current = false;
      // Any post-finalize queued chunks belong to the next prompt
      // (block_id null, so they wouldn't actually have landed here) —
      // safety: drop them.
      postFinalizeQueue.current = [];
    });
  }, [pendingFinalize, ptyId, block.id, finalize]);

  return (
    <article
      className={`block-running ${altActive ? "alt" : ""}`}
      data-block-id={block.id}
    >
      <header
        className="block-running-header"
        ref={headerRef}
        title={`running since ${new Date(block.started_at).toLocaleTimeString()}`}
      >
        <PromptLine html={block.prompt_html} cmd={block.cmd} />
      </header>
      <div className="block-running-body">
        <div className="pty-host" ref={wrapRef} />
      </div>
    </article>
  );
}
