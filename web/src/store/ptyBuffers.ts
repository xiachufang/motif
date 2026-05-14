// Per-PTY byte fanout. PtyTab attaches one listener per mount; this
// module keeps a bounded local history so a newly-created Terminal can
// replay bytes that arrived before mount.
//
// State is module-global so it survives PtyTab unmount/remount (StrictMode
// double-mount, tab switches via display:none don't unmount). Do not drain
// history on attach: React dev StrictMode intentionally mounts effects twice,
// and the first throwaway mount must not consume the PTY replay intended for
// the real mount.

export type PtyDataListener = (chunk: Uint8Array) => void;

const HISTORY_BYTES = 2 * 1024 * 1024;

interface PtyBuf {
  /** Recent bytes in arrival order. Replayed into newly-mounted terminals. */
  history: Uint8Array[];
  totalBytes: number;
}

const buffers   = new Map<string, PtyBuf>();
const listeners = new Map<string, Set<PtyDataListener>>();

function getBuf(ptyId: string): PtyBuf {
  let b = buffers.get(ptyId);
  if (!b) { b = { history: [], totalBytes: 0 }; buffers.set(ptyId, b); }
  return b;
}

function remember(ptyId: string, chunk: Uint8Array): void {
  const b = getBuf(ptyId);
  b.history.push(chunk);
  b.totalBytes += chunk.byteLength;
  while (b.totalBytes > HISTORY_BYTES && b.history.length > 0) {
    const old = b.history.shift()!;
    b.totalBytes -= old.byteLength;
  }
}

/** Workspace dispatcher -> for every `pty.output` event from the server. */
export function appendOutput(ptyId: string, chunk: Uint8Array): void {
  remember(ptyId, chunk);
  const ls = listeners.get(ptyId);
  if (ls && ls.size > 0) {
    ls.forEach(l => { try { l(chunk); } catch { /* ignore */ } });
  }
}

export interface PtyAttachment {
  /** Recent bytes that landed before this listener attached, in arrival order. */
  initial: Uint8Array[];
  detach:  () => void;
}

/** Hook calls this on mount: returns any pre-mount bytes and starts
 *  delivering future ones to `listener`. */
export function attachPty(ptyId: string, listener: PtyDataListener): PtyAttachment {
  const b = getBuf(ptyId);
  const initial = b.history.slice();
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
