import { useEffect } from "react";
import Login     from "./pages/Login";
import Sessions  from "./pages/Sessions";
import Workspace from "./pages/Workspace";
import { useApp } from "./store/store";
import { useEffectiveTheme } from "./hooks/useResolvedTheme";

export default function App() {
  const page = useApp(s => s.page);

  // Reflect the effective theme on <html> so all CSS (driven by [data-theme]
  // variable overrides) and form controls follow it on every page. Inside a
  // session this is the session-wide theme; otherwise the local preference.
  const resolved = useEffectiveTheme();
  useEffect(() => {
    const el = document.documentElement;
    el.dataset.theme = resolved;
    el.style.colorScheme = resolved;
  }, [resolved]);

  if (page.kind === "login")     return <Login />;
  if (page.kind === "sessions")  return <Sessions />;
  if (page.kind === "workspace") return <Workspace sessionName={page.sessionName} />;
  return null;
}
