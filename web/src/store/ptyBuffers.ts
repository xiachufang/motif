// Per-PTY byte fanout. PtyTab attaches one listener per mount; this
// module buffers bytes that land before any listener attaches and flushes
// them on attach.
//
// State is module-global so it survives PtyTab unmount/remount (StrictMode
// double-mount, tab switches via display:none don't unmount, but we still
// keep the buffer in case the listener hasn't run its first effect yet).

export type PtyDataListener = (chunk: Uint8Array) => void;

interface PtyBuf {
  /** Bytes accumulated while no listener was attached. Drained on attach. */
  pending: Uint8Array[];
}

const buffers   = new Map<string, PtyBuf>();
const listeners = new Map<string, Set<PtyDataListener>>();

function getBuf(ptyId: string): PtyBuf {
  let b = buffers.get(ptyId);
  if (!b) { b = { pending: [] }; buffers.set(ptyId, b); }
  return b;
}

/** Workspace dispatcher → for every `pty.output` event from the server. */
export function appendOutput(ptyId: string, chunk: Uint8Array): void {
  const ls = listeners.get(ptyId);
  if (ls && ls.size > 0) {
    ls.forEach(l => { try { l(chunk); } catch { /* ignore */ } });
    return;
  }
  getBuf(ptyId).pending.push(chunk);
}

export interface PtyAttachment {
  /** Bytes that landed before this listener attached, in arrival order. */
  initial: Uint8Array[];
  detach:  () => void;
}

/** Hook calls this on mount: returns any pre-mount bytes and starts
 *  delivering future ones to `listener`. */
export function attachPty(ptyId: string, listener: PtyDataListener): PtyAttachment {
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
