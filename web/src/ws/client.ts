// New-protocol web client. fetch() for /rpc/<method>, WebSocket for
// /events, one WebSocket per open PTY for /pty/<id>. Synthesizes legacy
// `pty.output` events from per-PTY byte streams so existing consumers
// (Workspace.tsx and friends) don't need rewires beyond the new
// connect API.
//
// Auth model:
//   - HTTP requests carry `Authorization: Bearer <browser_token>`.
//   - WS opens carry `?token=<browser_token>` in the URL because the
//     browser WebSocket API can't set headers. motifd accepts the query
//     token using the same server-side token store.
//
// Same-origin assumption: this client targets `location.origin` —
// motifd itself.

import type { Event } from "../proto/types";
import { ShellState, type ShellEvent } from "../shellIntegration";

export type EventHandler = (ev: Event) => void;

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 15_000;

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

function b64encode(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s);
}

export class RpcClient {
  private token: string;
  private sessionID: string | null = null;
  private eventsWs: WebSocket | null = null;
  private ptyWs   = new Map<string, WebSocket>();
  /// Per-PTY shell-integration parser. Drives block-state machine
  /// off shell-integration OSC markers in the /pty/<id> byte stream and
  /// emits the same shape of structured notifications the server
  /// used to push.
  private ptyShell = new Map<string, ShellState>();
  private handlers = new Set<EventHandler>();
  private closed = false;
  private reconnectDelay = RECONNECT_MIN_MS;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  /** Fires after a transparent reconnect of `/events`. Workspace
   *  calls `session.attach` with the last seen seq for replay. */
  public onReconnect: (() => void | Promise<void>) | null = null;
  public onClose:     (() => void) | null = null;

  private constructor(token: string) {
    this.token = token;
  }

  /** Probe the new endpoint by calling `session.list`. The server
   *  rejects unauthenticated bearer; success means the token is
   *  good and the new-protocol routes are wired. */
  static async connect(token: string): Promise<RpcClient> {
    const c = new RpcClient(token);
    await c.httpCall("session.list", {});  // throws on auth failure
    return c;
  }

