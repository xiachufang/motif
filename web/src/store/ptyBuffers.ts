// Per-PTY byte buffer + listener registry.
//
// Why this exists: `pty.output` events for a freshly-created PTY arrive
// *between* the `pty.created` notification and the moment the React-mounted
// `PtyTab` registers its `client.on` subscription. Without this layer, that
// initial burst (the shell banner + prompt) would be dropped on the floor and
// the new tab would render empty.
//
// Workspace's event handler always pushes incoming `pty.output` here. PtyTab
// on mount calls `attach()` which atomically returns the existing buffer and
// registers a listener for future chunks — so the order is guaranteed and no
// bytes leak between handover.
//
// State is module-global on purpose: it survives PtyTab unmount/remount (e.g.
// when we re-architect tab rendering later) and across React StrictMode's
// double-mount in dev.

type Listener = (chunk: Uint8Array) => void;

const buffers   = new Map<string, Uint8Array[]>();
const listeners = new Map<string, Set<Listener>>();

/** Workspace calls this for every `pty.output` event from the server. */
export function appendOutput(ptyId: string, chunk: Uint8Array): void {
  let buf = buffers.get(ptyId);
  if (!buf) { buf = []; buffers.set(ptyId, buf); }
  buf.push(chunk);
  const ls = listeners.get(ptyId);
  if (ls) ls.forEach(l => { try { l(chunk); } catch { /* ignore listener errors */ } });
}

export interface PtyAttachment {
  /** All chunks accumulated before this attach call. Write these first. */
  initial: Uint8Array[];
  /** Detach the listener. Buffered bytes are kept for future re-attachers. */
  detach: () => void;
}

/** PtyTab calls this on mount: returns the pre-buffered chunks AND starts
 *  delivering future chunks to the listener. The pair is captured atomically
 *  in one synchronous call, so ordering is preserved. */
export function attach(ptyId: string, listener: Listener): PtyAttachment {
  const initial = (buffers.get(ptyId) ?? []).slice();
  let ls = listeners.get(ptyId);
  if (!ls) { ls = new Set(); listeners.set(ptyId, ls); }
  ls.add(listener);
  return {
    initial,
    detach: () => { ls!.delete(listener); }
  };
}

/** Drop a PTY's buffer + listeners (call on pty.exited / session detach). */
export function clearPty(ptyId: string): void {
  buffers.delete(ptyId);
  listeners.delete(ptyId);
}

/** Drop everything (call on session detach / logout). */
export function clearAll(): void {
  buffers.clear();
  listeners.clear();
}
