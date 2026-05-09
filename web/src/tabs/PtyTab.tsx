// Layout shell for a PTY tab. Two slots host the SAME xterm instance:
//   .pty-stack — finalized BlockCard / AltStub history + (when a command is
//                running) a `.pty-live-slot` containing a sticky header and
//                the xterm host element.
//   .pty-float — when idle, hosts the same xterm element. Bottom-pinned.
//
// usePtyTerminal owns the Terminal, addons, and event listeners. PtyTab
// only re-parents `hostEl` between the two slots and triggers the
// running/idle mode transitions on store edges.

import { useCallback, useEffect, useLayoutEffect, useRef } from "react";

import { useApp, type BlockRender } from "../store/store";
import {
  bytesEnteredAltScreen, serializeBytesToHtml,
} from "./serializeBlock";
import { AltStub, BlockCard, BlockIdChip, PromptLine } from "./blockCards";
import { usePtyTerminal } from "./usePtyTerminal";
import type { BlockId, BlockSummary, GetBlockOutputResult } from "../proto/types";

interface Props { ptyId: string; active: boolean }

interface ListBlocksResult { blocks: BlockSummary[] }

function decodeB64(b64: string): Uint8Array {
  const bin = atob(b64);
  const u8 = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  return u8;
}

function concat(...parts: Uint8Array[]): Uint8Array {
  let len = 0;
  for (const p of parts) len += p.length;
  const out = new Uint8Array(len);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

export default function PtyTab({ ptyId, active }: Props) {
  const client            = useApp(s => s.client);
  const ptyInfo           = useApp(s => s.ptyInfos.get(ptyId));
  const blocks            = useApp(s => s.ptyBlocks.get(ptyId)?.blocks ?? EMPTY_BLOCKS);
  const backfilledInStore = useApp(s => s.ptyBlocks.get(ptyId)?.backfilled ?? false);
  const pendingFinalize   = useApp(s => s.ptyBlocks.get(ptyId)?.pendingFinalize ?? null);
  const selectedBlock     = useApp(s => s.selectedBlock);
  const setBackfilled     = useApp(s => s.setBackfilledBlocks);
  const setSelectedBlock  = useApp(s => s.setSelectedBlock);

  const stackRef          = useRef<HTMLDivElement | null>(null);
  const liveHeaderRef     = useRef<HTMLElement | null>(null);
  const liveHostRef       = useRef<HTMLDivElement | null>(null);
  const floatHostRef      = useRef<HTMLDivElement | null>(null);
  const wasAtBottomRef    = useRef<boolean>(true);

  const term = usePtyTerminal(ptyId);

  // Trailing entry, if running, is hoisted into the live slot.
  const trailing = blocks.length > 0 ? blocks[blocks.length - 1] : null;
  const runningBlock = trailing?.kind === "running" ? trailing : null;
  const finalizedBlocks = runningBlock ? blocks.slice(0, -1) : blocks;
  const running = !!runningBlock;
  const altActive = term.altActive;

  // ─────────────────────── slot re-parenting + mode transitions ───────────────────────
  const prevRunningIdRef = useRef<BlockId | null>(null);
  useLayoutEffect(() => {
    const newId   = runningBlock?.id ?? null;
    const prevId  = prevRunningIdRef.current;
    prevRunningIdRef.current = newId;

    // Always keep the hook's DOM measurement refs in sync.
    term.setStackEl(stackRef.current);
    term.setHeaderEl(liveHeaderRef.current);

    if (newId && newId !== prevId) {
      // Entering running mode for `newId`. Snapshot the rendered prompt
      // BEFORE clearing or re-parenting; the slot move happens in the
      // beginRunning callback so the snapshot sees the prompt content
      // intact.
      term.beginRunning(newId, () => {
        term.attachToSlot(liveHostRef.current);
        term.setMode("running");
        const stack = stackRef.current;
        if (stack) { stack.scrollTop = stack.scrollHeight; wasAtBottomRef.current = true; }
      });
    } else if (!newId && prevId) {
      // Leaving running mode. endRunning has already done the
      // serialize+clear; now re-parent back to the float slot.
      term.attachToSlot(floatHostRef.current);
      term.setMode("idle");
    } else {
      // Same state (initial mount, or re-render with stable runningBlock).
      const slot = newId ? liveHostRef.current : floatHostRef.current;
      term.attachToSlot(slot);
      term.setMode(newId ? "running" : "idle");
    }
  }, [runningBlock?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  // ─────────────────────── command_finished → endRunning ───────────────────────
  useEffect(() => {
    if (!pendingFinalize) return;
    if (!runningBlock || runningBlock.id !== pendingFinalize.id) return;
    term.endRunning(pendingFinalize.id, pendingFinalize.exit_code, pendingFinalize.finished_at);
  }, [pendingFinalize, runningBlock?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  // ─────────────────────── focus management ───────────────────────
  useEffect(() => {
    if (!active) return;
    const id = requestAnimationFrame(() => term.focus());
    return () => cancelAnimationFrame(id);
  }, [active, running]); // eslint-disable-line react-hooks/exhaustive-deps

  // ─────────────────────── selected-block scroll ───────────────────────
  useEffect(() => {
    if (!selectedBlock || selectedBlock.ptyId !== ptyId) return;
    const stack = stackRef.current;
    if (!stack) return;
    const el = stack.querySelector(`[data-block-id="${cssEscape(selectedBlock.blockId)}"]`);
    if (el && "scrollIntoView" in el) {
      (el as HTMLElement).scrollIntoView({ block: "nearest", behavior: "smooth" });
    }
  }, [selectedBlock, ptyId]);

  // ─────────────────────── backfill ───────────────────────
  // On first mount per PTY (across the whole session — not per component),
  // pull the last 50 finished blocks and pre-render their HTML. The flag
  // lives in the store so tab-switch / StrictMode remount doesn't redo the
  // 50-RPC fetch, and so it survives transparent WS reconnect (the server
  // replays missed events to keep blocks current).
  useEffect(() => {
    if (!client) return;
    if (backfilledInStore) return;
    let cancelled = false;
    (async () => {
      try {
        const r = await client.call<ListBlocksResult>("pty.list_blocks", {
          pty_id: ptyId, limit: 50,
        });
        if (cancelled) return;
        const cols = term.getCols() || ptyInfo?.cols || 80;
        // Server returns newest-first; flip so we render oldest-at-top.
        const summaries = [...r.blocks].reverse();
        const rendered = await Promise.all(summaries.map(async (s): Promise<BlockRender | null> => {
          try {
            const out = await client.call<GetBlockOutputResult>("pty.get_block_output", {
              pty_id: ptyId, block_id: s.id,
            });
            const promptBytes  = decodeB64(out.prompt_b64);
            const commandBytes = decodeB64(out.command_b64);
            const outputBytes  = decodeB64(out.output_b64);
            if (bytesEnteredAltScreen(outputBytes)) {
              const promptHtml = await serializeBytesToHtml(
                concat(promptBytes, commandBytes), { cols });
              return {
                kind:        "alt",
                id:          s.id,
                cmd:         s.cmd,
                cwd:         s.cwd,
                exit_code:   s.exit_code ?? null,
                started_at:  s.started_at,
                finished_at: s.finished_at ?? s.started_at,
                prompt_html: promptHtml,
              };
            }
            const [promptHtml, bodyHtml] = await Promise.all([
              serializeBytesToHtml(concat(promptBytes, commandBytes), { cols }),
              serializeBytesToHtml(outputBytes, { cols }),
            ]);
            return {
              kind:        "card",
              id:          s.id,
              cmd:         s.cmd,
              cwd:         s.cwd,
              exit_code:   s.exit_code ?? null,
              started_at:  s.started_at,
              finished_at: s.finished_at ?? s.started_at,
              html_body:   bodyHtml,
              prompt_html: promptHtml,
            };
          } catch {
            return null;
          }
        }));
        if (cancelled) return;
        const cards = rendered.filter((b): b is BlockRender => b !== null);
        setBackfilled(ptyId, cards);
      } catch {
        if (!cancelled) setBackfilled(ptyId, []);
      }
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [client, ptyId, backfilledInStore, setBackfilled]);

  // ─────────────────────── auto-scroll ───────────────────────
  useEffect(() => {
    const stack = stackRef.current;
    if (!stack) return;
    const onScroll = () => {
      const dist = stack.scrollHeight - stack.scrollTop - stack.clientHeight;
      wasAtBottomRef.current = dist < 64;
    };
    onScroll();
    stack.addEventListener("scroll", onScroll, { passive: true });
    return () => stack.removeEventListener("scroll", onScroll);
  }, []);

  // alt-screen exit reveals previously-hidden cards; force scroll-to-bottom
  // sync because the layout jump fires no scroll event.
  const prevAltRef = useRef<boolean>(false);
  useLayoutEffect(() => {
    const stack = stackRef.current;
    if (!stack) return;
    const wasAlt   = prevAltRef.current;
    const isAlt    = altActive;
    prevAltRef.current = isAlt;
    if (wasAlt && !isAlt) {
      stack.scrollTop = stack.scrollHeight;
      wasAtBottomRef.current = true;
      return;
    }
    if (!wasAtBottomRef.current) return;
    stack.scrollTop = stack.scrollHeight;
  }, [blocks, altActive]);

  // ─────────────────────── render ───────────────────────
  const onBlockSelect = useCallback((id: BlockId) => {
    const cur = useApp.getState().selectedBlock;
    if (cur && cur.ptyId === ptyId && cur.blockId === id) {
      setSelectedBlock(null, null);
    } else {
      setSelectedBlock(ptyId, id);
    }
  }, [ptyId, setSelectedBlock]);

  return (
    <div className={`pty-tab${running ? " running" : ""}${altActive ? " alt-active" : ""}`}>
      <div className="pty-meta muted small">
        {ptyInfo ? `${ptyInfo.cmd} · ${ptyInfo.cols}×${ptyInfo.rows}` : "(loading…)"}
      </div>
      <div className="pty-stack" ref={stackRef}>
        {finalizedBlocks.map(b => {
          const sel =
            !!selectedBlock
            && selectedBlock.ptyId === ptyId
            && selectedBlock.blockId === b.id;
          if (b.kind === "card") {
            return (
              <BlockCard key={b.id} block={b} selected={sel} onSelect={() => onBlockSelect(b.id)} />
            );
          }
          if (b.kind === "alt") {
            return (
              <AltStub key={b.id} block={b} selected={sel} onSelect={() => onBlockSelect(b.id)} />
            );
          }
          return null;
        })}
        {runningBlock && (
          <article
            className={`block-running ${altActive ? "alt" : ""}`}
            data-block-id={runningBlock.id}
          >
            <header
              className="block-running-header"
              ref={liveHeaderRef}
              title={`running since ${new Date(runningBlock.started_at).toLocaleTimeString()}`}
            >
              <PromptLine html={runningBlock.prompt_html} cmd={runningBlock.cmd} />
              <BlockIdChip id={runningBlock.id} />
            </header>
            <div className="block-running-body">
              <div className="pty-live-slot" ref={liveHostRef} />
            </div>
          </article>
        )}
      </div>
      <div className="pty-float">
        <div className="pty-float-host" ref={floatHostRef} />
      </div>
    </div>
  );
}

const EMPTY_BLOCKS: BlockRender[] = [];

function cssEscape(s: string): string {
  if (typeof CSS !== "undefined" && typeof CSS.escape === "function") return CSS.escape(s);
  return s.replace(/[^a-zA-Z0-9_-]/g, ch => "\\" + ch);
}
