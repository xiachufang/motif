import { lazy, Suspense, useCallback, useEffect, useRef, useState } from "react";
import type {
  AttachResult, DiffResult, Event, ReadResult,
  StatusResult, TreeResult, ViewSpec,
} from "../proto/types";
import FileTree   from "../panels/FileTree";
import GitStatus  from "../panels/GitStatus";
import TabBar     from "../panels/TabBar";
import Topbar     from "../panels/Topbar";
import Resizer    from "../panels/Resizer";
import { useDragSize } from "../hooks/useDragSize";
import { useApp } from "../store/store";
import { appendOutput, clearPty, clearAll } from "../store/ptyBuffers";

function loadBool(key: string, fallback: boolean): boolean {
  try {
    const v = localStorage.getItem(key);
    if (v === "1" || v === "true")  return true;
    if (v === "0" || v === "false") return false;
  } catch { /* ignore */ }
  return fallback;
}
function saveBool(key: string, v: boolean) {
  try { localStorage.setItem(key, v ? "1" : "0"); } catch { /* ignore */ }
}

// Tab bodies own the heavy deps (xterm, diff2html, highlight.js). Loading them
// only when a matching view is open keeps Login/Sessions screens lean and lets
// each tab type's chunk be cached independently.
const PtyTab         = lazy(() => import("../tabs/PtyTab"));
const DiffTab        = lazy(() => import("../tabs/DiffTab"));
const FilePreviewTab = lazy(() => import("../tabs/FilePreviewTab"));
const ImageTab       = lazy(() => import("../tabs/ImageTab"));

interface Props { sessionName: string }

function decodeB64(b64: string): Uint8Array {
  const bin = atob(b64);
  const u8 = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  return u8;
}

