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
import { useIsMobile } from "../hooks/useIsMobile";
import { useApp } from "../store/store";
import {
  appendOutput, clearPty, clearAll,
} from "../store/ptyBuffers";

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
const MobileInputDock = lazy(() => import("../panels/MobileInputDock"));

interface Props { sessionName: string }

function decodeB64(b64: string): Uint8Array {
  const bin = atob(b64);
  const u8 = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  return u8;
}

/** Pick the active PTY's cwd (if any) for the initial fs.tree/git.status
 *  fetch — saves a round-trip vs. fetching for session.workdir and then
 *  immediately re-fetching for the active cwd. */
function pickInitialCwd(a: AttachResult): string | null {
  const v = a.views.find(x => x.id === a.active_view);
  const spec = v?.spec;
  if (spec?.kind === "pty") {
    return a.ptys.find(p => p.id === spec.pty_id)?.cwd ?? null;
  }
  return a.ptys.find(p => p.alive)?.cwd ?? a.ptys[0]?.cwd ?? null;
}

/** Map `tree.changed` paths to the cached directories that need refresh.
 *  A cached dir D needs refresh if some changed path P is a direct child
 *  of D, or P === D itself (the dir was renamed/removed). We only return
 *  dirs we've actually cached (in `dirChildren`); refetching dirs the
 *  user hasn't expanded would be wasted work. */
