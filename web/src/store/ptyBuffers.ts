// Per-PTY byte fanout. Single listener model: one xterm.js instance per
// PTY (managed by usePtyTerminal) attaches once and consumes all bytes —
// `scope` no longer drives routing. The xterm processes prompt, command,
// and output bytes in arrival order; its own buffer state is the source
// of truth for what's on screen.
//
// `pending` holds bytes that arrived before any listener attached. As soon
// as the xterm attaches, `pending` is drained and future bytes flow live.
// `markPromptStarted` clears `pending` and fires `boundary()` on attached
// listeners — the xterm responds with `term.clear()+reset()` so the next
// PS1 paints on a fresh grid.
//
// State is module-global so it survives PtyTab unmount/remount (StrictMode
// double-mount, tab switches).

import type { BlockId } from "../proto/types";

export interface PromptListener {
  data:     (chunk: Uint8Array) => void;
  /** Fired synchronously on every `pty.prompt_started`. Hook uses this to
   *  `term.clear() + term.reset()` so the next PS1 paints fresh. */
  boundary: () => void;
}

interface PtyBuf {
  /** Bytes accumulated while no listener was attached. Drained on attach
   *  and cleared at every `prompt_started` (the previous wave is
   *  unreachable past the boundary anyway). */
  pending: Uint8Array[];
}

const buffers   = new Map<string, PtyBuf>();
const listeners = new Map<string, Set<PromptListener>>();

function getBuf(ptyId: string): PtyBuf {
  let b = buffers.get(ptyId);
  if (!b) { b = { pending: [] }; buffers.set(ptyId, b); }
  return b;
}

/** Workspace dispatcher → for every `pty.output` event from the server.
 *  `block_id` and `scope` are accepted for protocol compatibility but no
 *  longer drive routing — the single xterm consumes everything. */
export function appendOutput(
  ptyId:   string,
  chunk:   Uint8Array,
  _blockId: BlockId | null,
  _scope:   string,
): void {
  const ls = listeners.get(ptyId);
  if (ls && ls.size > 0) {
    ls.forEach(l => { try { l.data(chunk); } catch { /* ignore */ } });
    return;
  }
  getBuf(ptyId).pending.push(chunk);
}

/** Workspace → on `pty.prompt_started`. Drops any bytes accumulated since
 *  the last boundary (a not-yet-attached listener can't reach them after
 *  the boundary clears the grid) and fires every listener's `boundary`. */
export function markPromptStarted(ptyId: string, _blockId: BlockId): void {
  getBuf(ptyId).pending = [];
  const ls = listeners.get(ptyId);
  if (ls) ls.forEach(l => { try { l.boundary(); } catch { /* ignore */ } });
}

export interface PtyAttachment {
  /** Bytes that landed before this listener attached, in arrival order. */
  initial: Uint8Array[];
  detach:  () => void;
}

/** Hook calls this on first slot attach: returns any pre-mount bytes and
 *  starts delivering future ones to `listener.data`. Boundary edges fire
 *  `listener.boundary`. */
export function attachPty(ptyId: string, listener: PromptListener): PtyAttachment {
  const b = getBuf(ptyId);
  const initial = b.pending.slice();
  b.pending = [];
  let ls = listeners.get(ptyId);
  if (!ls) { ls = new Set(); listeners.set(ptyId, ls); }
  ls.add(listener);
  return {
    initial,
    detach: () => { ls!.delete(listener); }
  };
}

/** Drop a PTY's buffer + listeners (call on `pty.exited` / session detach). */
export function clearPty(ptyId: string): void {
  buffers.delete(ptyId);
  listeners.delete(ptyId);
}

/** Drop everything (call on session detach / logout). */
export function clearAll(): void {
  buffers.clear();
  listeners.clear();
}
