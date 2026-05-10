import Foundation
import Observation
import OSLog

/// High-level client around RpcClient that owns the active session +
/// PTY list and surfaces protocol events as observable state.
///
/// Lifecycle:
///   1. `connect(server:)` opens the WS to the local proxy (which forwards
///      to motifd over tsnet).
///   2. `attach(sessionName:)` joins a session and seeds the PTY/view
///      lists from the attach response.
///   3. UI subscribes to per-PTY output via `subscribe(ptyID:)`.
@MainActor
@Observable
final class MotifClient {
    private let log = Logger(subsystem: "io.allsunday.motif", category: "MotifClient")
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        case attached(session: String)
        case failed(message: String)
    }

    private(set) var state: State = .disconnected
    private(set) var sessions: [MotifProto.SessionInfo] = []
    private(set) var ptys: [MotifProto.PtyInfo] = []
    private(set) var views: [MotifProto.ViewInfo] = []
    private(set) var activeViewID: String?
    private(set) var lastSeq: UInt64 = 0

    private var rpc: RpcClient?
    private var eventTask: Task<Void, Never>?
    /// Per-PTY output multiplexer. One AsyncStream per pty_id, fed from
    /// the central event task.
    private var outputStreams: [String: (AsyncStream<Data>, AsyncStream<Data>.Continuation)] = [:]

    func connect(localPort: UInt16) async {
        if case .connected = state { return }
        if case .attached = state { return }
        state = .connecting
        let url = URL(string: "ws://127.0.0.1:\(localPort)/ws")!
        let rpc = RpcClient()
        do {
            try await rpc.connect(url: url)
        } catch {
            state = .failed(message: "ws connect: \(error)")
            return
        }
        self.rpc = rpc
        state = .connected
        eventTask = Task { [weak self] in
            guard let stream = self?.rpc?.events else { return }
            for await event in stream {
                self?.handleEvent(event)
            }
        }
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        if let rpc { await rpc.close() }
        rpc = nil
        for (_, pair) in outputStreams { pair.1.finish() }
        outputStreams.removeAll()
        ptys = []
        views = []
        activeViewID = nil
        state = .disconnected
    }

    // MARK: - Sessions

    func refreshSessions() async {
        guard let rpc else { return }
        do {
            let r = try await rpc.call("session.list", as: MotifProto.SessionListResult.self)
            sessions = r.sessions
        } catch {
            log.error("session.list: \(String(describing: error), privacy: .public)")
        }
    }

    func createSession(name: String, workdir: String?) async throws -> MotifProto.SessionInfo {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "session.create",
            params: MotifProto.SessionCreateParams(name: name, workdir: workdir),
            as: MotifProto.SessionCreateResult.self
        )
        sessions.append(r.session)
        return r.session
    }

    /// Leave the currently attached session but keep the WS connection
    /// alive — we go back to .connected so the UI lands on the session
    /// picker again. Different from `disconnect()` which closes the WS.
    func detach() async {
        guard let rpc else {
            state = .disconnected
            return
        }
        do {
            _ = try await rpc.call("session.detach")
        } catch {
            log.error("session.detach: \(String(describing: error), privacy: .public)")
            // Even if the server-side detach failed, locally tear down so
            // the user can still get back to the picker.
        }
        // Close any per-PTY output streams so the next attach starts fresh.
        for (_, pair) in outputStreams { pair.1.finish() }
        outputStreams.removeAll()
        ptys = []
        views = []
        activeViewID = nil
        state = .connected
    }

    func attach(sessionName: String) async throws {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "session.attach",
            params: MotifProto.SessionAttachParams(name: sessionName, last_seq: nil, term_fg: nil, term_bg: nil),
            as: MotifProto.SessionAttachResult.self
        )
        ptys = r.ptys ?? []
        views = r.views ?? []
        activeViewID = r.active_view
        lastSeq = r.last_seq ?? 0
        state = .attached(session: sessionName)
        log.notice("attached to \(sessionName, privacy: .public): \(self.ptys.count, privacy: .public) ptys, \(self.views.count, privacy: .public) views")
    }

    // MARK: - PTYs

    func createPty(cmd: String? = nil, cwd: String? = nil, cols: UInt16 = 80, rows: UInt16 = 24) async throws -> MotifProto.PtyInfo {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "pty.create",
            params: MotifProto.PtyCreateParams(cmd: cmd, cwd: cwd, env: nil, cols: cols, rows: rows),
            as: MotifProto.PtyCreateResult.self
        )
        ptys.append(r.info)
        return r.info
    }

    func write(ptyID: String, data: Data) async {
        guard let rpc else { return }
        let b64 = data.base64EncodedString()
        do {
            _ = try await rpc.call("pty.write", params: MotifProto.PtyWriteParams(pty_id: ptyID, data_b64: b64))
        } catch {
            log.error("pty.write: \(String(describing: error), privacy: .public)")
        }
    }

    func resize(ptyID: String, cols: UInt16, rows: UInt16) async {
        guard let rpc else { return }
        do {
            _ = try await rpc.call("pty.resize", params: MotifProto.PtyResizeParams(pty_id: ptyID, cols: cols, rows: rows))
        } catch {
            log.error("pty.resize: \(String(describing: error), privacy: .public)")
        }
    }

    func kill(ptyID: String) async {
        guard let rpc else { return }
        do {
            _ = try await rpc.call("pty.kill", params: MotifProto.PtyKillParams(pty_id: ptyID))
        } catch {
            log.error("pty.kill: \(String(describing: error), privacy: .public)")
        }
    }

    /// Subscribe to a PTY's output stream. The first subscriber on a PTY
    /// id creates the stream; subsequent subscribers share it (they all
    /// see the same bytes — currently we expect one terminal view per
    /// PTY, but the API doesn't enforce it).
    func outputs(for ptyID: String) -> AsyncStream<Data> {
        if let existing = outputStreams[ptyID] {
            return existing.0
        }
        let pair = AsyncStream.makeStream(of: Data.self)
        outputStreams[ptyID] = (pair.stream, pair.continuation)
        return pair.stream
    }

    // MARK: - Events

    private func handleEvent(_ event: RpcClient.Event) {
        switch event.method {
        case "pty.output":
            guard let payload = try? JSONDecoder().decode(MotifProto.PtyOutputEvent.self, from: event.params),
                  let bytes = Data(base64Encoded: payload.data_b64)
            else { return }
            if let cont = outputStreams[payload.pty_id]?.1 {
                cont.yield(bytes)
            }
            if let s = payload.seq { lastSeq = max(lastSeq, s) }

        case "pty.exited":
            guard let payload = try? JSONDecoder().decode(MotifProto.PtyExitedEvent.self, from: event.params)
            else { return }
            // Mark dead in our cached list + close the output stream.
            if let i = ptys.firstIndex(where: { $0.id == payload.pty_id }) {
                ptys[i].alive = false
            }
            outputStreams[payload.pty_id]?.1.finish()
            outputStreams.removeValue(forKey: payload.pty_id)

        case "pty.resize":
            if let payload = try? JSONDecoder().decode(MotifProto.PtyResizeEvent.self, from: event.params),
               let i = ptys.firstIndex(where: { $0.id == payload.pty_id })
            {
                ptys[i].cols = payload.cols
                ptys[i].rows = payload.rows
            }

        default:
            // We ignore everything else (view.*, tree.*, git.*, client.*,
            // pty.shell_*) for the MVP. Add cases as the UI grows.
            break
        }
    }
}
