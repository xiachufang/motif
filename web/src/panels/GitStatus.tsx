import { memo, useCallback, useEffect, useMemo, useState } from "react";
import type { GitFile, GitFileStatus } from "../proto/types";
import { useApp } from "../store/store";

interface Props {
  onOpenDiff:     () => void;
  onOpenFileDiff: (path: string) => void;
}

const SHORT: Record<GitFileStatus, string> = {
  unmodified: ".", modified: "M", added: "A", deleted: "D", renamed: "R",
  copied: "C", untracked: "?", ignored: "!", conflicted: "U",
};

type Mode = "list" | "tree";
const LS_MODE = "motif.gitstatus.filemode";

function loadMode(): Mode {
  try {
    const v = localStorage.getItem(LS_MODE);
    if (v === "list" || v === "tree") return v;
  } catch { /* ignore */ }
  return "list";
}
function saveMode(m: Mode) {
  try { localStorage.setItem(LS_MODE, m); } catch { /* ignore */ }
}

export default function GitStatus({ onOpenDiff, onOpenFileDiff }: Props) {
  const branch = useApp(s => s.gitBranch);
  const files  = useApp(s => s.gitFiles);

  const [mode, setMode] = useState<Mode>(loadMode);
  useEffect(() => saveMode(mode), [mode]);

  const tree    = useMemo(() => buildTree(files), [files]);
  const dirPaths = useMemo(() => collectDirPaths(tree), [tree]);
  // Track *collapsed* directories rather than expanded ones. Default = empty
  // = everything expanded. This way an external `git.changed` (which arrives
  // often in dev) refreshing `files` cannot undo a user click.
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const toggleDir = useCallback((path: string) => {
    setCollapsed(prev => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path); else next.add(path);
      return next;
    });
  }, []);
  const expandAll   = useCallback(() => setCollapsed(new Set()), []);
  const collapseAll = useCallback(() => setCollapsed(new Set(dirPaths)), [dirPaths]);

  return (
    <section className="git-status">
      <h3 className="row tight">
        git
        <span className="muted small">{branch ?? "(not a repo)"}</span>
        <button className="ghost small" onClick={onOpenDiff}>view diff</button>
        {mode === "tree" && dirPaths.length > 0 && (
          collapsed.size === 0 ? (
            <button
              className="ghost small icon-btn"
              onClick={collapseAll}
              title="Collapse all"
              aria-label="Collapse all"
            >▸▸</button>
          ) : (
            <button
              className="ghost small icon-btn"
              onClick={expandAll}
              title="Expand all"
              aria-label="Expand all"
            >▾▾</button>
          )
        )}
        <div className="seg seg-tiny" role="group" aria-label="File list view">
          <button
            className={mode === "list" ? "on" : ""}
            onClick={() => setMode("list")}
            title="Flat list"
          >List</button>
          <button
            className={mode === "tree" ? "on" : ""}
            onClick={() => setMode("tree")}
            title="Directory tree"
          >Tree</button>
        </div>
      </h3>
      {files.length === 0 ? (
        <ul><li className="muted">(clean)</li></ul>
      ) : mode === "list" ? (
        <FlatList files={files} onOpen={onOpenFileDiff} />
      ) : (
        <TreeView
          root={tree}
          collapsed={collapsed}
          onToggleDir={toggleDir}
          onOpen={onOpenFileDiff}
        />
      )}
    </section>
  );
}

const FlatList = memo(function FlatList({
  files, onOpen,
}: { files: GitFile[]; onOpen: (path: string) => void }) {
  return (
    <ul>
      {files.map(f => {
        // Trailing "/" = git status collapsed a whole untracked directory.
        // We don't open a directory-wide diff on click — leave the row as a
        // disabled marker until motifd restarts with --untracked-files=all,
        // after which entries will be individual files.
        const isDir = f.path.endsWith("/");
        return (
          <li
            key={f.path}
            className={isDir ? "git-dir" : "git-file"}
            onClick={isDir ? undefined : () => onOpen(f.path)}
            title={`${SHORT[f.staged]}${SHORT[f.unstaged]} ${f.path}`}
          >
            <span className="status-glyph">{SHORT[f.staged]}{SHORT[f.unstaged]}</span>{" "}
            {f.path}
          </li>
        );
      })}
    </ul>
  );
});

