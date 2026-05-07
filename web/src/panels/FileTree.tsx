// Recursive collapsible file tree.
//
// The tree is rooted at the active PTY's cwd (== `currentPath` in the store,
// always an absolute path) and follows that PTY's cwd as it changes. Clicking
// a directory toggles in-place expansion — it does NOT re-root the tree. The
// first expand of a given directory triggers a lazy `fs.tree` fetch via the
// parent; the store `dirChildren` map is keyed by absolute paths.

import type { TreeEntry } from "../proto/types";
import { useApp } from "../store/store";

interface Props {
  onOpen:    (path: string) => void;
  onExpand:  (path: string) => void;     // ensure children loaded
}

function joinPath(base: string, name: string): string {
  if (!base) return name;
  return base.endsWith("/") ? `${base}${name}` : `${base}/${name}`;
}

function lastSegment(abs: string): string {
  if (!abs || abs === "/") return abs || "/";
  const stripped = abs.replace(/\/+$/, "");
  const idx = stripped.lastIndexOf("/");
  return idx < 0 ? stripped : stripped.slice(idx + 1) || "/";
}

export default function FileTree({ onOpen, onExpand }: Props) {
  const dirChildren = useApp(s => s.dirChildren);
  const expanded    = useApp(s => s.expandedDirs);
  const currentPath = useApp(s => s.currentPath);
  const toggleDir   = useApp(s => s.toggleDir);

  const rootEntries = currentPath ? (dirChildren.get(currentPath) ?? null) : null;

  function handleDirClick(path: string) {
    if (!expanded.has(path)) onExpand(path);
    toggleDir(path);
  }

  function renderEntry(parent: string, e: TreeEntry, depth: number) {
    const path = joinPath(parent, e.name);
    if (e.type === "dir") {
      const open = expanded.has(path);
      const children = dirChildren.get(path);
      return (
        <li key={path}>
          <div
            className="row-tree dir"
            style={{ paddingLeft: `${depth * 0.9 + 0.2}em` }}
            onClick={() => handleDirClick(path)}
          >
            <span className="chevron">{open ? "▾" : "▸"}</span>
            <span>{e.name}/</span>
          </div>
          {open && children && (
            <ul className="subtree">
              {children.map(c => renderEntry(path, c, depth + 1))}
            </ul>
          )}
          {open && !children && (
            <div
              className="row-tree muted small"
              style={{ paddingLeft: `${(depth + 1) * 0.9 + 0.2}em` }}
            >
              loading…
            </div>
          )}
        </li>
      );
    }
    return (
      <li key={path}>
        <div
          className="row-tree file"
          style={{ paddingLeft: `${depth * 0.9 + 1.4}em` }}
          onClick={() => onOpen(path)}
          title={`${e.size} bytes`}
        >
          {e.name}
        </div>
      </li>
    );
  }

  return (
    <section className="file-tree">
      <h3 className="row tight">
        files
        <span className="muted small" title={currentPath}>
          {currentPath ? lastSegment(currentPath) || "/" : "(no cwd)"}
        </span>
      </h3>
      <ul>
        {rootEntries === null && <li className="muted">loading…</li>}
        {rootEntries !== null && rootEntries.length === 0 && <li className="muted">(empty)</li>}
        {rootEntries?.map(c => renderEntry(currentPath, c, 0))}
      </ul>
    </section>
  );
}