  /** New shape: routes by method name. */
  call<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    if (this.closed) return Promise.reject(new Error("closed"));
    switch (method) {
      case "session.attach": return this.doAttach<T>(params);
      case "session.detach": return this.doDetach<T>();
      case "pty.write":      return this.doPtyWrite<T>(params);
      case "pty.create":     return this.doPtyCreate<T>(params);
      case "pty.kill":       return this.doPtyKill<T>(params);
      default:               return this.httpCall<T>(method, params);
    }
  }

  on(h: EventHandler): () => void {
    this.handlers.add(h);
    return () => this.handlers.delete(h);
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    if (this.reconnectTimer) { clearTimeout(this.reconnectTimer); this.reconnectTimer = null; }
    this.tearDownEventsAndPty();
    this.onClose?.();
  }

  // ─────────────────────────── method handlers ───────────────────────────

  private async doAttach<T>(params: Record<string, unknown>): Promise<T> {
    const { body, sessionID } = await this.httpCallRaw("session.attach", params);
    if (!sessionID) throw new Error("attach: server didn't return X-Motif-Session");
    this.sessionID = sessionID;
    const result = body ? JSON.parse(new TextDecoder().decode(body)) : null;
    const lastSeq = (result && typeof result === "object" && "last_seq" in result) ? Number(result.last_seq) || 0 : 0;
    await this.openEvents(lastSeq);
    const ptys = (result && typeof result === "object" && Array.isArray((result as Record<string, unknown>).ptys))
      ? ((result as Record<string, unknown>).ptys as Array<Record<string, unknown>>)
      : [];
    for (const p of ptys) {
      const pid = typeof p.id === "string" ? p.id : null;
      if (pid) await this.openPty(pid, /*primary=*/false);
    }
    return result as T;
  }

  private async doDetach<T>(): Promise<T> {
    this.tearDownEventsAndPty();
    const r = await this.httpCall<T>("session.detach", {});
    this.sessionID = null;
    return r;
  }

  private async doPtyWrite<T>(params: Record<string, unknown>): Promise<T> {
    const pid  = typeof params.pty_id === "string" ? params.pty_id : "";
    const dataField = params.data ?? params.data_b64;
    if (!pid) throw new Error("pty.write: missing pty_id");
    await this.ensurePtyOpen(pid);
    let bytes: Uint8Array;
    if (typeof dataField === "string") {
      // already base64 (legacy path)
      const bin = atob(dataField);
      bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    } else if (Array.isArray(dataField)) {
      bytes = new Uint8Array(dataField as number[]);
    } else if (dataField instanceof Uint8Array) {
      bytes = dataField;
    } else {
      throw new Error("pty.write: data/data_b64 must be string|number[]|Uint8Array");
    }
    const ws = this.ptyWs.get(pid);
    if (!ws || ws.readyState !== WebSocket.OPEN) throw new Error(`pty.write: WS not open for ${pid}`);
    // Forward a fresh ArrayBuffer slice; ws.send wants ArrayBuffer-y
    // shapes and the TS types don't accept a Uint8Array view of
    // SharedArrayBuffer without a copy.
    ws.send(bytes.slice().buffer);
    return ({} as T);
  }

  private async doPtyCreate<T>(params: Record<string, unknown>): Promise<T> {
    const body = await this.httpCall<Record<string, unknown>>("pty.create", params);
    const info = (body && typeof body === "object" && (body as Record<string, unknown>).info) as Record<string, unknown> | undefined;
    const pid  = info && typeof info.id === "string" ? info.id : null;
    if (pid) await this.openPty(pid, /*primary=*/true);
    return body as T;
  }

  private async doPtyKill<T>(params: Record<string, unknown>): Promise<T> {
    const pid = typeof params.pty_id === "string" ? params.pty_id : "";
    const body = await this.httpCall<T>("pty.kill", params);
    const ws = this.ptyWs.get(pid);
    if (ws) { try { ws.close(); } catch {} this.ptyWs.delete(pid); }
    return body;
  }

  // ─────────────────────────── HTTP plumbing ───────────────────────────

  private async httpCall<T = unknown>(method: string, params: Record<string, unknown>): Promise<T> {
    const { body } = await this.httpCallRaw(method, params);
    if (!body || body.byteLength === 0) return (null as T);
    return JSON.parse(new TextDecoder().decode(body)) as T;
  }

  private async httpCallRaw(method: string, params: Record<string, unknown>): Promise<{ body: ArrayBuffer; sessionID: string | null }> {
    const url = `${location.origin}/rpc/${encodeURIComponent(method)}`;
    const headers: Record<string, string> = {
      "Authorization": `Bearer ${this.token}`,
      "Content-Type":  "application/json",
    };
    if (this.sessionID) headers["X-Motif-Session"] = this.sessionID;
    const t0 = performance.now();
    console.log(`[rpc →] ${method}`, summarize(params));
    const resp = await fetch(url, {
      method:  "POST",
      headers,
      body:    JSON.stringify(params),
    });
    const buf = await resp.arrayBuffer();
    console.log(`[rpc ←] ${method} status=${resp.status} ${Math.round(performance.now() - t0)}ms ${buf.byteLength}B`);
    if (!resp.ok) {
      try {
        const err = JSON.parse(new TextDecoder().decode(buf));
        throw new Error(`rpc ${err.code}: ${err.message}`);
      } catch (e) {
        if (e instanceof Error && /^rpc /.test(e.message)) throw e;
        throw new Error(`HTTP ${resp.status}`);
      }
    }
    return { body: buf, sessionID: resp.headers.get("x-motif-session") };
  }

  // ─────────────────────────── /events ───────────────────────────

  private async openEvents(since: number): Promise<void> {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const url = `${proto}://${location.host}/events?session=${encodeURIComponent(this.sessionID ?? "")}&since=${since}&token=${encodeURIComponent(this.token)}`;
    const ws = new WebSocket(url);
    await new Promise<void>((res, rej) => {
      ws.addEventListener("open",  () => res(),                                    { once: true });
      ws.addEventListener("error", () => rej(new Error("/events open failed")),    { once: true });
    });
    this.eventsWs = ws;
    ws.addEventListener("message", e => this.onEventsMessage(e.data));
    ws.addEventListener("close",   () => this.handleEventsClose());
    this.reconnectDelay = RECONNECT_MIN_MS;
  }

  private onEventsMessage(raw: unknown) {
    const text = typeof raw === "string" ? raw : "";
    if (!text) return;
    let parsed: { method?: string; params?: unknown };
    try { parsed = JSON.parse(text); } catch { return; }
    if (!parsed.method) return;
    const ev = { method: parsed.method, params: parsed.params } as Event;
    this.handlers.forEach(h => h(ev));
  }

  private handleEventsClose() {
    this.eventsWs = null;
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
      if (!this.sessionID) return;
      try {
        await this.openEvents(0);
      } catch {
        if (!this.closed) this.scheduleReconnect();
        return;
      }
      try { await this.onReconnect?.(); } catch {}
    }, delay);
  }

  // ─────────────────────────── /pty/<id> ───────────────────────────

  private async ensurePtyOpen(pid: string): Promise<void> {
    if (this.ptyWs.has(pid)) return;
    await this.openPty(pid, /*primary=*/false);
  }

  private async openPty(pid: string, primary: boolean): Promise<void> {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const url = `${proto}://${location.host}/pty/${encodeURIComponent(pid)}?session=${encodeURIComponent(this.sessionID ?? "")}&since=0&primary=${primary ? 1 : 0}&token=${encodeURIComponent(this.token)}`;
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    await new Promise<void>((res, rej) => {
      ws.addEventListener("open",  () => res(),                                              { once: true });
      ws.addEventListener("error", () => rej(new Error(`/pty/${pid} open failed`)),          { once: true });
    });
    this.ptyWs.set(pid, ws);
    this.ptyShell.set(pid, new ShellState());
    ws.addEventListener("message", e => this.onPtyMessage(pid, e.data));
    ws.addEventListener("close",   () => this.handlePtyClose(pid));
  }

  private onPtyMessage(pid: string, raw: unknown) {
    let bytes: Uint8Array;
    if (raw instanceof ArrayBuffer) {
      bytes = new Uint8Array(raw);
    } else if (typeof raw === "string") {
      bytes = new TextEncoder().encode(raw);
    } else {
      return;
    }
    const shell = this.ptyShell.get(pid);
    if (!shell) return;
    const { passthrough, events } = shell.feed(bytes);
    if (passthrough.length > 0) {
      const out = {
        method: "pty.output",
        params: {
          pty_id:   pid,
          data_b64: b64encode(passthrough),
          block_id: shell.activeBlockID,
          scope:    shell.activeScope,
          seq:      0,
        },
      } as unknown as Event;
      this.handlers.forEach(h => h(out));
    }
    for (const ev of events) {
      const wire = shellEventToNotification(pid, ev);
      this.handlers.forEach(h => h(wire));
    }
  }

  private handlePtyClose(pid: string) {
    const shell = this.ptyShell.get(pid);
    if (shell) {
      const tail = shell.onClose();
      if (tail) {
        const wire = shellEventToNotification(pid, tail);
        this.handlers.forEach(h => h(wire));
      }
    }
    this.ptyShell.delete(pid);
    this.ptyWs.delete(pid);
    const ev = {
      method: "pty.ws.closed",
      params: { pty_id: pid },
    } as unknown as Event;
    this.handlers.forEach(h => h(ev));
  }

  private tearDownEventsAndPty() {
    try { this.eventsWs?.close(); } catch {}
    this.eventsWs = null;
    for (const [, ws] of this.ptyWs) { try { ws.close(); } catch {} }
    this.ptyWs.clear();
    this.ptyShell.clear();
  }
}

