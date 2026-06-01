import { useEffect, useRef, useState } from "react";
import type { ListResult, SessionInfo } from "../proto/types";
import { useApp } from "../store/store";
import { HttpError } from "../ws/client";

export default function Sessions() {
  const client    = useApp(s => s.client);
  const setPage   = useApp(s => s.setPage);
  const setToken  = useApp(s => s.setToken);
  const [list,    setList]    = useState<SessionInfo[]>([]);
  const [error,   setError]   = useState<string | null>(null);
  const [name,    setName]    = useState("");
  const [workdir, setWorkdir] = useState("");
  const [busy,    setBusy]    = useState(false);
  // Guard against double auto-create from React StrictMode's mount/remount.
  const autoCreating = useRef(false);

  async function refresh(allowAutoCreate = true) {
    if (!client) return;
    try {
      const r = await client.call<ListResult>("session.list", {});
      if (r.sessions.length === 0 && allowAutoCreate && !autoCreating.current) {
        // Empty list → seed a default "home" session in the user's $HOME.
        // Server expands `~` against $HOME at session.create.
        autoCreating.current = true;
        try {
          await client.call("session.create", { name: "home", workdir: "~/AllSunday/claude-proj/motif" });
        } catch (e) {
          // "already exists" is benign (StrictMode double-fire, race with
          // another client). Anything else surfaces as an error banner but
          // we still re-list so the user sees what's actually there.
          const msg = e instanceof Error ? e.message : String(e);
          if (!msg.toLowerCase().includes("already exists")) {
            setError(`auto-create failed: ${msg}`);
          }
        }
        autoCreating.current = false;
        const r2 = await client.call<ListResult>("session.list", {});
        setList(r2.sessions);
      } else {
        setList(r.sessions);
      }
      setError(null);
    } catch (e) {
      if (e instanceof HttpError && e.status === 401) {
        // Token was rejected (revoked, rotated, or never valid).
        // `connect()` no longer pre-validates auth, so this is the first
        // place we learn — bounce back to login rather than stranding
        // the user on an empty sessions page.
        logout();
        return;
      }
      setError(e instanceof Error ? e.message : String(e));
    }
  }
  useEffect(() => { refresh(); /* eslint-disable-next-line */ }, [client]);

  async function create(e: React.FormEvent) {
    e.preventDefault();
    if (!client || !name.trim() || !workdir.trim()) return;
    setBusy(true);
    try {
      await client.call("session.create", { name: name.trim(), workdir: workdir.trim() });
      setName(""); setWorkdir("");
      refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function destroy(s: SessionInfo) {
    if (!client) return;
    const msg =
      `Destroy session "${s.name}"?\n\n` +
      `This kills every PTY in it and disconnects ` +
      `${s.client_count} attached client${s.client_count === 1 ? "" : "s"}.`;
    if (!window.confirm(msg)) return;
    setBusy(true);
    try {
      await client.call("session.destroy", { name: s.name });
      // Don't auto-create a default home if the user just nuked the only
      // session — they're clearly not done managing the list.
      refresh(false);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  function attach(s: SessionInfo) {
    // Ask for desktop-notification permission here: opening a session is a
    // real user gesture (browsers reject requestPermission outside one), and
    // it's the natural opt-in point. One-shot — only when still undecided.
    if (typeof Notification !== "undefined" && Notification.permission === "default") {
      Notification.requestPermission().catch(() => {});
    }
    setPage({ kind: "workspace", sessionName: s.name });
  }

  function logout() {
    localStorage.removeItem("motif.token");
    sessionStorage.removeItem("motif.token");
    // Clear the in-memory token too; otherwise Login.tsx's auto-connect
    // effect reads the stale store value and re-authenticates against the
    // still-valid server-side token, bouncing the user right back here.
    setToken(null);
    client?.close();
    setPage({ kind: "login" });
  }

  return (
    <div className="centered">
      <div className="card sessions">
        <header>
          <h1>sessions</h1>
          <div className="row">
            <button onClick={() => refresh()}>refresh</button>
            <button onClick={logout} className="ghost">log out</button>
          </div>
        </header>

        {error && <div className="error">{error}</div>}

        <ul className="session-list">
          {list.length === 0 && <li className="muted">(no sessions — create one below)</li>}
          {list.map(s => (
            <li key={s.id} onClick={() => attach(s)}>
              <div className="row tight">
                <strong>{s.name}</strong>
                <span className="pill">{s.client_count} attached</span>
                <button
                  className="ghost small destroy"
                  title="Destroy session (kills all PTYs)"
                  disabled={busy}
                  onClick={e => { e.stopPropagation(); destroy(s); }}
                >
                  ×
                </button>
              </div>
              <div className="muted small session-path" title={s.workdir}>{s.workdir}</div>
              <div className="muted small session-id" title={s.id}>id: {s.id}</div>
            </li>
          ))}
        </ul>

        <form onSubmit={create} className="row create">
          <input value={name} onChange={e => setName(e.target.value)} placeholder="name" />
          <input value={workdir} onChange={e => setWorkdir(e.target.value)} placeholder="absolute workdir" />
          <button type="submit" disabled={busy}>create</button>
        </form>
      </div>
    </div>
  );
}
