// A modern diff viewer:
//   • toolbar:  "By file" vs "All" layout, "Unified" vs "Split" format
//   • sidebar:  file list (flat or directory tree) with status / +-/− stats
//   • body:     per-file diff blocks rendered via diff2html
//
// Heavy work (parsing the patch into per-file blocks, calling diff2html) is
// memoized so toggling layout/format doesn't re-parse.

import {
  memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState,
} from "react";
import { html as diff2html } from "diff2html";
import "diff2html/bundles/css/diff2html.min.css";
import { parseUnifiedDiff, type FileDiff, type FileStatus } from "./diffParse";
import Resizer from "../panels/Resizer";
import { useDragSize } from "../hooks/useDragSize";
import { useIsMobile } from "../hooks/useIsMobile";

interface Props { patch: string }

type Layout   = "byfile" | "all";
type Format   = "line-by-line" | "side-by-side";
type FileMode = "list" | "tree";

const LS_LAYOUT   = "motif.diff.layout";
const LS_FORMAT   = "motif.diff.format";
const LS_FILEMODE = "motif.diff.filemode";

function loadPref<T extends string>(key: string, fallback: T, allowed: readonly T[]): T {
  try {
    const v = localStorage.getItem(key);
    if (v && (allowed as readonly string[]).includes(v)) return v as T;
  } catch { /* SSR or storage disabled */ }
  return fallback;
}
function savePref(key: string, v: string) {
  try { localStorage.setItem(key, v); } catch { /* ignore */ }
}

const STATUS_BADGE: Record<FileStatus, { glyph: string; label: string }> = {
  modified: { glyph: "M", label: "modified" },
  added:    { glyph: "A", label: "added"    },
  deleted:  { glyph: "D", label: "deleted"  },
  renamed:  { glyph: "R", label: "renamed"  },
  copied:   { glyph: "C", label: "copied"   },
  binary:   { glyph: "B", label: "binary"   },
  mode:     { glyph: "·", label: "mode"     },
};

