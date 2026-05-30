import Foundation

// Filesystem + git RPC wrappers. These are thin pass-throughs to `rpc.call`
// and don't mutate observable state.
extension MotifClient {
    func fsTree(path: String, depth: UInt32 = 1, showHidden: Bool = false) async throws -> MotifProto.FsTreeResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "fs.tree",
            params: MotifProto.FsTreeParams(path: path, depth: depth, show_hidden: showHidden),
            as: MotifProto.FsTreeResult.self
        )
    }

    /// Read a single file. `maxBytes == nil` lets the server cap at its
    /// default (10 MB per the protocol). Returns the raw `FsReadResult`
    /// — caller decodes `content_b64` only when `binary == false`.
    func fsRead(path: String, maxBytes: UInt64? = nil) async throws -> MotifProto.FsReadResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "fs.read",
            params: MotifProto.FsReadParams(path: path, max_bytes: maxBytes),
            as: MotifProto.FsReadResult.self
        )
    }

    func gitStatus(cwd: String? = nil) async throws -> MotifProto.GitStatusResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "git.status",
            params: MotifProto.GitStatusParams(cwd: cwd),
            as: MotifProto.GitStatusResult.self
        )
    }

    /// Returns the unified-diff text, or "" when there are no changes.
    /// `path == nil` => full repo diff. `staged` selects HEAD-vs-index
    /// (true) or index-vs-worktree (false).
    func gitDiff(path: String? = nil, staged: Bool, cwd: String? = nil) async throws -> String {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "git.diff",
            params: MotifProto.GitDiffParams(path: path, staged: staged, cwd: cwd),
            as: MotifProto.GitDiffResult.self
        )
        return r.patch
    }

    /// Per-file additions/deletions, same scope as `gitDiff`. Cheaper
    /// than parsing the full unified patch and used by GitDiffPanel's
    /// file picker to render `+N −M` chips next to each path.
    func gitDiffSummary(path: String? = nil, staged: Bool, cwd: String? = nil) async throws -> [MotifProto.DiffSummaryFile] {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        let r = try await rpc.call(
            "git.diffSummary",
            params: MotifProto.GitDiffParams(path: path, staged: staged, cwd: cwd),
            as: MotifProto.DiffSummaryResult.self
        )
        return r.files
    }

    /// Cheap file metadata. Used before a destructive UI action so we
    /// can surface "delete a 5 MB file?" or to confirm a path's type
    /// before opening a preview tab.
    func fsStat(path: String) async throws -> MotifProto.FsStatResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "fs.stat",
            params: MotifProto.FsStatParams(path: path),
            as: MotifProto.FsStatResult.self
        )
    }

    /// Write bytes to a file. `expectedSha256` enables optimistic-lock
    /// behavior: if the on-disk content has drifted, the server returns
    /// `Conflict (-32004)` and the caller can decide to reload or
    /// `force` an overwrite. Pass `nil` for "I'm creating this file"
    /// or "I genuinely don't care".
    @discardableResult
    func fsWrite(path: String, contentB64: String, expectedSha256: String?, force: Bool) async throws -> MotifProto.FsWriteResult {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        return try await rpc.call(
            "fs.write",
            params: MotifProto.FsWriteParams(
                path: path,
                content_b64: contentB64,
                expected_sha256: expectedSha256,
                force: force
            ),
            as: MotifProto.FsWriteResult.self
        )
    }

    func fsMkdir(path: String) async throws {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        _ = try await rpc.call(
            "fs.mkdir",
            params: MotifProto.FsMkdirParams(path: path)
        )
    }

    func fsRemove(path: String) async throws {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        _ = try await rpc.call(
            "fs.remove",
            params: MotifProto.FsRemoveParams(path: path)
        )
    }

    func fsRename(from: String, to: String) async throws {
        guard let rpc else { throw RpcClient.RpcError.notConnected }
        _ = try await rpc.call(
            "fs.rename",
            params: MotifProto.FsRenameParams(from: from, to: to)
        )
    }
}
