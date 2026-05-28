import { useState } from "react";
import { useApp } from "../store/store";
import SettingsSheet from "./SettingsSheet";

interface Toggle { visible: boolean; toggle: () => void }

interface Props {
  sessionName: string;
  fileTree?:   Toggle;
  gitStatus?:  Toggle;
  mobileDock?: Toggle;
}

export default function Topbar({ sessionName, fileTree, gitStatus, mobileDock }: Props) {
  const others       = useApp(s => s.otherClients);
  const setPage      = useApp(s => s.setPage);
  const session      = useApp(s => s.session);
  const currentPath  = useApp(s => s.currentPath);
  const [settingsOpen, setSettingsOpen] = useState(false);

  const fullPath = currentPath || session?.workdir || "";

  return (
    <div className="topbar">
      <div className="row tight">
        <button className="ghost small" onClick={() => setPage({ kind: "sessions" })}>← sessions</button>
        <strong>{sessionName}</strong>
        <span className="muted small topbar-path" title={fullPath}>{fullPath}</span>
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
        {mobileDock && (
          <ToggleButton
            visible={mobileDock.visible}
            onClick={mobileDock.toggle}
            title={mobileDock.visible ? "Hide mobile input dock" : "Show mobile input dock"}
            label="⌨"
          />
        )}
        <button
          className="ghost small panel-toggle"
          onClick={() => setSettingsOpen(true)}
          title="Settings"
          aria-label="Settings"
        >⚙</button>
        <span className="pill">{others.length + 1} client{others.length === 0 ? "" : "s"}</span>
      </div>
      {settingsOpen && <SettingsSheet onClose={() => setSettingsOpen(false)} />}
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
