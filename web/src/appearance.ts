// Global appearance settings (font size + theme) shared by the store, the
// theme hook, and the terminal/diff surfaces. Persisted per-browser in
// localStorage following the existing `motif.*` key convention.

import type { ITheme } from "@xterm/xterm";

export type ThemeSetting  = "system" | "light" | "dark";
export type ResolvedTheme = "light" | "dark";

export const FONT_SIZE_MIN     = 10;
export const FONT_SIZE_MAX     = 24;
export const FONT_SIZE_DEFAULT = 13;
export const DEFAULT_THEME: ThemeSetting = "system";

export const THEME_OPTIONS: { value: ThemeSetting; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light",  label: "Light"  },
  { value: "dark",   label: "Dark"   },
];

// xterm color palettes. Dark matches the original hardcoded values; light is
// tuned for a white background. Both carry the 16 ANSI colors so programs that
// emit color (ls, git, vim) stay legible under either scheme.
export const XTERM_THEME: Record<ResolvedTheme, ITheme> = {
  dark: {
    background: "#0e0e0e", foreground: "#e6e6e6",
    cursor:     "#e6e6e6", cursorAccent: "#0e0e0e",
    selectionBackground: "#264f78",
    black: "#2a2a2a", red: "#e06c75", green: "#98c379", yellow: "#d19a66",
    blue: "#61afef", magenta: "#c678dd", cyan: "#56b6c2", white: "#d7d7d7",
    brightBlack: "#5c6370", brightRed: "#e06c75", brightGreen: "#98c379",
    brightYellow: "#d19a66", brightBlue: "#61afef", brightMagenta: "#c678dd",
    brightCyan: "#56b6c2", brightWhite: "#ffffff",
  },
  light: {
    background: "#ffffff", foreground: "#1a1a1a",
    cursor:     "#1a1a1a", cursorAccent: "#ffffff",
    selectionBackground: "#aaccff",
    black: "#1a1a1a", red: "#c0392b", green: "#2e7d32", yellow: "#b8860b",
    blue: "#1565c0", magenta: "#8e24aa", cyan: "#00838f", white: "#d0d0d0",
    brightBlack: "#666666", brightRed: "#e74c3c", brightGreen: "#388e3c",
    brightYellow: "#c98a00", brightBlue: "#1976d2", brightMagenta: "#9c27b0",
    brightCyan: "#0097a7", brightWhite: "#ffffff",
  },
};

// Convert a `#rrggbb` hex string into the rgb portion of an OSC 10/11 reply
// (`RRRR/GGGG/BBBB`, 16-bit per channel) that motifd caches and hands back to
// shell programs querying their terminal colours. We duplicate each 8-bit
// channel into 16 bits to match the server's canonical-default encoding.
function hexToOscRgb(hex: string): string | undefined {
  const m = /^#?([0-9a-fA-F]{6})$/.exec(hex.trim());
  if (!m) return undefined;
  const h = m[1].toLowerCase();
  const r = h.slice(0, 2), g = h.slice(2, 4), b = h.slice(4, 6);
  return `${r}${r}/${g}${g}/${b}${b}`;
}

// Foreground + background the active xterm theme actually renders, encoded for
// the `session.attach` / `session.set_palette` `term_fg` / `term_bg` fields so
// OSC 10/11 queries inside the PTY match what the user sees in this browser.
export function oscPalette(resolved: ResolvedTheme): { term_fg?: string; term_bg?: string } {
  const t = XTERM_THEME[resolved];
  return {
    term_fg: typeof t.foreground === "string" ? hexToOscRgb(t.foreground) : undefined,
    term_bg: typeof t.background === "string" ? hexToOscRgb(t.background) : undefined,
  };
}

const FONT_KEY  = "motif.appearance.fontSize";
const THEME_KEY = "motif.appearance.theme";

function clampFont(n: number): number {
  if (!Number.isFinite(n)) return FONT_SIZE_DEFAULT;
  return Math.min(FONT_SIZE_MAX, Math.max(FONT_SIZE_MIN, Math.round(n)));
}

export function loadFontSize(): number {
  try {
    const v = localStorage.getItem(FONT_KEY);
    if (v != null) return clampFont(Number(v));
  } catch { /* ignore */ }
  return FONT_SIZE_DEFAULT;
}
export function saveFontSize(n: number) {
  try { localStorage.setItem(FONT_KEY, String(clampFont(n))); } catch { /* ignore */ }
}

export function loadTheme(): ThemeSetting {
  try {
    const v = localStorage.getItem(THEME_KEY);
    if (v === "system" || v === "light" || v === "dark") return v;
  } catch { /* ignore */ }
  return DEFAULT_THEME;
}
export function saveTheme(t: ThemeSetting) {
  try { localStorage.setItem(THEME_KEY, t); } catch { /* ignore */ }
}
