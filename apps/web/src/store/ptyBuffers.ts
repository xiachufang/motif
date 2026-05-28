// Per-PTY byte fanout. PtyTab attaches one listener per mount; RpcClient
// opens exactly one live /pty stream for the active terminal tab and pushes
// bytes here. History lives on motifd now, not in the browser.
//
// State is module-global so it survives PtyTab unmount/remount (StrictMode
// double-mount, tab switches via display:none don't unmount), but it only
// stores listeners. Server catch-up is driven by RpcClient's per-PTY cursor.

export type PtyDataListener = (chunk: Uint8Array) => void;
export type PtyResetListener = () => void;

const listeners = new Map<string, Set<PtyDataListener>>();
const resetListeners = new Map<string, Set<PtyResetListener>>();

/** Workspace dispatcher -> for every `pty.output` event from the server. */
export function appendOutput(ptyId: string, chunk: Uint8Array): void {
  const ls = listeners.get(ptyId);
  if (ls && ls.size > 0) {
    ls.forEach(l => { try { l(chunk); } catch { /* ignore */ } });
  }
}

/** Tell attached terminals to discard their local surface. Used when the
 *  server says the byte cursor is no longer replayable (4011/4012). */
export function resetPty(ptyId: string): void {
  const ls = resetListeners.get(ptyId);
  if (ls && ls.size > 0) {
    ls.forEach(l => { try { l(); } catch { /* ignore */ } });
  }
}

export interface PtyAttachment {
  detach:  () => void;
}

/** Hook calls this on mount: starts delivering future bytes to `listener`. */
export function attachPty(
  ptyId: string,
  listener: PtyDataListener,
  onReset?: PtyResetListener,
): PtyAttachment {
  let ls = listeners.get(ptyId);
  if (!ls) { ls = new Set(); listeners.set(ptyId, ls); }
  ls.add(listener);
  let rs: Set<PtyResetListener> | undefined;
  if (onReset) {
    rs = resetListeners.get(ptyId);
    if (!rs) { rs = new Set(); resetListeners.set(ptyId, rs); }
    rs.add(onReset);
  }
  return {
    detach: () => {
      ls!.delete(listener);
      if (onReset) rs!.delete(onReset);
    }
  };
}

/** Drop a PTY's listeners (call on `pty.exited` / session detach). */
export function clearPty(ptyId: string): void {
  listeners.delete(ptyId);
  resetListeners.delete(ptyId);
}

/** Drop everything (call on session detach / logout). */
export function clearAll(): void {
  listeners.clear();
  resetListeners.clear();
}
