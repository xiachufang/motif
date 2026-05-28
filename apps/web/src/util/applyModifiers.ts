// Sticky modifier transform + helpers shared between the dock composer and
// the xterm key hook. Ported from iOS BottomInputBar.swift's applyModifiers:
// the two sides MUST agree on the byte form so a chip-armed Ctrl produces
// the same wire bytes whether the next key lands on the textarea or xterm.

export function applyModifiers(payload: Uint8Array, ctrl: boolean, alt: boolean): Uint8Array {
  if (!ctrl && !alt) return payload;

  if (payload.length === 1) {
    let byte = payload[0];
    if (ctrl) {
      // ASCII letters + [\]^_ — mask 0x1F per Ctrl-key convention. Other
      // bytes pass through (digits, punctuation, etc.).
      const isLower = byte >= 0x61 && byte <= 0x7A;
      const isUpper = byte >= 0x41 && byte <= 0x5A;
      const isBracketRun = byte >= 0x5B && byte <= 0x5F;
      if (isLower || isUpper || isBracketRun) byte &= 0x1F;
    }
    return alt ? new Uint8Array([0x1B, byte]) : new Uint8Array([byte]);
  }

  // 3-byte CSI: ESC [ X where X is arrow (A..D), Home (H), End (F).
  if (payload.length === 3 && payload[0] === 0x1B && payload[1] === 0x5B) {
    const finalByte = payload[2];
    const isArrow = finalByte >= 0x41 && finalByte <= 0x44;
    const isModifiable = isArrow || finalByte === 0x48 || finalByte === 0x46;
    if (isModifiable) {
      // Alt-only Left/Right: readline word-jump (ESC b / ESC f). bash and zsh
      // bind these by default but ignore the CSI mod form, so prefer the
      // bindable form when ctrl isn't also armed.
      if (alt && !ctrl) {
        if (finalByte === 0x44) return new Uint8Array([0x1B, 0x62]); // Alt+Left  → ESC b
        if (finalByte === 0x43) return new Uint8Array([0x1B, 0x66]); // Alt+Right → ESC f
      }
      const mod = 1 + (alt ? 2 : 0) + (ctrl ? 4 : 0);
      return new Uint8Array([0x1B, 0x5B, 0x31, 0x3B, 0x30 + mod, finalByte]);
    }
  }

  // Multi-byte non-CSI (PgUp/PgDn, etc.): Alt-only prepends ESC.
  if (alt && !ctrl) {
    const out = new Uint8Array(payload.length + 1);
    out[0] = 0x1B;
    out.set(payload, 1);
    return out;
  }
  return payload;
}

export const BRACKETED_PASTE_START = new Uint8Array([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]);
export const BRACKETED_PASTE_END   = new Uint8Array([0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]);

export function bytesToB64(u8: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
  return btoa(bin);
}

export function b64ToBytes(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function concatBytes(...parts: Uint8Array[]): Uint8Array {
  let total = 0;
  for (const p of parts) total += p.length;
  const out = new Uint8Array(total);
  let off = 0;
  for (const p of parts) { out.set(p, off); off += p.length; }
  return out;
}

/** Map a KeyboardEvent to the byte payload xterm would have emitted for it,
 *  so the sticky-modifier path can transform and send the same bytes. Only
 *  the keys that make sense to combine with Ctrl/Alt are covered; unknown
 *  keys return null so the caller can fall through to xterm's default
 *  handling. */
export function keyEventToPayload(ev: KeyboardEvent): Uint8Array | null {
  switch (ev.key) {
    case "Enter":       return new Uint8Array([0x0D]);
    case "Tab":         return new Uint8Array([0x09]);
    case "Escape":      return new Uint8Array([0x1B]);
    case "Backspace":   return new Uint8Array([0x7F]);
    case "ArrowUp":     return new Uint8Array([0x1B, 0x5B, 0x41]);
    case "ArrowDown":   return new Uint8Array([0x1B, 0x5B, 0x42]);
    case "ArrowRight":  return new Uint8Array([0x1B, 0x5B, 0x43]);
    case "ArrowLeft":   return new Uint8Array([0x1B, 0x5B, 0x44]);
    case "Home":        return new Uint8Array([0x1B, 0x5B, 0x48]);
    case "End":         return new Uint8Array([0x1B, 0x5B, 0x46]);
    case "PageUp":      return new Uint8Array([0x1B, 0x5B, 0x35, 0x7E]);
    case "PageDown":    return new Uint8Array([0x1B, 0x5B, 0x36, 0x7E]);
  }
  // Single printable character. ev.key for these is the literal char.
  if (ev.key.length === 1) {
    // Skip if browser-handled modifier-letter combos (e.g. Cmd+C copy on Mac)
    // are in flight — caller already gates on its own state, but never let
    // OS-level modifiers slip into our transform path.
    if (ev.metaKey) return null;
    return new TextEncoder().encode(ev.key);
  }
  return null;
}
