// Collapses the user's theme preference into a concrete light/dark value.
// `system` tracks the browser's prefers-color-scheme live; explicit
// light/dark short-circuit the media query. Modeled on useIsMobile.

import { useEffect, useState } from "react";
import { useApp } from "../store/store";
import type { ResolvedTheme } from "../appearance";

const QUERY = "(prefers-color-scheme: dark)";

function systemPrefersDark(): boolean {
  try { return window.matchMedia(QUERY).matches; } catch { return false; }
}

export function useResolvedTheme(): ResolvedTheme {
  const theme = useApp(s => s.theme);
  const [systemDark, setSystemDark] = useState(systemPrefersDark);

  useEffect(() => {
    if (theme !== "system") return;
    const mq = window.matchMedia(QUERY);
    const cb = () => setSystemDark(mq.matches);
    cb();
    if ("addEventListener" in mq) {
      mq.addEventListener("change", cb);
      return () => mq.removeEventListener("change", cb);
    }
    (mq as unknown as { addListener: (cb: () => void) => void }).addListener(cb);
    return () => {
      (mq as unknown as { removeListener: (cb: () => void) => void }).removeListener(cb);
    };
  }, [theme]);

  if (theme === "light") return "light";
  if (theme === "dark")  return "dark";
  return systemDark ? "dark" : "light";
}

// The theme the UI should actually render in. Inside a session the server
// broadcasts a session-wide theme (set by the focused/driving client) so every
// client looks identical and PTY output colours match the background; outside a
// session we fall back to this device's own preference. Use this for rendering;
// use `useResolvedTheme` for the value this device *pushes* when it's driving.
export function useEffectiveTheme(): ResolvedTheme {
  const sessionTheme = useApp(s => s.sessionTheme);
  const local = useResolvedTheme();
  return sessionTheme ?? local;
}
