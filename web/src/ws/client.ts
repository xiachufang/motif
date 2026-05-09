// JSON-RPC 2.0 over a single WebSocket. Designed for the motif-web bridge:
// the first frame is `auth.login`, the bridge replies with a synthetic
// success, and from then on frames flow transparently to/from motifd.
//
// Auto-reconnect: on unexpected close, the client opens a fresh WS,
// re-runs `auth.login` with the cached token, then fires `onReconnect`
// so the workspace can call `session.attach { last_seq }` to replay
// missed events. Pending requests issued on the dead socket are
// rejected; new calls during the gap also reject (caller should retry
// after onReconnect). Explicit `close()` disables reconnect.

import type { Event } from "../proto/types";

interface PendingCall {
  resolve: (v: unknown) => void;
  reject:  (e: Error) => void;
}

export type EventHandler = (ev: Event) => void;

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 15_000;

// Truncate long strings (base64 PTY chunks, big HTML blobs) so the console
// stays readable. Frames are still logged in full structure, just with
// long strings summarized.
function summarize(v: unknown, maxStr = 200): string {
  try {
    return JSON.stringify(v, (_k, val) => {
      if (typeof val === "string" && val.length > maxStr) {
        return `<${val.length} chars> ${val.slice(0, 60)}…`;
      }
      return val;
    });
  } catch {
    return String(v);
  }
}

export class RpcClient {
  private ws:        WebSocket | null = null;
  private token:     string;
  private nextId   = 1;
  private pending  = new Map<number, PendingCall>();
  private handlers = new Set<EventHandler>();
  private closed   = false;
  private reconnectDelay = RECONNECT_MIN_MS;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  /** Fires after a transparent reconnect + auth.login succeed. The
   *  workspace uses this to call `session.attach` with the last seen
   *  `seq` so the server can replay missed events. */
  public  onReconnect: (() => void | Promise<void>) | null = null;
  /** Fires only on explicit close() or when reconnect is permanently
   *  given up (auth.login fails — token revoked). */
  public  onClose:     (() => void) | null = null;

  private constructor(token: string) {
    this.token = token;
  }

  /** Open a connection, perform auth.login, return a ready RpcClient. */
  static async connect(token: string): Promise<RpcClient> {
    const c = new RpcClient(token);
    await c.openSocket();
    return c;
  }

  private async openSocket(): Promise<void> {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const url   = `${proto}://${location.host}/ws`;
    console.log("[rpc] opening", url);
    const ws    = new WebSocket(url);
    await new Promise<void>((res, rej) => {
      ws.addEventListener("open",  () => res(),                                  { once: true });
      ws.addEventListener("error", () => rej(new Error("connection failed")),    { once: true });
    });
    console.log("[rpc] open");
    this.ws = ws;
    ws.addEventListener("message", e => this.onMessage(e.data));
    ws.addEventListener("close",   () => this.handleSocketClose());
    ws.addEventListener("error",   () => { /* surface via close */ });
    await this.sendCall("auth.login", { token: this.token });
    this.reconnectDelay = RECONNECT_MIN_MS;
  }

  private handleSocketClose() {
    console.log("[rpc] socket closed");
    this.ws = null;
    // Reject every in-flight call — they were sent on a dead socket and
    // the server won't respond.
    if (this.pending.size > 0) {
      const dead = this.pending;
      this.pending = new Map();
      for (const p of dead.values()) p.reject(new Error("disconnected"));
    }
    if (this.closed) return;
    this.scheduleReconnect();
  }

  private scheduleReconnect() {
    if (this.reconnectTimer) return;
    const delay = this.reconnectDelay;
    this.reconnectDelay = Math.min(this.reconnectDelay * 2, RECONNECT_MAX_MS);
    this.reconnectTimer = setTimeout(async () => {
      this.reconnectTimer = null;
      if (this.closed) return;
      try {
        await this.openSocket();
      } catch {
        if (!this.closed) this.scheduleReconnect();
        return;
      }
      try { await this.onReconnect?.(); } catch { /* surfaced by caller */ }
    }, delay);
  }

