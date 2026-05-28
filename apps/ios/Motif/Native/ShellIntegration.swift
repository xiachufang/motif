import Foundation

/// Per-PTY shell-integration parser. Consumes raw PTY bytes, separates
/// Motif private OSC 777 markers from passthrough
/// terminal output, and drives a block state machine that emits high-
/// level events. Mirrors the Rust parser in
/// `crates/motif-client/src/shell_integration.rs`; this is the Swift
/// half of the Phase-5b client-side OSC parsing migration.
///
/// Coverage:
///   - OSC 777;A → promptStarted
///   - OSC 777;B → promptEnded
///   - OSC 777;E → cmd text staged for the next command start
///   - OSC 777;C → commandStarted
///   - OSC 777;D[;exit] → commandFinished
///   - OSC 777;P;Cwd=... → cwdChanged
///   - OSC 777;P;Context=... → shellContext snapshot
///
/// Out of scope (deferred for parity with the Rust state machine):
///   - Per-segment truncation buffers (the Rust parser tracked them
///     for BlockStore backfill; client-side block UIs scroll-buffer
///     the raw stream instead, so we drop the prompt/command/output
///     byte buffers)
///   - DCS / Kitty keyboard / DA2 / XtVersion answers (those are
///     still handled server-side by motifd's reader_loop and never
///     reach the /pty/<id> stream).
enum ShellEvent: Equatable {
    case bootstrapped(shell: String)
    case promptStarted(blockID: String)
    case promptEnded(blockID: String)
    case commandStarted(blockID: String, text: String, cwd: String, startedAt: UInt64)
    case commandFinished(blockID: String, exitCode: Int?, finishedAt: UInt64)
    case shellContext(ctx: [String: String])
    case cwdChanged(cwd: String)
}

enum ShellOutputScope: String, Codable {
    case prompt      = "Prompt"
    case command     = "Command"
    case output      = "Output"
    case passthrough = "Passthrough"
}

final class ShellState {
    /// Active block id, if any. Stable across a prompt → command →
    /// output cycle.
    private(set) var activeBlockID: String?
    /// Currently-active scope — drives `pty.output.scope` in the
    /// synthesized notifications.
    private(set) var activeScope: ShellOutputScope = .passthrough

    private var stage: Stage = .unknown
    private var currentCwd: String = ""
    /// Explicit command text normally arrives just before command start;
    /// stash it and consume on the next command-start marker so a missing
    /// explicit command marker doesn't block the
    /// transition.
    private var pendingCmd: String?
    private(set) var bootstrapAnnounced = false
    /// Walks the byte stream and pulls OSC markers out.
    private let scanner = OscScanner()

    enum Stage {
        case unknown
        case atPrompt(blockID: String, cwd: String, startedAt: UInt64)
        case composing(blockID: String, cwd: String, startedAt: UInt64)
        case running(blockID: String, cmd: String, cwd: String, startedAt: UInt64)
    }

    /// Drives the parser on a chunk of PTY bytes. Returns:
    ///   - `passthrough`: bytes with OSC markers stripped, ready to
    ///      forward to the terminal renderer.
    ///   - `events`: high-level shell events emitted by the state
    ///      machine in arrival order.
    func feed(_ data: Data) -> (passthrough: Data, events: [ShellEvent]) {
        let scan = scanner.feed(data)
        var events: [ShellEvent] = []
        var passthrough = Data()
        passthrough.reserveCapacity(scan.passthrough.count)
        for item in scan.items {
            switch item {
            case .bytes(let b):
                passthrough.append(b)
            case .marker(let m):
                events.append(contentsOf: handle(m))
            }
        }
        return (passthrough, events)
    }

    /// Force-finalize any in-flight block. Called when the WS closes
    /// so a CommandFinished event still fires (mirrors the Rust
    /// `on_exit`).
    func onClose() -> ShellEvent? {
        switch stage {
        case .running(let id, _, _, _):
            return .commandFinished(blockID: id, exitCode: nil, finishedAt: nowMs())
        default:
            return nil
        }
    }

