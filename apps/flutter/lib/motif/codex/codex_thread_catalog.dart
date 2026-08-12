import 'dart:convert';

import 'protocol/generated/codex_app_server_protocol.dart';

final class CodexLocalProject {
  const CodexLocalProject({
    required this.id,
    required this.name,
    required this.rootPaths,
    this.updatedAt,
  });

  final String id;
  final String name;
  final List<String> rootPaths;
  final DateTime? updatedAt;
}

final class CodexThreadProjectAssignment {
  const CodexThreadProjectAssignment({required this.projectId, this.cwd});

  final String projectId;
  final String? cwd;
}

/// Tolerant projection of the private Codex global state fields used by the
/// sidebar. Unknown and malformed fields are ignored.
final class CodexGlobalStateData {
  const CodexGlobalStateData({
    required this.projects,
    required this.projectOrder,
    required this.pinnedThreadIds,
    required this.projectlessThreadIds,
    required this.assignments,
    required this.projectThreadOrders,
    this.selectedProjectId,
  });

  final Map<String, CodexLocalProject> projects;
  final List<String> projectOrder;
  final List<String> pinnedThreadIds;
  final List<String> projectlessThreadIds;
  final Map<String, CodexThreadProjectAssignment> assignments;
  final Map<String, List<String>> projectThreadOrders;
  final String? selectedProjectId;

  static CodexGlobalStateData? tryParse(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map) return null;
      final root = decoded.cast<String, Object?>();
      final rawProjects = root['local-projects'];
      if (rawProjects is! Map) return null;

      final projects = <String, CodexLocalProject>{};
      for (final entry in rawProjects.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final map = value.cast<Object?, Object?>();
        final id = _string(map['id']) ?? _string(entry.key);
        if (id == null || id.isEmpty) continue;
        final roots = _stringList(map['rootPaths']);
        final name = _string(map['name'])?.trim();
        projects[id] = CodexLocalProject(
          id: id,
          name: name?.isNotEmpty == true
              ? name!
              : roots.isNotEmpty
              ? codexPathBasename(roots.first)
              : id,
          rootPaths: roots,
          updatedAt: _dateTime(map['updatedAt']),
        );
      }

      final assignments = <String, CodexThreadProjectAssignment>{};
      final rawAssignments = root['thread-project-assignments'];
      if (rawAssignments is Map) {
        for (final entry in rawAssignments.entries) {
          final threadId = _string(entry.key);
          final value = entry.value;
          if (threadId == null || value is! Map) continue;
          final map = value.cast<Object?, Object?>();
          if (_string(map['projectKind']) != 'local') continue;
          final projectId = _string(map['projectId']);
          if (projectId == null || !projects.containsKey(projectId)) continue;
          assignments[threadId] = CodexThreadProjectAssignment(
            projectId: projectId,
            cwd: _string(map['cwd']),
          );
        }
      }

      final projectThreadOrders = <String, List<String>>{};
      final rawOrders = root['sidebar-project-thread-orders'];
      if (rawOrders is Map) {
        for (final entry in rawOrders.entries) {
          final projectId = _string(entry.key);
          final value = entry.value;
          if (projectId == null || value is! Map) continue;
          final threadIds = _stringList(
            value.cast<Object?, Object?>()['threadIds'],
          );
          projectThreadOrders[projectId] = threadIds;
        }
      }

      String? selectedProjectId;
      final selected = root['selected-project'];
      if (selected is Map) {
        selectedProjectId = _string(
          selected.cast<Object?, Object?>()['projectId'],
        );
      } else {
        selectedProjectId = _string(selected);
      }
      if (!projects.containsKey(selectedProjectId)) selectedProjectId = null;

      return CodexGlobalStateData(
        projects: Map.unmodifiable(projects),
        projectOrder: _stringList(root['project-order']),
        pinnedThreadIds: _stringList(root['pinned-thread-ids']),
        projectlessThreadIds: _stringList(root['projectless-thread-ids']),
        assignments: Map.unmodifiable(assignments),
        projectThreadOrders: Map.unmodifiable(projectThreadOrders),
        selectedProjectId: selectedProjectId,
      );
    } catch (_) {
      return null;
    }
  }
}

final class CodexProjectGroup {
  const CodexProjectGroup({required this.project, required this.threads});

  final CodexLocalProject project;
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
    required this.usesGlobalState,
  });

  const CodexCatalogSnapshot.empty()
    : allThreads = const [],
      pinnedThreads = const [],
      projects = const [],
      projectlessThreads = const [],
      pinnedThreadIds = const {},
      projectNamesByThreadId = const {},
      selectedProjectId = null,
      usesGlobalState = false;

  final List<CodexThread> allThreads;
  final List<CodexThread> pinnedThreads;
  final List<CodexProjectGroup> projects;
  final List<CodexThread> projectlessThreads;
  final Set<String> pinnedThreadIds;
  final Map<String, String> projectNamesByThreadId;
  final String? selectedProjectId;
  final bool usesGlobalState;

  bool isPinned(String threadId) => pinnedThreadIds.contains(threadId);

  String? projectNameForThread(String threadId) =>
      projectNamesByThreadId[threadId];
}

