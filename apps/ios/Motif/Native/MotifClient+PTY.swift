import Foundation

// PTY lifecycle RPCs + the per-PTY live output fan-out channels.
extension MotifClient {
    func createPty(cmd: String? = nil, cwd: String? = nil, cols: UInt16 = 80, rows: UInt16 = 24) async throws -> MotifProto.PtyInfo {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "pty.create",
            params: MotifProto.PtyCreateParams(cmd: cmd, cwd: cwd, env: nil, cols: cols, rows: rows),
            as: MotifProto.PtyCreateResult.self
        )
        ptys.append(r.info)
        _ = ensureChannel(r.info.id)
        return r.info
    }

    func write(ptyID: String, data: Data) async {
        guard let rpc else { return }
        await rpc.writePty(ptyID: ptyID, data: data)
    }

    /// Change the active PTY's working directory by sending a `cd` command
    /// to its shell (single-quote escaped so spaces / special chars survive).
    /// Runs in the user's shell, so it respects aliases / functions and the
    /// shell-integration hooks update `pty.cwd` afterwards.
    func changeDirectory(ptyID: String, path: String) async {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        var data = Data("cd '\(escaped)'".utf8)
        data.append(0x0D) // CR = Enter
        await write(ptyID: ptyID, data: data)
    }

    /// Write raw bytes to a path on the server. Absolute paths are used
    /// as-is; relative paths are joined against the session workdir. Parent
    /// dirs are created server-side. Returns the written content's sha256.
    /// Used by image attach. Goes through `fs.write`'s binary variant (raw
    /// bytes over `application/octet-stream`), avoiding base64 inflation.
    @discardableResult
    func writeFile(path: String, data: Data) async throws -> String {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.writeFileBinary(path: path, data: data)
    }

    /// Send `text` to the PTY as an xterm bracketed paste
    /// (ESC[200~ … ESC[201~) — the same wrapping the `.paste` quick command
    /// uses, and the shape a terminal emits when a file is dragged in. Claude
    /// Code's paste handler inspects bracketed-paste content for image paths.
    func bracketedPaste(ptyID: String, text: String) async {
        var data = Data([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E])           // ESC [ 200 ~
        data.append(Data(text.utf8))
        data.append(contentsOf: [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E])   // ESC [ 201 ~
        await write(ptyID: ptyID, data: data)
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

    func activatePtyStream(ptyID: String) async {
        guard let rpc else { return }
        do {
            try await rpc.activatePty(ptyID: ptyID)
        } catch {
            log.error("pty stream activate \(ptyID, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    func deactivatePtyStream(ptyID: String) async {
        guard let rpc else { return }
        await rpc.deactivatePty(ptyID: ptyID)
    }

    // MARK: - Output channels

    /// Subscribe to a PTY's current live output stream. Historical bytes are
    /// no longer cached here; the active terminal runtime opens
    /// `/pty/<id>?since=<cursor>` through `RpcClient`, and motifd replays any
    /// missed server buffer before live bytes.
    func outputs(for ptyID: String, replayBuffered: Bool = true) -> AsyncStream<Data> {
        _ = replayBuffered
        let ch = ensureChannel(ptyID)
        let (stream, cont) = AsyncStream.makeStream(of: Data.self)
        let key = UUID()
        ch.subscribers[key] = cont
        cont.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.ptyChannels[ptyID]?.subscribers.removeValue(forKey: key)
            }
        }
        if ch.finished { cont.finish() }
        return stream
    }

    @discardableResult
    func ensureChannel(_ ptyID: String) -> PtyChannel {
        if let ch = ptyChannels[ptyID] { return ch }
        let ch = PtyChannel()
        ptyChannels[ptyID] = ch
        return ch
    }

    func appendOutput(ptyID: String, data: Data) {
        let ch = ensureChannel(ptyID)
        for (_, sub) in ch.subscribers { sub.yield(data) }
    }

    func finishChannel(_ ptyID: String) {
        guard let ch = ptyChannels[ptyID] else { return }
        ch.finished = true
        for (_, sub) in ch.subscribers { sub.finish() }
        ch.subscribers.removeAll()
    }

    func finishAllChannels() {
        for (_, ch) in ptyChannels {
            ch.finished = true
            for (_, sub) in ch.subscribers { sub.finish() }
            ch.subscribers.removeAll()
        }
    }
}
