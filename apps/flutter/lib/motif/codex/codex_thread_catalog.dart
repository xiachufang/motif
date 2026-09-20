import 'protocol/generated/codex_app_server_protocol.dart';

final class CodexProjectGroup {
  const CodexProjectGroup({required this.project, required this.threads});

  final CodexProject project;
  final List<CodexThread> threads;
}

final class CodexCatalogSnapshot {
  const CodexCatalogSnapshot({
    required this.allThreads,
    required this.pinnedThreads,
    required this.projects,
    required this.projectlessThreads,
    required this.pinnedThreadIds,
    required this.projectNamesByThreadId,
    required this.selectedProjectId,
  });

  const CodexCatalogSnapshot.empty()
    : allThreads = const [],
      pinnedThreads = const [],
      projects = const [],
      projectlessThreads = const [],
      pinnedThreadIds = const {},
      projectNamesByThreadId = const {},
      selectedProjectId = null;

  final List<CodexThread> allThreads;
  final List<CodexThread> pinnedThreads;
  final List<CodexProjectGroup> projects;
  final List<CodexThread> projectlessThreads;
  final Set<String> pinnedThreadIds;
  final Map<String, String> projectNamesByThreadId;
  final String? selectedProjectId;

  bool isPinned(String threadId) => pinnedThreadIds.contains(threadId);

  String? projectNameForThread(String threadId) =>
      projectNamesByThreadId[threadId];
}

/// Project identity and ordering come exclusively from app-server.
CodexCatalogSnapshot buildCodexCatalog(
  Iterable<CodexThread> source,
  Iterable<CodexProject> projects, {
  Iterable<String> pinnedThreadIds = const [],
  String? selectedProjectId,
  Map<String, String?> insertBeforeByThreadId = const {},
}) {
  final unique = <String, CodexThread>{
    for (final thread in source)
      if (!thread.ephemeral) thread.id: thread,
  };
  final threads = unique.values.toList()..sort(compareCodexThreadsByRecency);
  final orderedProjects = projects.toList()
    ..sort((a, b) {
      final position = a.position.compareTo(b.position);
      return position != 0 ? position : a.id.compareTo(b.id);
    });
  final byProject = {
    for (final project in orderedProjects) project.id: project,
  };
  final members = {
    for (final project in orderedProjects) project.id: <CodexThread>[],
  };
  final pinnedIds = pinnedThreadIds.where(unique.containsKey).toSet();
  final pinned = [for (final id in pinnedIds) unique[id]!];
  final projectless = <CodexThread>[];
  final names = <String, String>{};
  for (final thread in threads) {
    final project = thread.projectId != null
        ? byProject[thread.projectId]
        : _projectForDirectory(thread.cwd.value, orderedProjects);
    if (project != null) names[thread.id] = project.name;
    if (pinnedIds.contains(thread.id)) continue;
    if (project == null) {
      projectless.add(thread);
    } else {
      members[project.id]!.add(thread);
    }
  }
  return CodexCatalogSnapshot(
    allThreads: List.unmodifiable(threads),
    pinnedThreads: List.unmodifiable(
      _applyThreadPlacements(pinned, insertBeforeByThreadId),
    ),
    projects: List.unmodifiable([
      for (final project in orderedProjects)
        CodexProjectGroup(
          project: project,
          threads: List.unmodifiable(members[project.id]!),
        ),
    ]),
    projectlessThreads: List.unmodifiable(
      _applyThreadPlacements(projectless, insertBeforeByThreadId),
    ),
    pinnedThreadIds: Set.unmodifiable(pinnedIds),
    projectNamesByThreadId: Map.unmodifiable(names),
    selectedProjectId: byProject.containsKey(selectedProjectId)
        ? selectedProjectId
        : null,
  );
}

// Desktop-created threads can lack projectId even when their project is
// returned by project/list. Group those by the server's roots for display only.
// Prefer the most specific root; shared roots are ambiguous and stay ungrouped.
CodexProject? _projectForDirectory(String cwd, List<CodexProject> projects) {
  final directory = _projectPath(cwd);
  if (directory.isEmpty) return null;
  CodexProject? match;
  var longest = -1;
  var ambiguous = false;
  for (final project in projects) {
    for (final root in project.roots) {
      final path = _projectPath(root.path.value);
      if (path.isEmpty ||
          (directory != path &&
              !directory.startsWith(path.endsWith('/') ? path : '$path/'))) {
        continue;
      }
      if (path.length > longest) {
        match = project;
        longest = path.length;
        ambiguous = false;
      } else if (path.length == longest && match?.id != project.id) {
        ambiguous = true;
      }
    }
  }
  return ambiguous ? null : match;
}

String _projectPath(String path) {
  final normalized = _normalizedCodexPath(path);
  return RegExp(r'^[A-Za-z]:/').hasMatch(normalized) ||
          normalized.startsWith('//')
      ? normalized.toLowerCase()
      : normalized;
}