/// Translate a high-level `ShellEvent` into the legacy `Event` JSON-RPC
/// notification shape so existing consumers (Workspace.tsx etc.) keep
/// processing them unchanged.
function shellEventToNotification(pid: string, ev: ShellEvent): Event {
  switch (ev.kind) {
    case "bootstrapped":
      return { method: "pty.shell_bootstrapped", params: { pty_id: pid, shell: ev.shell, seq: 0 } } as unknown as Event;
    case "promptStarted":
      return { method: "pty.prompt_started", params: { pty_id: pid, block_id: ev.blockID, seq: 0 } } as unknown as Event;
    case "promptEnded":
      return { method: "pty.prompt_ended", params: { pty_id: pid, block_id: ev.blockID, seq: 0 } } as unknown as Event;
    case "commandStarted":
      return { method: "pty.command_started", params: {
        pty_id: pid, block_id: ev.blockID, text: ev.text, cwd: ev.cwd, started_at: ev.startedAt, seq: 0,
      } } as unknown as Event;
    case "commandFinished":
      return { method: "pty.command_finished", params: {
        pty_id: pid, block_id: ev.blockID, exit_code: ev.exitCode, finished_at: ev.finishedAt, seq: 0,
      } } as unknown as Event;
    case "shellContext":
      return { method: "pty.shell_context", params: { pty_id: pid, ctx: ev.ctx, seq: 0 } } as unknown as Event;
    case "cwdChanged":
      return { method: "pty.cwd_changed", params: { pty_id: pid, cwd: ev.cwd, seq: 0 } } as unknown as Event;
  }
}
