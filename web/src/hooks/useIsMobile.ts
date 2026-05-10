// Tiny matchMedia hook. Used to switch panels (workspace sidebar, diff
// file pane) from inline-flex columns to slide-in drawers when the
// viewport is too narrow to host them alongside the main content.

import { useEffect, useState } from "react";

const QUERY = "(max-width: 540px)";

function read(): boolean {
  try { return window.matchMedia(QUERY).matches; } catch { return false; }
}

export function useIsMobile(): boolean {
  const [v, setV] = useState(read);
  useEffect(() => {
    const mq = window.matchMedia(QUERY);
    const cb = () => setV(mq.matches);
    // Older Safari uses addListener / removeListener — modern API is
    // addEventListener("change"). Try the modern one first; the legacy
    // path is a no-op on browsers that already removed it.
    if ("addEventListener" in mq) {
      mq.addEventListener("change", cb);
      return () => mq.removeEventListener("change", cb);
    }
    (mq as unknown as { addListener: (cb: () => void) => void }).addListener(cb);
    return () => {
      (mq as unknown as { removeListener: (cb: () => void) => void }).removeListener(cb);
    };
  }, []);
  return v;
}
