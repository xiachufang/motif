// Per-PTY sticky Ctrl/Alt state machine. Mirrors iOS libghostty's
// `TerminalPublicStickyActivation`: tapping cycles
//   inactive → armed → locked → inactive.
// `armed` consumes back to `inactive` after one key press; `locked` persists.
//
// State is partitioned by ptyId so switching tabs keeps each terminal's
// armed/locked flags independent. Subscribers (the dock chips, the xterm
// key hook, the composer textarea) all read the same shape via `useSticky`.
//
// We don't use zustand here so the store doesn't tug at every snapshot —
// useSyncExternalStore with a per-pty version counter means a Ctrl chip
// armed in PTY A doesn't re-render the dock mounted against PTY B.

import { useSyncExternalStore } from "react";

export type StickyState  = "inactive" | "armed" | "locked";
export type ModifierKind = "ctrl" | "alt";

export interface StickySnapshot { ctrl: StickyState; alt: StickyState }

const INACTIVE: StickySnapshot = { ctrl: "inactive", alt: "inactive" };

// One snapshot per pty. Missing entry == both inactive. Snapshots are
// frozen-by-replacement: every mutation creates a new object so
// `useSyncExternalStore`'s default identity check sees the change.
const states = new Map<string, StickySnapshot>();
const listeners = new Map<string, Set<() => void>>();

function notify(ptyId: string) {
  const set = listeners.get(ptyId);
  if (!set) return;
  for (const cb of set) { try { cb(); } catch { /* ignore */ } }
}

function cycle(s: StickyState): StickyState {
  return s === "inactive" ? "armed" : s === "armed" ? "locked" : "inactive";
}

export function getSticky(ptyId: string | null): StickySnapshot {
  if (!ptyId) return INACTIVE;
  return states.get(ptyId) ?? INACTIVE;
}

export function toggleSticky(ptyId: string, kind: ModifierKind): void {
  const cur = states.get(ptyId) ?? INACTIVE;
  const next: StickySnapshot = kind === "ctrl"
    ? { ctrl: cycle(cur.ctrl), alt: cur.alt }
    : { ctrl: cur.ctrl,        alt: cycle(cur.alt) };
  states.set(ptyId, next);
  notify(ptyId);
}

/** Drop any `armed` modifier back to `inactive`. `locked` is preserved — it
 *  is the user's "stay on" intent. Called after each transformed keystroke. */
export function consumeArmed(ptyId: string): void {
  const cur = states.get(ptyId);
  if (!cur) return;
  if (cur.ctrl !== "armed" && cur.alt !== "armed") return;
  const next: StickySnapshot = {
    ctrl: cur.ctrl === "armed" ? "inactive" : cur.ctrl,
    alt:  cur.alt  === "armed" ? "inactive" : cur.alt,
  };
  states.set(ptyId, next);
  notify(ptyId);
}

/** Clear all sticky state for a PTY. Called when the PTY is being torn down
 *  so a re-used id doesn't inherit stale armed/locked flags. */
export function resetSticky(ptyId: string): void {
  if (!states.has(ptyId)) return;
  states.delete(ptyId);
  notify(ptyId);
}

export function useSticky(ptyId: string | null): StickySnapshot {
  return useSyncExternalStore(
    (cb) => {
      if (!ptyId) return () => { /* nothing to do */ };
      let set = listeners.get(ptyId);
      if (!set) { set = new Set(); listeners.set(ptyId, set); }
      set.add(cb);
      return () => {
        set!.delete(cb);
        if (set!.size === 0) listeners.delete(ptyId);
      };
    },
    () => getSticky(ptyId),
    () => INACTIVE, // SSR fallback; not really used (web is CSR-only)
  );
}
