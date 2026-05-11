import Foundation

/// Minimal subset of the motif JSON-RPC protocol shapes the native UI
/// needs. Names and field casing match the wire (i.e. the Rust types in
/// motif-proto and motif-server) so we can `JSONDecoder` straight off the
/// wire without custom keys.
enum MotifProto {
    // MARK: - Sessions

    struct SessionInfo: Codable, Identifiable, Hashable, Sendable {
        var name: String
        var workdir: String?
        var created_at: UInt64?
        /// How many WebSocket peers are currently attached to this session.
        /// Optional for forward-compat with motifd builds that predate the
        /// field; treat `nil` as "unknown" rather than "zero".
        var client_count: UInt32?
        var id: String { name }
    }

    /// Peer attached to the same session. Emitted in `session.attach` and
    /// kept in sync by `client.joined` / `client.left` events.
    struct ClientInfo: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var since: UInt64?
    }

    struct SessionListResult: Codable {
        var sessions: [SessionInfo]
    }

    struct SessionCreateParams: Codable {
        var name: String
        // motif-server's CreateParams.workdir is `PathBuf` (non-Optional);
        // sending null here is a deserialize error on the wire. We require
        // a value at the call site instead.
        var workdir: String
    }

    struct SessionCreateResult: Codable {
        var session: SessionInfo
    }

    struct SessionAttachParams: Codable {
        var name: String
        var last_seq: UInt64?
        var term_fg: String?
        var term_bg: String?
    }

    struct SessionAttachResult: Codable {
        var session: SessionInfo
        var client_id: String?
        var clients: [ClientInfo]?
        var ptys: [PtyInfo]?
        var views: [ViewInfo]?
        var active_view: String?
        var last_seq: UInt64?
    }

    struct SessionDestroyParams: Codable {
        var name: String
    }

    // MARK: - PTYs

    enum ShellKind: String, Codable, Sendable {
        case bash, zsh, fish, unknown
    }

    /// All-optional bundle of cheap context the shell's precmd hook
    /// publishes. Old clients ignore unknown fields; new servers tolerate
    /// missing ones — matches Rust's `#[serde(default,
    /// skip_serializing_if = "Option::is_none")]` per field.
    struct ShellContext: Codable, Sendable, Hashable {
        var branch: String?
        var head: String?
        var venv: String?
        var conda: String?
        var node: String?
    }

    struct PtyInfo: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var cmd: String?
        var cwd: String?
        var cols: UInt16
        var rows: UInt16
        var alive: Bool?
        var created_at: UInt64?
    }

    struct PtyListResult: Codable {
        var ptys: [PtyInfo]
    }

    struct PtyCreateParams: Codable {
        var cmd: String?
        var cwd: String?
        var env: [[String]]?    // [[k, v], ...]
        var cols: UInt16
        var rows: UInt16
    }

    struct PtyCreateResult: Codable {
        var info: PtyInfo
    }

    struct PtyWriteParams: Codable {
        var pty_id: String
        /// Wire field is named `data_b64` for backward compat with older
        /// JSON clients; JSONEncoder base64-encodes Data automatically and
        /// MessagePackEncoder writes it as native bin.
        var data: Data
        enum CodingKeys: String, CodingKey {
            case pty_id
            case data = "data_b64"
        }
    }

    struct PtyResizeParams: Codable {
        var pty_id: String
        var cols: UInt16
        var rows: UInt16
    }

    struct PtyKillParams: Codable {
        var pty_id: String
    }

    // MARK: - Views

    /// `view_id == nil` is the wire form of "no active view" — only used
    /// when the last view closes. We always send a real id from the
    /// client side.
    struct ViewActivateParams: Codable {
        var view_id: String?
    }

    struct ViewOpenParams: Codable {
        var spec: ViewSpec
        var activate: Bool
    }

    struct ViewOpenResult: Codable {
        var view: ViewInfo
    }

    struct ViewCloseParams: Codable {
        var view_id: String
    }

    struct ViewMoveParams: Codable {
        var view_id: String
        var to_index: Int
    }

    struct ViewInfo: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var spec: ViewSpec
        var created_at: UInt64?
    }

    /// Tagged enum matching Rust's `#[serde(tag = "kind", rename_all =
    /// "lowercase")]` on `motif_proto::view::ViewSpec`. The wire form is:
    ///
    ///   {"kind":"pty",     "pty_id":"sh-1"}
    ///   {"kind":"preview", "path":"src/main.rs"}
    ///   {"kind":"diff",    "staged":false, "path":"src/main.rs"|null}
    ///   {"kind":"image",   "path":"docs/screenshot.png"}
    ///
    /// `.other` is a forward-compat fallback for any future kind value
    /// — decoders treat it as opaque, and we never re-encode it (the UI
    /// won't try to round-trip an unknown spec).
    enum ViewSpec: Codable, Hashable, Sendable {
        case pty(ptyID: String)
        case preview(path: String)
        case diff(staged: Bool, path: String?)
        case image(path: String)
        case other(typeName: String)

        private enum Keys: String, CodingKey {
            case kind
            case pty_id
            case path
            case staged
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let kind = (try? c.decode(String.self, forKey: .kind)) ?? "?"
            switch kind {
            case "pty":
                let id = (try? c.decode(String.self, forKey: .pty_id)) ?? ""
                self = .pty(ptyID: id)
            case "preview":
                let p = (try? c.decode(String.self, forKey: .path)) ?? ""
                self = .preview(path: p)
            case "diff":
                let staged = (try? c.decode(Bool.self, forKey: .staged)) ?? false
                let path   = try? c.decodeIfPresent(String.self, forKey: .path)
                self = .diff(staged: staged, path: path ?? nil)
            case "image":
                let p = (try? c.decode(String.self, forKey: .path)) ?? ""
                self = .image(path: p)
            default:
                self = .other(typeName: kind)
            }
        }

        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .pty(let id):
                try c.encode("pty", forKey: .kind)
                try c.encode(id, forKey: .pty_id)
            case .preview(let p):
                try c.encode("preview", forKey: .kind)
                try c.encode(p, forKey: .path)
            case .diff(let staged, let path):
                try c.encode("diff", forKey: .kind)
                try c.encode(staged, forKey: .staged)
                // Match Rust's serde: emit `path` always, null when absent.
                try c.encode(path, forKey: .path)
            case .image(let p):
                try c.encode("image", forKey: .kind)
                try c.encode(p, forKey: .path)
            case .other(let t):
                try c.encode(t, forKey: .kind)
            }
        }
    }

    // MARK: - fs.*

    enum FileType: String, Codable, Sendable {
        case file, dir, symlink
    }

    enum GitFileStatus: String, Codable, Sendable {
        case unmodified, modified, added, deleted, renamed, copied, untracked, ignored, conflicted
    }

    struct TreeEntry: Codable, Sendable, Hashable, Identifiable {
        var name: String
        var type: FileType
        var size: UInt64
        var mtime: UInt64
        var git_status: GitFileStatus?
        var id: String { name }
    }

    struct FsTreeParams: Codable {
        var path: String
        var depth: UInt32?
        var show_hidden: Bool?
    }

    struct FsTreeResult: Codable {
        var path: String
        var entries: [TreeEntry]
    }

    struct FsStatParams: Codable {
        var path: String
    }

    struct FsStatResult: Codable {
        var type: FileType
        var size: UInt64
        var mtime: UInt64
        var git_status: GitFileStatus?
    }

    struct FsReadParams: Codable {
        var path: String
        var max_bytes: UInt64?
    }

    struct FsReadResult: Codable {
        var content_b64: String
        var sha256: String
        var truncated: Bool
        var binary: Bool
        var mime: String?
    }

    /// `expected_sha256 == nil` is the wire form of "I'm creating a new
    /// file / I don't care about racing"; the server still rejects on
    /// `Conflict (-32004)` when it would clobber existing content unless
    /// `force == true`.
    struct FsWriteParams: Codable {
        var path: String
        var content_b64: String
        var expected_sha256: String?
        var force: Bool
    }

    struct FsWriteResult: Codable {
        var sha256: String
    }

    struct FsMkdirParams: Codable {
        var path: String
    }

    struct FsRemoveParams: Codable {
        var path: String
    }

    struct FsRenameParams: Codable {
        var from: String
        var to: String
    }

    // MARK: - git.*

    struct GitFile: Codable, Sendable, Hashable {
        var path: String
        var staged: GitFileStatus
        var unstaged: GitFileStatus
    }

    struct GitStatusParams: Codable {
        var cwd: String?
    }

    struct GitStatusResult: Codable {
        var branch: String?
        var ahead: UInt32
        var behind: UInt32
        var files: [GitFile]
    }

    struct GitDiffParams: Codable {
        var path: String?
        var staged: Bool
        var cwd: String?
    }

    struct GitDiffResult: Codable {
        var patch: String
    }

    /// One row of `git.diffSummary` — same scope as `git.diff` but with
    /// per-file +/- counts pre-computed by the server.
    struct DiffSummaryFile: Codable, Sendable, Hashable {
        var path: String
        var additions: UInt32
        var deletions: UInt32
    }

    struct DiffSummaryResult: Codable {
        var files: [DiffSummaryFile]
    }

    // MARK: - Server-pushed events

    /// Decoded form of a `pty.output` notification's params.
    struct PtyOutputEvent: Decodable {
        var pty_id: String
        /// Wire field name is `data_b64` (kept for compat); JSON decoder
        /// base64-decodes the string, MessagePack decoder reads native bin.
        var data: Data
        var seq: UInt64?
        enum CodingKeys: String, CodingKey {
            case pty_id
            case data = "data_b64"
            case seq
        }
    }

    struct PtyExitedEvent: Decodable {
        var pty_id: String
        var exit_code: Int?
        var seq: UInt64?
    }

    struct PtyResizeEvent: Decodable {
        var pty_id: String
        var cols: UInt16
        var rows: UInt16
        var seq: UInt64?
    }

    struct PtyCwdChangedEvent: Decodable {
        var pty_id: String
        var cwd: String
        var seq: UInt64?
    }

    struct PtyCreatedEvent: Decodable {
        var info: PtyInfo
        var seq: UInt64?
    }

    /// `tree.changed` — fs notify batch. `paths` are absolute paths whose
    /// `fs.tree` listings may now be stale.
    struct TreeChangedEvent: Decodable {
        var paths: [String]
        var seq: UInt64?
    }

    struct GitChangedEvent: Decodable {
        var seq: UInt64?
    }

    struct ClientJoinedEvent: Decodable {
        var client_id: String
        var since: UInt64?
        var seq: UInt64?
    }

    struct ClientLeftEvent: Decodable {
        var client_id: String
        var seq: UInt64?
    }

    struct ViewOpenedEvent: Decodable {
        var view: ViewInfo
        var seq: UInt64?
    }

    struct ViewClosedEvent: Decodable {
        var view_id: String
        var seq: UInt64?
    }

    struct ViewActiveChangedEvent: Decodable {
        var view_id: String?
        var seq: UInt64?
    }

    struct ViewMovedEvent: Decodable {
        var order: [String]
        var seq: UInt64?
    }

    struct PtyShellBootstrappedEvent: Decodable {
        var pty_id: String
        var shell: ShellKind
        var seq: UInt64?
    }

    struct PtyShellContextEvent: Decodable {
        var pty_id: String
        var ctx: ShellContext
        var seq: UInt64?
    }

    /// `pty.command_started` — fires when the shell hands a command line off
    /// to the kernel (FinalTerm 133;C boundary). `text` is the OSC 7770
    /// logical command string, "" when the shell didn't emit one.
    struct PtyCommandStartedEvent: Decodable {
        var pty_id: String
        var block_id: String
        var text: String
        var cwd: String?
        var started_at: UInt64?
        var seq: UInt64?
    }

    struct PtyCommandFinishedEvent: Decodable {
        var pty_id: String
        var block_id: String
        var exit_code: Int?
        var finished_at: UInt64?
        var seq: UInt64?
    }
}
