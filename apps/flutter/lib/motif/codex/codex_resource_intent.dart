sealed class CodexResourceIntent {
  const CodexResourceIntent();
}

final class CodexFileIntent extends CodexResourceIntent {
  const CodexFileIntent(this.path);

  final String path;
}

final class CodexDiffIntent extends CodexResourceIntent {
  const CodexDiffIntent(this.path, {this.staged = false});

  final String path;
  final bool staged;
}

final class CodexImageIntent extends CodexResourceIntent {
  const CodexImageIntent(this.path);

  final String path;
}

final class CodexWorkspaceRequest {
  const CodexWorkspaceRequest({
    required this.threadId,
    required this.cwd,
    required this.title,
    this.resource,
  });

  final String threadId;
  final String cwd;
  final String title;
  final CodexResourceIntent? resource;
}
