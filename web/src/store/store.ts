// Application state.
//
// PTY/preview/diff/image tabs are now server-side state ("views") synced via
// view.opened / view.closed / view.active_changed events. The store mirrors
// `views` and `activeView`. Per-view client-side cache (preview content,
// diff patch, image blob URL) lives in `viewCache` and is hydrated on the
// fly when a view first becomes visible — content is not synced.
//
// Path model: file-tree paths are ABSOLUTE. The tree is rooted at the active
// PTY's cwd (or session.workdir before any PTY is active). When the active
// PTY's cwd changes, `currentPath` follows it and we re-fetch fs.tree at the
// new root. There is no longer a workdir-relative path space.

import { create } from "zustand";
import type {
  ClientInfo, GitFile, PtyInfo, SessionInfo, TreeEntry, ViewId, ViewInfo,
} from "../proto/types";
import type { RpcClient } from "../ws/client";

export type Page =
  | { kind: "login" }
  | { kind: "sessions" }
  | { kind: "workspace"; sessionName: string };

/** Per-view cache: optional content/patch/blob URL stored locally on each
 *  client. Populated lazily when the view is first rendered. */
export type ViewCache =
  | { kind: "preview"; content: string; mime: string | null; binary: boolean }
  | { kind: "diff";    patch: string }
  | { kind: "image";   blobUrl: string };

export interface AppState {
  page:          Page;
  token:         string | null;
  client:        RpcClient | null;

  session:       SessionInfo | null;
  myClientId:    string | null;
  otherClients:  ClientInfo[];
  gitBranch:     string | null;
  gitFiles:      GitFile[];
  ptyInfos:      Map<string, PtyInfo>;

  /// Synced tabs from the server. Order matters (matches server's view list).
  views:         ViewInfo[];
  activeView:    ViewId | null;

  /// Local-only per-view cache.
  viewCache:     Map<ViewId, ViewCache>;

  /** Absolute path of the file-tree root (== active PTY cwd, or workdir). */
  currentPath:   string;
  /** Absolute-path-keyed children. Includes the root entry under `currentPath`. */
  dirChildren:   Map<string, TreeEntry[]>;
  /** Absolute paths the user has expanded inside the tree. */
  expandedDirs:  Set<string>;

  status:        string;

  setPage:       (p: Page) => void;
  setToken:      (t: string | null) => void;
  setClient:     (c: RpcClient | null) => void;
  setStatus:     (s: string) => void;

  hydrateWorkspace: (
    s: SessionInfo, me: string, others: ClientInfo[],
    ptys: PtyInfo[], views: ViewInfo[], activeView: ViewId | null,
    rootPath: string, rootEntries: TreeEntry[],
    git: { branch: string | null; files: GitFile[] } | null,
  ) => void;

  setGit:        (branch: string | null, files: GitFile[]) => void;
  setDirChildren: (path: string, entries: TreeEntry[]) => void;
  toggleDir:     (path: string) => void;

  // ── view sync (driven by view.* events) ──
  applyViewOpened:        (v: ViewInfo) => void;
  applyViewClosed:        (id: ViewId) => void;
  applyViewActiveChanged: (id: ViewId | null) => void;
  applyViewMoved:         (order: ViewId[]) => void;

  // ── per-view local cache ──
  setViewCache:  (id: ViewId, cache: ViewCache) => void;
  clearViewCache: (id: ViewId) => void;

  // ── PTY info (still useful for cwd, cmd display) ──
  registerPty:   (info: PtyInfo) => void;
  removePty:     (id: string) => void;
  updatePtyFg:   (id: string, cwd: string, fg_name: string | null) => void;
  setCurrentPath: (p: string) => void;

  clientJoined:  (c: ClientInfo) => void;
  clientLeft:    (id: string) => void;

  reset: () => void;
}

const initial = (): Pick<AppState,
  "page"|"token"|"client"|"session"|"myClientId"|"otherClients"|
  "gitBranch"|"gitFiles"|"ptyInfos"|
  "views"|"activeView"|"viewCache"|
  "currentPath"|"dirChildren"|"expandedDirs"|"status"