// ── tree ────────────────────────────────────────────────────────────────

interface FileNode { kind: "file"; file: GitFile }
interface DirNode  { kind: "dir";  name: string; path: string; children: TreeNode[] }
type     TreeNode  = FileNode | DirNode;

function buildTree(files: GitFile[]): DirNode {
  const root: DirNode = { kind: "dir", name: "", path: "", children: [] };
  for (const f of files) {
    // A trailing "/" means git status reported a whole untracked directory
    // (porcelain without --untracked-files=all). Treat it as a leaf directory
    // node so the row is expand/collapse rather than a file click.
    const isDirEntry = f.path.endsWith("/");
    const segments = f.path.split("/").filter(Boolean);
    if (segments.length === 0) {
      root.children.push({ kind: "file", file: f });
      continue;
    }
    let cursor = root;
    const lastIdx = isDirEntry ? segments.length : segments.length - 1;
    for (let i = 0; i < lastIdx; i++) {
      const seg = segments[i];
      const dirPath = cursor.path ? `${cursor.path}/${seg}` : seg;
      let next = cursor.children.find(
        c => c.kind === "dir" && c.name === seg,
      ) as DirNode | undefined;
      if (!next) {
        next = { kind: "dir", name: seg, path: dirPath, children: [] };
        cursor.children.push(next);
      }
      cursor = next;
    }
    if (!isDirEntry) cursor.children.push({ kind: "file", file: f });
  }
  compactDirs(root);
  sortTree(root);
  return root;
}

function compactDirs(node: DirNode) {
  for (const child of node.children) {
    if (child.kind === "dir") compactDirs(child);
  }
  if (node.path === "") return;
  while (node.children.length === 1 && node.children[0].kind === "dir") {
    const only = node.children[0];
    node.name     = `${node.name}/${only.name}`;
    node.path     = only.path;
    node.children = only.children;
  }
}

function sortTree(node: DirNode) {
  node.children.sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === "dir" ? -1 : 1;
    const an = a.kind === "dir" ? a.name : a.file.path;
    const bn = b.kind === "dir" ? b.name : b.file.path;
    return an.localeCompare(bn);
  });
  for (const c of node.children) {
    if (c.kind === "dir") sortTree(c);
  }
}

function collectDirPaths(node: DirNode): string[] {
  const out: string[] = [];
  function walk(n: DirNode) {
    if (n.path) out.push(n.path);
    for (const c of n.children) if (c.kind === "dir") walk(c);
  }
  walk(node);
  return out;
}

function basename(p: string): string {
  const i = p.lastIndexOf("/");
  return i < 0 ? p : p.slice(i + 1);
}

const TreeView = memo(function TreeView({
  root, collapsed, onToggleDir, onOpen,
}: {
  root:        DirNode;
  collapsed:   Set<string>;
  onToggleDir: (path: string) => void;
  onOpen:      (path: string) => void;
}) {
  function renderNodes(nodes: TreeNode[], depth: number): React.ReactNode {
    return nodes.map(n => {
      if (n.kind === "dir") {
        const open = !collapsed.has(n.path);
        return (
          <div key={"d:" + n.path}>
            <div
              className="row-tree dir"
              style={{ paddingLeft: `${depth * 0.9 + 0.2}em` }}
              onClick={() => onToggleDir(n.path)}
              title={n.path}
            >
              <span className="chevron">{open ? "▾" : "▸"}</span>
              <span>{n.name}/</span>
            </div>
            {open && renderNodes(n.children, depth + 1)}
          </div>
        );
      }
      const f = n.file;
      return (
        <div
          key={"f:" + f.path}
          className="row-tree file git-file"
          style={{ paddingLeft: `${depth * 0.9 + 0.2}em` }}
          onClick={() => onOpen(f.path)}
          title={`${SHORT[f.staged]}${SHORT[f.unstaged]} ${f.path}`}
        >
          <span className="status-glyph">{SHORT[f.staged]}{SHORT[f.unstaged]}</span>{" "}
          <span className="git-file-name">{basename(f.path)}</span>
        </div>
      );
    });
  }
  return <div className="git-tree">{renderNodes(root.children, 0)}</div>;
});