List<CodexThread> _applyThreadPlacements(
  List<CodexThread> source,
  Map<String, String?> insertBeforeByThreadId,
) {
  if (source.length < 2 || insertBeforeByThreadId.isEmpty) return source;
  final result = List<CodexThread>.of(source);
  var fallbackIndex = 0;
  for (final placement in insertBeforeByThreadId.entries) {
    final threadIndex = result.indexWhere(
      (thread) => thread.id == placement.key,
    );
    if (threadIndex == -1) continue;
    final thread = result.removeAt(threadIndex);
    final anchorId = placement.value;
    final anchorIndex = anchorId == null
        ? -1
        : result.indexWhere((candidate) => candidate.id == anchorId);
    if (anchorIndex == -1) {
      final index = fallbackIndex > result.length
          ? result.length
          : fallbackIndex;
      result.insert(index, thread);
      fallbackIndex = index + 1;
    } else {
      result.insert(anchorIndex, thread);
    }
  }
  return result;
}

int compareCodexThreadsByRecency(CodexThread a, CodexThread b) {
  final time = codexThreadTimestamp(b).compareTo(codexThreadTimestamp(a));
  return time != 0 ? time : a.id.compareTo(b.id);
}

int codexThreadTimestamp(CodexThread thread) =>
    thread.recencyAt ??
    (thread.updatedAt == 0 ? thread.createdAt : thread.updatedAt);

String codexThreadTitle(CodexThread thread) {
  final name = thread.name?.trim();
  if (name?.isNotEmpty == true) return name!;
  for (final line in thread.preview.split(RegExp(r'[\r\n]+'))) {
    final value = line.trim();
    if (value.isNotEmpty) return value;
  }
  return 'Untitled thread';
}

String nextCodexForkThreadName(
  CodexThread source,
  Iterable<CodexThread> existingThreads,
) {
  final current = codexThreadTitle(source).trim();
  final suffix = RegExp(r'^(.*\S)\s+(\d+)$').firstMatch(current);
  final parsedSuffix = suffix == null ? null : int.tryParse(suffix.group(2)!);
  final base = parsedSuffix != null && parsedSuffix >= 2
      ? suffix!.group(1)!
      : current;
  var number = parsedSuffix != null && parsedSuffix >= 2 ? parsedSuffix + 1 : 2;
  final existingNames = existingThreads
      .map(codexThreadTitle)
      .map((name) => name.trim())
      .toSet();
  while (existingNames.contains('$base $number')) {
    number++;
  }
  return '$base $number';
}

String codexPathBasename(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  final index = normalized.lastIndexOf('/');
  final name = index < 0 ? normalized : normalized.substring(index + 1);
  return name.isEmpty ? path : name;
}

bool codexThreadIsManagedWorktree(CodexThread thread, String codexHome) {
  final cwd = _normalizedCodexPath(thread.cwd.value);
  final home = _normalizedCodexPath(codexHome);
  if (cwd.isEmpty || home.isEmpty) return false;

  var worktreesRoot = home == '/' ? '/worktrees' : '$home/worktrees';
  var candidate = cwd;
  final windowsPath =
      RegExp(r'^[A-Za-z]:/').hasMatch(home) || home.startsWith('//');
  if (windowsPath) {
    worktreesRoot = worktreesRoot.toLowerCase();
    candidate = candidate.toLowerCase();
  }
  return candidate.startsWith('$worktreesRoot/');
}

String _normalizedCodexPath(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

bool codexThreadIsActive(CodexThread thread) =>
    thread.status is CodexActiveThreadStatus;

String codexThreadDateLabel(CodexThread thread, {DateTime? now}) {
  final date = DateTime.fromMillisecondsSinceEpoch(
    codexThreadTimestamp(thread) * 1000,
  ).toLocal();
  final localNow = (now ?? DateTime.now()).toLocal();
  final today = DateTime(localNow.year, localNow.month, localNow.day);
  final day = DateTime(date.year, date.month, date.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}

CodexThread codexThreadWithStatus(
  CodexThread thread,
  CodexThreadStatus status,
) {
  final json = thread.toJson()..['status'] = status.toJson();
  return CodexThread.fromJson(json);
}

CodexThread codexThreadWithName(CodexThread thread, String? name) {
  final json = thread.toJson();
  if (name == null) {
    json.remove('name');
  } else {
    json['name'] = name;
  }
  return CodexThread.fromJson(json);
}

CodexThread codexThreadWithPreview(CodexThread thread, String preview) {
  final json = thread.toJson()..['preview'] = preview;
  return CodexThread.fromJson(json);
}

CodexThread codexThreadWithTurns(CodexThread thread, List<CodexTurn> turns) {
  final json = thread.toJson()..['turns'] = CodexJson.encode(turns);
  return CodexThread.fromJson(json);
}
