// Image tab: fetch the blob through the bridge HTTP wrapper (with Bearer auth),
// then render via an Object URL. Bypassing <img src> directly because browsers
// don't attach the Authorization header to image requests.

import { useEffect, useState } from "react";
import { useApp } from "../store/store";
import type { OpenBlobResult } from "../proto/types";

interface Props {
  path: string;
}

export default function ImageTab({ path }: Props) {
  const client = useApp(s => s.client);
  const token = useApp(s => s.token) ?? "";
  const [src, setSrc] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let revoke: string | null = null;
    let cancelled = false;
    const ac = new AbortController();

    setSrc(null);
    setErr(null);

    if (!client) {
      setErr("not connected");
      return () => { cancelled = true; ac.abort(); };
    }

    client.call<OpenBlobResult>("fs.openBlob", { path, mode: "read" })
      .then(r => fetch(r.blob_path, {
        headers: { Authorization: `Bearer ${token}` },
        signal: ac.signal,
      }))
      .then(async r => {
        if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
        return r.blob();
      })
      .then(b => {
        if (cancelled) return;
        revoke = URL.createObjectURL(b);
        setSrc(revoke);
      })
      .catch(e => {
        if (cancelled || (e instanceof DOMException && e.name === "AbortError")) return;
        setErr(e instanceof Error ? e.message : String(e));
      });
    return () => {
      cancelled = true;
      ac.abort();
      if (revoke) URL.revokeObjectURL(revoke);
    };
  }, [client, path, token]);

  if (err) return <div className="error">image load failed: {err}</div>;
  if (!src) return <div className="muted center">loading…</div>;
  return (
    <div className="image-tab">
      <img src={src} alt="" />
    </div>
  );
}
