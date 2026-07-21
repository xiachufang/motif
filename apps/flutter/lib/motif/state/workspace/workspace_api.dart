import 'dart:typed_data';

import '../../models/motif_proto.dart';
import 'workspace_content_view_model.dart';

typedef WorkspaceRpcCall =
    Future<Map<String, Object?>> Function(
      String method, [
      Map<String, Object?> params,
    ]);

final class WorkspaceApiTransport {
  const WorkspaceApiTransport({
    required this.isAvailable,
    required this.call,
    required this.writeFileBytes,
  });

  final bool Function() isAvailable;
  final WorkspaceRpcCall call;
  final Future<String> Function(String path, Uint8List data) writeFileBytes;
}

/// Filesystem and Git capability for one attached workspace.
final class WorkspaceApi {
  const WorkspaceApi({
    required this.content,
    required this.transport,
    required this.activeCwd,
  });

  final WorkspaceContentViewModel content;
  final WorkspaceApiTransport transport;
  final String? Function() activeCwd;

  Future<List<TreeEntry>> tree(
    String path, {
    int? depth,
    bool? showHidden,
  }) async {
    if (!transport.isAvailable()) return const [];
    final body = await transport.call('fs.tree', {
      'path': path,
      'depth': ?depth,
      'show_hidden': ?showHidden,
    });
    return ((body['entries'] as List?) ?? [])
        .map(
          (entry) => TreeEntry.fromJson((entry as Map).cast<String, Object?>()),
        )
        .toList();
  }

  Future<FsReadResult> read(String path, {int? maxBytes}) async {
    final body = await transport.call('fs.read', {
      'path': path,
      'max_bytes': ?maxBytes,
    });
    return FsReadResult.fromJson(body);
  }

  Future<String> write(
    String path,
    String contentB64, {
    String? expectedSha256,
    bool force = true,
  }) async {
    final body = await transport.call('fs.write', {
      'path': path,
      'content_b64': contentB64,
      'expected_sha256': ?expectedSha256,
      'force': force,
    });
    return (body['sha256'] as String?) ?? '';
  }

  Future<String> writeBytes(String path, Uint8List data) =>
      transport.writeFileBytes(path, data);

  Future<void> mkdir(String path) async {
    if (!transport.isAvailable()) return;
    await transport.call('fs.mkdir', {'path': path});
  }

  Future<void> remove(String path) async {
    if (!transport.isAvailable()) return;
    await transport.call('fs.remove', {'path': path});
  }

  Future<void> rename(String from, String to) async {
    if (!transport.isAvailable()) return;
    await transport.call('fs.rename', {'from': from, 'to': to});
  }

  Future<GitStatusResult> gitStatus({String? cwd}) async {
    final body = await transport.call('git.status', {'cwd': ?cwd});
    return GitStatusResult.fromJson(body);
  }

  Future<String> gitDiff({
    String? path,
    bool staged = false,
    String? cwd,
  }) async {
    final body = await transport.call('git.diff', {
      'path': ?path,
      'staged': staged,
      'cwd': ?cwd,
    });
    return (body['patch'] as String?) ?? '';
  }

  Future<List<DiffSummaryFile>> gitDiffSummary({
    String? path,
    bool staged = false,
    String? cwd,
  }) async {
    final body = await transport.call('git.diffSummary', {
      'path': ?path,
      'staged': staged,
      'cwd': ?cwd,
    });
    return ((body['files'] as List?) ?? [])
        .map(
          (file) =>
              DiffSummaryFile.fromJson((file as Map).cast<String, Object?>()),
        )
        .toList();
  }
}
