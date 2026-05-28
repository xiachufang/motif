// User-customizable quick commands shown in the mobile dock. Ported to the
// iOS data model so behavior matches across platforms:
//
//   - `kind` discriminates how a tap is handled:
//       bytes   — write `payload` to the PTY (sendImmediately) or insert it
//                 into the composer (!sendImmediately).
//       paste   — read clipboard at tap time, wrap in xterm bracketed paste.
//       ctrl    — toggle sticky Ctrl on the active PTY.
//       alt     — toggle sticky Alt on the active PTY.
//       cd      — open the directory picker.
//   - `payloadB64` carries the raw bytes (base64-encoded so JSON survives
//     control chars). Bytes-kind commands without a payload are inert.
//   - `symbol` is a Unicode glyph (web has no SF Symbol vocabulary) — when
//     set the chip renders the glyph instead of `label`.
//
// Per-program command sets live alongside the `global` list. When the
// foreground command in the active PTY (tracked via shell-integration in
// `runningCmds`) matches a set's `matches[]`, that set's commands replace
// the global list in the dock. Match precedence is array order.
//
// Persisted under `motif.quickCommands.v2`. v1 (`motif.mobile.quickCommands.v1`)
// is no longer read — pre-v2 customizations are lost on upgrade. The dock
// has no real users yet, so this is acceptable.

import { useSyncExternalStore } from "react";
import { bytesToB64, b64ToBytes } from "../util/applyModifiers";

export type QuickCommandKind = "bytes" | "paste" | "ctrl" | "alt" | "cd";

export interface QuickCommand {
  id:              string;
  label:           string;
  /** Unicode glyph rendered instead of the label when set (e.g. "⌃", "↑"). */
  symbol?:         string;
  /** Raw bytes sent to the PTY (or inserted into the composer), base64-encoded. */
  payloadB64:      string;
  /** bytes-only: tap-runs vs insert-into-composer. Non-bytes kinds ignore this. */
  sendImmediately: boolean;
  kind:            QuickCommandKind;
}

export interface QuickCommandSet {
  id:       string;
  name:     string;
  /** programKey values this set matches against (e.g. ["claude"]). */
  matches:  string[];
  commands: QuickCommand[];
}

export type QuickCommandScope =
  | { kind: "global" }
  | { kind: "set"; id: string };

interface PersistShape {
  global: QuickCommand[];
  sets:   QuickCommandSet[];
}

const STORAGE_KEY = "motif.quickCommands.v2";

// ── byte presets (mirrors iOS QuickCommandKey enum) ─────────────────

export interface KeyPreset {
  key:     string;
  label:   string;
  symbol?: string;
  bytes:   number[];
}

export const KEY_PRESETS: KeyPreset[] = [
  // Movement / control keys first — most commonly tapped.
  { key: "esc",         label: "Esc",  symbol: "⎋",  bytes: [0x1B] },
  { key: "tab",         label: "Tab",  symbol: "⇥",  bytes: [0x09] },
  { key: "enter",       label: "↵",                  bytes: [0x0D] },
  { key: "up",          label: "Up",   symbol: "↑",  bytes: [0x1B, 0x5B, 0x41] },
  { key: "down",        label: "Down", symbol: "↓",  bytes: [0x1B, 0x5B, 0x42] },
  { key: "left",        label: "Left", symbol: "←",  bytes: [0x1B, 0x5B, 0x44] },
  { key: "right",       label: "Right",symbol: "→",  bytes: [0x1B, 0x5B, 0x43] },
  { key: "home",        label: "Home",               bytes: [0x1B, 0x5B, 0x48] },
  { key: "end",         label: "End",                bytes: [0x1B, 0x5B, 0x46] },
  { key: "pageUp",      label: "PgUp",               bytes: [0x1B, 0x5B, 0x35, 0x7E] },
  { key: "pageDown",    label: "PgDn",               bytes: [0x1B, 0x5B, 0x36, 0x7E] },

  // Process / line-editing control codes.
  { key: "ctrlC",       label: "^C",                 bytes: [0x03] },
  { key: "ctrlD",       label: "^D",                 bytes: [0x04] },
  { key: "ctrlZ",       label: "^Z",                 bytes: [0x1A] },
  { key: "ctrlL",       label: "^L",                 bytes: [0x0C] },
  { key: "ctrlR",       label: "^R",                 bytes: [0x12] },
  { key: "ctrlU",       label: "^U",                 bytes: [0x15] },
  { key: "ctrlW",       label: "^W",                 bytes: [0x17] },
  { key: "ctrlA",       label: "^A",                 bytes: [0x01] },
  { key: "ctrlE",       label: "^E",                 bytes: [0x05] },
  { key: "ctrlK",       label: "^K",                 bytes: [0x0B] },
  { key: "ctrlB",       label: "^B",                 bytes: [0x02] },
  { key: "ctrlF",       label: "^F",                 bytes: [0x06] },
  { key: "ctrlG",       label: "^G",                 bytes: [0x07] },
  { key: "ctrlN",       label: "^N",                 bytes: [0x0E] },
  { key: "ctrlP",       label: "^P",                 bytes: [0x10] },
  { key: "ctrlT",       label: "^T",                 bytes: [0x14] },
  { key: "ctrlY",       label: "^Y",                 bytes: [0x19] },

  // Punctuation often awkward on mobile keyboards.
  { key: "pipe",        label: "|",                  bytes: [0x7C] },
  { key: "slash",       label: "/",                  bytes: [0x2F] },
  { key: "tilde",       label: "~",                  bytes: [0x7E] },
  { key: "dash",        label: "-",                  bytes: [0x2D] },
  { key: "underscore",  label: "_",                  bytes: [0x5F] },
  { key: "backtick",    label: "`",                  bytes: [0x60] },
  { key: "singleQuote", label: "'",                  bytes: [0x27] },
  { key: "doubleQuote", label: "\"",                 bytes: [0x22] },
];