    // ─── private state-machine glue ────────────────────────────────

    private func handle(_ m: OscMarker) -> [ShellEvent] {
        var out: [ShellEvent] = []
        let bootstrap = firstOscSeen(out: &out)
        if let bs = bootstrap { out.insert(bs, at: 0) }
        switch m {
        case .osc7Cwd(let cwd):
            if cwd != currentCwd {
                currentCwd = cwd
                out.append(.cwdChanged(cwd: cwd))
            }
        case .osc133PromptStart:
            pendingCmd = nil
            // Pure redraw → keep block id; fresh start / running→A → new id.
            let cwd = currentCwd.isEmpty ? "/" : currentCwd
            switch stage {
            case .atPrompt(let id, let c, let at),
                 .composing(let id, let c, let at):
                stage = .atPrompt(blockID: id, cwd: c, startedAt: at)
                out.append(.promptStarted(blockID: id))
            case .running(let id, let cmd, let c, let at):
                out.append(.commandFinished(blockID: id, exitCode: nil, finishedAt: nowMs()))
                _ = cmd; _ = c; _ = at
                let newID = ULIDString()
                stage = .atPrompt(blockID: newID, cwd: cwd, startedAt: nowMs())
                out.append(.promptStarted(blockID: newID))
            case .unknown:
                let newID = ULIDString()
                stage = .atPrompt(blockID: newID, cwd: cwd, startedAt: nowMs())
                out.append(.promptStarted(blockID: newID))
            }
        case .osc133PromptEnd:
            if case .atPrompt(let id, let c, let at) = stage {
                out.append(.promptEnded(blockID: id))
                stage = .composing(blockID: id, cwd: c, startedAt: at)
            }
        case .osc7770Cmd(let text):
            pendingCmd = text
        case .osc133CmdStart(let cmdlineUrl):
            // Consume explicit command text; transition Composing → Running.
            if case .composing(let id, let c, _) = stage {
                let cmd = cmdlineUrl ?? pendingCmd ?? ""
                pendingCmd = nil
                let startedAt = nowMs()
                stage = .running(blockID: id, cmd: cmd, cwd: c, startedAt: startedAt)
                out.append(.commandStarted(blockID: id, text: cmd, cwd: c, startedAt: startedAt))
            }
        case .osc133CmdEnd(let exit):
            pendingCmd = nil
            if case .running(let id, _, _, _) = stage {
                out.append(.commandFinished(blockID: id, exitCode: exit, finishedAt: nowMs()))
                stage = .unknown
            }
        case .osc7771Context(let ctx):
            out.append(.shellContext(ctx: ctx))
        }
        // Refresh the public projections after each marker.
        switch stage {
        case .unknown:                       activeBlockID = nil;          activeScope = .passthrough
        case .atPrompt(let id, _, _):        activeBlockID = id;           activeScope = .prompt
        case .composing(let id, _, _):       activeBlockID = id;           activeScope = .command
        case .running(let id, _, _, _):      activeBlockID = id;           activeScope = .output
        }
        return out
    }

    private func firstOscSeen(out: inout [ShellEvent]) -> ShellEvent? {
        if bootstrapAnnounced { return nil }
        bootstrapAnnounced = true
        // We don't know the shell kind from raw OSC alone; iOS-side
        // detection would need to inspect the bootstrap-script
        // identifier (out of scope here). Report `unknown`.
        return .bootstrapped(shell: "unknown")
    }

    func recordOutputScope(_ scope: ShellOutputScope) {
        activeScope = scope
    }
}

/// One element of the parser's scan output.
private enum ScanItem {
    case bytes(Data)
    case marker(OscMarker)
}

