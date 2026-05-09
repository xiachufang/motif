// Per-PTY byte fanout, scope-driven. The server tags every `pty.output`
// event with `(block_id, scope)` (see docs/rpc.md §6). Routing rules:
//
//   scope=prompt | scope=command
//     → FloatTerm prompt listener (live render of input pane).
//     → If block_id is non-null (PTY is bootstrapped), ALSO stashed under
//       preMountByBlock[blockId].prompt so the matching BlockTerm can
//       replay them on mount and serialize the prompt_html itself.
//   scope=output
//     → BlockTerm listener for that block_id (live), or queued under
//       preMountByBlock[blockId].output if BlockTerm hasn't mounted yet.
//
// Two storage shapes:
//
//   promptChunks[ptyId] — prompt-zone bytes since the last `prompt_started`,
//     replayed to a (re)mounting FloatTerm. Cleared at every prompt
//     boundary so long sessions don't accumulate.
//
//   preMountByBlock[ptyId][blockId] — { prompt, output } byte queues for
//     bytes that arrived before BlockTerm mounted. Drained and deleted on
//     `attachBlock`. Once a BlockTerm listener is attached, future output
//     bytes flow straight through; prompt|command bytes for that block_id
//     don't continue to arrive in steady state (they fully drain before
//     `pty.command_started` fires the BlockTerm mount).
//
// State is module-global on purpose: it survives PtyTab unmount/remount
// (StrictMode double-mount, tab switches).

import type { BlockId, OutputScope } from "../proto/types";

type DataListener = (chunk: Uint8Array) => void;

export interface PromptListener {
  data:     DataListener;
  /** Fired synchronously on every `pty.prompt_started`. FloatTerm uses this
   *  to `term.clear() + term.reset()` so the next PS1 paints on a fresh
   *  grid. */
  boundary: () => void;
}

interface PreMount {
  prompt: Uint8Array[];
  output: Uint8Array[];
}

interface PtyBuf {
  promptChunks:    Uint8Array[];
  preMountByBlock: Map<BlockId, PreMount>;
}

const buffers         = new Map<string, PtyBuf>();
const promptListeners = new Map<string, Set<PromptListener>>();
const blockListeners  = new Map<string, Map<BlockId, Set<DataListener>>>();

function getBuf(ptyId: string): PtyBuf {
  let b = buffers.get(ptyId);
  if (!b) {
    b = { promptChunks: [], preMountByBlock: new Map() };
    buffers.set(ptyId, b);
  }
  return b;
}

function getPreMount(b: PtyBuf, blockId: BlockId): PreMount {
  let pm = b.preMountByBlock.get(blockId);
  if (!pm) { pm = { prompt: [], output: [] }; b.preMountByBlock.set(blockId, pm); }
  return pm;
}

/** Workspace dispatcher → for every `pty.output` event from the server. */
export function appendOutput(
  ptyId:   string,
  chunk:   Uint8Array,
  blockId: BlockId | null,
  scope:   OutputScope,
): void {
  const b = getBuf(ptyId);

  if (scope === 'output') {
    // Output bytes always carry a block_id by protocol invariant.
    if (blockId === null) return;
    const ls = blockListeners.get(ptyId)?.get(blockId);
    if (ls && ls.size > 0) {
      ls.forEach(l => { try { l(chunk); } catch { /* ignore */ } });
      return;
    }
    // No BlockTerm attached yet — queue until it mounts.
    getPreMount(b, blockId).output.push(chunk);
    return;
  }

  // scope=passthrough|prompt|command — all flow through FloatTerm.
  // (passthrough = pre-bootstrap banners or between-block housekeeping;
  //  prompt|command = inside a real block lifecycle.)
  b.promptChunks.push(chunk);
  const pls = promptListeners.get(ptyId);
  if (pls) pls.forEach(l => { try { l.data(chunk); } catch { /* ignore */ } });

  // Stash for the BlockTerm that will mount on `pty.command_started`.
  // - passthrough never has a block_id (pre-bootstrap / between blocks),
  //   so nothing to stash.
  // - prompt|command from un-bootstrapped PTYs would also have block_id
  //   = null and similarly skip.
  // - prompt|command with a block_id is the inside-of-cycle case; stash
  //   for the upcoming BlockTerm mount.
  if (scope !== 'passthrough' && blockId !== null) {
    getPreMount(b, blockId).prompt.push(chunk);
  }
}

