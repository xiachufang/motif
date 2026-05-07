// Hand-written TypeScript mirrors of motif-proto. Keep these in sync with
// crates/motif-proto/src/*.rs. Future work: derive via `ts-rs`.

export type SessionId = string;
export type ClientId  = string;
export type PtyId     = string;
export type Seq       = number;

export interface SessionInfo {
  id:           SessionId;
  name:         string;
  workdir:      string;
  created_at:   number;
  client_count: number;
}
export interface ClientInfo { id: ClientId; since: number }

export interface AttachResult {
  session:     SessionInfo;
  client_id:   ClientId;
  clients:     ClientInfo[];
  ptys:        PtyInfo[];
  views:       ViewInfo[];
  active_view: ViewId | null;
  last_seq:    Seq;
}
export interface ListResult { sessions: SessionInfo[] }

export type FileType = "file" | "dir" | "symlink";
export interface TreeEntry {
  name:        string;
  type:        FileType;
  size:        number;
  mtime:       number;
  git_status?: GitFileStatus | null;
}
export interface TreeResult { path: string; entries: TreeEntry[] }

export interface ReadResult {
  content_b64: string;
  sha256:      string;
  truncated:   boolean;
  binary:      boolean;
  mime?:       string | null;
}

export type GitFileStatus =
  | "unmodified" | "modified" | "added" | "deleted" | "renamed"
  | "copied" | "untracked" | "ignored" | "conflicted";

export interface GitFile {
  path:     string;
  staged:   GitFileStatus;
  unstaged: GitFileStatus;
}
export interface StatusResult {
  branch?: string | null;
  ahead:   number;
  behind:  number;
  files:   GitFile[];
}
export interface DiffResult { patch: string }

export interface PtyInfo {
  id:         PtyId;
  cmd:        string;
  cwd:        string;
  cols:       number;
  rows:       number;
  alive:      boolean;
  created_at: number;
  /** Best-effort name of the foreground process inside this PTY (e.g.
   *  "zsh", "vim", "cargo"). Undefined until the server's watcher resolves
   *  it on its first poll. */
  fg_name?:   string | null;
}

export type Event =
  | { method: "tree.changed";   params: { paths: string[]; seq: Seq } }
  | { method: "pty.output";     params: { pty_id: PtyId; data_b64: string; seq: Seq } }
  | { method: "pty.resize";     params: { pty_id: PtyId; cols: number; rows: number; seq: Seq } }
  | { method: "pty.created";    params: { info: PtyInfo; seq: Seq } }
  | { method: "pty.exited";     params: { pty_id: PtyId; exit_code: number | null; seq: Seq } }
  | { method: "pty.fg_changed"; params: { pty_id: PtyId; cwd: string; name: string | null; seq: Seq } }
  | { method: "git.changed";    params: { seq: Seq } }
  | { method: "client.joined";  params: { client_id: ClientId; since: number; seq: Seq } }
  | { method: "client.left";    params: { client_id: ClientId; seq: Seq } }
  | { method: "view.opened";    params: { view: ViewInfo; seq: Seq } }
  | { method: "view.closed";    params: { view_id: ViewId; seq: Seq } }
  | { method: "view.active_changed"; params: { view_id: ViewId | null; seq: Seq } }
  | { method: "view.moved";     params: { order: ViewId[]; seq: Seq } };

// ── View / tab synchronization ───────────────────────────────────────────

export type ViewId = string;

export type ViewSpec =
  | { kind: "pty";     pty_id: PtyId }
  | { kind: "preview"; path:   string }
  | { kind: "diff";    staged: boolean; path?: string | null }
  | { kind: "image";   path:   string };

export interface ViewInfo {
  id:         ViewId;
  spec:       ViewSpec;
  created_at: number;
}

export interface OpenBlobResult {
  transfer_id: string;
  blob_path:   string;
  expires_at:  number;
  size?:       number | null;
  mime?:       string | null;
  sha256?:     string | null;
}
