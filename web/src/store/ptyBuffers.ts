// Per-PTY byte buffer + dual listener registry, phase-aware.
//
// The renderer splits the PTY byte stream into zones based on shell
// integration phase events (driven by OSC 133;A/B/C/D on the server):
//
//   prompt      — PS1 bytes between 133;A and 133;B → FloatTerm
//   compose     — user-typing echo between 133;B and 133;C → FloatTerm
//   output      — command output between 133;C and 133;D, tagged with
//                 block_id → that block's BlockTerm
//   post-output — server-side filler between 133;D and the next 133;A
//                 (fish missing-newline marker, mode resets, etc.) → DROPPED
//   unknown     — pre-bootstrap or shell that didn't bootstrap → routed
//                 to FloatTerm as a fallback so terminals without shell
//                 integration still render
//
// `promptStart` advances on every 133;A. FloatTerm clears its xterm on
// the matching `boundary` callback, so on later re-attach we replay
// only prompt+compose chunks AFTER that boundary — earlier chunks
// belong to a prompt the user has already sent.
//
// State is module-global on purpose: it survives PtyTab unmount/remount
// (e.g. across React StrictMode's double-mount in dev) and across tab
// switches.
//
// `dropBlockBytes(ptyId, blockId)` is called by BlockTerm right after
// finalize so its bytes don't pile up in `chunks` indefinitely.

type DataListener = (chunk: Uint8Array) => void;

export interface PromptListener {
  data:     DataListener;
  /** Called synchronously each time a PromptStarted event arrives.
   *  FloatTerm uses this to drain pending writes, capture prompt_html
   *  if requested, then `term.clear() + term.reset()` so the next PS1
   *  paints on a fresh grid. */
  boundary: () => void;
}

type Zone = 'prompt' | 'compose' | 'output' | 'post-output' | 'unknown';

interface Tagged {
  zone:    Zone;
  /** Only set when zone === 'output'. */
  blockId: string | null;
  bytes:   Uint8Array;
}

interface PtyBuf {
  chunks: Tagged[];
  phase:  Zone;
  /** Index in `chunks` where the current PS1 region began. Bumped to
   *  `chunks.length` on every PromptStarted. */
  promptStart: number;
}

const buffers         = new Map<string, PtyBuf>();
const promptListeners = new Map<string, Set<PromptListener>>();
const blockListeners  = new Map<string, Map<string, Set<DataListener>>>();

function getBuf(ptyId: string): PtyBuf {
  let b = buffers.get(ptyId);
  if (!b) {
    // Pre-bootstrap default: 'unknown' acts like a passthrough into
    // FloatTerm. Once the shell integration kicks in, the first 133;A
    // moves us to 'prompt' and the proper zones take over.
    b = { chunks: [], phase: 'unknown', promptStart: 0 };
    buffers.set(ptyId, b);
  }
  return b;
}

/** Workspace dispatcher → for every `pty.output` event from the server.
 *  Routing depends on the PTY's current `phase`, not on `blockId` alone:
 *  the server tags `output` chunks with `blockId`, but `null`-tagged
 *  chunks could belong to prompt / compose / post-output / unknown,
 *  which is what `phase` disambiguates. */
export function appendOutput(ptyId: string, chunk: Uint8Array, blockId: string | null): void {
  const b = getBuf(ptyId);
  // post-output: drop. These are the bytes between 133;D and the next
  // 133;A — fish's missing-newline marker, mode resets, repaint
  // preamble. Letting them into FloatTerm is what causes the duplicated
  // prompt rows the bug fix is for.
  if (b.phase === 'post-output') return;

  // output zone: route by blockId. If the server somehow sent us
  // `block_id == null` while we think we're in output, that's a bug
  // upstream — drop rather than misroute to the prompt pane.
  if (b.phase === 'output') {
    if (blockId === null) return;
    b.chunks.push({ zone: 'output', blockId, bytes: chunk });
    const ls = blockListeners.get(ptyId)?.get(blockId);
    if (ls) ls.forEach(l => { try { l(chunk); } catch { /* ignore */ } });
    return;
  }

  // prompt / compose / unknown → FloatTerm
  b.chunks.push({ zone: b.phase, blockId: null, bytes: chunk });
  const ls = promptListeners.get(ptyId);
  if (ls) ls.forEach(l => { try { l.data(chunk); } catch { /* ignore */ } });
}

