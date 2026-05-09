// Layout shell for a PTY tab. Two stacked panes:
//   .pty-stack — finalized BlockCard / AltStub history + the trailing
//                BlockTerm if a command is currently running.
//   .pty-float — always-visible FloatTerm hosting PS1 + user input + PS2.
//
// All xterm work lives in FloatTerm / BlockTerm; PtyTab only does:
//   - block backfill on mount (pty.list_blocks → SerializeAddon → store)
//   - selectedBlock scrollIntoView
//   - auto-pin to bottom on block-list changes
//   - publish FloatTerm's cols to the BlockTerm so they stay aligned
//
// FloatTerm owns pty.resize (cols + viewport-derived rows). BlockTerm
// mirrors cols only.

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";

import { useApp, type BlockRender } from "../store/store";
import {
  bytesEnteredAltScreen, serializeBytesToHtml,
} from "./serializeBlock";
import { AltStub, BlockCard } from "./blockCards";
import FloatTerm from "./FloatTerm";
import BlockTerm from "./BlockTerm";
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
  const selectedBlock     = useApp(s => s.selectedBlock);
  const setBackfilled     = useApp(s => s.setBackfilledBlocks);
  const setSelectedBlock  = useApp(s => s.setSelectedBlock);

  const stackRef          = useRef<HTMLDivElement | null>(null);
  const wasAtBottomRef    = useRef<boolean>(true);
  // Mirror FloatTerm's chosen cols so BlockTerm stays in sync. Seeded
  // from the server-known PtyInfo.cols (matters for re-attach where a
  // running block already exists and BlockTerm mounts before FloatTerm
  // has fit/published a value); FloatTerm overwrites this on first fit.
  const [floatCols, setFloatCols] = useState<number>(ptyInfo?.cols ?? 80);

  // Trailing entry, if running, is hoisted into BlockTerm in the stack.
  const trailing = blocks.length > 0 ? blocks[blocks.length - 1] : null;
  const runningBlock = trailing?.kind === "running" ? trailing : null;
  const finalizedBlocks = runningBlock ? blocks.slice(0, -1) : blocks;

  // Lifted from BlockTerm: when an alt-screen app is running we collapse
  // the surrounding chrome (.pty-meta, finalized blocks, FloatTerm) via a
  // class on .pty-tab so vim/htop get the full tab area.
  const [altActive, setAltActive] = useState(false);
  // Belt-and-braces: if the running block goes away (finalize, unmount)
  // and BlockTerm's own cleanup didn't fire (defensive), force false.
  useEffect(() => {
    if (!runningBlock) setAltActive(false);
  }, [runningBlock]);

  const prevRunningIdRef = useRef<BlockId | null>(null);
  useLayoutEffect(() => {
    const id = runningBlock?.id ?? null;
    if (id && id !== prevRunningIdRef.current) {
      const stack = stackRef.current;
      if (stack) {
        stack.scrollTop = stack.scrollHeight;
        wasAtBottomRef.current = true;
      }
    }
    prevRunningIdRef.current = id;
  }, [runningBlock?.id]);

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
            // Alt-screen detection runs over the output segment — the
            // prompt/command segments can't enter alt mode by definition.
            if (bytesEnteredAltScreen(outputBytes)) {
              const promptHtml = await serializeBytesToHtml(
                concat(promptBytes, commandBytes), { cols: floatCols });
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
            // Header gets prompt+command rendered together (mirrors
            // what the live FloatTerm captures from its xterm); body
            // gets the output segment alone.
            const [promptHtml, bodyHtml] = await Promise.all([
              serializeBytesToHtml(concat(promptBytes, commandBytes), { cols: floatCols }),
              serializeBytesToHtml(outputBytes, { cols: floatCols }),
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
        // Server may not support list_blocks (older build) or the call
        // failed transiently — flip the flag anyway so we don't busy-loop.
        if (!cancelled) setBackfilled(ptyId, []);
      }
    })();
    return () => { cancelled = true; };
    // floatCols intentionally omitted — backfill runs once at mount; later
    // cols changes don't re-render history.
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

  // Exiting alt-screen mode is the trickiest case: we hide block cards via
  // CSS (display:none) while .alt-active is on, which means scrollHeight
  // shrinks without firing a scroll event. When the class drops on
  // alt-exit the cards reappear, scrollHeight jumps, and the browser
  // gives no scroll event either — wasAtBottomRef stays at its pre-alt
  // value but scrollTop is now stuck near the top. We track the alt
  // transition explicitly and force the scroll synchronously at commit
  // time (useLayoutEffect — avoids a paint flash that rAF would cause).
  const prevAltRef = useRef<boolean>(false);
  useLayoutEffect(() => {
    const stack = stackRef.current;
    if (!stack) return;
    const wasAlt   = prevAltRef.current;
    const isAlt    = altActive;
    prevAltRef.current = isAlt;
    // alt → non-alt: previously-hidden cards just reappeared.
    if (wasAlt && !isAlt) {
      stack.scrollTop = stack.scrollHeight;
      wasAtBottomRef.current = true;
      return;
    }
    // Normal block-list change: stick to the bottom if we were already
    // there. Done in the same layout effect so the new content + scroll
    // commit in one frame, no flash.
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

  // While a command is executing the BlockTerm owns the terminal: it
  // focuses itself, and FloatTerm collapses to height 0 (.running class).
  // .alt-active is the stricter subset for full-takeover apps (vim/htop)
  // — it additionally hides meta strip, prior block cards, and the
  // running header.
  const running = !!runningBlock;

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
              <BlockCard
                key={b.id}
                block={b}
                selected={sel}
                onSelect={() => onBlockSelect(b.id)}
              />
            );
          }
          if (b.kind === "alt") {
            return (
              <AltStub
                key={b.id}
                block={b}
                selected={sel}
                onSelect={() => onBlockSelect(b.id)}
              />
            );
          }
          return null;
        })}
        {runningBlock && (
          <BlockTerm
            key={runningBlock.id}
            ptyId={ptyId}
            active={active}
            block={runningBlock}
            cols={floatCols}
            stackElRef={stackRef}
            onAltChange={setAltActive}
          />
        )}
      </div>
      <div className="pty-float">
        <FloatTerm
          ptyId={ptyId}
          active={active}
          running={running}
          stackElRef={stackRef}
          onColsChange={setFloatCols}
        />
      </div>
    </div>
  );
}

const EMPTY_BLOCKS: BlockRender[] = [];

function cssEscape(s: string): string {
  if (typeof CSS !== "undefined" && typeof CSS.escape === "function") return CSS.escape(s);
  return s.replace(/[^a-zA-Z0-9_-]/g, ch => "\\" + ch);
}
