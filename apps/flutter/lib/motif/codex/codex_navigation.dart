import 'dart:async';

import '../models/resource_documents.dart';

typedef CodexOpenFile = FutureOr<void> Function(String path);
typedef CodexOpenImage = FutureOr<void> Function(String path);
typedef CodexOpenTurnDiff =
    FutureOr<void> Function(DiffDocument document, {String? initialPath});

/// Explicit request to leave Codex and open its terminal workspace.
///
/// File, image, and turn-diff previews deliberately do not use this request.
class CodexWorkspaceRequest {
  const CodexWorkspaceRequest({
    required this.threadId,
    required this.cwd,
    required this.title,
  });

  final String threadId;
  final String cwd;
  final String title;
}

/// Resolves a Markdown link emitted by Codex into an app-server file path.
///
/// Codex responses commonly append `:line` or `:line:column` to local file
/// links. The preview currently opens the file itself, so those locations are
/// removed before calling `fs/readFile`.
String? codexFilePathFromMarkdownLink(String href, {String? cwd}) {
  var target = href.trim();
  if (target.isEmpty || target.startsWith('#')) return null;
  target = target.replaceFirst(RegExp(r':\d+(?::\d+)?$'), '');

  final windowsPath = RegExp(r'^[A-Za-z]:[\\/]');
  if (target.startsWith('file:')) {
    final uri = Uri.tryParse(target);
    if (uri == null || uri.scheme != 'file') return null;
    target = uri.host.isEmpty ? uri.path : '//${uri.host}${uri.path}';
  } else if (!windowsPath.hasMatch(target)) {
    final uri = Uri.tryParse(target);
    if (uri == null || uri.scheme.isNotEmpty) return null;
    target = uri.path;
  }

  try {
    target = Uri.decodeFull(target);
  } on FormatException {
    return null;
  }
  if (target.isEmpty) return null;

  final absolute =
      target.startsWith('/') ||
      target.startsWith(r'\\') ||
      windowsPath.hasMatch(target);
  if (absolute) return target;

  final base = cwd?.trim();
  if (base == null || base.isEmpty) return target;
  final separator = base.contains(r'\') && !base.contains('/') ? r'\' : '/';
  return base.endsWith('/') || base.endsWith(r'\')
      ? '$base$target'
      : '$base$separator$target';
}
