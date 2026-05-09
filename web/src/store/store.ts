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
  BlockId, ClientInfo, GitFile, PtyInfo, SessionInfo,
  ShellContext, ShellKind, TreeEntry, ViewId, ViewInfo,
} from "../proto/types";
import type { RpcClient } from "../ws/client";

/** A single rendered block in the per-PTY stack.
 *  - `running`: the in-flight block (header only, body is the live xterm)
 *  - `card`:    a finalized block with serialized HTML body
 *  - `alt`:     a finalized block that entered alt-screen mode (no body)
 *
 *  `prompt_html` is the SerializeAddon-rendered HTML of the PS1 + typed
 *  command line — captured at command_started so the sticky header can
 *  render it with full ANSI colors (matches what the user originally saw
 *  in the live xterm). May be empty if capture failed (e.g. no shell
 *  integration, or backfilled history where we don't have the prompt
 *  bytes); callers fall back to `$ cmd` plain text.
 */
export type BlockRender =
  | {
      kind:        "running";
      id:          BlockId;
      cmd:         string;
      cwd:         string;
      started_at:  number;
      prompt_html: string;
    }
  | {
      kind:        "card";
      id:          BlockId;
      cmd:         string;
      cwd:         string;
      exit_code:   number | null;
      started_at:  number;
      finished_at: number;
      html_body:   string;
      prompt_html: string;
    }
  | {
      kind:        "alt";
      id:          BlockId;
      cmd:         string;
      cwd:         string;
      exit_code:   number | null;
      started_at:  number;
      finished_at: number;
      prompt_html: string;
    };

/** Per-PTY shell-integration + render state. */
export interface PtyRenderUi {
  /** Detected/announced shell kind. `unknown` means bootstrap timed out. */
  shell:  ShellKind | null;
  /** Ordered top-to-bottom (oldest first). The trailing entry, if any, is
   *  always the running block; everything else is finalized. */
  blocks: BlockRender[];
  /** Latest precmd context (git branch / venv chip in the topbar). */
  ctx:    ShellContext | null;
  /** Server signaled `pty.command_finished` but PtyTab hasn't yet drained
   *  + serialized the live xterm. Workspace stages the request here;
   *  PtyTab consumes it via an effect, runs the serialize pipeline, then
   *  calls `finalizeRunningBlock` (which clears this field). Decoupling
   *  this lets Workspace stay store-only while DOM-aware work lives in
   *  PtyTab. */
  pendingFinalize: { id: BlockId; exit_code: number | null; finished_at: number } | null;
  /** True once `pty.list_blocks` + `pty.get_block_output` finished for
   *  this PTY. Lets PtyTab skip backfill on remount (tab switch /
   *  StrictMode double-mount) and avoid re-issuing 50 RPCs.
   *  Survives transparent WS reconnect — the server replays missed
   *  events, so we don't re-backfill. */
  backfilled: boolean;
}

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

  /// After a transparent WS reconnect + session.attach, refresh the
  /// server-authoritative bits (session/clients/ptys/views) but keep
  /// local-only state (ptyBlocks, viewCache, dirChildren, expandedDirs)
  /// — the server replays missed events to bring blocks current.
  rehydrateOnReconnect: (
    s: SessionInfo, me: string, others: ClientInfo[],
    ptys: PtyInfo[], views: ViewInfo[], activeView: ViewId | null,
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
  updatePtyCwd:  (id: string, cwd: string) => void;
  setCurrentPath: (p: string) => void;

  // ── v2 shell-integration ──
  ptyBlocks:        Map<string, PtyRenderUi>;
  /// Currently-selected block — set by clicking a card header; observed
  /// by PtyTab to `scrollIntoView` the matching card and highlight its
  /// border. `null` means no selection.
  selectedBlock:    { ptyId: string; blockId: BlockId } | null;
  /// Server announced a shell on a PTY (or 5s timeout → "unknown").
  applyShellBootstrapped: (pty_id: string, shell: ShellKind) => void;
  /// `pty.command_started` arrived — append a `running` BlockRender.
  applyCommandStarted:    (pty_id: string, id: BlockId, text: string, cwd: string, started_at: number) => void;
  /// PtyTab serialized the prompt row (PS1 + typed command) — attach it
  /// to the trailing running block so the sticky header can render it.
  setRunningPromptHtml:   (pty_id: string, id: BlockId, html: string) => void;
  /// `pty.command_finished` arrived from the server — stage a pending
  /// finalize. PtyTab observes and runs serialize (then commits via
  /// `finalizeRunningBlock`).
  requestFinalizeBlock:   (pty_id: string, id: BlockId, exit_code: number | null, finished_at: number) => void;
  /// PtyTab finished serializing — replace the trailing `running` entry
  /// with `card`/`alt` and clear `pendingFinalize`. PtyTab is the only
  /// caller; serialization needs DOM access.
  finalizeRunningBlock:   (
    pty_id: string,
    id: BlockId,
    payload:
      | { kind: "card"; html_body: string; exit_code: number | null; finished_at: number }
      | { kind: "alt";  exit_code: number | null; finished_at: number },
  ) => void;
  applyShellContext:      (pty_id: string, ctx: ShellContext) => void;
  /// Replace the per-PTY history with backfilled cards (called after
  /// `pty.list_blocks` + serialize). Preserves any trailing `running`.
  setBackfilledBlocks:    (pty_id: string, blocks: BlockRender[]) => void;
  setSelectedBlock:       (pty_id: string | null, block_id: BlockId | null) => void;

  clientJoined:  (c: ClientInfo) => void;
  clientLeft:    (id: string) => void;

  reset: () => void;
}