function affectedDirs(paths: string[], cached: Map<string, unknown>): string[] {
  if (paths.length === 0 || cached.size === 0) return [];
  const out = new Set<string>();
  for (const p of paths) {
    if (cached.has(p)) out.add(p);
    const slash = p.lastIndexOf("/");
    if (slash > 0) {
      const parent = p.slice(0, slash);
      if (cached.has(parent)) out.add(parent);
    } else if (slash === 0 && cached.has("/")) {
      out.add("/");
    }
  }
  return [...out];
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
  const updatePtyCwd   = useApp(s => s.updatePtyCwd);
  const clientJoined   = useApp(s => s.clientJoined);
  const clientLeft     = useApp(s => s.clientLeft);
  const setStatus      = useApp(s => s.setStatus);
  const applyViewOpened        = useApp(s => s.applyViewOpened);
  const applyViewClosed        = useApp(s => s.applyViewClosed);
  const applyViewActiveChanged = useApp(s => s.applyViewActiveChanged);
  const applyViewMoved         = useApp(s => s.applyViewMoved);
  const setViewCache           = useApp(s => s.setViewCache);
  const rehydrateOnReconnect   = useApp(s => s.rehydrateOnReconnect);

  // Highest `seq` we've processed. Sent as `last_seq` on reconnect so the
  // server replays missed notifications. A ref (not store) to avoid a
  // re-render on every event.
  const lastSeqRef = useRef<number>(0);
  // Event delivery is at-least-once across replay/re-attach edges. Keep a
  // bounded de-dupe window so repeated notifications don't double-write xterm
  // buffers or issue duplicate follow-up RPCs.
  const seenSeqRef = useRef<Set<number>>(new Set());
  const seenSeqOrderRef = useRef<number[]>([]);
  // Last cwd we already pulled `fs.tree` + `git.status` for. Seeded by the
  // attach effect so the cwd-follow effect below won't re-fetch the very
  // same path on first mount.
  const lastFetchedCwdRef = useRef<string | null>(null);

  // ── attach + initial fetch ──
  useEffect(() => {
    if (!client) return;
    // ptyBuffers is module-global and ptyId ("sh-N") is per-session, so a
    // PtyId from the previous session can collide with a fresh one here and
    // leak its old bytes into the new tab. Clear on entry and exit.
    clearAll();
    seenSeqRef.current.clear();
    seenSeqOrderRef.current = [];
    lastSeqRef.current = 0;
    let cancelled = false;
    (async () => {
      try {
        const a = await client.call<AttachResult>("session.attach", { name: sessionName });
        lastSeqRef.current = a.last_seq;
        // Pick the active PTY's cwd if any so we don't fetch tree/git for
        // session.workdir and then immediately re-fetch for the active cwd
        // (which the cwd-follow effect would do).
        const initialCwd = pickInitialCwd(a) ?? a.session.workdir;
        const tree = await client.call<TreeResult>("fs.tree", { path: initialCwd, depth: 1 })
          .catch(() => ({ path: initialCwd, entries: [] } as TreeResult));
        const git  = await client.call<StatusResult>("git.status", { cwd: initialCwd }).catch(() => null);
        if (cancelled) return;
        hydrate(
          a.session, a.client_id, a.clients,
          a.ptys, a.views, a.active_view,
          initialCwd, tree.entries,
          git ? { branch: git.branch ?? null, files: git.files } : null,
        );
        lastFetchedCwdRef.current = initialCwd;
      } catch (e) {
        setStatus(`attach failed: ${e instanceof Error ? e.message : String(e)}`);
        setPage({ kind: "sessions" });
      }
    })();
    return () => {
      cancelled = true;
      // Tell the server we're leaving so other clients see `client.left`
      // immediately rather than waiting for the WS to actually close.
      client.call("session.detach", {}).catch(() => { /* ignore — may not be attached yet */ });
      clearAll();
    };
  }, [client, sessionName, hydrate, setPage, setStatus]);

  // Re-attach on transparent WS reconnect. Server replays events from
  // last_seq+1 (if the ring still has them); we soft-rehydrate the
  // server-authoritative bits and let those events bring blocks current.
  useEffect(() => {
    if (!client) return;
    client.onReconnect = async () => {
      try {
        const a = await client.call<AttachResult>("session.attach", {
          name:     sessionName,
          last_seq: lastSeqRef.current,
        });
        rehydrateOnReconnect(
          a.session, a.client_id, a.clients,
          a.ptys, a.views, a.active_view,
        );
        lastSeqRef.current = a.last_seq;
        setStatus("reconnected");
      } catch (e) {
        setStatus(`reconnect failed: ${e instanceof Error ? e.message : String(e)}`);
        setPage({ kind: "sessions" });
      }
    };
    return () => { client.onReconnect = null; };
  }, [client, sessionName, rehydrateOnReconnect, setPage, setStatus]);

  // ── event subscription ──
  useEffect(() => {
    if (!client) return;
    return client.on(async ev => {
      const e = ev as Event;
      const seq = (e.params as { seq?: number } | undefined)?.seq;
      if (typeof seq === "number" && seq > 0) {
        const seen = seenSeqRef.current;
        if (seen.has(seq)) return;
        seen.add(seq);
        seenSeqOrderRef.current.push(seq);
        while (seenSeqOrderRef.current.length > 8192) {
          const old = seenSeqOrderRef.current.shift();
          if (old !== undefined) seen.delete(old);
        }
        if (seq > lastSeqRef.current) lastSeqRef.current = seq;
      }
      switch (e.method) {
        case "client.joined": clientJoined({ id: e.params.client_id, since: e.params.since }); break;
        case "client.left":   clientLeft(e.params.client_id); break;
        case "pty.created":   registerPty(e.params.info); break;
        case "pty.exited":    removePty(e.params.pty_id); clearPty(e.params.pty_id); setStatus(`pty ${e.params.pty_id} exited`); break;
        case "pty.output":    appendOutput(e.params.pty_id, decodeB64(e.params.data_b64)); break;
        case "pty.cwd_changed": updatePtyCwd(e.params.pty_id, e.params.cwd); break;

        // v2 shell-integration events still arrive on the wire but the
        // web UI no longer renders blocks/chips, so we ignore them.
        case "pty.shell_bootstrapped":
        case "pty.prompt_started":
        case "pty.prompt_ended":
        case "pty.command_started":
        case "pty.command_finished":
        case "pty.shell_context":
          break;

        case "view.opened":         applyViewOpened(e.params.view); break;
        case "view.closed":         applyViewClosed(e.params.view_id); break;
        case "view.active_changed": applyViewActiveChanged(e.params.view_id); break;
        case "view.moved":          applyViewMoved(e.params.order); break;

        case "tree.changed":  setStatus("tree changed");
                              {
                                // Honor `paths`: only refetch dirs we've cached
                                // that are actually affected (== parent of a
                                // changed path, or the changed path itself if
                                // it's a directory we listed). Without this,
                                // any unrelated `fs.write` triggers a refetch
                                // of the active root.
                                const cached = useApp.getState().dirChildren;
                                const affected = affectedDirs(e.params.paths ?? [], cached);
                                for (const dir of affected) {
                                  try {
                                    const t = await client.call<TreeResult>("fs.tree", { path: dir, depth: 1 });
                                    setDirChildren(dir, t.entries);
                                  } catch { /* ignore */ }
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
  }, [client, clientJoined, clientLeft, registerPty, removePty, updatePtyCwd,
      applyViewOpened, applyViewClosed, applyViewActiveChanged, applyViewMoved,
      setDirChildren, setGit, setStatus]);

  // ── follow active PTY's cwd → re-root the file tree ──
  const activeViewObj = views.find(v => v.id === activeView) ?? null;
  const activePtyId   = activeViewObj?.spec.kind === "pty" ? activeViewObj.spec.pty_id : null;
  const activeCwd     = activePtyId ? ptyInfos.get(activePtyId)?.cwd ?? null : null;
  useEffect(() => {
    if (!client || !session || !activeCwd) return;
    setCurrentPath(activeCwd);
    // Skip the fetch if attach already loaded this exact cwd. Without this,
    // the very first activation would fire fs.tree + git.status a second
    // time for the same path the attach effect just hydrated.
    if (lastFetchedCwdRef.current === activeCwd) return;
    lastFetchedCwdRef.current = activeCwd;
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
        if (spec.kind === "preview" || spec.kind === "image") {
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
        }
      } catch (e) {
        setStatus(`load view failed: ${e instanceof Error ? e.message : String(e)}`);
      }
    })();
  }, [client, activeViewObj, session, viewCache, setViewCache, setStatus]);

  // Pulled out so openFile/openDiff can call it without depending on the
  // mobile flag at definition time.
  const isMobileRef = useRef(false);

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
      // Auto-collapse the drawer so the freshly-opened tab is fully visible.
      if (isMobileRef.current) {
        setFileTreeVisible(false);
        setGitStatusVisible(false);
      }
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
      } else {
        await client.call("view.open", {
          spec: { kind: "diff", staged: false, path: path ?? null } as ViewSpec,
          activate: true,
        });
      }
      if (isMobileRef.current) {
        setFileTreeVisible(false);
        setGitStatusVisible(false);
      }
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

  const isMobile = useIsMobile();
  useEffect(() => { isMobileRef.current = isMobile; }, [isMobile]);

  const [fileTreeVisible,  setFileTreeVisible]  = useState(() => loadBool("motif.layout.fileTreeVisible",  true));
  const [gitStatusVisible, setGitStatusVisible] = useState(() => loadBool("motif.layout.gitStatusVisible", true));
  // Sidebar is shown whenever at least one of its sections (file tree, git
  // status) is visible. There's no separate sidebar toggle anymore — hide
  // both child panels to hide the sidebar. On mobile the sidebar is collapsed
  // by default — opening it would obscure the whole content area on first
  // visit, which surprises new users; the topbar buttons re-open it.
  const sidebarVisible = fileTreeVisible || gitStatusVisible;
  useEffect(() => {
    if (!isMobile) return;
    setFileTreeVisible(false);
    setGitStatusVisible(false);
    // Run once when we cross into mobile (matchMedia change). Stable ids
    // for setters are React-guaranteed.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isMobile]);

  const closeSidebar = useCallback(() => {
    setFileTreeVisible(false);
    setGitStatusVisible(false);
  }, []);
  // Mobile input dock: visible by default; user can hide via the 📱 topbar
  // toggle. Choice is persisted to localStorage.
  const [mobileDockVisible, setMobileDockVisible] = useState(() =>
    loadBool("motif.layout.mobileDockVisible", true));
  useEffect(() => saveBool("motif.layout.fileTreeVisible",  fileTreeVisible),  [fileTreeVisible]);
  useEffect(() => saveBool("motif.layout.gitStatusVisible", gitStatusVisible), [gitStatusVisible]);
  useEffect(() => saveBool("motif.layout.mobileDockVisible", mobileDockVisible), [mobileDockVisible]);

  // On mobile we render the sidebar as an absolute overlay drawer (fixed
  // width, slides in from the left, with a tap-to-dismiss backdrop). On
  // desktop it stays an inline flex column whose width is drag-resizable.
  const sidebarStyle = isMobile ? undefined : { width: sidebar.size };

  return (
    <div className={"workspace" + (isMobile ? " is-mobile" : "")}>
      <Topbar
        sessionName={sessionName}
        fileTree={{   visible: fileTreeVisible,   toggle: () => setFileTreeVisible(v => !v) }}
        gitStatus={{  visible: gitStatusVisible,  toggle: () => setGitStatusVisible(v => !v) }}
        mobileDock={{ visible: mobileDockVisible, toggle: () => setMobileDockVisible(v => !v) }}
      />
      <div className="layout">
        {sidebarVisible && (
          <>
            <aside
              ref={sidebarRef}
              className={"sidebar" + (isMobile ? " sidebar-drawer" : "")}
              style={sidebarStyle}
            >
              {fileTreeVisible && (
                <div
                  className="sidebar-section"
                  style={!isMobile && gitStatusVisible
                    ? { height: fileTreeH.size, flex: "0 0 auto" }
                    : { flex: "1 1 auto" }}
                >
                  <FileTree onOpen={openFile} onExpand={onExpandDir} />
                </div>
              )}
              {!isMobile && fileTreeVisible && gitStatusVisible && (
                <Resizer axis="y" onPointerDown={fileTreeH.onPointerDown} />
              )}
              {gitStatusVisible && (
                <div className="sidebar-section" style={{ flex: "1 1 auto", overflow: "auto" }}>
                  <GitStatus
                    onOpenDiff={() => openDiff()}
                    onOpenFileDiff={(path) => openDiff(path)}
                  />
                </div>
              )}
            </aside>
            {!isMobile && <Resizer axis="x" onPointerDown={sidebar.onPointerDown} />}
            {isMobile && (
              <div
                className="sidebar-backdrop"
                onClick={closeSidebar}
                aria-hidden
              />
            )}
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
                    {(view.spec.kind === "preview" || view.spec.kind === "image") && cache?.kind === "preview" && (
                      <FilePreviewTab path={view.spec.path} content={cache.content} mime={cache.mime} binary={cache.binary} />
                    )}
                    {(view.spec.kind === "preview" || view.spec.kind === "image") && !cache && (
                      <div className="muted center">loading…</div>
                    )}
                    {view.spec.kind === "diff" && cache?.kind === "diff" && (
                      <DiffTab patch={cache.patch} />
                    )}
                    {view.spec.kind === "diff" && !cache && (
                      <div className="muted center">loading diff…</div>
                    )}
                  </Suspense>
                </div>
              );
            })}
          </div>
          {mobileDockVisible && (
            activePtyId ? (
              <Suspense fallback={null}>
                <MobileInputDock ptyId={activePtyId} />
              </Suspense>
            ) : (
              <div className="mdock mdock-empty muted small">
                open a PTY tab to use the mobile input dock
              </div>
            )
          )}
        </main>
      </div>
    </div>
  );
}
