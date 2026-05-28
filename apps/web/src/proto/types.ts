// Hand-written TypeScript mirrors of motif-proto. Keep these in sync with
// crates/motif-proto/src/*.rs. Future work: derive via `ts-rs`.

/** Frozen `service` magic string returned by `GET /ping`. Mirrors
 *  `motif_proto::ping::PING_SERVICE`. Identity probe, not a version check. */
export const PING_SERVICE = "motif-server";

export interface PingInfo {
  service: string;
  version: string;
}

export type SessionId = string;
export type ClientId  = string;
export type PtyId     = string;
export type Seq       = number;
/** ULID text for a shell-integration block (one command's lifecycle). */
export type BlockId   = string;

export type ShellKind = "bash" | "zsh" | "fish" | "unknown";

/** Cheap-to-compute prompt context emitted by the shell's precmd hook. */
export interface ShellContext {
  branch?: string | null;
  head?:   string | null;
  venv?:   string | null;
  conda?:  string | null;
  node?:   string | null;
}

/** Which segment of a block a chunk of bytes belongs to.
 *
 *  `passthrough` is for bytes that aren't part of any block — pre-bootstrap
 *  banners, between-block housekeeping (`777;D` to next `777;A`), or shells
 *  with shell-integration disabled. `block_id` is always null for these.
 *  `prompt` / `command` / `output` correspond to shell-integration zones. */
export type OutputScope = "passthrough" | "prompt" | "command" | "output";

export interface BlockSummary {
  id:                BlockId;
  cwd:               string;
  cmd:               string;
  started_at:        number;
  finished_at?:      number | null;
  exit_code?:        number | null;
  prompt_size:       number;
  prompt_truncated:  boolean;
  command_size:      number;
  command_truncated: boolean;
  output_size:       number;
  output_truncated:  boolean;
}

export interface GetBlockOutputResult {
  prompt_b64:        string;
  prompt_truncated:  boolean;
  command_b64:       string;
  command_truncated: boolean;
  output_b64:        string;
  output_truncated:  boolean;
}

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
  theme?:      "light" | "dark";
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
}

export type Event =
  | { method: "tree.changed";   params: { paths: string[]; seq: Seq } }
  | { method: "pty.output";     params: { pty_id: PtyId; data_b64: string; block_id?: BlockId | null; scope: OutputScope; seq: Seq } }
  | { method: "pty.resize";     params: { pty_id: PtyId; cols: number; rows: number; seq: Seq } }
  | { method: "pty.created";    params: { info: PtyInfo; seq: Seq } }
  | { method: "pty.exited";     params: { pty_id: PtyId; exit_code: number | null; seq: Seq } }
  | { method: "pty.reset";      params: { pty_id: PtyId } }
  | { method: "pty.cwd_changed"; params: { pty_id: PtyId; cwd: string; seq: Seq } }
  | { method: "git.changed";    params: { seq: Seq } }
  | { method: "client.joined";  params: { client_id: ClientId; since: number; seq: Seq } }
  | { method: "client.left";    params: { client_id: ClientId; seq: Seq } }
  | { method: "view.opened";    params: { view: ViewInfo; seq: Seq } }
  | { method: "view.closed";    params: { view_id: ViewId; seq: Seq } }
  | { method: "view.active_changed"; params: { view_id: ViewId | null; seq: Seq } }
  | { method: "view.moved";     params: { order: ViewId[]; seq: Seq } }
  | { method: "session.theme_changed"; params: { theme: "light" | "dark"; seq: Seq } }
  // ── v2 shell-integration ──
  | { method: "pty.shell_bootstrapped"; params: { pty_id: PtyId; shell: ShellKind; seq: Seq } }
  | { method: "pty.prompt_started";     params: { pty_id: PtyId; block_id: BlockId; seq: Seq } }
  | { method: "pty.prompt_ended";       params: { pty_id: PtyId; block_id: BlockId; seq: Seq } }
  | { method: "pty.command_started";    params: { pty_id: PtyId; block_id: BlockId; text: string; cwd: string; started_at: number; seq: Seq } }
  | { method: "pty.command_finished";   params: { pty_id: PtyId; block_id: BlockId; exit_code?: number | null; finished_at: number; seq: Seq } }
  | { method: "pty.shell_context";      params: { pty_id: PtyId; ctx: ShellContext; seq: Seq } };

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