CodexCatalogSnapshot buildCodexCatalog(
  Iterable<CodexThread> source,
  CodexGlobalStateData? globalState,
) {
  final unique = <String, CodexThread>{};
  for (final thread in source) {
    if (!thread.ephemeral) unique[thread.id] = thread;
  }
  final threads = unique.values.toList()..sort(compareCodexThreadsByRecency);
  if (globalState == null) return _buildCwdCatalog(threads);

  final byId = {for (final thread in threads) thread.id: thread};
  final pinnedThreads = <CodexThread>[];
  final pinnedIds = <String>{};
  for (final id in globalState.pinnedThreadIds) {
    final thread = byId[id];
    if (thread != null && pinnedIds.add(id)) pinnedThreads.add(thread);
  }

  final orderedProjectIds = <String>[];
  final seenProjects = <String>{};
  for (final id in globalState.projectOrder) {
    if (globalState.projects.containsKey(id) && seenProjects.add(id)) {
      orderedProjectIds.add(id);
    }
  }
  final remainingProjects =
      globalState.projects.values
          .where((project) => !seenProjects.contains(project.id))
          .toList()
        ..sort((a, b) {
          final updated = (b.updatedAt?.millisecondsSinceEpoch ?? 0).compareTo(
            a.updatedAt?.millisecondsSinceEpoch ?? 0,
          );
          return updated != 0
              ? updated
              : a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
  orderedProjectIds.addAll(remainingProjects.map((project) => project.id));

  final projectThreads = <String, List<CodexThread>>{
    for (final id in orderedProjectIds) id: <CodexThread>[],
  };
  final projectIdByRootPath = <String, String>{};
  for (final projectId in orderedProjectIds) {
    for (final rootPath in globalState.projects[projectId]!.rootPaths) {
      final normalized = rootPath.trim();
      if (normalized.isNotEmpty) {
        projectIdByRootPath.putIfAbsent(normalized, () => projectId);
      }
    }
  }
  final projectNamesByThreadId = <String, String>{};
  final projectless = <CodexThread>[];
  final explicitProjectless = globalState.projectlessThreadIds.toSet();
  for (final thread in threads) {
    final assignment = globalState.assignments[thread.id];
    final assignedProject = assignment == null
        ? null
        : globalState.projects[assignment.projectId];
    final inferredProjectId = projectIdByRootPath[thread.cwd.value.trim()];
    final project = explicitProjectless.contains(thread.id)
        ? null
        : assignedProject ??
              (inferredProjectId == null
                  ? null
                  : globalState.projects[inferredProjectId]);
    if (project != null) {
      projectNamesByThreadId[thread.id] = project.name;
    }
    if (pinnedIds.contains(thread.id)) continue;
    if (project == null) {
      projectless.add(thread);
    } else {
      projectThreads[project.id]!.add(thread);
    }
  }

  final groups = <CodexProjectGroup>[];
  for (final projectId in orderedProjectIds) {
    final project = globalState.projects[projectId]!;
    final members = projectThreads[projectId]!;
    final memberById = {for (final thread in members) thread.id: thread};
    final orderedMembers = <CodexThread>[];
    for (final id in globalState.projectThreadOrders[projectId] ?? const []) {
      final thread = memberById.remove(id);
      if (thread != null) orderedMembers.add(thread);
    }
    final remaining = memberById.values.toList()
      ..sort(compareCodexThreadsByRecency);
    orderedMembers.addAll(remaining);
    groups.add(
      CodexProjectGroup(
        project: project,
        threads: List.unmodifiable(orderedMembers),
      ),
    );
  }
  projectless.sort(compareCodexThreadsByRecency);

  return CodexCatalogSnapshot(
    allThreads: List.unmodifiable(threads),
    pinnedThreads: List.unmodifiable(pinnedThreads),
    projects: List.unmodifiable(groups),
    projectlessThreads: List.unmodifiable(projectless),
    pinnedThreadIds: Set.unmodifiable(pinnedIds),
    projectNamesByThreadId: Map.unmodifiable(projectNamesByThreadId),
    selectedProjectId: globalState.selectedProjectId,
    usesGlobalState: true,
  );
}

CodexCatalogSnapshot _buildCwdCatalog(List<CodexThread> threads) {
  final grouped = <String, List<CodexThread>>{};
  final projectless = <CodexThread>[];
  final projectNamesByThreadId = <String, String>{};
  for (final thread in threads) {
    final cwd = thread.cwd.value.trim();
    if (cwd.isEmpty) {
      projectless.add(thread);
      continue;
    }
    grouped.putIfAbsent(cwd, () => []).add(thread);
    projectNamesByThreadId[thread.id] = codexPathBasename(cwd);
  }
  final groups =
      grouped.entries.map((entry) {
        final members = entry.value..sort(compareCodexThreadsByRecency);
        return CodexProjectGroup(
          project: CodexLocalProject(
            id: 'cwd:${entry.key}',
            name: codexPathBasename(entry.key),
            rootPaths: [entry.key],
          ),
          threads: List.unmodifiable(members),
        );
      }).toList()..sort((a, b) {
        final recency = compareCodexThreadsByRecency(
          a.threads.first,
          b.threads.first,
        );
        return recency != 0
            ? recency
            : a.project.name.toLowerCase().compareTo(
                b.project.name.toLowerCase(),
              );
      });

  return CodexCatalogSnapshot(
    allThreads: List.unmodifiable(threads),
    pinnedThreads: const [],
    projects: List.unmodifiable(groups),
    projectlessThreads: List.unmodifiable(projectless),
    pinnedThreadIds: const {},
    projectNamesByThreadId: Map.unmodifiable(projectNamesByThreadId),
    selectedProjectId: null,
    usesGlobalState: false,
  );
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

String codexPathBasename(String path) {
  var normalized = path.trim().replaceAll('\\', '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  final index = normalized.lastIndexOf('/');
  final name = index < 0 ? normalized : normalized.substring(index + 1);
  return name.isEmpty ? path : name;
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

String? _string(Object? value) => value is String ? value : null;

List<String> _stringList(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];

DateTime? _dateTime(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  if (value is num) {
    final raw = value.toInt();
    final milliseconds = raw.abs() < 100000000000 ? raw * 1000 : raw;
    return DateTime.fromMillisecondsSinceEpoch(milliseconds);
  }
  return null;
}
