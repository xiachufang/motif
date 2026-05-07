import { useEffect, useState } from "react";
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
  const views        = useApp(s => s.views);
  const activeView   = useApp(s => s.activeView);
  const ptyBlocks    = useApp(s => s.ptyBlocks);

  // Active PTY (if any) drives the v2 chips below.
  const activeViewObj = views.find(v => v.id === activeView);
  const activePtyId = activeViewObj?.spec.kind === "pty" ? activeViewObj.spec.pty_id : null;
  const blockUi = activePtyId ? ptyBlocks.get(activePtyId) ?? null : null;

  // The "command finished" flash sticks for ~3s. We tick a clock so the
  // chip removes itself without needing another event.
  const [, force] = useState(0);
  useEffect(() => {
    if (!blockUi || blockUi.running) return;
    const last = blockUi.recent[0];
    if (!last) return;
    const remaining = 3000 - (Date.now() - last.finished_at!);
    if (remaining <= 0) return;
    const t = window.setTimeout(() => force(x => x + 1), remaining + 50);
    return () => window.clearTimeout(t);
  }, [blockUi]);

  const fullPath = currentPath || session?.workdir || "";

  return (
    <div className="topbar">
      <div className="row tight">
        <button className="ghost small" onClick={() => setPage({ kind: "sessions" })}>← sessions</button>
        <strong>{sessionName}</strong>
        <span className="muted small" title={fullPath}>📂 {fullPath}</span>
        {blockUi?.ctx && <ContextChips ctx={blockUi.ctx} />}
        {blockUi && <BlockChip ui={blockUi} />}
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

import type { PtyBlockUi } from "../store/store";
import type { ShellContext } from "../proto/types";

/** Currently-running command, or recently-finished flash. */
function BlockChip({ ui }: { ui: PtyBlockUi }) {
  if (ui.running) {
    return (
      <span className="pill running" title={ui.running.text}>
        ▶ {trim(ui.running.text, 40)}
      </span>
    );
  }
  const last = ui.recent[0];
  if (last && last.finished_at && Date.now() - last.finished_at < 3000) {
    const code = last.exit_code;
    const cls = code === 0 ? "success" : code == null ? "neutral" : "failure";
    const sym = code === 0 ? "✓" : code == null ? "·" : "✗";
    return (
      <span className={"pill " + cls} title={last.cmd}>
        {sym}{code != null ? code : ""} {trim(last.cmd, 40)}
      </span>
    );
  }
  return null;
}

/** git branch / venv chips from the precmd context blob. */
function ContextChips({ ctx }: { ctx: ShellContext }) {
  return (
    <>
      {ctx.branch && <span className="pill" title={ctx.head ? `${ctx.branch} @ ${ctx.head}` : ctx.branch}>⎇ {ctx.branch}</span>}
      {ctx.venv   && <span className="pill" title="Python virtualenv">🐍 {ctx.venv}</span>}
      {ctx.conda  && <span className="pill" title="Conda env">∎ {ctx.conda}</span>}
      {ctx.node   && <span className="pill" title="Node.js">⬢ {ctx.node}</span>}
    </>
  );
}

function trim(s: string, max: number): string {
  return s.length > max ? s.slice(0, max - 1) + "…" : s;
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
