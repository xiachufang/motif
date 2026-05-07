import Login     from "./pages/Login";
import Sessions  from "./pages/Sessions";
import Workspace from "./pages/Workspace";
import { useApp } from "./store/store";

export default function App() {
  const page = useApp(s => s.page);
  if (page.kind === "login")     return <Login />;
  if (page.kind === "sessions")  return <Sessions />;
  if (page.kind === "workspace") return <Workspace sessionName={page.sessionName} />;
  return null;
}