export default function Workspace({ sessionName }: Props) {
  const client       = useApp(s => s.client);
  const session      = useApp(s => s.session);
  const views        = useApp(s => s.views);
  const activeView   = useApp(s => s.activeView);
  const viewCache    = useApp(s => s.viewCache);
  const ptyInfos     = useApp(s => s.ptyInfos);
  const setCurrentPath = useApp(s => s.setCurrentPath);
  const setDirChildren = useApp(s => s.setDirChildren);
  const setPage        = useApp(s => s.setPage);
  const hydrate        = useApp(s => s.hydrateWorkspace);
  const setGit         = useApp(s => s.setGit);
  const registerPty    = useApp(s => s.registerPty);
  const removePty      = useApp(s => s.removePty);
  const updatePtyFg    = useApp(s => s.updatePtyFg);
  const clientJoined   = useApp(s => s.clientJoined);
  const clientLeft     = useApp(s => s.clientLeft);
  const setStatus      = useApp(s => s.setStatus);
  const applyViewOpened        = useApp(s => s.applyViewOpened);
  const applyViewClosed        = useApp(s => s.applyViewClosed);
  const applyViewActiveChanged = useApp(s => s.applyViewActiveChanged);
  const applyViewMoved         = useApp(s => s.applyViewMoved);
  const setViewCache           = useApp(s => s.setViewCache);

  // ── attach + initial fetch ──
  useEffect(() => {
    if (!client) return;
    // ptyBuffers is module-global and ptyId ("sh-N") is per-session, so a
    // PtyId from the previous session can collide with a fresh one here and
    // leak its old bytes into the new tab. Clear on entry and exit.
    clearAll();
    let cancelled = false;
    (async () => {
      try {
        const a = await client.call<AttachResult>("session.attach", { name: sessionName });
        // Initial tree root is the session's workdir; the cwd-tracking effect
        // below will retarget it once the active PTY surfaces its cwd.
        const tree = await client.call<TreeResult>("fs.tree", { path: a.session.workdir, depth: 1 })
          .catch(() => ({ path: a.session.workdir, entries: [] } as TreeResult));
        const git  = await client.call<StatusResult>("git.status", { cwd: a.session.workdir }).catch(() => null);
        if (cancelled) return;
        hydrate(
          a.session, a.client_id, a.clients,
          a.ptys, a.views, a.active_view,
          a.session.workdir, tree.entries,
          git ? { branch: git.branch ?? null, files: git.files } : null,
        );
      } catch (e) {
        setStatus(`attach failed: ${e instanceof Error ? e.message : String(e)}`);
        setPage({ kind: "sessions" });
      }
    })();
    return () => { cancelled = true; clearAll(); };
  }, [client, sessionName, hydrate, setPage, setStatus]);

  // ── event subscription ──
  useEffect(() => {
    if (!client) return;
    return client.on(async ev => {
      const e = ev as Event;
      switch (e.method) {
        case "client.joined": clientJoined({ id: e.params.client_id, since: e.params.since }); break;
        case "client.left":   clientLeft(e.params.client_id); break;
        case "pty.created":   registerPty(e.params.info); break;
        case "pty.exited":    removePty(e.params.pty_id); clearPty(e.params.pty_id); setStatus(`pty ${e.params.pty_id} exited`); break;
        case "pty.output":    appendOutput(e.params.pty_id, decodeB64(e.params.data_b64)); break;
        case "pty.fg_changed":  updatePtyFg(e.params.pty_id, e.params.cwd, e.params.name); break;

        case "view.opened":         applyViewOpened(e.params.view); break;
        case "view.closed":         applyViewClosed(e.params.view_id); break;
        case "view.active_changed": applyViewActiveChanged(e.params.view_id); break;
        case "view.moved":          applyViewMoved(e.params.order); break;

        case "tree.changed":  setStatus("tree changed");
                              {
                                const root = useApp.getState().currentPath;
                                if (root) {
                                  try { const t = await client.call<TreeResult>("fs.tree", { path: root, depth: 1 }); setDirChildren(root, t.entries); } catch {/*ignore*/}
                                }
                              }
                              break;
        case "git.changed":   {
                                const root = useApp.getState().currentPath;
                                if (root) {
                                  try { const g = await client.call<StatusResult>("git.status", { cwd: root }); setGit(g.branch ?? null, g.files); } catch {/*ignore*/}
                                }
                              }
                              break;
      }
    });
  }, [client, clientJoined, clientLeft, registerPty, removePty, updatePtyFg,
      applyViewOpened, applyViewClosed, applyViewActiveChanged, applyViewMoved,
      setDirChildren, setGit, setStatus]);

  // ── follow active PTY's cwd → re-root the file tree ──
  const activeViewObj = views.find(v => v.id === activeView) ?? null;
  const activePtyId   = activeViewObj?.spec.kind === "pty" ? activeViewObj.spec.pty_id : null;
  const activeCwd     = activePtyId ? ptyInfos.get(activePtyId)?.cwd ?? null : null;
  useEffect(() => {
    if (!client || !session || !activeCwd) return;
    setCurrentPath(activeCwd);
    (async () => {
      try {
        const t = await client.call<TreeResult>("fs.tree", { path: activeCwd, depth: 1 });
        setDirChildren(activeCwd, t.entries);
      } catch (e) {
        setStatus(`fs.tree failed: ${e instanceof Error ? e.message : String(e)}`);
      }
      try {
        const g = await client.call<StatusResult>("git.status", { cwd: activeCwd });
        setGit(g.branch ?? null, g.files);
      } catch {
        // outside any git repo — clear the pane.
        setGit(null, []);
      }
    })();
  }, [client, session, activeCwd, setCurrentPath, setDirChildren, setGit, setStatus]);

  // ── lazy-load preview/diff caches when their views become active ──
  useEffect(() => {
    if (!client || !activeViewObj || !session) return;
    const vid = activeViewObj.id;
    if (viewCache.has(vid)) return;          // already loaded
    const spec = activeViewObj.spec;
    (async () => {
      try {
        if (spec.kind === "preview") {
          const r = await client.call<ReadResult>("fs.read", { path: spec.path });
          const bytes = decodeB64(r.content_b64);
          const content = r.binary
            ? `(binary file, ${bytes.length} bytes, mime: ${r.mime ?? "?"})`
            : new TextDecoder().decode(bytes);
          setViewCache(vid, { kind: "preview", content, mime: r.mime ?? null, binary: r.binary });
        } else if (spec.kind === "diff") {
          // Compute the diff against whatever the file-tree pane is currently
          // pointing at (== active PTY cwd, or workdir as fallback). If the
          // user later cd's elsewhere and reopens diff, they'll get a fresh
          // view scoped to the new cwd.
          const cwd = useApp.getState().currentPath || session.workdir;
          const r = await client.call<DiffResult>("git.diff", { staged: spec.staged, path: spec.path, cwd });
          setViewCache(vid, { kind: "diff", patch: r.patch });
        } else if (spec.kind === "image") {
          // ImageTab does its own fetch; we only cache the auth'd blob URL
          // path in the tab itself. Skip pre-loading here.
        }
      } catch (e) {
        setStatus(`load view failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    })();
  }, [client, activeViewObj, session, viewCache, setViewCache, setStatus]);

  // ── actions ──
  const openFile = useCallback(async (path: string) => {
    if (!client) return;
    try {
      // Server creates the view (broadcast) and we'll pick it up via the
      // view.opened event; cache content on our client.
      await client.call("view.open", {
        spec: { kind: "preview", path } as ViewSpec,
        activate: true,
      });
    } catch (e) {
      setStatus(`open failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }, [client, setStatus]);

  const openDiff = useCallback(async (path?: string) => {
    if (!client) return;
    try {
      // Reuse an existing diff tab with the same (staged, path) so clicking
      // around the file list doesn't spam new tabs.
      const existing = useApp.getState().views.find(v =>
        v.spec.kind === "diff"
        && v.spec.staged === false
        && (v.spec.path ?? null) === (path ?? null)
      );
      if (existing) {
        await client.call("view.activate", { view_id: existing.id });
        return;
      }
      await client.call("view.open", {
        spec: { kind: "diff", staged: false, path: path ?? null } as ViewSpec,
        activate: true,
      });
    } catch (e) {
      setStatus(`diff failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }, [client, setStatus]);

  const newPty = useCallback(async () => {
    if (!client) return;
    try {
      // Server creates PTY → opens Pty view → broadcasts. All clients see
      // a new tab + active changes. We don't add anything locally.
      await client.call("pty.create", { cols: 100, rows: 30, env: [] });
    } catch (e) {
      setStatus(`pty.create failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }, [client, setStatus]);

  const onExpandDir = useCallback(async (path: string) => {
    if (!client) return;
    try {
      const t = await client.call<TreeResult>("fs.tree", { path, depth: 1 });
      setDirChildren(path, t.entries);
    } catch (e) {
      setStatus(`fs.tree failed: ${e instanceof Error ? e.message : String(e)}`);
    }
  }, [client, setDirChildren, setStatus]);

  // ── layout: sizes + visibility, all persisted in localStorage ──
  const sidebarRef = useRef<HTMLElement | null>(null);
  const sidebar = useDragSize({
    initial: 280, min: 180,
    max: () => Math.max(240, window.innerWidth - 320),
    axis: "x",
    storageKey: "motif.layout.sidebarWidth",
  });
  const fileTreeH = useDragSize({
    initial: 240, min: 80,
    max: () => Math.max(120, (sidebarRef.current?.clientHeight ?? 600) - 120),
    axis: "y",
    storageKey: "motif.layout.fileTreeHeight",
  });

  const [sidebarVisible,   setSidebarVisible]   = useState(() => loadBool("motif.layout.sidebarVisible",   true));
  const [fileTreeVisible,  setFileTreeVisible]  = useState(() => loadBool("motif.layout.fileTreeVisible",  true));
  const [gitStatusVisible, setGitStatusVisible] = useState(() => loadBool("motif.layout.gitStatusVisible", true));
  useEffect(() => saveBool("motif.layout.sidebarVisible",   sidebarVisible),   [sidebarVisible]);
  useEffect(() => saveBool("motif.layout.fileTreeVisible",  fileTreeVisible),  [fileTreeVisible]);
  useEffect(() => saveBool("motif.layout.gitStatusVisible", gitStatusVisible), [gitStatusVisible]);

  return (
    <div className="workspace">
      <Topbar
        sessionName={sessionName}
        sidebar={{   visible: sidebarVisible,   toggle: () => setSidebarVisible(v => !v) }}
        fileTree={{  visible: fileTreeVisible,  toggle: () => setFileTreeVisible(v => !v) }}
        gitStatus={{ visible: gitStatusVisible, toggle: () => setGitStatusVisible(v => !v) }}
      />
      <div className="layout">
        {sidebarVisible && (
          <>
            <aside
              ref={sidebarRef}
              className="sidebar"
              style={{ width: sidebar.size }}
            >
              {fileTreeVisible && (
                <div
                  className="sidebar-section"
                  style={gitStatusVisible ? { height: fileTreeH.size, flex: "0 0 auto" } : { flex: "1 1 auto" }}
                >
                  <FileTree onOpen={openFile} onExpand={onExpandDir} />
                </div>
              )}
              {fileTreeVisible && gitStatusVisible && (
                <Resizer axis="y" onPointerDown={fileTreeH.onPointerDown} />
              )}
              {gitStatusVisible && (
                <div className="sidebar-section" style={{ flex: "1 1 auto" }}>
                  <GitStatus
                    onOpenDiff={() => openDiff()}
                    onOpenFileDiff={(path) => openDiff(path)}
                  />
                </div>
              )}
            </aside>
            <Resizer axis="x" onPointerDown={sidebar.onPointerDown} />
          </>
        )}
        <main className="content">
          <TabBar onNewPty={newPty} />
          <div className="tab-body">
            {views.length === 0 && (
              <div className="muted center">no tab open — press "+ new pty" or click a file</div>
            )}
            {views.map(view => {
              const active = view.id === activeView;
              const cache  = viewCache.get(view.id);
              return (
                <div key={view.id} className={"pane " + (active ? "active" : "hidden")}>
                  <Suspense fallback={<div className="muted center">loading…</div>}>
                    {view.spec.kind === "pty" && (
                      <PtyTab ptyId={view.spec.pty_id} active={active} />
                    )}
                    {view.spec.kind === "preview" && cache?.kind === "preview" && (
                      <FilePreviewTab content={cache.content} mime={cache.mime} binary={cache.binary} />
                    )}
                    {view.spec.kind === "preview" && !cache && (
                      <div className="muted center">loading…</div>
                    )}
                    {view.spec.kind === "diff" && cache?.kind === "diff" && (
                      <DiffTab patch={cache.patch} />
                    )}
                    {view.spec.kind === "diff" && !cache && (
                      <div className="muted center">loading diff…</div>
                    )}
                    {view.spec.kind === "image" && (
                      <ImageTab transferId={view.id /* unused; ImageTab fetches by path */} mime="" />
                    )}
                  </Suspense>
                </div>
              );
            })}
          </div>
        </main>
      </div>
    </div>
  );
}