// ── store ────────────────────────────────────────────────────────────

let cache: PersistShape | null = null;
const listeners = new Set<() => void>();

function load(): PersistShape {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return seedShape();
    const obj = JSON.parse(raw);
    if (!isPersistShape(obj)) return seedShape();
    return obj;
  } catch {
    return seedShape();
  }
}

function isPersistShape(x: unknown): x is PersistShape {
  if (!x || typeof x !== "object") return false;
  const o = x as Record<string, unknown>;
  return Array.isArray(o.global) && Array.isArray(o.sets);
}

function persist(shape: PersistShape) {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(shape)); } catch { /* ignore */ }
}

function notify() { for (const l of listeners) { try { l(); } catch { /* ignore */ } } }

function getSnapshot(): PersistShape {
  if (cache === null) cache = load();
  return cache;
}

function subscribe(cb: () => void) {
  listeners.add(cb);
  return () => { listeners.delete(cb); };
}

export function useQuickCommandStore(): PersistShape {
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

function writeShape(next: PersistShape) {
  cache = next;
  persist(cache);
  notify();
}

// ── helpers ──────────────────────────────────────────────────────────

function newId(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
}

export function payloadBytes(c: QuickCommand): Uint8Array {
  if (!c.payloadB64) return new Uint8Array();
  try { return b64ToBytes(c.payloadB64); } catch { return new Uint8Array(); }
}

export function makePayload(u8: Uint8Array): string {
  return u8.length === 0 ? "" : bytesToB64(u8);
}

/** Build a `bytes`-kind command from a UTF-8 string. */
export function makeTextCommand(label: string, text: string, opts?: { symbol?: string; sendImmediately?: boolean }): QuickCommand {
  return {
    id: newId("qc"),
    label,
    symbol: opts?.symbol,
    payloadB64: makePayload(new TextEncoder().encode(text)),
    sendImmediately: opts?.sendImmediately ?? true,
    kind: "bytes",
  };
}

/** Build a `bytes`-kind command from a raw byte array (control codes). */
export function makeBytesCommand(label: string, bytes: number[], opts?: { symbol?: string; sendImmediately?: boolean }): QuickCommand {
  return {
    id: newId("qc"),
    label,
    symbol: opts?.symbol,
    payloadB64: makePayload(new Uint8Array(bytes)),
    sendImmediately: opts?.sendImmediately ?? true,
    kind: "bytes",
  };
}

export function makePresetCommand(preset: KeyPreset): QuickCommand {
  return {
    id: newId("qc"),
    label: preset.label,
    symbol: preset.symbol,
    payloadB64: makePayload(new Uint8Array(preset.bytes)),
    sendImmediately: true,
    kind: "bytes",
  };
}

export function makePasteCommand(): QuickCommand {
  return { id: newId("qc"), label: "Paste", symbol: "📋", payloadB64: "", sendImmediately: true, kind: "paste" };
}
export function makeCtrlCommand(): QuickCommand {
  return { id: newId("qc"), label: "Ctrl",  symbol: "⌃",  payloadB64: "", sendImmediately: false, kind: "ctrl" };
}
export function makeAltCommand(): QuickCommand {
  return { id: newId("qc"), label: "Alt",   symbol: "⌥",  payloadB64: "", sendImmediately: false, kind: "alt"  };
}
export function makeCdCommand(): QuickCommand {
  return { id: newId("qc"), label: "cd",    symbol: "↦",  payloadB64: "", sendImmediately: false, kind: "cd"   };
}

/** Clone a command, assigning it a fresh id. Used when seeding a new set
 *  from a copy of global so the two lists' rows stay independent. */
export function cloneCommand(c: QuickCommand): QuickCommand {
  return { ...c, id: newId("qc") };
}

/** Derive the override key (program name) from a raw running-command string:
 *  first whitespace-delimited token, then its path basename. Matches iOS
 *  `QuickCommandStore.programKey`. */
export function programKey(running: string | null | undefined): string | null {
  if (!running) return null;
  const trimmed = running.trim();
  if (!trimmed) return null;
  const wsIdx = trimmed.search(/\s/);
  const token = wsIdx >= 0 ? trimmed.slice(0, wsIdx) : trimmed;
  const noTrail = token.endsWith("/") ? token.slice(0, -1) : token;
  const slash = noTrail.lastIndexOf("/");
  const leaf = slash >= 0 ? noTrail.slice(slash + 1) : noTrail;
  return leaf || null;
}

function matchingSet(shape: PersistShape, running: string | null | undefined): QuickCommandSet | null {
  const key = programKey(running);
  if (!key) return null;
  return shape.sets.find(s => s.matches.includes(key)) ?? null;
}

/** Effective command list for whatever is running in the active PTY: first
 *  matching set if one exists, else global. */
export function resolvedQuickCommands(running: string | null | undefined): QuickCommand[] {
  const shape = getSnapshot();
  return matchingSet(shape, running)?.commands ?? shape.global;
}

/** Which scope a "pencil → edit" tap should target for the running command. */
export function effectiveScope(running: string | null | undefined): QuickCommandScope {
  const shape = getSnapshot();
  const m = matchingSet(shape, running);
  return m ? { kind: "set", id: m.id } : { kind: "global" };
}

// ── scope-aware CRUD ────────────────────────────────────────────────

function mutate(scope: QuickCommandScope, edit: (list: QuickCommand[]) => QuickCommand[]) {
  const cur = getSnapshot();
  if (scope.kind === "global") {
    writeShape({ global: edit(cur.global), sets: cur.sets });
    return;
  }
  const sets = cur.sets.map(s => s.id === scope.id ? { ...s, commands: edit(s.commands) } : s);
  writeShape({ global: cur.global, sets });
}

export function listCommands(scope: QuickCommandScope): QuickCommand[] {
  const s = getSnapshot();
  if (scope.kind === "global") return s.global;
  return s.sets.find(x => x.id === scope.id)?.commands ?? [];
}

export function addCommand(scope: QuickCommandScope, c: QuickCommand) {
  mutate(scope, list => [...list, c]);
}

export function updateCommand(scope: QuickCommandScope, c: QuickCommand) {
  mutate(scope, list => list.map(x => x.id === c.id ? c : x));
}

export function removeCommand(scope: QuickCommandScope, id: string) {
  mutate(scope, list => list.filter(x => x.id !== id));
}

export function moveCommand(scope: QuickCommandScope, fromIdx: number, toIdx: number) {
  mutate(scope, list => {
    if (fromIdx < 0 || fromIdx >= list.length) return list;
    let t = Math.max(0, Math.min(toIdx, list.length));
    if (t === fromIdx || t === fromIdx + 1) return list;
    const next = list.slice();
    const [item] = next.splice(fromIdx, 1);
    if (t > fromIdx) t -= 1;
    next.splice(t, 0, item);
    return next;
  });
}

export function replaceCommands(scope: QuickCommandScope, list: QuickCommand[]) {
  mutate(scope, () => list);
}

// ── set management ──────────────────────────────────────────────────

/** Create a new named set seeded from a copy of the global list, mirroring
 *  iOS so the user tweaks rather than rebuilds from scratch. */
export function createSet(name: string, matches: string[] = []): string {
  const cur = getSnapshot();
  const id  = newId("set");
  const set: QuickCommandSet = {
    id, name, matches,
    commands: cur.global.map(cloneCommand),
  };
  writeShape({ global: cur.global, sets: [...cur.sets, set] });
  return id;
}

export function removeSet(id: string) {
  const cur = getSnapshot();
  writeShape({ global: cur.global, sets: cur.sets.filter(s => s.id !== id) });
}

export function renameSet(id: string, name: string) {
  const cur = getSnapshot();
  writeShape({
    global: cur.global,
    sets:   cur.sets.map(s => s.id === id ? { ...s, name } : s),
  });
}

export function setMatches(id: string, matches: string[]) {
  const cur = getSnapshot();
  writeShape({
    global: cur.global,
    sets:   cur.sets.map(s => s.id === id ? { ...s, matches } : s),
  });
}

export function resetGlobalToDefaults() {
  const cur = getSnapshot();
  writeShape({ global: seedDefaults(), sets: cur.sets });
}

// ── seed ────────────────────────────────────────────────────────────

function seedDefaults(): QuickCommand[] {
  const byKey = (k: string) => KEY_PRESETS.find(p => p.key === k)!;
  return [
    makeCtrlCommand(),
    makeAltCommand(),
    makePresetCommand(byKey("esc")),
    makePresetCommand(byKey("tab")),
    makePresetCommand(byKey("up")),
    makePresetCommand(byKey("down")),
    makePresetCommand(byKey("left")),
    makePresetCommand(byKey("right")),
    makePresetCommand(byKey("ctrlC")),
    makePresetCommand(byKey("ctrlD")),
    makeTextCommand("cd ..", "cd ..\n"),
    makeTextCommand("ls",    "ls\n"),
    makePresetCommand(byKey("pipe")),
    makePresetCommand(byKey("slash")),
    makePresetCommand(byKey("tilde")),
    makePresetCommand(byKey("dash")),
    makePresetCommand(byKey("underscore")),
    makePresetCommand(byKey("backtick")),
    makePresetCommand(byKey("singleQuote")),
    makePresetCommand(byKey("doubleQuote")),
    makeCdCommand(),
    makePasteCommand(),
  ];
}

function seedShape(): PersistShape {
  return { global: seedDefaults(), sets: [] };
}

// ── escape decoder (used by the snippet editor) ─────────────────────

/** Decode JS-style escape sequences (\n, \t, \r, \x1b, \\, \") so users can
 *  enter control bytes in the editor's plain text field. Unrecognized
 *  escapes pass through verbatim — a lenient decoder is friendlier than
 *  rejecting input the user can't easily inspect. */
export function decodeEscapes(s: string): string {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s.charCodeAt(i);
    if (ch !== 0x5c /* \ */ || i + 1 >= s.length) { out += s[i]; continue; }
    const n = s[i + 1];
    if      (n === "n")  { out += "\n"; i++; }
    else if (n === "r")  { out += "\r"; i++; }
    else if (n === "t")  { out += "\t"; i++; }
    else if (n === "e")  { out += "\x1b"; i++; }
    else if (n === "0")  { out += "\0"; i++; }
    else if (n === "\\") { out += "\\"; i++; }
    else if (n === "\"") { out += "\""; i++; }
    else if (n === "'")  { out += "'";  i++; }
    else if (n === "x" && i + 3 < s.length) {
      const hex = s.slice(i + 2, i + 4);
      if (/^[0-9a-fA-F]{2}$/.test(hex)) { out += String.fromCharCode(parseInt(hex, 16)); i += 3; }
      else { out += s[i]; }
    }
    else if (n === "u" && i + 5 < s.length) {
      const hex = s.slice(i + 2, i + 6);
      if (/^[0-9a-fA-F]{4}$/.test(hex)) { out += String.fromCharCode(parseInt(hex, 16)); i += 5; }
      else { out += s[i]; }
    }
    else { out += s[i]; }
  }
  return out;
}

