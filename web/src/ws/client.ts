// JSON-RPC 2.0 over a single WebSocket. Designed for the motif-web bridge:
// the first frame is `auth.login`, the bridge replies with a synthetic
// success, and from then on frames flow transparently to/from motifd.

import type { Event } from "../proto/types";

interface PendingCall {
  resolve: (v: unknown) => void;
  reject:  (e: Error) => void;
}

export type EventHandler = (ev: Event) => void;

export class RpcClient {
  private ws:        WebSocket;
  private nextId   = 1;
  private pending  = new Map<number, PendingCall>();
  private handlers = new Set<EventHandler>();
  private closed   = false;
  public  onClose: (() => void) | null = null;

  constructor(ws: WebSocket) {
    this.ws = ws;
    ws.addEventListener("message", e => this.onMessage(e.data));
    ws.addEventListener("close",   ()  => { this.closed = true; this.onClose?.(); });
    ws.addEventListener("error",   ()  => { /* surface via close */ });
  }

  /** Open a connection, perform auth.login, return a ready RpcClient. */
  static async connect(token: string): Promise<RpcClient> {
    const proto = location.protocol === "https:" ? "wss" : "ws";
    const url   = `${proto}://${location.host}/ws`;
    const ws    = new WebSocket(url);
    await new Promise<void>((res, rej) => {
      ws.addEventListener("open",  () => res(),         { once: true });
      ws.addEventListener("error", () => rej(new Error("connection failed")), { once: true });
    });
    const c = new RpcClient(ws);
    await c.call("auth.login", { token });
    return c;
  }

  call<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    if (this.closed) return Promise.reject(new Error("closed"));
    const id = this.nextId++;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (v: unknown) => void, reject });
      this.ws.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
    });
  }

  on(h: EventHandler): () => void {
    this.handlers.add(h);
    return () => this.handlers.delete(h);
  }

  close() { this.ws.close(); }

  private onMessage(raw: unknown) {
    const text = typeof raw === "string" ? raw : "";
    if (!text) return;
    let msg: { id?: number; method?: string; result?: unknown; error?: { code: number; message: string }; params?: unknown };
    try { msg = JSON.parse(text); } catch { return; }

    if (msg.id != null) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(`rpc ${msg.error.code}: ${msg.error.message}`));
      else           p.resolve(msg.result);
      return;
    }
    if (msg.method) {
      const ev = { method: msg.method, params: msg.params } as Event;
      this.handlers.forEach(h => h(ev));
    }
  }
}
