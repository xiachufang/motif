// Per-PTY shell-integration parser, web flavor. Same shape as the
// Swift port in `ios/Motif/Native/ShellIntegration.swift` and the
// Rust port in `motif-client/src/shell_integration.rs`. Phase 5b of
// the protocol redesign moved shell-integration OSC parsing off the
// server and into each client; this file is the web slice.

export type OutputScope = "Prompt" | "Command" | "Output" | "Passthrough";

export type ShellEvent =
  | { kind: "bootstrapped"; shell: string }
  | { kind: "promptStarted"; blockID: string }
  | { kind: "promptEnded"; blockID: string }
  | { kind: "commandStarted"; blockID: string; text: string; cwd: string; startedAt: number }
  | { kind: "commandFinished"; blockID: string; exitCode: number | null; finishedAt: number }
  | { kind: "shellContext"; ctx: Record<string, string> }
  | { kind: "cwdChanged"; cwd: string };

type Stage =
  | { tag: "unknown" }
  | { tag: "atPrompt";  blockID: string; cwd: string; startedAt: number }
  | { tag: "composing"; blockID: string; cwd: string; startedAt: number }
  | { tag: "running";   blockID: string; cmd: string; cwd: string; startedAt: number };

type ScanItem =
  | { kind: "bytes"; data: Uint8Array }
  | { kind: "marker"; marker: OscMarker };

type OscMarker =
  | { kind: "osc7Cwd"; cwd: string }
  | { kind: "osc133PromptStart" }
  | { kind: "osc133PromptEnd" }
  | { kind: "osc133CmdStart"; cmdlineUrl?: string | null }
  | { kind: "osc133CmdEnd"; exit: number | null }
  | { kind: "osc7770Cmd"; text: string }
  | { kind: "osc7771Context"; ctx: Record<string, string> };

export class ShellState {
  private stage: Stage = { tag: "unknown" };
  private currentCwd = "";
  private pendingCmd: string | null = null;
  private bootstrapAnnounced = false;
  private scanner = new OscScanner();

  public activeBlockID: string | null = null;
  public activeScope: OutputScope = "Passthrough";

  /// Drives the parser on a chunk of bytes. Returns the passthrough
  /// stream (OSC markers stripped) plus high-level events emitted by
  /// the state machine in arrival order.
  feed(bytes: Uint8Array): { passthrough: Uint8Array; events: ShellEvent[] } {
    const scan = this.scanner.feed(bytes);
    const events: ShellEvent[] = [];
    const passthroughChunks: Uint8Array[] = [];
    for (const item of scan.items) {
      if (item.kind === "bytes") {
        passthroughChunks.push(item.data);
      } else {
        events.push(...this.handle(item.marker));
      }
    }
    return { passthrough: concat(passthroughChunks), events };
  }

  /// Force-finalize any in-flight block on socket close.
  onClose(): ShellEvent | null {
    if (this.stage.tag === "running") {
      return { kind: "commandFinished", blockID: this.stage.blockID, exitCode: null, finishedAt: nowMs() };
    }
    return null;
  }

