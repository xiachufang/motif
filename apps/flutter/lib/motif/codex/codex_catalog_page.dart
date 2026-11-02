import 'protocol/generated/codex_app_server_protocol.dart';

/// Progress for one independently loaded catalog query.
final class CodexCatalogPage {
  bool started = false;
  bool loading = false;
  String? nextCursor;
  String? error;
  final Set<String> threadIds = {};
  final Set<String> seenCursors = {};

  bool get hasMore => !started || nextCursor != null;

  void accept(String? cursor) {
    started = true;
    final next = cursor?.trim();
    nextCursor = next == null || next.isEmpty || !seenCursors.add(next)
        ? null
        : next;
  }
}

final class CodexThreadQueryPage {
  const CodexThreadQueryPage({
    required this.threads,
    this.nextCursor,
    this.snippets = const {},
  });

  final List<CodexThread> threads;
  final String? nextCursor;
  final Map<String, String> snippets;
}
