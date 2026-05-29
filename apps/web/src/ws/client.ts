// New-protocol web client. fetch() for /rpc/<method>, WebSocket for
// /events, one active WebSocket for /pty/<id>. Synthesizes legacy
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

import { PING_SERVICE, type Event, type PingInfo } from "../proto/types";
import { ShellState, type ShellEvent } from "../shellIntegration";

export type EventHandler = (ev: Event) => void;

/// Carries the HTTP status alongside the error message so callers can
/// branch on 401 (bad/expired token → bounce to login) without parsing
/// the string. Thrown by `httpCall` for any non-2xx response.
export class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = "HttpError";
  }
}

const RECONNECT_MIN_MS = 500;
const RECONNECT_MAX_MS = 15_000;

/// `/ping` HTTP probe timeout — used both at connect for the identity check
/// and by the `/events` liveness watchdog. Tight enough that a hung probe
/// still leaves headroom under the server's 45s IDLE_TIMEOUT.
const PING_PROBE_TIMEOUT_MS = 5_000;
/// How often the `/events` watchdog re-evaluates whether to probe. Matches
/// the server's HEARTBEAT_TICK so the two sides poll at similar granularity.
const WATCHDOG_TICK_MS = 10_000;
/// Silence threshold on `/events` before the watchdog issues a `/ping` probe.
/// Chosen below the server's 45s IDLE_TIMEOUT so we detect a wedged link
/// before the server gives up and closes us.
const IDLE_PROBE_MS = 30_000;