  private handle(m: OscMarker): ShellEvent[] {
    const out: ShellEvent[] = [];
    const bs = this.firstOscSeen();
    if (bs) out.push(bs);

    switch (m.kind) {
      case "osc7Cwd": {
        if (m.cwd !== this.currentCwd) {
          this.currentCwd = m.cwd;
          out.push({ kind: "cwdChanged", cwd: m.cwd });
        }
        break;
      }
      case "osc133PromptStart": {
        this.pendingCmd = null;
        const cwd = this.currentCwd || "/";
        switch (this.stage.tag) {
          case "atPrompt":
          case "composing": {
            this.stage = { tag: "atPrompt", blockID: this.stage.blockID, cwd: this.stage.cwd, startedAt: this.stage.startedAt };
            out.push({ kind: "promptStarted", blockID: this.stage.blockID });
            break;
          }
          case "running": {
            out.push({ kind: "commandFinished", blockID: this.stage.blockID, exitCode: null, finishedAt: nowMs() });
            const newID = ulid();
            this.stage = { tag: "atPrompt", blockID: newID, cwd, startedAt: nowMs() };
            out.push({ kind: "promptStarted", blockID: newID });
            break;
          }
          case "unknown": {
            const newID = ulid();
            this.stage = { tag: "atPrompt", blockID: newID, cwd, startedAt: nowMs() };
            out.push({ kind: "promptStarted", blockID: newID });
            break;
          }
        }
        break;
      }
      case "osc133PromptEnd": {
        if (this.stage.tag === "atPrompt") {
          const { blockID, cwd, startedAt } = this.stage;
          out.push({ kind: "promptEnded", blockID });
          this.stage = { tag: "composing", blockID, cwd, startedAt };
        }
        break;
      }
      case "osc7770Cmd": {
        this.pendingCmd = m.text;
        break;
      }
      case "osc133CmdStart": {
        if (this.stage.tag === "composing") {
          const cmd = m.cmdlineUrl ?? this.pendingCmd ?? "";
          this.pendingCmd = null;
          const { blockID, cwd } = this.stage;
          const at = nowMs();
          this.stage = { tag: "running", blockID, cmd, cwd, startedAt: at };
          out.push({ kind: "commandStarted", blockID, text: cmd, cwd, startedAt: at });
        }
        break;
      }
      case "osc133CmdEnd": {
        this.pendingCmd = null;
        if (this.stage.tag === "running") {
          const { blockID } = this.stage;
          out.push({ kind: "commandFinished", blockID, exitCode: m.exit, finishedAt: nowMs() });
          this.stage = { tag: "unknown" };
        }
        break;
      }
      case "osc7771Context": {
        out.push({ kind: "shellContext", ctx: m.ctx });
        break;
      }
    }

    switch (this.stage.tag) {
      case "unknown":   this.activeBlockID = null;                this.activeScope = "Passthrough"; break;
      case "atPrompt":  this.activeBlockID = this.stage.blockID;  this.activeScope = "Prompt";      break;
      case "composing": this.activeBlockID = this.stage.blockID;  this.activeScope = "Command";     break;
      case "running":   this.activeBlockID = this.stage.blockID;  this.activeScope = "Output";      break;
    }
    return out;
  }

  private firstOscSeen(): ShellEvent | null {
    if (this.bootstrapAnnounced) return null;
    this.bootstrapAnnounced = true;
    return { kind: "bootstrapped", shell: "unknown" };
  }
}

// ─────────────────────────── OSC scanner ───────────────────────────

class OscScanner {
  private pending: number[] = [];
  private inOsc = false;

  feed(bytes: Uint8Array): { items: ScanItem[] } {
    const items: ScanItem[] = [];
    for (let i = 0; i < bytes.length; i++) {
      this.step(bytes[i], items);
    }
    return { items };
  }

  private step(b: number, items: ScanItem[]) {
    if (!this.inOsc) {
      if (b === 0x1b) {
        this.pending = [b];
        this.inOsc = true;
      } else {
        appendPassthrough(b, items);
      }
      return;
    }
    this.pending.push(b);
    if (this.pending.length === 2) {
      if (this.pending[1] !== 0x5d /* ']' */) {
        for (const x of this.pending) appendPassthrough(x, items);
        this.pending = []; this.inOsc = false;
      }
      return;
    }
    const isBel = b === 0x07;
    const isSt  = this.pending.length >= 3
      && this.pending[this.pending.length - 2] === 0x1b
      && b === 0x5c;
    if (!isBel && !isSt) {
      if (this.pending.length > 4096) {
        for (const x of this.pending) appendPassthrough(x, items);
        this.pending = []; this.inOsc = false;
      }
      return;
    }
    const bodyEnd = isSt ? this.pending.length - 2 : this.pending.length - 1;
    const body = this.pending.slice(2, bodyEnd);
    const marker = parseOscBody(body);
    if (marker) {
      items.push({ kind: "marker", marker });
    } else {
      for (const x of this.pending) appendPassthrough(x, items);
    }
    this.pending = []; this.inOsc = false;
  }
}

function appendPassthrough(b: number, items: ScanItem[]) {
  const last = items[items.length - 1];
  if (last && last.kind === "bytes") {
    const next = new Uint8Array(last.data.length + 1);
    next.set(last.data); next[last.data.length] = b;
    items[items.length - 1] = { kind: "bytes", data: next };
  } else {
    items.push({ kind: "bytes", data: new Uint8Array([b]) });
  }
}

