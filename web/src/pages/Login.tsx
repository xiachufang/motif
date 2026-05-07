import { useState } from "react";
import { useApp } from "../store/store";
import { RpcClient } from "../ws/client";

export default function Login() {
  const setClient  = useApp(s => s.setClient);
  const setPage    = useApp(s => s.setPage);
  const setToken   = useApp(s => s.setToken);
  const initial    = useApp(s => s.token);
  const [token,    setT]      = useState(initial ?? "");
  const [remember, setR]      = useState(true);
  const [busy,     setBusy]   = useState(false);
  const [err,      setErr]    = useState<string | null>(null);

  async function submit(e: React.FormEvent) {
    e.preventDefault();
    if (!token.trim()) return;
    setBusy(true); setErr(null);
    try {
      const c = await RpcClient.connect(token.trim());
      const storage = remember ? localStorage : sessionStorage;
      storage.setItem("motif.token", token.trim());
      setToken(token.trim());
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

  return (
    <div className="centered">
      <form onSubmit={submit} className="card login">
        <h1>motif</h1>
        <p className="muted">Sign in with the token configured on your motif-web bridge.</p>
        <input
          type="password"
          value={token}
          onChange={e => setT(e.target.value)}
          placeholder="paste token"
          autoFocus
          disabled={busy}
        />
        <label className="row">
          <input type="checkbox" checked={remember} onChange={e => setR(e.target.checked)} />
          remember on this device
        </label>
        <button type="submit" disabled={busy || !token.trim()}>
          {busy ? "connecting…" : "Connect"}
        </button>
        {err && <div className="error">{err}</div>}
      </form>
    </div>
  );
}