  call<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    if (this.closed) return Promise.reject(new Error("closed"));
    return this.sendCall(method, params) as Promise<T>;
  }

  private sendCall(method: string, params: Record<string, unknown>): Promise<unknown> {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) {
      return Promise.reject(new Error("disconnected"));
    }
    const id = this.nextId++;
    console.log(`[rpc →] #${id} ${method}`, summarize(params));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  on(h: EventHandler): () => void {
    this.handlers.add(h);
    return () => this.handlers.delete(h);
  }

  /** Permanently close. No more reconnects, no more events. */
  close() {
    if (this.closed) return;
    console.log("[rpc] close()");
    this.closed = true;
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.ws?.close();
    this.ws = null;
    this.onClose?.();
  }

  private onMessage(raw: unknown) {
    const text = typeof raw === "string" ? raw : "";
    if (!text) return;
    let msg: { id?: number; method?: string; result?: unknown; error?: { code: number; message: string }; params?: unknown };
    try { msg = JSON.parse(text); } catch { return; }

    if (msg.id != null) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) {
        console.log(`[rpc ←] #${msg.id} error`, msg.error);
        p.reject(new Error(`rpc ${msg.error.code}: ${msg.error.message}`));
      } else {
        console.log(`[rpc ←] #${msg.id} ok`, summarize(msg.result));
        p.resolve(msg.result);
      }
      return;
    }
    if (msg.method) {
      console.log(`[rpc ev] ${msg.method}`, summarize(msg.params));
      logShellEvent(msg.method, msg.params);
      const ev = { method: msg.method, params: msg.params } as Event;
      this.handlers.forEach(h => h(ev));
    }
  }
}

/** Compact log line for shell-integration lifecycle events. The full
 *  `[rpc ev]` log above stays for byte-level debugging; this gives a
 *  filterable `[shell]` channel that strips out the noisy fields and
 *  shows just block lifecycle, in arrival order. Useful for diagnosing
 *  prompt-fallback / off-by-one / state-machine issues without
 *  scrolling through every `pty.output` chunk. */
function logShellEvent(method: string, raw: unknown): void {
  if (!method.startsWith("pty.")) return;
  const sub = method.slice(4);
  // pty.output is too high-frequency to log per-chunk here; everything
  // else is a shell-integration boundary that fires at most once per
  // user action. Resize / write are also skipped (visual / input-only).
  if (sub === "output" || sub === "resize" || sub === "write") return;

  const p = (raw && typeof raw === "object") ? raw as Record<string, unknown> : {};
  const bid = typeof p.block_id === "string"
    ? `block=…${(p.block_id as string).slice(-6)}`
    : "";
  const pty = typeof p.pty_id === "string" ? `pty=${p.pty_id}` : "";
  const seq = typeof p.seq === "number" ? `seq=${p.seq}` : "";
  // Per-event extras worth surfacing inline.
  const extras: string[] = [];
  if (sub === "command_started" && typeof p.text === "string") {
    extras.push(`cmd=${JSON.stringify(p.text)}`);
  }
  if (sub === "command_finished" && p.exit_code !== undefined) {
    extras.push(`exit=${p.exit_code}`);
  }
  if (sub === "shell_bootstrapped" && typeof p.shell === "string") {
    extras.push(`shell=${p.shell}`);
  }
  if (sub === "cwd_changed" && typeof p.cwd === "string") {
    extras.push(`cwd=${p.cwd}`);
  }
  if (sub === "shell_context" && p.ctx && typeof p.ctx === "object") {
    extras.push(`ctx=${JSON.stringify(p.ctx)}`);
  }
  const head = `[shell] ${sub.padEnd(17)}`;
  const fields = [bid, pty, seq, ...extras].filter(Boolean).join(" ");
  console.log(`${head}${fields ? " " + fields : ""}`);
}