const initial = (): Pick<AppState,
  "page"|"token"|"client"|"session"|"myClientId"|"otherClients"|
  "gitBranch"|"gitFiles"|"ptyInfos"|"ptyBlocks"|"selectedBlock"|
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
  ptyBlocks:     new Map(),
  selectedBlock: null,
  views:         [],
  activeView:    null,
  viewCache:     new Map(),
  currentPath:   "",
  dirChildren:   new Map(),
  expandedDirs:  new Set(),
  status:        "",
});

const emptyBlockUi = (): PtyRenderUi => ({ shell: null, blocks: [], ctx: null, pendingFinalize: null, backfilled: false });

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
      ptyBlocks:    new Map(),
      selectedBlock: null,
      views,
      activeView,
      viewCache:    new Map(),
      currentPath:  rootPath,
      dirChildren,
      expandedDirs: new Set<string>(),
    };
  }),

  rehydrateOnReconnect: (session, me, others, ptys, views, activeView) => set(s => {
    // Drop ptyInfos / ptyBlocks entries for PTYs the server no longer
    // knows about (died during the gap and was reaped past the ring).
    const knownPtyIds = new Set(ptys.map(p => p.id));
    const ptyBlocks = new Map<string, PtyRenderUi>();
    for (const [id, ui] of s.ptyBlocks) {
      if (knownPtyIds.has(id)) ptyBlocks.set(id, ui);
    }
    // Drop view caches for views that no longer exist.
    const viewIds = new Set(views.map(v => v.id));
    const viewCache = new Map<ViewId, ViewCache>();
    for (const [id, c] of s.viewCache) {
      if (viewIds.has(id)) viewCache.set(id, c);
    }
    return {
      session,
      myClientId:   me,
      otherClients: others,
      ptyInfos:     new Map(ptys.map(p => [p.id, p])),
      views,
      activeView,
      ptyBlocks,
      viewCache,
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
  updatePtyCwd: (id, cwd) => set(s => {
    const cur = s.ptyInfos.get(id);
    if (!cur) return {};
    const m = new Map(s.ptyInfos);
    m.set(id, { ...cur, cwd });
    return { ptyInfos: m };
  }),
  setCurrentPath: (currentPath) => set({ currentPath }),

  applyShellBootstrapped: (pty_id, shell) => set(s => {
    const m = new Map(s.ptyBlocks);
    const cur = m.get(pty_id) ?? emptyBlockUi();
    m.set(pty_id, { ...cur, shell });
    return { ptyBlocks: m };
  }),
  applyCommandStarted: (pty_id, id, text, cwd, started_at) => set(s => {
    const m = new Map(s.ptyBlocks);
    const cur = m.get(pty_id) ?? emptyBlockUi();
    // The broadcast stream is at-least-once around replay/re-attach edges.
    // Drop any prior copy of this block id before appending the live one, and
    // still enforce "only one trailing running block".
    const withoutSame = cur.blocks.filter(b => b.id !== id);
    const head = withoutSame.length > 0 && withoutSame[withoutSame.length - 1].kind === "running"
      ? withoutSame.slice(0, -1)
      : withoutSame;
    const next: BlockRender = { kind: "running", id, cmd: text, cwd, started_at, prompt_html: "" };
    m.set(pty_id, { ...cur, blocks: [...head, next] });
    return { ptyBlocks: m };
  }),
  setRunningPromptHtml: (pty_id, id, html) => set(s => {
    const m = new Map(s.ptyBlocks);
    const cur = m.get(pty_id);
    if (!cur || cur.blocks.length === 0) return {};
    const last = cur.blocks[cur.blocks.length - 1];
    if (last.kind !== "running" || last.id !== id) return {};
    const updated: BlockRender = { ...last, prompt_html: html };
    const blocks = [...cur.blocks.slice(0, -1), updated];
    m.set(pty_id, { ...cur, blocks });
    return { ptyBlocks: m };
  }),
  requestFinalizeBlock: (pty_id, id, exit_code, finished_at) => set(s => {
    const m = new Map(s.ptyBlocks);
    const cur = m.get(pty_id) ?? emptyBlockUi();
    m.set(pty_id, { ...cur, pendingFinalize: { id, exit_code, finished_at } });
    return { ptyBlocks: m };
  }),
  finalizeRunningBlock: (pty_id, id, payload) => set(s => {
    const m = new Map(s.ptyBlocks);
    const cur = m.get(pty_id);
    if (!cur || cur.blocks.length === 0) return {};
    const last = cur.blocks[cur.blocks.length - 1];
    if (last.kind !== "running" || last.id !== id) {
      // Running entry already gone (e.g. backfill replaced it). Just
      // clear pending so PtyTab doesn't keep re-running the effect.
      m.set(pty_id, { ...cur, pendingFinalize: null });
      return { ptyBlocks: m };
    }
    const finalized: BlockRender = payload.kind === "card"
      ? { kind: "card", id: last.id, cmd: last.cmd, cwd: last.cwd,
          started_at: last.started_at, finished_at: payload.finished_at,
          exit_code: payload.exit_code, html_body: payload.html_body,
          prompt_html: last.prompt_html }
      : { kind: "alt",  id: last.id, cmd: last.cmd, cwd: last.cwd,
          started_at: last.started_at, finished_at: payload.finished_at,
          exit_code: payload.exit_code, prompt_html: last.prompt_html };
    const blocks = [...cur.blocks.slice(0, -1), finalized];
    // Cap history to last 200 entries to keep DOM bounded; matches old recent[] cap.
    const trimmed = blocks.length > 200 ? blocks.slice(blocks.length - 200) : blocks;
    m.set(pty_id, { ...cur, blocks: trimmed, pendingFinalize: null });
    return { ptyBlocks: m };
  }),
  applyShellContext: (pty_id, ctx) => set(s => {
    const m = new Map(s.ptyBlocks);
    const cur = m.get(pty_id) ?? emptyBlockUi();
    m.set(pty_id, { ...cur, ctx });
    return { ptyBlocks: m };
  }),
  setBackfilledBlocks: (pty_id, blocks) => set(s => {
    const m = new Map(s.ptyBlocks);
    const cur = m.get(pty_id) ?? emptyBlockUi();
    // Merge by id: any blocks already in `cur.blocks` came in via live
    // events while backfill was loading — keep those (their HTML was
    // serialized from the live xterm and is more authoritative than a
    // re-render from server-stored bytes). Only adopt backfill entries
    // for ids `cur` doesn't have. Order: ULID-sorted ascending so
    // chronology is correct; any trailing `running` naturally lands
    // last because its id is the newest.
    const have = new Map(cur.blocks.map(b => [b.id, b] as const));
    for (const b of blocks) {
      if (!have.has(b.id)) have.set(b.id, b);
    }
    const merged = [...have.values()].sort((a, b) =>
      a.id < b.id ? -1 : a.id > b.id ? 1 : 0,
    );
    m.set(pty_id, { ...cur, blocks: merged, backfilled: true });
    return { ptyBlocks: m };
  }),
  setSelectedBlock: (pty_id, block_id) => set(() => ({
    selectedBlock: pty_id && block_id ? { ptyId: pty_id, blockId: block_id } : null,
  })),

  clientJoined: (c)  => set(s => ({ otherClients: [...s.otherClients, c] })),
  clientLeft:   (id) => set(s => ({ otherClients: s.otherClients.filter(x => x.id !== id) })),

  reset: () => set(initial()),
}));