/** Workspace → on `pty.prompt_started`. Fires every prompt listener's
 *  `boundary` callback synchronously, then drops the previous cycle's
 *  prompt-zone bytes (FloatTerm's `promptChunks` and the named block's
 *  pre-mount prompt slot — for same-cycle 133;A redraws the previous
 *  wave is unreachable past this boundary). */
export function markPromptStarted(ptyId: string, blockId: BlockId): void {
  const b = getBuf(ptyId);
  b.promptChunks = [];
  const pm = b.preMountByBlock.get(blockId);
  if (pm) pm.prompt = [];
  const ls = promptListeners.get(ptyId);
  if (ls) ls.forEach(l => { try { l.boundary(); } catch { /* ignore */ } });
}

export interface PromptAttachment {
  /// Prompt-zone bytes since the last `prompt_started`. The float xterm
  /// should write these to reach steady state.
  initial: Uint8Array[];
  detach:  () => void;
}

export interface BlockAttachment {
  /// Prompt-zone bytes (PS1 + cmd) for this block, in arrival order.
  /// BlockTerm should write these first, serialize prompt_html, then
  /// `term.clear()` before processing outputInitial.
  promptInitial: Uint8Array[];
  /// Output-zone bytes that arrived for this block_id before mount.
  outputInitial: Uint8Array[];
  detach:        () => void;
}

/** FloatTerm calls this on mount: returns prompt-zone bytes since the last
 *  `prompt_started`, AND starts delivering future ones to `listener.data`.
 *  Boundary edges fire `listener.boundary`. */
export function attachPrompt(ptyId: string, listener: PromptListener): PromptAttachment {
  const b = getBuf(ptyId);
  const initial = b.promptChunks.slice();
  let ls = promptListeners.get(ptyId);
  if (!ls) { ls = new Set(); promptListeners.set(ptyId, ls); }
  ls.add(listener);
  return {
    initial,
    detach: () => { ls!.delete(listener); }
  };
}

/** BlockTerm calls this on mount: drains any prompt+output bytes that
 *  queued up before mount, AND starts delivering future output bytes to
 *  `listener`. Once a listener is attached, output bytes flow straight
 *  through and are no longer stored. */
export function attachBlock(ptyId: string, blockId: BlockId, listener: DataListener): BlockAttachment {
  const b = getBuf(ptyId);
  const pm = b.preMountByBlock.get(blockId);
  const promptInitial = pm ? pm.prompt.slice() : [];
  const outputInitial = pm ? pm.output.slice() : [];
  b.preMountByBlock.delete(blockId);

  let byBlock = blockListeners.get(ptyId);
  if (!byBlock) { byBlock = new Map(); blockListeners.set(ptyId, byBlock); }
  let ls = byBlock.get(blockId);
  if (!ls) { ls = new Set(); byBlock.set(blockId, ls); }
  ls.add(listener);
  return {
    promptInitial,
    outputInitial,
    detach: () => {
      ls!.delete(listener);
      if (ls!.size === 0) byBlock!.delete(blockId);
    }
  };
}

/** Drop a PTY's buffer + listeners (call on `pty.exited` / session detach). */
export function clearPty(ptyId: string): void {
  buffers.delete(ptyId);
  promptListeners.delete(ptyId);
  blockListeners.delete(ptyId);
}

/** Drop everything (call on session detach / logout). */
export function clearAll(): void {
  buffers.clear();
  promptListeners.clear();
  blockListeners.clear();
}