/// OSC markers the parser recognizes. Mirrors the subset of
/// `motif_proto::terminal_query::QueryKind` that's shell-integration.
private enum OscMarker {
    case osc7Cwd(String)
    case osc133PromptStart
    case osc133PromptEnd
    case osc133CmdStart(String?) // command start, optional cmdline_url from legacy 133;C
    case osc133CmdEnd(Int?)    // command end, optional exit
    case osc7770Cmd(String)
    case osc7771Context([String: String])
}

private struct ScanResult {
    var items: [ScanItem] = []
    var passthrough: Data  = Data()
}

/// Minimal OSC scanner. Looks for `ESC ] payload BEL` (or `ESC ] payload
/// ESC \\`) sequences. Anything that isn't a recognized shell-integration
/// marker is passed through verbatim — including DCS sequences and
/// terminal capability queries, which the server already strips on the
/// /pty/<id> side.
private final class OscScanner {
    private var pending: [UInt8] = []
    private var inOsc = false

    func feed(_ data: Data) -> ScanResult {
        var r = ScanResult()
        for b in data {
            step(b, &r)
        }
        return r
    }

    private func step(_ b: UInt8, _ r: inout ScanResult) {
        if !inOsc {
            if b == 0x1b {
                pending = [b]
                inOsc = true
            } else {
                appendPassthrough(b, &r)
            }
            return
        }
        pending.append(b)
        // Need at least ESC + one byte.
        if pending.count == 2 {
            if pending[1] != 0x5d /* ']' */ {
                // Not OSC — flush as passthrough and reset.
                for byte in pending { appendPassthrough(byte, &r) }
                pending.removeAll(); inOsc = false
            }
            return
        }
        // Watching for BEL or ESC \ terminator.
        let isBel = b == 0x07
        let isSt  = pending.count >= 3 && pending[pending.count - 2] == 0x1b && b == 0x5c
        if !isBel && !isSt {
            // Bound runaway escapes — flush if it gets ridiculous.
            if pending.count > 4096 {
                for byte in pending { appendPassthrough(byte, &r) }
                pending.removeAll(); inOsc = false
            }
            return
        }
        // Have a complete OSC. Body is between `ESC ]` and the
        // terminator.
        let bodyEnd = isSt ? pending.count - 2 : pending.count - 1
        let body = Array(pending[2..<bodyEnd])
        if let marker = parseOscBody(body) {
            r.items.append(.marker(marker))
        } else {
            // Unknown OSC — pass through verbatim so the terminal
            // emulator gets a chance at it.
            for byte in pending { appendPassthrough(byte, &r) }
        }
        pending.removeAll(); inOsc = false
    }

    private func appendPassthrough(_ b: UInt8, _ r: inout ScanResult) {
        r.passthrough.append(b)
        if case .bytes(var buf)? = r.items.last {
            buf.append(b)
            r.items[r.items.count - 1] = .bytes(buf)
        } else {
            r.items.append(.bytes(Data([b])))
        }
    }
}

/// Parse an OSC payload (between `ESC ]` and the terminator) into a
/// recognized shell-integration marker. Returns nil for anything
/// unfamiliar.
private func parseOscBody(_ body: [UInt8]) -> OscMarker? {
    guard let s = String(bytes: body, encoding: .utf8) else { return nil }
    // Split on the leading "N;..." prefix.
    guard let semi = s.firstIndex(of: ";") else {
        // Compatibility for malformed semicolon-less parsing paths.
        if s == "133;A" { return .osc133PromptStart }
        if s == "133;B" { return .osc133PromptEnd }
        if s == "133;C" { return .osc133CmdStart(nil) }
        if s == "133;D" { return .osc133CmdEnd(nil) }
        return nil
    }
    let kind = String(s[..<semi])
    let rest = String(s[s.index(after: semi)...])
    switch kind {
    case "7":
        // file://host/path  — host is informational; we keep just path.
        if let url = URL(string: rest), let path = url.path.removingPercentEncoding {
            return .osc7Cwd(path)
        }
        return .osc7Cwd(rest)
    case "133":
        return parse133(rest)
    case "777":
        return parse777(rest)
    case "7770":
        guard let text = decodeHexString(rest) else { return nil }
        return .osc7770Cmd(text)
    case "7771":
        guard let ctx = parseContextHex(rest) else { return nil }
        return .osc7771Context(ctx)
    default:
        return nil
    }
}

