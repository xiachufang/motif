// Per-running-block xterm. Lives inside `.block-running` in the stack while a
// command is executing; receives only that block's bytes (server tags
// `pty.output.block_id`), so streaming output appears in place without
// competing with FloatTerm's prompt rendering.
//
// On `pty.command_finished` (observed via `pendingFinalize` in the store) we
// drain pending writes, serialize the block's rows to HTML, dispatch
// `finalizeRunningBlock`, and let PtyTab unmount us by no longer rendering
// this BlockTerm (the trailing store entry has flipped from `running` →
// `card`/`alt`).
//
// Sizing:
//   - normal: rows = (cursorY + 1), capped at the stack viewport
//   - alt-screen (vim/htop/less): full viewport
//
// `cols` is mirrored from FloatTerm via the parent. We do NOT call pty.resize
// from here — FloatTerm owns the protocol resize so there's one writer.
//
// Input: while a command is running (this component is mounted) we hold
// keyboard focus. Keystrokes route through onData → pty.write so they reach
// the running program (vim, htop, or just the shell's stdin). FloatTerm is
// collapsed to height 0 by CSS during this window and refocuses itself when
// we unmount.

import { useEffect, useRef, useState } from "react";
import { Terminal, type IMarker } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { SerializeAddon } from "@xterm/addon-serialize";

import { useApp, type BlockRender } from "../store/store";
import { attachBlock } from "../store/ptyBuffers";
import { PromptLine, BlockIdChip } from "./blockCards";
import { serializeBytesToHtml } from "./serializeBlock";

