// Recursive collapsible file tree.
//
// The tree is rooted at the active PTY's cwd (== `currentPath` in the store,
// always an absolute path) and follows that PTY's cwd as it changes. Clicking
// a directory toggles in-place expansion — it does NOT re-root the tree. The
// first expand of a given directory triggers a lazy `fs.tree` fetch via the
// parent; the store `dirChildren` map is keyed by absolute paths.

import { useMemo } from "react";
import type { GitFile, GitFileStatus, TreeEntry } from "../proto/types";
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

const SHORT: Record<GitFileStatus, string> = {
  unmodified: "", modified: "M", added: "A", deleted: "D", renamed: "R",
  copied: "C", untracked: "?", ignored: "!", conflicted: "U",
};

const RANK: Record<GitFileStatus, number> = {
  unmodified: 0,
  ignored: 1,
  untracked: 2,
  copied: 3,
  renamed: 4,
  added: 5,
  modified: 6,
  deleted: 7,
  conflicted: 8,
};

function strongest(a: GitFileStatus | null | undefined, b: GitFileStatus): GitFileStatus {
  if (!a) return b;
  return RANK[b] > RANK[a] ? b : a;
}

function fileStatus(f: GitFile): GitFileStatus | null {
  if (f.unstaged !== "unmodified") return f.unstaged;
  if (f.staged   !== "unmodified") return f.staged;
  return null;
}

function normalizePath(path: string): string {
  const absolute = path.startsWith("/");
  const parts: string[] = [];
  for (const part of path.split("/")) {
    if (!part || part === ".") continue;
    if (part === "..") {
      if (parts.length > 0) parts.pop();
      else if (!absolute) parts.push(part);
    } else {
      parts.push(part);
    }
  }
  const normalized = parts.join("/");
  return absolute ? `/${normalized}` : normalized;
}

function dirname(path: string): string {
  const p = normalizePath(path).replace(/\/+$/, "");
  if (!p || p === "/") return "/";
  const i = p.lastIndexOf("/");
  return i <= 0 ? "/" : p.slice(0, i);
}

function isInside(path: string, root: string): boolean {
  const p = normalizePath(path);
  const r = normalizePath(root).replace(/\/+$/, "") || "/";
  return p === r || p.startsWith(r.endsWith("/") ? r : `${r}/`);
}

function statusMapFor(root: string, files: GitFile[]): Map<string, GitFileStatus> {
  const out = new Map<string, GitFileStatus>();
  if (!root) return out;

  const merge = (path: string, status: GitFileStatus) => {
    const key = normalizePath(path);
    out.set(key, strongest(out.get(key), status));
  };

  for (const f of files) {
    const status = fileStatus(f);
    if (!status) continue;
    const abs = normalizePath(joinPath(root, f.path));
    if (!isInside(abs, root)) continue;
    merge(abs, status);

    let parent = dirname(abs);
    while (parent !== "/" && isInside(parent, root)) {
      merge(parent, status);
      if (parent === normalizePath(root)) break;
      parent = dirname(parent);
    }
  }
  return out;
}

export default function FileTree({ onOpen, onExpand }: Props) {
  const dirChildren = useApp(s => s.dirChildren);
  const expanded    = useApp(s => s.expandedDirs);
  const currentPath = useApp(s => s.currentPath);
  const gitFiles    = useApp(s => s.gitFiles);
  const toggleDir   = useApp(s => s.toggleDir);

  const rootEntries = currentPath ? (dirChildren.get(currentPath) ?? null) : null;
  const gitStatusByPath = useMemo(
    () => statusMapFor(currentPath, gitFiles),
    [currentPath, gitFiles],
  );

  function handleDirClick(path: string) {
    if (!expanded.has(path)) onExpand(path);
    toggleDir(path);
  }

  function renderEntry(parent: string, e: TreeEntry, depth: number) {
    const path = joinPath(parent, e.name);
    const status = gitStatusByPath.get(path) ?? e.git_status ?? null;
    const glyph = status ? SHORT[status] : "";
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
            {glyph && <span className="tree-status">{glyph}</span>}
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
          <span>{e.name}</span>
          {glyph && <span className="tree-status">{glyph}</span>}
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
