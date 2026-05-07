// Image tab: fetch the blob through the bridge HTTP wrapper (with Bearer auth),
// then render via an Object URL. Bypassing <img src> directly because browsers
// don't attach the Authorization header to image requests.

import { useEffect, useState } from "react";
import { useApp } from "../store/store";

interface Props {
  transferId: string;
  mime:       string;
}

export default function ImageTab({ transferId }: Props) {
  const token = useApp(s => s.token) ?? "";
  const [src, setSrc] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let revoke: string | null = null;
    let cancelled = false;
    fetch(`/blob/${transferId}`, { headers: { Authorization: `Bearer ${token}` } })
      .then(async r => {
        if (!r.ok) throw new Error(`${r.status} ${r.statusText}`);
        return r.blob();
      })
      .then(b => {
        if (cancelled) return;
        revoke = URL.createObjectURL(b);
        setSrc(revoke);
      })
      .catch(e => { if (!cancelled) setErr(e instanceof Error ? e.message : String(e)); });
    return () => {
      cancelled = true;
      if (revoke) URL.revokeObjectURL(revoke);
    };
  }, [transferId, token]);

  if (err) return <div className="error">image load failed: {err}</div>;
  if (!src) return <div className="muted center">loading…</div>;
  return (
    <div className="image-tab">
      <img src={src} alt="" />
    </div>
  );
}