function concat(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

interface Props {
  ptyId:       string;
  /** Whether this block's PTY tab is currently visible. When the user flips
   *  back to a tab whose command is still running we re-grab focus so typed
   *  keystrokes land on the running program. */
  active:      boolean;
  block:       Extract<BlockRender, { kind: "running" }>;
  cols:        number;
  /** Read .clientHeight at any time to compute max rows. */
  stackElRef:  React.MutableRefObject<HTMLDivElement | null>;
  /** Notify parent when the terminal flips into / out of alt-screen mode so
   *  the surrounding layout can collapse chrome (PtyTab uses this to
   *  fullscreen vim/htop). */
  onAltChange?: (alt: boolean) => void;
}

export default function BlockTerm({ ptyId, active, block, cols, stackElRef, onAltChange }: Props) {
  const pendingFinalize    = useApp(s => s.ptyBlocks.get(ptyId)?.pendingFinalize ?? null);
  const finalize           = useApp(s => s.finalizeRunningBlock);
  const setRunningPromptHtml = useApp(s => s.setRunningPromptHtml);

  const wrapRef         = useRef<HTMLDivElement | null>(null);
  const headerRef       = useRef<HTMLElement | null>(null);
  const termRef         = useRef<Terminal | null>(null);
  const fitRef          = useRef<FitAddon | null>(null);
  const serializeRef    = useRef<SerializeAddon | null>(null);
  const startMarkerRef  = useRef<IMarker | null>(null);
  const disposedRef     = useRef<boolean>(false);
  const scheduleSizeRef = useRef<(() => void) | null>(null);
  const colsRef         = useRef<number>(cols);
  // Saved at mount-time `attachBlock` so the finalize path can fall back
  // to a headless serialize if the live xterm never managed to capture
  // prompt_html (e.g. layout was 0×0 when the trailing block paint
  // finished, or command finished before start() got a non-zero
  // clientWidth). Without this fallback the card renders the `$ cmd`
  // stub from blockCards.tsx for short-running commands.
  const promptBytesRef  = useRef<Uint8Array[]>([]);
  // Sticky: did we ever enter alt-screen during this block? Decides
  // `card` vs `alt` payload at finalize.
  const altSeenRef      = useRef<boolean>(false);
  const cellHeightRef   = useRef<number>(16);
  const rafSizeRef      = useRef<number | null>(null);
  const rafFinalizeRef  = useRef<number | null>(null);

  const [altActive, setAltActive] = useState(false);
  colsRef.current = cols;

  // ─────────────────────── mount ───────────────────────
  useEffect(() => {
    if (!wrapRef.current) return;
    disposedRef.current = false;
    const wrap = wrapRef.current;
    const term = new Terminal({
      fontFamily: "ui-monospace, Menlo, Consolas, monospace",
      fontSize:   13,
      cursorBlink: true,
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

    // startMarkerRef is registered later in start(), AFTER the boot phase
    // has serialized the prompt+cmd rows and reset the buffer — `reset()`
    // would invalidate any marker registered now anyway.

    const offBuf = term.buffer.onBufferChange(() => {
      if (disposedRef.current) return;
      const isAlt = term.buffer.active.type === "alternate";
      if (isAlt) altSeenRef.current = true;
      setAltActive(isAlt);
      onAltChange?.(isAlt);
      // Take focus when entering alt mode so vim/htop sees a focused
      // (solid) cursor and our onData handler routes keystrokes.
      if (isAlt) {
        requestAnimationFrame(() => termRef.current?.focus());
      }
      scheduleLiveSize();
    });

    const updateLiveSize = () => {
      rafSizeRef.current = null;
      if (disposedRef.current) return;
      const t = termRef.current;
      if (!t) return;
      const cellH = cellHeightRef.current;
      const stack = stackElRef.current;
      const stackH = stack?.clientHeight ?? 480;
      const headerH = headerRef.current?.offsetHeight ?? 0;
      const maxRows = Math.max(8, Math.floor((stackH - headerH) / cellH));

      const isAlt = t.buffer.active.type === "alternate";
      let rows: number;
      if (isAlt) {
        rows = maxRows;
      } else {
        const buf = t.buffer.active;
        const lastUsedAbs = buf.viewportY + buf.cursorY;
        rows = Math.max(1, Math.min(maxRows, lastUsedAbs + 1));
      }

      // Mirror `cols` prop; if it changed, propagate to xterm.
      const liveCols = colsRef.current;
      if (t.cols !== liveCols || t.rows !== rows) {
        try { t.resize(liveCols, rows); } catch { /* ignore */ }
      }
      wrap.style.height = `${rows * cellH}px`;
    };
    const scheduleLiveSize = () => {
      if (rafSizeRef.current != null) return;
      rafSizeRef.current = requestAnimationFrame(updateLiveSize);
    };
    scheduleSizeRef.current = scheduleLiveSize;

    // Sequential write helper: respects xterm's parser drain order so the
    // buffer state is fully settled before the callback fires.
    const writeAll = (parts: Uint8Array[], cb: () => void) => {
      if (disposedRef.current) return;
      if (parts.length === 0) { cb(); return; }
      let i = 0;
      const next = () => {
        if (disposedRef.current) return;
        if (i >= parts.length) { cb(); return; }
        term.write(parts[i++], () => {
          if (disposedRef.current) return;
          next();
        });
      };
      next();
    };

    let started = false;
    // Live bytes that arrive during the boot phase (rare — prompt|command
    // bytes drain before mount, output starts after) are deferred so they
    // don't interleave with the prompt-serialize/clear/reset dance.
    // Pre-start: bytes arrive after attachBlock but before start()'s
    // dimensions are ready; they're held here too and replayed once
    // start() completes.
    let booting = true;
    const bootQueue: Uint8Array[] = [];

    // Attach immediately on mount — independent of layout. This guarantees
    // promptInitial bytes are captured (and saved to promptBytesRef) for
    // the finalize fallback path even if start() never gets a non-zero
    // clientWidth before the command finishes.
    const att = attachBlock(ptyId, block.id, chunk => {
      if (disposedRef.current) return;
      if (!started || booting) bootQueue.push(chunk);
      else term.write(chunk, () => {
        if (!disposedRef.current) scheduleLiveSize();
      });
    });
    const detachBuffer = att.detach;
    promptBytesRef.current = att.promptInitial;
    const outputInitial = att.outputInitial;

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

      // Boot phase: render PS1 + cmd into a fresh buffer, serialize the
      // rendered rows as prompt_html for the running block's sticky header,
      // then wipe the visible content so output streams onto a clean grid.
      writeAll(att.promptInitial, () => {
        if (disposedRef.current) return;
        const buf = term.buffer.active;
        const endAbs = buf.viewportY + buf.cursorY - 1;
        if (endAbs >= 0) {
          try {
            const html = serialize.serializeAsHTML({
              range: { startLine: 0, endLine: endAbs, startCol: 0 },
              includeGlobalBackground: true,
            });
            if (html) setRunningPromptHtml(ptyId, block.id, html);
          } catch { /* ignore */ }
        }
        term.clear();
        term.reset();
        // After reset(), markers registered earlier (none in our case) are
        // invalid. Anchor the body's start marker now — the finalize range
        // serialization reads from this line.
        startMarkerRef.current = term.registerMarker(0);

        writeAll(outputInitial, () => {
          if (disposedRef.current) return;
          booting = false;
          for (const c of bootQueue) {
            term.write(c, () => {
              if (!disposedRef.current) scheduleLiveSize();
            });
          }
          bootQueue.length = 0;
          scheduleLiveSize();
        });
      });

      scheduleLiveSize();
    };

    const ro = new ResizeObserver(() => {
      if (disposedRef.current) return;
      if (!started) start();
      else scheduleLiveSize();
    });
    ro.observe(wrap);
    if (stackElRef.current) ro.observe(stackElRef.current);
    start();

    const offCursor   = term.onCursorMove(() => scheduleLiveSize());
    const offScroll   = term.onScroll(() => scheduleLiveSize());
    const offLineFeed = term.onLineFeed(() => scheduleLiveSize());

    // Route keystrokes from this xterm straight to pty.write. We pull `client`
    // from the store at fire time so the effect doesn't need to redo on
    // re-connects.
    const offData = term.onData(data => {
      const c = useApp.getState().client;
      if (!c) return;
      const u8 = new TextEncoder().encode(data);
      let bin = "";
      for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
      const b64 = btoa(bin);
      c.call("pty.write", { pty_id: ptyId, data_b64: b64 }).catch(() => { /* ignore */ });
    });

    return () => {
      disposedRef.current = true;
      if (rafSizeRef.current != null) cancelAnimationFrame(rafSizeRef.current);
      rafSizeRef.current = null;
      if (rafFinalizeRef.current != null) cancelAnimationFrame(rafFinalizeRef.current);
      rafFinalizeRef.current = null;
      scheduleSizeRef.current = null;
      ro.disconnect();
      offBuf.dispose();
      offCursor.dispose();
      offScroll.dispose();
      offLineFeed.dispose();
      offData.dispose();
      detachBuffer?.();
      termRef.current      = null;
      fitRef.current       = null;
      serializeRef.current = null;
      startMarkerRef.current = null;
      requestAnimationFrame(() => {
        try { term.dispose(); } catch { /* ignore */ }
      });
    };
    // The cols mirror happens inside scheduleLiveSize, so we don't need to
    // re-mount on cols change.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [ptyId, block.id]);

  useEffect(() => {
    scheduleSizeRef.current?.();
  }, [cols]);

  // Hold focus while we're the visible tab. Re-grab on tab-switch back
  // (a hidden tab is display:none, which drops focus from the textarea).
  useEffect(() => {
    if (!active) return;
    const id = requestAnimationFrame(() => termRef.current?.focus());
    return () => cancelAnimationFrame(id);
  }, [active]);

  // ─────────────────────── command_finished ───────────────────────
  // Drain → serialize → finalize. Once finalize commits to the store the
  // trailing block transitions from `running` → `card`/`alt` and PtyTab
  // stops rendering this BlockTerm (component unmounts).
  useEffect(() => {
    if (!pendingFinalize) return;
    if (pendingFinalize.id !== block.id) return;
    const term = termRef.current;
    const serialize = serializeRef.current;
    if (!term || !serialize) return;

    // Capture references that the async fallback path needs — `block.prompt_html`
    // is read at write-callback time so a setRunningPromptHtml that
    // landed mid-write is observed.
    const livePromptHtmlAtDispatch = block.prompt_html;
    const promptBytes = promptBytesRef.current;
    const colsAtDispatch = colsRef.current;

    term.write("", async () => {
      if (disposedRef.current) return;
      const startMarker = startMarkerRef.current;
      const endMarker   = term.registerMarker(0);
      const altSeen     = altSeenRef.current;

      // If the live xterm never captured prompt_html (start() bailed on
      // a 0-px wrap and the command finished before resize triggered it
      // again), fall back to a headless serialize of the raw
      // prompt+command bytes. This mirrors what PtyTab does for
      // backfilled history, just driven from in-process bytes so we
      // don't need a server round-trip. Skip when we already have html
      // from the live path (its colours match the live xterm exactly).
      let promptHtmlFallback: string | undefined;
      if (!livePromptHtmlAtDispatch
          && useApp.getState().ptyBlocks.get(ptyId)?.blocks.find(b => b.id === block.id)?.prompt_html === ""
          && promptBytes.length > 0) {
        try {
          promptHtmlFallback = await serializeBytesToHtml(
            concat(promptBytes),
            { cols: colsAtDispatch },
          );
        } catch { /* leave undefined — store falls back to "" */ }
        if (disposedRef.current) return;
      }

      let payload: Parameters<typeof finalize>[2];
      if (altSeen) {
        payload = {
          kind:        "alt",
          exit_code:   pendingFinalize.exit_code,
          finished_at: pendingFinalize.finished_at,
          prompt_html_fallback: promptHtmlFallback,
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
          prompt_html_fallback: promptHtmlFallback,
        };
      }

      endMarker?.dispose();
      rafFinalizeRef.current = requestAnimationFrame(() => {
        rafFinalizeRef.current = null;
        if (disposedRef.current) return;
        finalize(ptyId, pendingFinalize.id, payload);
      });
    });
  }, [pendingFinalize, ptyId, block.id, block.prompt_html, finalize]);

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
        <BlockIdChip id={block.id} />
      </header>
      <div className="block-running-body">
        <div className="pty-host" ref={wrapRef} />
      </div>
    </article>
  );
}