/** Workspace → on `pty.prompt_started`. Marks a fresh PS1 boundary:
 *  any subsequent prompt-zone bytes belong to the new prompt, and
 *  re-attaching FloatTerms should replay only from here. Fires
 *  every listener's `boundary` callback synchronously. */
export function markPromptStarted(ptyId: string): void {
  const b = getBuf(ptyId);
  b.phase = 'prompt';
  b.promptStart = b.chunks.length;
  const ls = promptListeners.get(ptyId);
  if (ls) ls.forEach(l => { try { l.boundary(); } catch { /* ignore */ } });
}

/** Workspace → on `pty.prompt_ended`. PS1 done, user is composing. */
export function markPromptEnded(ptyId: string): void {
  getBuf(ptyId).phase = 'compose';
}

/** Workspace → on `pty.command_started`. Output zone begins. */
export function markCommandStarted(ptyId: string): void {
  getBuf(ptyId).phase = 'output';
}

/** Workspace → on `pty.command_finished`. Subsequent server bytes are
 *  shell-internal repaint preamble; drop them until the next 133;A. */
export function markCommandFinished(ptyId: string): void {
  getBuf(ptyId).phase = 'post-output';
}

/** BlockTerm calls this after it finishes its finalize/serialize pipeline
 *  so the buffer doesn't keep that block's bytes around forever. */
export function dropBlockBytes(ptyId: string, blockId: string): void {
  const b = buffers.get(ptyId);
  if (!b) return;
  const next: Tagged[] = [];
  let removed = 0;
  let removedBeforePromptStart = 0;
  for (let i = 0; i < b.chunks.length; i++) {
    const c = b.chunks[i];
    if (c.zone === 'output' && c.blockId === blockId) {
      removed++;
      if (i < b.promptStart) removedBeforePromptStart++;
      continue;
    }
    next.push(c);
  }
  if (removed === 0) return;
  b.chunks = next;
  b.promptStart -= removedBeforePromptStart;
}

export interface PromptAttachment {
  /// prompt+compose bytes since the last PromptStarted boundary.
  /// These are the bytes the float xterm should currently display.
  initial: Uint8Array[];
  detach:  () => void;
}

export interface BlockAttachment {
  initial: Uint8Array[];
  detach:  () => void;
}

/** FloatTerm calls this on mount: returns prompt-zone + compose-zone
 *  bytes since the last PromptStarted, AND starts delivering future
 *  ones to `listener.data`. PromptStarted edges are delivered via
 *  `listener.boundary` so FloatTerm can reset its xterm. */
export function attachPrompt(ptyId: string, listener: PromptListener): PromptAttachment {
  const b = getBuf(ptyId);
  const start = Math.min(b.promptStart, b.chunks.length);
  const initial: Uint8Array[] = [];
  for (let i = start; i < b.chunks.length; i++) {
    const c = b.chunks[i];
    if (c.zone === 'prompt' || c.zone === 'compose' || c.zone === 'unknown') {
      initial.push(c.bytes);
    }
  }
  let ls = promptListeners.get(ptyId);
  if (!ls) { ls = new Set(); promptListeners.set(ptyId, ls); }
  ls.add(listener);
  return {
    initial,
    detach: () => { ls!.delete(listener); }
  };
}

/** BlockTerm calls this on mount: returns all output-zone bytes seen
 *  for that block AND starts delivering future ones. */
export function attachBlock(ptyId: string, blockId: string, listener: DataListener): BlockAttachment {
  const b = getBuf(ptyId);
  const initial: Uint8Array[] = [];
  for (const c of b.chunks) {
    if (c.zone === 'output' && c.blockId === blockId) initial.push(c.bytes);
  }
  let byBlock = blockListeners.get(ptyId);
  if (!byBlock) { byBlock = new Map(); blockListeners.set(ptyId, byBlock); }
  let ls = byBlock.get(blockId);
  if (!ls) { ls = new Set(); byBlock.set(blockId, ls); }
  ls.add(listener);
  return {
    initial,
    detach: () => {
      ls!.delete(listener);
      if (ls!.size === 0) byBlock!.delete(blockId);
    }
  };
}

/** Drop a PTY's buffer + listeners (call on pty.exited / session detach). */
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