/// `GET /ping` identity probe. Confirms the target is a motif-server (vs.
/// any other HTTP service on the same host/port) and is reachable. Browsers
/// don't surface WebSocket Ping/Pong frames to JS, so this HTTP probe is the
/// only application-visible liveness signal available to the watchdog.
async function pingProbe(timeoutMs: number): Promise<void> {
  const ctrl = new AbortController();
  const t = setTimeout(() => ctrl.abort(), timeoutMs);
  try {
    const resp = await fetch(`${location.origin}/ping`, { signal: ctrl.signal });
    if (!resp.ok) throw new Error(`/ping HTTP ${resp.status}`);
    const info = await resp.json() as PingInfo;
    if (info.service !== PING_SERVICE) {
      throw new Error(`not a motif-server (got service=${JSON.stringify(info.service)})`);
    }
  } finally {
    clearTimeout(t);
  }
}

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
  // Per-PTY absolute byte cursor. History lives on motifd; when a tab becomes
  // active we reconnect `/pty/<id>?since=<cursor>` and motifd replays the
  // missed bytes before switching to live. A PTY with *no* cursor entry has
  // never synced (fresh, or its cursor rolled off motifd's ring): we then
  // connect *without* `since` — a "tail" request. Either way motifd's leading
  // Text meta frame hands us the offset to adopt. See `applyPtyMeta`.
  private ptyCursor = new Map<string, number>();
  // Per-PTY shell-integration parser. This survives inactive-tab WS closes so
  // replay bytes continue the parser state at the same byte cursor.
  private ptyShell = new Map<string, ShellState>();
  private activePtyID: string | null = null;
  private handlers = new Set<EventHandler>();
  private closed = false;
  private reconnectDelay = RECONNECT_MIN_MS;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  /// Wall-clock timestamp of the most recent frame received on `/events`,
  /// refreshed by the message handler. The watchdog compares against this
  /// to decide when to issue a `/ping` probe. Initialized lazily when
  /// `openEvents` succeeds, not at construction time.
  private eventsLastRxAt = 0;
  /// Periodic timer that triggers liveness probes on `/events`. Lives
  /// only while a /events socket is installed; cleared on close,
  /// teardown, or replacement by a fresh `openEvents`.
  private eventsWatchdog: ReturnType<typeof setInterval> | null = null;
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
  /** Fires once each time the `/events` WS drops and we enter reconnect
   *  backoff. Workspace flips `isLive=false` so the mobile dock disables
   *  input and shows "reconnecting…". */
  public onDisconnect: (() => void) | null = null;
  public onClose:     (() => void) | null = null;

  private constructor(token: string) {
    this.token = normalizeToken(token);
  }

  /** Identity probe only. `/ping` is unauthenticated, so this never
   *  validates the token — the first authenticated call (Sessions page's
   *  `session.list`, or `session.attach`) is what surfaces a bad token.
   *  That's deliberate: we don't want a redundant pre-login RPC. */
  static async connect(token: string): Promise<RpcClient> {
    await pingProbe(PING_PROBE_TIMEOUT_MS);
    return new RpcClient(token);
  }

  /** New shape: routes by method name. */
  call<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    if (this.closed) return Promise.reject(new Error("closed"));
    switch (method) {
      case "session.attach": return this.doAttach<T>(params);
      case "session.detach": return this.doDetach<T>();
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
      const result = body ? JSON.parse(new TextDecoder().decode(body)) : null;
      const lastSeq = (result && typeof result === "object" && "last_seq" in result) ? Number(result.last_seq) || 0 : 0;
      const prevSessionID = this.sessionID;
      this.sessionID = sessionID;
      const sessionIDChanged = Boolean(prevSessionID && prevSessionID !== sessionID);
      if (sessionIDChanged) {
        this.closeAllPtyConnections(false);
      }
      await this.openEvents(lastSeq);
      if (this.activePtyID && !this.hasOpenPty(this.activePtyID)) {
        await this.openPty(this.activePtyID);
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

  /// Write raw PTY input (stdin) to a PTY's `/pty/<id>` stream as a binary
  /// frame — the only PTY write path. Best-effort: writes only target a PTY
  /// whose stream is open; a keystroke arriving in the sub-frame window before
  /// the stream connects is dropped (no HTTP fallback).
  writePty(pid: string, bytes: Uint8Array): void {
    const ws = this.ptyWs.get(pid);
    if (ws && ws.readyState === WebSocket.OPEN) {
      // Forward a fresh ArrayBuffer slice; ws.send wants ArrayBuffer-y shapes
      // and the TS types don't accept a Uint8Array view of SharedArrayBuffer
      // without a copy.
      ws.send(bytes.slice().buffer);
    }
  }

  private async doPtyCreate<T>(params: Record<string, unknown>): Promise<T> {
    const body = await this.httpCall<Record<string, unknown>>("pty.create", params);
    return body as T;
  }

  private async doPtyKill<T>(params: Record<string, unknown>): Promise<T> {
    const pid = typeof params.pty_id === "string" ? params.pty_id : "";
    const body = await this.httpCall<T>("pty.kill", params);
    this.closePtyConnection(pid, true);
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
      // Two error-body shapes: the pre-dispatch auth check returns plain
      // text ("missing or invalid Bearer token"), while RPC-layer errors
      // return a JSON envelope. Try JSON first; fall back to the status
      // line. Either way the HttpError preserves `status` for branchable
      // 401 handling.
      let msg = `HTTP ${resp.status}`;
      try {
        const err = JSON.parse(new TextDecoder().decode(buf));
        if (err && typeof err === "object" && "message" in err) {
          msg = `rpc ${(err as { code?: unknown }).code}: ${(err as { message?: unknown }).message}`;
        }
      } catch { /* not JSON — keep "HTTP <status>" */ }
      throw new HttpError(resp.status, msg);
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
    this.eventsLastRxAt = Date.now();
    this.startEventsWatchdog();
    ws.addEventListener("message", e => {
      if (this.eventsWs !== ws) return;
      this.eventsLastRxAt = Date.now();
      this.onEventsMessage(e.data);
    });
    ws.addEventListener("close", () => {
      if (this.eventsWs !== ws) return;
      this.eventsWs = null;
      this.stopEventsWatchdog();
      if (this.closed) return;
      this.scheduleReconnect();
    });
    if (prev) { try { prev.close(); } catch { /* ignore */ } }
    this.reconnectDelay = RECONNECT_MIN_MS;
  }

  // ─────────────────────────── liveness watchdog ───────────────────────────

  /// Start (or restart) the `/events` liveness watchdog. Browsers don't
  /// expose WebSocket Ping/Pong to JS, so a healthy-but-idle `/events`
  /// socket looks identical to a wedged one from here. We close that gap
  /// by issuing an HTTP `/ping` whenever no `/events` frame has arrived in
  /// `IDLE_PROBE_MS`; a probe failure force-closes the WS, which routes
  /// into the existing `scheduleReconnect` path.
  private startEventsWatchdog() {
    this.stopEventsWatchdog();
    this.eventsWatchdog = setInterval(() => {
      void this.eventsWatchdogTick();
    }, WATCHDOG_TICK_MS);
  }

  private stopEventsWatchdog() {
    if (this.eventsWatchdog) {
      clearInterval(this.eventsWatchdog);
      this.eventsWatchdog = null;
    }
  }

  private async eventsWatchdogTick(): Promise<void> {
    if (this.closed) return;
    const ws = this.eventsWs;
    if (!ws) return;
    const idle = Date.now() - this.eventsLastRxAt;
    if (idle <= IDLE_PROBE_MS) return;
    try {
      await pingProbe(PING_PROBE_TIMEOUT_MS);
      // Server alive — /events is just quiet (no events to deliver).
      // Reset the watermark so we don't probe again on the next tick.
      this.eventsLastRxAt = Date.now();
    } catch (e) {
      console.warn(
        `[events] liveness probe failed after ${idle}ms idle:`,
        e instanceof Error ? e.message : String(e),
      );
      // The watchdog awaited across a network roundtrip; bail if the
      // socket has been replaced or torn down in the meantime so we
      // don't close someone else's WS.
      if (this.eventsWs === ws) {
        try { ws.close(); } catch { /* ignore */ }
      }
    }
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
    try { this.onDisconnect?.(); } catch { /* ignore */ }
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

  async activatePtyStream(pid: string): Promise<void> {
    if (this.closed) return;
    if (this.activePtyID !== pid) {
      this.activePtyID = pid;
      for (const id of Array.from(this.ptyWs.keys())) {
        if (id !== pid) this.closePtyConnection(id, false);
      }
    }
    await this.openPty(pid);
  }

  deactivatePtyStream(pid: string): void {
    if (this.activePtyID === pid) this.activePtyID = null;
    this.closePtyConnection(pid, false);
  }

  private async openPty(pid: string): Promise<void> {
    if (!this.sessionID) throw new Error("pty stream: not attached");
    if (this.hasOpenPty(pid)) return;
    const sessionID = this.sessionID;
    // No cursor for this PTY ⇒ "tail" request: omit `since`. With a cursor we
    // resume exactly from it. Either way motifd's first frame is a Text meta
    // frame carrying the absolute offset of the bytes that follow.
    const haveCursor = this.ptyCursor.has(pid);
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const url = new URL(`${proto}://${location.host}/pty/${encodeURIComponent(pid)}`);
    url.searchParams.set("session", sessionID);
    if (haveCursor) url.searchParams.set("since", String(this.ptyCursor.get(pid)!));
    if (this.token) url.searchParams.set("token", this.token);
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    await new Promise<void>((res, rej) => {
      ws.addEventListener("open",  () => res(),                                              { once: true });
      ws.addEventListener("error", () => rej(new Error(`/pty/${pid} open failed`)),          { once: true });
    });
    if (this.closed || this.sessionID !== sessionID || this.activePtyID !== pid) {
      try { ws.close(); } catch { /* ignore */ }
      return;
    }
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
    if (!this.ptyShell.has(pid)) this.ptyShell.set(pid, new ShellState());
    // Every /pty connection leads with a Text meta frame: consume it once to
    // (re)seed the cursor, then treat everything as data bytes.
    let awaitingMeta = true;
    ws.addEventListener("message", e => {
      if (this.ptyWs.get(pid) !== ws) return;
      if (awaitingMeta) {
        awaitingMeta = false;
        if (typeof e.data === "string") { this.applyPtyMeta(pid, e.data); return; }
      }
      this.onPtyMessage(pid, e.data);
    });
    ws.addEventListener("close", e => {
      if (this.ptyWs.get(pid) !== ws) return;
      this.handlePtyClose(pid, e);
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
    // Advance only a cursor the meta frame already seeded — never fabricate a
    // 0-based one, or a dropped/oversized meta frame would leave us resuming
    // from a bogus offset and looping on 4011.
    const cur = this.ptyCursor.get(pid);
    if (cur !== undefined) this.ptyCursor.set(pid, cur + bytes.byteLength);
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

  private handlePtyClose(pid: string, ev: CloseEvent) {
    this.ptyWs.delete(pid);
    if (ev.code === 4011 || ev.code === 4012) {
      // Our byte cursor rolled off motifd's ring (4011) or is ahead of it
      // (4012). Drop the cursor so the reconnect is a tail request — motifd's
      // meta frame re-establishes an exact one — discard the now-misaligned
      // local surface, and reconnect.
      this.ptyCursor.delete(pid);
      this.ptyShell.set(pid, new ShellState());
      this.handlers.forEach(h => h({
        method: "pty.reset",
        params: { pty_id: pid },
      } as unknown as Event));
      if (!this.closed && this.activePtyID === pid) {
        window.setTimeout(() => {
          if (!this.closed && this.activePtyID === pid) {
            this.openPty(pid).catch(() => {});
          }
        }, 250);
      }
      return;
    }
    const shell = this.ptyShell.get(pid);
    if (shell) {
      const tail = shell.onClose();
      if (tail) {
        const wire = shellEventToNotification(pid, tail);
        this.handlers.forEach(h => h(wire));
      }
    }
    const closedEvent = {
      method: "pty.ws.closed",
      params: { pty_id: pid },
    } as unknown as Event;
    this.handlers.forEach(h => h(closedEvent));
  }

  /** Parse the leading Text meta frame motifd sends on every /pty connection
   *  (`{"since":<offset>}`) and adopt the offset as the absolute byte cursor.
   *  From here the cursor is exact, so later reconnects resume incrementally
   *  with `?since=<cursor>` instead of re-fetching the whole ring. */
  private applyPtyMeta(pid: string, raw: string): void {
    try {
      const meta = JSON.parse(raw) as { since?: number };
      if (typeof meta.since === "number" && Number.isSafeInteger(meta.since)) {
        this.ptyCursor.set(pid, meta.since);
      }
    } catch { /* ignore malformed meta */ }
  }

  private closePtyConnection(pid: string, removeState: boolean): void {
    const ws = this.ptyWs.get(pid);
    this.ptyWs.delete(pid);
    try { ws?.close(); } catch { /* ignore */ }
    if (removeState) {
      this.ptyCursor.delete(pid);
      this.ptyShell.delete(pid);
      if (this.activePtyID === pid) this.activePtyID = null;
    }
  }

  private closeAllPtyConnections(removeState: boolean): void {
    for (const pid of Array.from(this.ptyWs.keys())) {
      this.closePtyConnection(pid, removeState);
    }
    if (removeState) {
      this.ptyCursor.clear();
      this.ptyShell.clear();
      this.activePtyID = null;
    }
  }

  private hasOpenPty(pid: string): boolean {
    return this.ptyWs.get(pid)?.readyState === WebSocket.OPEN;
  }

  private tearDownEventsAndPty() {
    // Clear the maps before calling close(). The ownership-aware close
    // handlers in openEvents/openPty bail when the map slot no longer
    // points at their captured `ws`; nulling first makes that check
    // succeed unconditionally — the close is intentional and must not
    // schedule a reconnect or emit a stale pty.ws.closed event.
    const eventsWs = this.eventsWs;
    this.eventsWs = null;
    this.stopEventsWatchdog();
    this.closeAllPtyConnections(true);
    try { eventsWs?.close(); } catch { /* ignore */ }
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