> => ({
  page:          { kind: "login" },
  token:         loadToken(),
  client:        null,
  session:       null,
  myClientId:    null,
  otherClients:  [],
  gitBranch:     null,
  gitFiles:      [],
  ptyInfos:      new Map(),
  views:         [],
  activeView:    null,
  viewCache:     new Map(),
  currentPath:   "",
  dirChildren:   new Map(),
  expandedDirs:  new Set(),
  status:        "",
});

function loadToken(): string | null {
  return localStorage.getItem("motif.token") ?? sessionStorage.getItem("motif.token");
}

export const useApp = create<AppState>((set) => ({
  ...initial(),

  setPage:    (page)  => set({ page }),
  setToken:   (token) => set({ token }),
  setClient:  (client) => set({ client }),
  setStatus:  (status) => set({ status }),

  hydrateWorkspace: (session, me, others, ptys, views, activeView, rootPath, rootEntries, git) => set(_s => {
    const dirChildren = new Map<string, TreeEntry[]>();
    dirChildren.set(rootPath, rootEntries);
    return {
      session,
      myClientId:   me,
      otherClients: others,
      gitBranch:    git?.branch ?? null,
      gitFiles:     git?.files ?? [],
      ptyInfos:     new Map(ptys.map(p => [p.id, p])),
      views,
      activeView,
      viewCache:    new Map(),
      currentPath:  rootPath,
      dirChildren,
      expandedDirs: new Set<string>(),
    };
  }),

  setGit:   (gitBranch, gitFiles) => set({ gitBranch, gitFiles }),
  setDirChildren: (path, entries) => set(s => {
    const dirChildren = new Map(s.dirChildren);
    dirChildren.set(path, entries);
    return { dirChildren };
  }),
  toggleDir: (path) => set(s => {
    const expandedDirs = new Set(s.expandedDirs);
    if (expandedDirs.has(path)) expandedDirs.delete(path);
    else expandedDirs.add(path);
    return { expandedDirs };
  }),

  applyViewOpened: (v) => set(s => {
    if (s.views.some(x => x.id === v.id)) return {};
    return { views: [...s.views, v] };
  }),
  applyViewClosed: (id) => set(s => {
    const views = s.views.filter(v => v.id !== id);
    const cache = new Map(s.viewCache); cache.delete(id);
    return { views, viewCache: cache };
  }),
  applyViewActiveChanged: (id) => set({ activeView: id }),
  applyViewMoved: (order) => set(s => {
    // Sort local views to match the server's order. Anything not in `order`
    // (rare race) is appended after, so we never silently drop a tab.
    const byId = new Map(s.views.map(v => [v.id, v]));
    const next: ViewInfo[] = [];
    for (const id of order) {
      const v = byId.get(id);
      if (v) { next.push(v); byId.delete(id); }
    }
    for (const v of byId.values()) next.push(v);
    return { views: next };
  }),

  setViewCache: (id, cache) => set(s => {
    const m = new Map(s.viewCache); m.set(id, cache);
    return { viewCache: m };
  }),
  clearViewCache: (id) => set(s => {
    const m = new Map(s.viewCache); m.delete(id);
    return { viewCache: m };
  }),

  registerPty: (info) => set(s => {
    const m = new Map(s.ptyInfos); m.set(info.id, info);
    return { ptyInfos: m };
  }),
  removePty: (id) => set(s => {
    const m = new Map(s.ptyInfos); m.delete(id);
    return { ptyInfos: m };
  }),
  updatePtyFg: (id, cwd, fg_name) => set(s => {
    const cur = s.ptyInfos.get(id);
    if (!cur) return {};
    const m = new Map(s.ptyInfos);
    m.set(id, { ...cur, cwd, fg_name });
    return { ptyInfos: m };
  }),
  setCurrentPath: (currentPath) => set({ currentPath }),

  clientJoined: (c)  => set(s => ({ otherClients: [...s.otherClients, c] })),
  clientLeft:   (id) => set(s => ({ otherClients: s.otherClients.filter(x => x.id !== id) })),

  reset: () => set(initial()),
}));