export default function DiffTab({ patch }: Props) {
  const files = useMemo(() => parseUnifiedDiff(patch), [patch]);
  const isMobile = useIsMobile();

  const [layout, setLayout] = useState<Layout>(() =>
    loadPref<Layout>(LS_LAYOUT, "byfile", ["byfile", "all"] as const));
  const [format, setFormat] = useState<Format>(() =>
    loadPref<Format>(LS_FORMAT, "side-by-side", ["line-by-line", "side-by-side"] as const));
  const [fileMode, setFileMode] = useState<FileMode>(() =>
    loadPref<FileMode>(LS_FILEMODE, "list", ["list", "tree"] as const));
  const [selected, setSelected] = useState(0);
  // Mobile-only: file list is a toggleable drawer rather than an inline
  // column. Collapsed by default so the diff content gets the full width.
  const [filesDrawerOpen, setFilesDrawerOpen] = useState(false);
  // Mobile-only: force "Unified" since side-by-side wraps awkwardly on
  // narrow viewports. We only force it during render — the user's saved
  // preference is preserved for desktop.
  const effectiveFormat: Format = isMobile ? "line-by-line" : format;

  useEffect(() => savePref(LS_LAYOUT, layout), [layout]);
  useEffect(() => savePref(LS_FORMAT, format), [format]);
  useEffect(() => savePref(LS_FILEMODE, fileMode), [fileMode]);

  // Re-clamp selection when the underlying patch changes (e.g. a refresh
  // dropped the previously-selected file off the list).
  useEffect(() => {
    if (selected >= files.length) setSelected(0);
  }, [files, selected]);

  // Refs to the scroll container (.diff-content) and to each per-file block
  // in "all" layout, so the sidebar can scroll a clicked file into view
  // without triggering scrollIntoView on outer ancestors (which used to push
  // the toolbar off-screen).
  const bodyRef    = useRef<HTMLDivElement | null>(null);
  const contentRef = useRef<HTMLDivElement | null>(null);
  const blockRefs  = useRef<Map<number, HTMLDivElement>>(new Map());

  const filesPane = useDragSize({
    initial: 260, min: 160,
    max: () => Math.max(220, (bodyRef.current?.clientWidth ?? 800) - 240),
    axis: "x",
    storageKey: "motif.diff.filesWidth",
  });
  const setBlockRef = useCallback((i: number, el: HTMLDivElement | null) => {
    if (el) blockRefs.current.set(i, el);
    else    blockRefs.current.delete(i);
  }, []);

  const onSelectFile = useCallback((i: number) => {
    setSelected(i);
    if (layout === "all") {
      const container = contentRef.current;
      const block     = blockRefs.current.get(i);
      if (container && block) {
        // Compute the block's offset within the scroll container and scroll
        // only the container — never the page.
        const top = block.getBoundingClientRect().top
                  - container.getBoundingClientRect().top
                  + container.scrollTop;
        container.scrollTo({ top, behavior: "smooth" });
      }
    }
    // Auto-close the drawer so the freshly-selected file is fully visible.
    setFilesDrawerOpen(false);
  }, [layout]);

  // Tree of files for "tree" file-mode (memoized; cheap, but skip when unused).
  const tree     = useMemo(() => buildTree(files), [files]);
  const dirPaths = useMemo(() => collectDirPaths(tree), [tree]);
  // Track *collapsed* dirs rather than expanded — default empty = everything
  // open, and external refreshes can't reset a user's click.
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

  if (!patch.trim() || files.length === 0) {
    return (
      <div className="diff-viewer empty">
        <p className="muted center">(no changes)</p>
      </div>
    );
  }

  const totalAdd = files.reduce((s, f) => s + f.additions, 0);
  const totalDel = files.reduce((s, f) => s + f.deletions, 0);

  // On mobile the file pane is positioned as an absolute drawer, so don't
  // apply an inline width (the CSS rule sets the drawer width directly).
  const filesPaneStyle = isMobile ? undefined : { width: filesPane.size };
  // Show the file pane on desktop always; on mobile only when the user has
  // opened the drawer.
  const filesPaneShown = !isMobile || filesDrawerOpen;

  return (
    <div className={"diff-viewer" + (isMobile ? " is-mobile" : "")}>
      <div className="diff-toolbar">
        <div className="diff-summary">
          {isMobile && (
            <button
              className="ghost small diff-files-toggle"
              onClick={() => setFilesDrawerOpen(v => !v)}
              aria-expanded={filesDrawerOpen}
              aria-label="Toggle file list"
              title="Files"
            >
              ☰ {files.length}
            </button>
          )}
          <span className="pill">{files.length} file{files.length === 1 ? "" : "s"}</span>
          <span className="diff-add">+{totalAdd}</span>
          <span className="diff-del">−{totalDel}</span>
        </div>
        <div className="diff-controls">
          <div className="seg" role="group" aria-label="Layout">
            <button
              className={layout === "byfile" ? "on" : ""}
              onClick={() => setLayout("byfile")}
              title="View one file at a time"
            >By file</button>
            <button
              className={layout === "all" ? "on" : ""}
              onClick={() => setLayout("all")}
              title="View all files in a single scrolling list"
            >All</button>
          </div>
          {/* Side-by-side wraps badly on phones; hide the format toggle there
              and force unified at render time. */}
          {!isMobile && (
            <div className="seg" role="group" aria-label="Format">
              <button
                className={format === "line-by-line" ? "on" : ""}
                onClick={() => setFormat("line-by-line")}
                title="Unified (single column)"
              >Unified</button>
              <button
                className={format === "side-by-side" ? "on" : ""}
                onClick={() => setFormat("side-by-side")}
                title="Side-by-side (two columns)"
              >Split</button>
            </div>
          )}
        </div>
      </div>

      <div className="diff-body" ref={bodyRef}>
        {filesPaneShown && (
          <aside
            className={"diff-files" + (isMobile ? " diff-files-drawer" : "")}
            style={filesPaneStyle}
          >
            <div className="diff-files-header">
              <div className="seg" role="group" aria-label="File list view">
                <button
                  className={fileMode === "list" ? "on" : ""}
                  onClick={() => setFileMode("list")}
                  title="Flat list"
                >List</button>
                <button
                  className={fileMode === "tree" ? "on" : ""}
                  onClick={() => setFileMode("tree")}
                  title="Directory tree"
                >Tree</button>
              </div>
              {fileMode === "tree" && dirPaths.length > 0 && (
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
              {isMobile && (
                <button
                  className="ghost small"
                  onClick={() => setFilesDrawerOpen(false)}
                  aria-label="Close file list"
                  title="Close"
                  style={{ marginLeft: "auto" }}
                >✕</button>
              )}
            </div>
            <div className="diff-files-body">
              {fileMode === "list" ? (
                <FileList files={files} selected={selected} onSelect={onSelectFile} />
              ) : (
                <FileTreeView
                  root={tree}
                  files={files}
                  selected={selected}
                  collapsed={collapsed}
                  onToggleDir={toggleDir}
                  onSelect={onSelectFile}
                />
              )}
            </div>
          </aside>
        )}
        {!isMobile && <Resizer axis="x" onPointerDown={filesPane.onPointerDown} />}
        {isMobile && filesDrawerOpen && (
          <div
            className="diff-files-backdrop"
            onClick={() => setFilesDrawerOpen(false)}
            aria-hidden
          />
        )}
        <div
          ref={contentRef}
          className={"diff-content " + (layout === "all" ? "scroll-all" : "single")}
        >
          {layout === "byfile" ? (
            files[selected] && (
              <FileBlock
                key={files[selected].path + ":" + selected}
                file={files[selected]}
                format={effectiveFormat}
                collapsible={false}
              />
            )
          ) : (
            files.map((f, i) => (
              <div
                key={f.path + ":" + i}
                ref={el => setBlockRef(i, el)}
                data-file-idx={i}
              >
                <FileBlock file={f} format={effectiveFormat} collapsible={true} />
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}

// ── flat file list ───────────────────────────────────────────────────────

interface FileListProps {
  files:    FileDiff[];
  selected: number;
  onSelect: (i: number) => void;
}

const FileList = memo(function FileList({ files, selected, onSelect }: FileListProps) {
  return (
    <ul className="diff-file-list">
      {files.map((f, i) => {
        const badge = STATUS_BADGE[f.status];
        const renamed = (f.status === "renamed" || f.status === "copied") && f.oldPath && f.newPath && f.oldPath !== f.newPath;
        return (
          <li
            key={f.path + ":" + i}
            className={"diff-file-item " + (i === selected ? "active" : "")}
            onClick={() => onSelect(i)}
            title={renamed ? `${f.oldPath} → ${f.newPath}` : f.path}
          >
            <span className={"diff-badge st-" + f.status} aria-label={badge.label}>{badge.glyph}</span>
            <span className="diff-file-path">
              {renamed ? (
                <>
                  <span className="muted">{shortenPath(f.oldPath!)}</span>
                  <span className="muted"> → </span>
                  {shortenPath(f.newPath!)}
                </>
              ) : (
                shortenPath(f.path)
              )}
            </span>
            <span className="diff-file-stats">
              {f.additions > 0 && <span className="diff-add">+{f.additions}</span>}
              {f.deletions > 0 && <span className="diff-del">−{f.deletions}</span>}
            </span>
          </li>
        );
      })}
    </ul>
  );
});

function shortenPath(p: string): string {
  // Show "dir/.../file.ext" when paths get long enough to wrap awkwardly.
  // We're conservative — only truncate when really long.
  if (p.length <= 60) return p;
  const parts = p.split("/");
  if (parts.length < 3) return p;
  return parts[0] + "/…/" + parts.slice(-2).join("/");
}

// ── tree view ────────────────────────────────────────────────────────────

interface FileNode { kind: "file"; index: number; file: FileDiff }
interface DirNode  { kind: "dir";  name: string; path: string; children: TreeNode[] }
type     TreeNode  = FileNode | DirNode;

function buildTree(files: FileDiff[]): DirNode {
  const root: DirNode = { kind: "dir", name: "", path: "", children: [] };
  files.forEach((file, index) => {
    const segments = file.path.split("/").filter(Boolean);
    if (segments.length === 0) {
      root.children.push({ kind: "file", index, file });
      return;
    }
    let cursor = root;
    for (let i = 0; i < segments.length - 1; i++) {
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
    cursor.children.push({ kind: "file", index, file });
  });
  compactDirs(root);
  sortTree(root);
  return root;
}

// Collapse any dir with a single dir child into "name/child". Stops when the
// only child is a file (so files keep their basename) or when there are
// multiple children.
function compactDirs(node: DirNode) {
  for (const child of node.children) {
    if (child.kind === "dir") compactDirs(child);
  }
  // Don't compact the synthetic root.
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

interface FileTreeViewProps {
  root:        DirNode;
  files:       FileDiff[];
  selected:    number;
  collapsed:   Set<string>;
  onToggleDir: (path: string) => void;
  onSelect:    (i: number) => void;
}

const FileTreeView = memo(function FileTreeView({
  root, selected, collapsed, onToggleDir, onSelect,
}: FileTreeViewProps) {
  function renderNodes(nodes: TreeNode[], depth: number): React.ReactNode {
    return nodes.map(n => {
      if (n.kind === "dir") {
        const open = !collapsed.has(n.path);
        return (
          <div key={"d:" + n.path} className="diff-tree-dir">
            <div
              className="diff-tree-row dir"
              style={{ paddingLeft: `${depth * 0.9 + 0.4}em` }}
              onClick={() => onToggleDir(n.path)}
              title={n.path}
            >
              <span className="chevron">{open ? "▾" : "▸"}</span>
              <span className="diff-tree-name">{n.name}/</span>
            </div>
            {open && (
              <div className="diff-tree-children">
                {renderNodes(n.children, depth + 1)}
              </div>
            )}
          </div>
        );
      }
      const f = n.file;
      const badge = STATUS_BADGE[f.status];
      const isActive = n.index === selected;
      return (
        <div
          key={"f:" + n.index + ":" + f.path}
          className={"diff-tree-row file " + (isActive ? "active" : "")}
          style={{ paddingLeft: `${depth * 0.9 + 0.4}em` }}
          onClick={() => onSelect(n.index)}
          title={f.path}
        >
          <span className={"diff-badge st-" + f.status} aria-label={badge.label}>{badge.glyph}</span>
          <span className="diff-tree-name">{basename(f.path)}</span>
          <span className="diff-file-stats">
            {f.additions > 0 && <span className="diff-add">+{f.additions}</span>}
            {f.deletions > 0 && <span className="diff-del">−{f.deletions}</span>}
          </span>
        </div>
      );
    });
  }
  return <div className="diff-tree">{renderNodes(root.children, 0)}</div>;
});

function basename(p: string): string {
  const i = p.lastIndexOf("/");
  return i < 0 ? p : p.slice(i + 1);
}

// ── per-file diff block ──────────────────────────────────────────────────

interface FileBlockProps {
  file:        FileDiff;
  format:      Format;
  collapsible: boolean;
}

const FileBlock = memo(function FileBlock({ file, format, collapsible }: FileBlockProps) {
  const [open, setOpen] = useState(true);
  const ref = useRef<HTMLDivElement | null>(null);
  const badge = STATUS_BADGE[file.status];

  // Use layout effect so the diff html is in the DOM before paint, avoiding
  // a flash of empty content when toggling format/file.
  useLayoutEffect(() => {
    if (!ref.current) return;
    if (!open) { ref.current.innerHTML = ""; return; }
    if (file.isBinary) {
      ref.current.innerHTML = `<div class="diff-binary muted">Binary file — no textual diff</div>`;
      return;
    }
    if (file.status === "mode") {
      ref.current.innerHTML = `<div class="diff-binary muted">Mode change only — no content diff</div>`;
      return;
    }
    if (!file.patch.includes("@@")) {
      ref.current.innerHTML = `<div class="diff-binary muted">(empty diff)</div>`;
      return;
    }
    const out = diff2html(file.patch, {
      drawFileList: false,
      matching:     "lines",
      outputFormat: format,
      // diff2html has its own dark/light styles toggled by attribute. The
      // class is added on the wrapper element it renders.
      colorScheme:  "dark" as never,
    } as never);
    ref.current.innerHTML = out;
  }, [file.patch, file.isBinary, file.status, format, open]);

  return (
    <section className={"diff-file-block st-" + file.status}>
      <header className="diff-file-header">
        {collapsible && (
          <button
            className="diff-collapse"
            onClick={() => setOpen(o => !o)}
            title={open ? "Collapse" : "Expand"}
            aria-label={open ? "Collapse" : "Expand"}
          >{open ? "▾" : "▸"}</button>
        )}
        <span className={"diff-badge st-" + file.status} aria-label={badge.label}>{badge.glyph}</span>
        <span className="diff-file-name">
          {file.status === "renamed" || file.status === "copied"
            ? `${file.oldPath ?? ""} → ${file.newPath ?? ""}`
            : file.path}
        </span>
        <span className="diff-file-stats">
          {file.additions > 0 && <span className="diff-add">+{file.additions}</span>}
          {file.deletions > 0 && <span className="diff-del">−{file.deletions}</span>}
        </span>
      </header>
      <div className="diff-file-body" ref={ref} />
    </section>
  );
});
