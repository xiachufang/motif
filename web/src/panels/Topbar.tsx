import { useApp } from "../store/store";

interface Toggle { visible: boolean; toggle: () => void }

interface Props {
  sessionName: string;
  sidebar?:    Toggle;
  fileTree?:   Toggle;
  gitStatus?:  Toggle;
}

export default function Topbar({ sessionName, sidebar, fileTree, gitStatus }: Props) {
  const others       = useApp(s => s.otherClients);
  const setPage      = useApp(s => s.setPage);
  const session      = useApp(s => s.session);
  const currentPath  = useApp(s => s.currentPath);

  const fullPath = currentPath || session?.workdir || "";

  return (
    <div className="topbar">
      <div className="row tight">
        <button className="ghost small" onClick={() => setPage({ kind: "sessions" })}>← sessions</button>
        <strong>{sessionName}</strong>
        <span className="muted small" title={fullPath}>📂 {fullPath}</span>
      </div>
      <div className="row tight">
        {fileTree && (
          <ToggleButton
            visible={fileTree.visible}
            onClick={fileTree.toggle}
            title={fileTree.visible ? "Hide file tree" : "Show file tree"}
            label="▤"
          />
        )}
        {gitStatus && (
          <ToggleButton
            visible={gitStatus.visible}
            onClick={gitStatus.toggle}
            title={gitStatus.visible ? "Hide git panel" : "Show git panel"}
            label="⎇"
          />
        )}
        {sidebar && (
          <ToggleButton
            visible={sidebar.visible}
            onClick={sidebar.toggle}
            title={sidebar.visible ? "Hide sidebar" : "Show sidebar"}
            label="◧"
          />
        )}
        <span className="pill">{others.length + 1} client{others.length === 0 ? "" : "s"}</span>
      </div>
    </div>
  );
}

function ToggleButton({
  visible, onClick, title, label,
}: { visible: boolean; onClick: () => void; title: string; label: string }) {
  return (
    <button
      className={"ghost small panel-toggle " + (visible ? "on" : "off")}
      onClick={onClick}
      title={title}
      aria-pressed={visible}
    >
      {label}
    </button>
  );
}
