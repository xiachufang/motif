// User-customizable quick commands shown in the mobile dock. Persisted to
// localStorage; subscribers re-render via useSyncExternalStore.
//
// `value` is the raw bytes inserted into the dock's text input. Control
// chars use JS-style escapes (\n, \t, \x03, \x1b…) and are decoded in the
// dock before being inserted. `appendNewline` (kept for back-compat) means
// "press Enter after this command" — the dock appends a CR (\r), matching
// what xterm sends for the Enter key, so the shell's ICRNL line discipline
// runs the command.

import { useSyncExternalStore } from "react";

export interface QuickCommand {
  id:             string;
  label:          string;
  value:          string;
  appendNewline?: boolean;
}

const STORAGE_KEY = "motif.mobile.quickCommands.v1";

const DEFAULTS: QuickCommand[] = [
  { id: "ls",       label: "ls",         value: "ls",         appendNewline: true  },
  { id: "ll",       label: "ll",         value: "ll",         appendNewline: true  },
  { id: "pwd",      label: "pwd",        value: "pwd",        appendNewline: true  },
  { id: "gst",      label: "git status", value: "git status", appendNewline: true  },
  { id: "clear",    label: "clear",      value: "clear",      appendNewline: true  },
  { id: "up",       label: "↑",          value: "\\x1b[A",    appendNewline: false },
  { id: "tab",      label: "Tab",        value: "\\t",        appendNewline: false },
  { id: "esc",      label: "Esc",        value: "\\x1b",      appendNewline: false },
  { id: "ctrlc",    label: "^C",         value: "\\x03",      appendNewline: false },
];

let cache: QuickCommand[] | null = null;
const listeners = new Set<() => void>();

function load(): QuickCommand[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return DEFAULTS.slice();
    const arr = JSON.parse(raw);
    if (!Array.isArray(arr)) return DEFAULTS.slice();
    return arr.filter(isQuickCommand);
  } catch {
    return DEFAULTS.slice();
  }
}

function isQuickCommand(x: unknown): x is QuickCommand {
  if (!x || typeof x !== "object") return false;
  const o = x as Record<string, unknown>;
  return typeof o.id === "string"
    && typeof o.label === "string"
    && typeof o.value === "string";
}

function persist(list: QuickCommand[]) {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(list)); } catch { /* ignore */ }
}

function notify() { listeners.forEach(l => { try { l(); } catch { /* ignore */ } }); }

function getSnapshot(): QuickCommand[] {
  if (cache === null) cache = load();
  return cache;
}

function subscribe(cb: () => void) {
  listeners.add(cb);
  return () => { listeners.delete(cb); };
}

export function useQuickCommands(): QuickCommand[] {
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

export function setQuickCommands(next: QuickCommand[]) {
  cache = next.slice();
  persist(cache);
  notify();
}

export function addQuickCommand(c: Omit<QuickCommand, "id"> & { id?: string }) {
  const id = c.id ?? `qc-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 6)}`;
  setQuickCommands([...getSnapshot(), { ...c, id }]);
}

export function updateQuickCommand(id: string, patch: Partial<Omit<QuickCommand, "id">>) {
  setQuickCommands(getSnapshot().map(c => c.id === id ? { ...c, ...patch } : c));
}

export function deleteQuickCommand(id: string) {
  setQuickCommands(getSnapshot().filter(c => c.id !== id));
}

export function moveQuickCommand(id: string, delta: -1 | 1) {
  const list = getSnapshot().slice();
  const i = list.findIndex(c => c.id === id);
  if (i < 0) return;
  const j = i + delta;
  if (j < 0 || j >= list.length) return;
  [list[i], list[j]] = [list[j], list[i]];
  setQuickCommands(list);
}

export function resetQuickCommands() {
  setQuickCommands(DEFAULTS.slice());
}

/** Decode JS-style escape sequences (\n, \t, \r, \x1b, \\, \") so users can
 *  enter control bytes in the manager's plain text field. Unrecognized
 *  escapes pass through verbatim — a lenient decoder is friendlier than
 *  rejecting input the user can't easily inspect. */
export function decodeEscapes(s: string): string {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const ch = s.charCodeAt(i);
    if (ch !== 0x5c /* \ */ || i + 1 >= s.length) { out += s[i]; continue; }
    const n = s[i + 1];
    if (n === "n")      { out += "\n"; i++; }
    else if (n === "r") { out += "\r"; i++; }
    else if (n === "t") { out += "\t"; i++; }
    else if (n === "0") { out += "\0"; i++; }
    else if (n === "\\") { out += "\\"; i++; }
    else if (n === "\"") { out += "\""; i++; }
    else if (n === "'")  { out += "'";  i++; }
    else if (n === "x" && i + 3 < s.length) {
      const hex = s.slice(i + 2, i + 4);
      if (/^[0-9a-fA-F]{2}$/.test(hex)) {
        out += String.fromCharCode(parseInt(hex, 16));
        i += 3;
      } else { out += s[i]; }
    }
    else if (n === "u" && i + 5 < s.length) {
      const hex = s.slice(i + 2, i + 6);
      if (/^[0-9a-fA-F]{4}$/.test(hex)) {
        out += String.fromCharCode(parseInt(hex, 16));
        i += 5;
      } else { out += s[i]; }
    }
    else { out += s[i]; }
  }
  return out;
}