function parseOscBody(body: number[]): OscMarker | null {
  const s = new TextDecoder("utf-8", { fatal: false }).decode(new Uint8Array(body));
  const semi = s.indexOf(";");
  if (semi < 0) {
    // No semicolon at all: not a shell-integration OSC we recognize.
    if (s === "133;A") return { kind: "osc133PromptStart" };
    if (s === "133;B") return { kind: "osc133PromptEnd" };
    if (s === "133;C") return { kind: "osc133CmdStart", cmdlineUrl: null };
    if (s === "133;D") return { kind: "osc133CmdEnd", exit: null };
    if (s === "777;A") return { kind: "osc133PromptStart" };
    if (s === "777;B") return { kind: "osc133PromptEnd" };
    if (s === "777;C") return { kind: "osc133CmdStart", cmdlineUrl: null };
    if (s === "777;D") return { kind: "osc133CmdEnd", exit: null };
    return null;
  }
  const kind = s.slice(0, semi);
  const rest = s.slice(semi + 1);
  switch (kind) {
    case "7": {
      // file://host/path  — host informational; keep the path.
      try {
        const u = new URL(rest);
        return { kind: "osc7Cwd", cwd: decodeURIComponent(u.pathname) };
      } catch {
        return { kind: "osc7Cwd", cwd: rest };
      }
    }
    case "133":   return parse133(rest);
    case "777":   return parse777(rest);
    case "7770": {
      const text = decodeHexString(rest);
      return text == null ? null : { kind: "osc7770Cmd", text };
    }
    case "7771": {
      const ctx = parseContextHex(rest);
      return ctx == null ? null : { kind: "osc7771Context", ctx };
    }
    default:      return null;
  }
}

function parse133(rest: string): OscMarker | null {
  const semi = rest.indexOf(";");
  const head = semi < 0 ? rest : rest.slice(0, semi);
  const tail = semi < 0 ? null : rest.slice(semi + 1);
  switch (head) {
    case "A": return { kind: "osc133PromptStart" };
    case "B": return { kind: "osc133PromptEnd" };
    case "C": {
      const cmdlineUrl = tail == null ? null : parse133CmdlineUrl(tail);
      return { kind: "osc133CmdStart", cmdlineUrl };
    }
    case "D": {
      const first = tail == null ? "" : tail.split(";", 1)[0].trim();
      const exit = first ? Number(first) : NaN;
      return { kind: "osc133CmdEnd", exit: Number.isFinite(exit) ? exit : null };
    }
    default:  return null;
  }
}

function parse777(rest: string): OscMarker | null {
  const semi = rest.indexOf(";");
  const head = semi < 0 ? rest : rest.slice(0, semi);
  const tail = semi < 0 ? null : rest.slice(semi + 1);
  switch (head) {
    case "A": return { kind: "osc133PromptStart" };
    case "B": return { kind: "osc133PromptEnd" };
    case "C": return { kind: "osc133CmdStart", cmdlineUrl: null };
    case "D": {
      const first = tail == null ? "" : tail.split(";", 1)[0].trim();
      const exit = first ? Number(first) : NaN;
      return { kind: "osc133CmdEnd", exit: Number.isFinite(exit) ? exit : null };
    }
    case "E": {
      if (tail == null) return null;
      const text = decodeHexString(tail);
      return text == null ? null : { kind: "osc7770Cmd", text };
    }
    case "P": {
      if (tail == null) return null;
      if (tail.startsWith("Cwd=")) return { kind: "osc7Cwd", cwd: parseCwd(tail.slice(4)) };
      if (tail.startsWith("Context=")) {
        const ctx = parseContextHex(tail.slice(8));
        return ctx == null ? null : { kind: "osc7771Context", ctx };
      }
      return null;
    }
    default: return null;
  }
}

function parse133CmdlineUrl(tail: string): string | null {
  for (const piece of tail.split(";")) {
    if (piece.startsWith("cmdline_url=")) {
      try {
        return decodeURIComponent(piece.slice("cmdline_url=".length));
      } catch {
        return piece.slice("cmdline_url=".length);
      }
    }
  }
  return null;
}

function parseCwd(raw: string): string {
  try {
    const u = new URL(raw);
    return decodeURIComponent(u.pathname);
  } catch {
    try {
      return decodeURIComponent(raw);
    } catch {
      return raw;
    }
  }
}

function decodeHexString(hex: string): string | null {
  if (hex.length % 2 !== 0 || /[^0-9a-fA-F]/.test(hex)) return null;
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return new TextDecoder("utf-8", { fatal: false }).decode(bytes);
}

function parseContextHex(hex: string): Record<string, string> | null {
  const json = decodeHexString(hex);
  if (json == null) return null;
  try {
    const value = JSON.parse(json);
    return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, string> : null;
  } catch {
    return null;
  }
}

function concat(chunks: Uint8Array[]): Uint8Array {
  let len = 0;
  for (const c of chunks) len += c.length;
  const out = new Uint8Array(len);
  let off = 0;
  for (const c of chunks) { out.set(c, off); off += c.length; }
  return out;
}

function ulid(): string {
  const alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  let out = "";
  for (const b of bytes) {
    out += alphabet[b & 0x1f];
    out += alphabet[(b >> 5) & 0x1f];
  }
  return out.slice(0, 26);
}

function nowMs(): number { return Date.now(); }
