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
        var id: String { name }
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
        var ptys: [PtyInfo]?
        var views: [ViewInfo]?
        var active_view: String?
        var last_seq: UInt64?
    }

    // MARK: - PTYs

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
        var data_b64: String
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

    struct ViewInfo: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var spec: ViewSpec
        var created_at: UInt64?
    }

    /// Untagged ViewSpec — the wire form is one of:
    ///   {"type":"pty","pty_id":"..."}
    ///   {"type":"preview","path":"..."}
    ///   {"type":"diff","staged":bool,"path":"..."}
    ///   {"type":"image","path":"..."}
    /// We only act on `pty` for now; the rest decode loosely so we don't
    /// blow up on unknown variants.
    enum ViewSpec: Codable, Hashable, Sendable {
        case pty(ptyID: String)
        case other(typeName: String)

        private enum Keys: String, CodingKey {
            case type
            case pty_id
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            let type = (try? c.decode(String.self, forKey: .type)) ?? "?"
            if type == "pty" {
                let id = (try? c.decode(String.self, forKey: .pty_id)) ?? ""
                self = .pty(ptyID: id)
            } else {
                self = .other(typeName: type)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .pty(let id):
                try c.encode("pty", forKey: .type)
                try c.encode(id, forKey: .pty_id)
            case .other(let t):
                try c.encode(t, forKey: .type)
            }
        }
    }

    // MARK: - Server-pushed events

    /// Decoded form of a `pty.output` notification's params.
    struct PtyOutputEvent: Decodable {
        var pty_id: String
        var data_b64: String
        var seq: UInt64?
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
}
