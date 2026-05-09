// Headless-xterm helper. Used to convert a block's raw byte stream into
// HTML — driven by both the live finalize path (PtyTab serializes its
// own xterm) and the backfill path (PtyTab pulls historical bytes via
// `pty.get_block_output` and replays them through a hidden xterm here).
//
// The terminal is never `open()`-ed; we only `.write()` and read out via
// SerializeAddon. xterm's parser runs without a renderer, so this is
// fast (no canvas / DOM cost).

import { Terminal } from "@xterm/xterm";
import { SerializeAddon } from "@xterm/addon-serialize";

export interface SerializeOptions {
  /** Terminal width to write under. Should match the live terminal so
   *  wrapping aligns with what the user originally saw. */
  cols:       number;
  /** Terminal height. Doesn't bound the output (xterm scrollback grows
   *  without rendering); 24 is fine. */
  rows?:      number;
  /** Scrollback limit. Make this generous — historical blocks can be
   *  many thousands of lines (`yes | head -10000` etc.). The server
   *  caps a single block at 1 MiB (~10k typical lines). */
  scrollback?: number;
}

/** Replay raw PTY bytes through a headless xterm and return its content
 *  as HTML. Resolves once xterm's parser has drained the input.
 *
 *  Returns `""` on empty input (skip rendering). Disposes the terminal
 *  on success and on error. */
export async function serializeBytesToHtml(
  bytes: Uint8Array,
  opts:  SerializeOptions,
): Promise<string> {
  if (bytes.length === 0) return "";
  const term = new Terminal({
    cols:       opts.cols,
    rows:       opts.rows ?? 24,
    scrollback: opts.scrollback ?? 20_000,
    allowProposedApi: true,
    // Use page bg (--bg) — the live xterm uses the same value, and finalized
    // cards sit directly on the page bg too (no panel surround in the new
    // gutter layout). Matching backgrounds removes the visual seam between
    // live xterm and serialized HTML bodies.
    theme: { background: "#0e0e0e", foreground: "#e6e6e6" },
  });
  const addon = new SerializeAddon();
  term.loadAddon(addon);

  try {
    // Anchor a marker at line 0 before any writes so the start of the
    // serialize range survives potential scrollback growth.
    const startMarker = term.registerMarker(0);
    await new Promise<void>(resolve => term.write(bytes, () => resolve()));
    // Without a range, serializeAsHTML emits every row of the headless
    // terminal's viewport (rows: 24) — padding short outputs with up to
    // 23 empty lines. Bound the range to actual used lines, mirroring
    // BlockTerm's live finalize path.
    const endMarker = term.registerMarker(0);
    const startLine = startMarker?.line ?? 0;
    const endLine   = endMarker?.line   ?? startLine;
    // includeGlobalBackground: true makes the wrapper read fg/bg from the
    // theme above. With `false` the addon hard-codes black-on-white.
    if (endLine < startLine) return "";
    return addon.serializeAsHTML({
      range: { startLine, endLine, startCol: 0 },
      includeGlobalBackground: true,
    });
  } finally {
    addon.dispose();
    term.dispose();
  }
}

/** Quick check: did the raw bytes ever toggle the alternate screen
 *  buffer? Used at backfill time to decide whether to render a card or
 *  an alt-stub, since the live `buffer.onBufferChange` signal isn't
 *  available for historical bytes.
 *
 *  Looks for the DEC private mode 1049 (alt buffer + cursor save) which
 *  is what every modern fullscreen TUI uses (vim, less, htop, tmux). */
export function bytesEnteredAltScreen(bytes: Uint8Array): boolean {
  // ESC [ ? 1 0 4 9 h  — needle as ASCII bytes
  // 0x1b 0x5b 0x3f 0x31 0x30 0x34 0x39 0x68
  const needle = [0x1b, 0x5b, 0x3f, 0x31, 0x30, 0x34, 0x39, 0x68];
  outer: for (let i = 0; i + needle.length <= bytes.length; i++) {
    for (let j = 0; j < needle.length; j++) {
      if (bytes[i + j] !== needle[j]) continue outer;
    }
    return true;
  }
  return false;
}