/** Inverse of decodeEscapes: turn raw bytes (UTF-8 where possible, hex
 *  fallback for non-printable) back into a JS-string with `\n / \t / \xHH`
 *  escapes so the editor can show the payload as editable text. */
export function encodeEscapes(u8: Uint8Array): string {
  // Pure ASCII path: emit printable bytes verbatim, escape control chars.
  let allAscii = true;
  for (let i = 0; i < u8.length; i++) {
    if (u8[i] > 0x7f) { allAscii = false; break; }
  }
  if (!allAscii) {
    // Multi-byte UTF-8 text. Decode and re-escape control chars only;
    // leave printable Unicode intact so users can edit it.
    let text: string;
    try { text = new TextDecoder("utf-8", { fatal: false }).decode(u8); }
    catch { return [...u8].map(b => "\\x" + b.toString(16).padStart(2, "0")).join(""); }
    let out = "";
    for (const ch of text) {
      const cp = ch.codePointAt(0)!;
      if (cp < 0x20 || cp === 0x7f) out += "\\x" + cp.toString(16).padStart(2, "0");
      else if (cp === 0x5c) out += "\\\\";
      else out += ch;
    }
    return out;
  }
  let out = "";
  for (let i = 0; i < u8.length; i++) {
    const b = u8[i];
    if (b === 0x0a) out += "\\n";
    else if (b === 0x0d) out += "\\r";
    else if (b === 0x09) out += "\\t";
    else if (b === 0x1b) out += "\\e";
    else if (b === 0x5c) out += "\\\\";
    else if (b < 0x20 || b === 0x7f) out += "\\x" + b.toString(16).padStart(2, "0");
    else out += String.fromCharCode(b);
  }
  return out;
}
