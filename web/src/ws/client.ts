// New-protocol web client. fetch() for /rpc/<method>, WebSocket for
// /events, one WebSocket per open PTY for /pty/<id>. Synthesizes legacy
// `pty.output` events from per-PTY byte streams so existing consumers
// (Workspace.tsx and friends) don't need rewires beyond the new
// connect API.
//
// Auth model:
//   - If a browser token is present, HTTP requests carry
//     `Authorization: Bearer <browser_token>`.
//   - If a browser token is present, WS opens carry `?token=<browser_token>`
//     because the browser WebSocket API can't set headers. motifd accepts the
//     query token using the same server-side token store.
//   - Empty token means the user is connecting to a no-auth motifd.
//
// Same-origin assumption: this client targets `location.origin` —
// motifd itself.

import type { Event } from "../proto/types";
import { ShellState, type ShellEvent } from "../shellIntegration";

export type EventHandler = (ev: Event) => void;

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 15_000;

function normalizeToken(token: string): string | null {
  const t = token.trim();
  return t ? t : null;
}

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
  private token: string | null;
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
  /// Serializes session.attach / session.detach so a mount → unmount →
  /// mount cycle (React StrictMode in dev) can't run two attaches
  /// concurrently. Without this, attach #1's HTTP could land *after* the
  /// cleanup's detach, opening a second /events + /pty WS set that
  /// double-delivers every PTY byte alongside attach #2's sockets —
  /// presenting as duplicated prompts and double-echoed input.
  private attachQueue: Promise<unknown> = Promise.resolve();
  /** Fires after a transparent reconnect of `/events`. Workspace
   *  calls `session.attach` with the last seen seq for replay. */
  public onReconnect: (() => void | Promise<void>) | null = null;
  public onClose:     (() => void) | null = null;

  private constructor(token: string) {
    this.token = normalizeToken(token);
  }

  /** Probe the new endpoint by calling `session.list`. The server
   *  rejects missing/invalid auth when auth is enabled; success means
   *  the token choice is accepted and the new-protocol routes are wired. */
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

  /// Queue `fn` after every prior attach/detach. Order is preserved even
  /// across rejections — a failed attach must not let the next detach
  /// jump it in line, or the detach would tear down sockets that
  /// haven't been opened yet.
  private serializeAttach<T>(fn: () => Promise<T>): Promise<T> {
    const result = this.attachQueue.then(fn, fn);
    this.attachQueue = result.catch(() => {});
    return result;
  }

  private doAttach<T>(params: Record<string, unknown>): Promise<T> {
    return this.serializeAttach(async () => {
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
    });
  }

  private doDetach<T>(): Promise<T> {
    return this.serializeAttach(async () => {
      this.tearDownEventsAndPty();
      const r = await this.httpCall<T>("session.detach", {});
      this.sessionID = null;
      return r;
    });
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
      "Content-Type":  "application/json",
    };
    if (this.token) headers["Authorization"] = `Bearer ${this.token}`;
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
    const url = new URL(`${proto}://${location.host}/events`);
    url.searchParams.set("session", this.sessionID ?? "");
    url.searchParams.set("since", String(since));
    if (this.token) url.searchParams.set("token", this.token);
    const ws = new WebSocket(url);
    await new Promise<void>((res, rej) => {
      ws.addEventListener("open",  () => res(),                                    { once: true });
      ws.addEventListener("error", () => rej(new Error("/events open failed")),    { once: true });
    });
    // Swap-then-close. Each WS's message/close handlers compare `this.eventsWs`
    // against their captured `ws`, so the displaced socket sees itself as
    // stale: late messages are dropped, and the intentional close doesn't
    // schedule a reconnect or clobber the new socket. Without this, opening
    // /events twice (reconnect timer racing the post-reconnect re-attach,
    // or any concurrent attach path) leaves the prior onMessage handler
    // dispatching events alongside the new one — same shape of bug as the
    // /pty leak below.
    const prev = this.eventsWs;
    this.eventsWs = ws;
    ws.addEventListener("message", e => {
      if (this.eventsWs !== ws) return;
      this.onEventsMessage(e.data);
    });
    ws.addEventListener("close", () => {
      if (this.eventsWs !== ws) return;
      this.eventsWs = null;
      if (this.closed) return;
      this.scheduleReconnect();
    });
    if (prev) { try { prev.close(); } catch { /* ignore */ } }
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
    const url = new URL(`${proto}://${location.host}/pty/${encodeURIComponent(pid)}`);
    url.searchParams.set("session", this.sessionID ?? "");
    url.searchParams.set("since", "0");
    url.searchParams.set("primary", primary ? "1" : "0");
    if (this.token) url.searchParams.set("token", this.token);
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    await new Promise<void>((res, rej) => {
      ws.addEventListener("open",  () => res(),                                              { once: true });
      ws.addEventListener("error", () => rej(new Error(`/pty/${pid} open failed`)),          { once: true });
    });
    // Swap-then-close. The displaced socket's handlers compare the map entry
    // against their own captured `ws` and bail when displaced — so its late
    // ring-replay frames (and live bytes already in flight) don't get fed
    // into the shell parser and forwarded to `appendOutput` a second time.
    // The previous code overwrote `ptyWs.set(pid, ws)` without closing the
    // prior socket, which under a /events reconnect-induced re-attach left
    // *both* /pty/<id> sockets delivering the full `?since=0` ring replay
    // into xterm — the visible "lss" + duplicated prompts symptom.
    const prev = this.ptyWs.get(pid);
    this.ptyWs.set(pid, ws);
    this.ptyShell.set(pid, new ShellState());
    ws.addEventListener("message", e => {
      if (this.ptyWs.get(pid) !== ws) return;
      this.onPtyMessage(pid, e.data);
    });
    ws.addEventListener("close", () => {
      if (this.ptyWs.get(pid) !== ws) return;
      this.handlePtyClose(pid);
    });
    if (prev) { try { prev.close(); } catch { /* ignore */ } }
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
    // Clear the maps before calling close(). The ownership-aware close
    // handlers in openEvents/openPty bail when the map slot no longer
    // points at their captured `ws`; nulling first makes that check
    // succeed unconditionally — the close is intentional and must not
    // schedule a reconnect or emit a stale pty.ws.closed event.
    const eventsWs = this.eventsWs;
    const ptyWses = Array.from(this.ptyWs.values());
    this.eventsWs = null;
    this.ptyWs.clear();
    this.ptyShell.clear();
    try { eventsWs?.close(); } catch { /* ignore */ }
    for (const ws of ptyWses) { try { ws.close(); } catch { /* ignore */ } }
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
