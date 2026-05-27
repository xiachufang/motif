import { useEffect, useRef, useState } from "react";
import { useApp } from "../store/store";
import { RpcClient } from "../ws/client";

function isRunningNative(): boolean {
  const w = window as unknown as { motifNative?: { isNative?: boolean } };
  return w.motifNative?.isNative === true;
}

export default function Login() {
  const setClient  = useApp(s => s.setClient);
  const setPage    = useApp(s => s.setPage);
  const setToken   = useApp(s => s.setToken);
  const initial    = useApp(s => s.token);
  const [token,    setT]      = useState(initial ?? "");
  const [remember, setR]      = useState(true);
  const [busy,     setBusy]   = useState(false);
  const [err,      setErr]    = useState<string | null>(null);
  const autoTried = useRef(false);
  const native = isRunningNative();

  async function connect(rawToken: string, persist: boolean) {
    // On native, the local proxy injects Authorization on the WS upgrade,
    // so the JS-side token is unused. Connect with an empty placeholder
    // and skip the persist step.
    const nextToken = native ? "" : rawToken.trim();
    setBusy(true); setErr(null);
    try {
      const c = await RpcClient.connect(nextToken);
      if (persist && !native) {
        const storage = remember ? localStorage : sessionStorage;
        localStorage.removeItem("motif.token");
        sessionStorage.removeItem("motif.token");
        storage.setItem("motif.token", nextToken);
      }
      setToken(nextToken);
      setClient(c);
      c.onClose = () => {
        setClient(null);
        setPage({ kind: "login" });
      };
      setPage({ kind: "sessions" });
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    if (autoTried.current) return;
    if (native) {
      autoTried.current = true;
      connect("", false);
      return;
    }
    if (initial === null) return;
    autoTried.current = true;
    connect(initial, false);
    // `connect` intentionally closes over the current store setters.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [initial, native]);

  if (native) {
    // Hosted inside the iOS App: there's no token to type in here. Just
    // show a connecting state while the auto-connect above runs (or an
    // error if it fell over).
    return (
      <div className="centered">
        <div className="card login">
          <h1>motif</h1>
          <p className="muted">
            {busy ? "connecting…" : err ? "" : "ready"}
          </p>
          {err && <div className="error">{err}</div>}
        </div>
      </div>
    );
  }

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    await connect(token, true);
  }

  return (
    <div className="centered">
      <form onSubmit={submit} className="card login">
        <h1>motif</h1>
        <p className="muted">Enter the token configured on your motifd server, or leave it blank when auth is disabled.</p>
        <input
          type="password"
          value={token}
          onChange={e => setT(e.target.value)}
          placeholder="token (optional)"
          autoFocus
          disabled={busy}
        />
        <label className="row">
          <input type="checkbox" checked={remember} onChange={e => setR(e.target.checked)} />
          remember on this device
        </label>
        <button type="submit" disabled={busy}>
          {busy ? "connecting…" : "Connect"}
        </button>
        {err && <div className="error">{err}</div>}
      </form>
    </div>
  );
}