private func parse133(_ rest: String) -> OscMarker? {
    let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first else { return nil }
    switch first {
    case "A": return .osc133PromptStart
    case "B": return .osc133PromptEnd
    case "C":
        let cmdlineUrl = parts.count == 2 ? parse133CmdlineUrl(String(parts[1])) : nil
        return .osc133CmdStart(cmdlineUrl)
    case "D":
        let firstField = parts.count == 2 ? String(parts[1]).split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" : ""
        if let exit = Int(firstField.trimmingCharacters(in: .whitespaces)) {
            return .osc133CmdEnd(exit)
        }
        return .osc133CmdEnd(nil)
    default:  return nil
    }
}

private func parse777(_ rest: String) -> OscMarker? {
    let parts = rest.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
    guard let first = parts.first else { return nil }
    let tail = parts.count == 2 ? String(parts[1]) : nil
    switch first {
    case "A": return .osc133PromptStart
    case "B": return .osc133PromptEnd
    case "C": return .osc133CmdStart(nil)
    case "D":
        let firstField = tail?.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if let exit = Int(firstField.trimmingCharacters(in: .whitespaces)) {
            return .osc133CmdEnd(exit)
        }
        return .osc133CmdEnd(nil)
    case "E":
        guard let tail, let text = decodeHexString(tail) else { return nil }
        return .osc7770Cmd(text)
    case "P":
        guard let tail else { return nil }
        if tail.hasPrefix("Cwd=") {
            return .osc7Cwd(parseCwd(String(tail.dropFirst(4))))
        }
        if tail.hasPrefix("Context="), let ctx = parseContextHex(String(tail.dropFirst(8))) {
            return .osc7771Context(ctx)
        }
        return nil
    default:
        return nil
    }
}

private func parse133CmdlineUrl(_ tail: String) -> String? {
    for piece in tail.split(separator: ";", omittingEmptySubsequences: false) {
        let s = String(piece)
        if s.hasPrefix("cmdline_url=") {
            let raw = String(s.dropFirst("cmdline_url=".count))
            return raw.removingPercentEncoding ?? raw
        }
    }
    return nil
}

private func parseCwd(_ raw: String) -> String {
    if let url = URL(string: raw), let path = url.path.removingPercentEncoding {
        return path
    }
    return raw.removingPercentEncoding ?? raw
}

private func decodeHexString(_ hex: String) -> String? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data()
    data.reserveCapacity(hex.count / 2)
    var idx = hex.startIndex
    while idx < hex.endIndex {
        let next = hex.index(idx, offsetBy: 2)
        guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
        data.append(byte)
        idx = next
    }
    return String(data: data, encoding: .utf8)
}

private func parseContextHex(_ hex: String) -> [String: String]? {
    guard let json = decodeHexString(hex), let data = json.data(using: .utf8) else { return nil }
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let dict = object as? [String: Any] else { return nil }
    var out: [String: String] = [:]
    for (key, value) in dict {
        if let s = value as? String {
            out[key] = s
        }
    }
    return out
}

/// Quick ULID-like 26-char base32 id. We don't need full ULID precision
/// here — clients only use this for block correlation within a single
/// PTY session, and a 130-bit random suffix from `SystemRandomNumberGenerator`
/// is more than enough to avoid collisions across pure redraw cycles.
private func ULIDString() -> String {
    let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    var bytes = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    var out = ""
    for b in bytes {
        out.append(alphabet[Int(b & 0x1f)])
        out.append(alphabet[Int((b >> 5) & 0x1f)])
    }
    return String(out.prefix(26))
}

private func nowMs() -> UInt64 {
    UInt64(Date().timeIntervalSince1970 * 1000)
}
