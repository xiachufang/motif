import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_observation/flutter_observation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'codex_state.g.dart';

enum CodexSidebarMode { projects, timeline }

final class CodexSideChatIndex {
  const CodexSideChatIndex({this.threadIds = const [], this.selectedThreadId});

  final List<String> threadIds;
  final String? selectedThreadId;

  Map<String, Object?> toJson() => {
    'threadIds': threadIds,
    if (selectedThreadId != null) 'selectedThreadId': selectedThreadId,
  };

  static CodexSideChatIndex fromJson(Object? json) {
    if (json is! Map) return const CodexSideChatIndex();
    final ids = <String>[];
    final seen = <String>{};
    final rawIds = json['threadIds'];
    if (rawIds is List) {
      for (final value in rawIds.whereType<String>()) {
        final id = value.trim();
        if (id.isNotEmpty && seen.add(id)) ids.add(id);
      }
    }
    final rawSelected = json['selectedThreadId'];
    final selected = rawSelected is String && ids.contains(rawSelected)
        ? rawSelected
        : null;
    return CodexSideChatIndex(
      threadIds: List.unmodifiable(ids),
      selectedThreadId: selected,
    );
  }
}

final class CodexProjectSidebarPreferences {
  const CodexProjectSidebarPreferences({
    this.initialized = false,
    this.showAllProjects = false,
    this.expandedProjects = const {},
    this.visibleThreadCounts = const {},
  });

  final bool initialized;
  final bool showAllProjects;
  final Set<String> expandedProjects;
  final Map<String, int> visibleThreadCounts;

  CodexProjectSidebarPreferences copyWith({
    bool? showAllProjects,
    Set<String>? expandedProjects,
    Map<String, int>? visibleThreadCounts,
  }) => CodexProjectSidebarPreferences(
    initialized: true,
    showAllProjects: showAllProjects ?? this.showAllProjects,
    expandedProjects: expandedProjects ?? this.expandedProjects,
    visibleThreadCounts: visibleThreadCounts ?? this.visibleThreadCounts,
  );

  Map<String, Object?> toJson() => {
    'showAllProjects': showAllProjects,
    'expandedProjects': expandedProjects.toList()..sort(),
    'visibleThreadCounts': Map.fromEntries(
      visibleThreadCounts.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    ),
  };

  static CodexProjectSidebarPreferences fromJson(Object? json) {
    if (json is! Map) return const CodexProjectSidebarPreferences();
    final visibleThreadCounts = _positiveIntMap(json['visibleThreadCounts']);
    // Migrate the previous all-or-nothing expansion preference. A large count
    // preserves its old "show all" behavior until the project is collapsed.
    if (visibleThreadCounts.isEmpty) {
      for (final projectId in _stringSet(json['expandedThreadLists'])) {
        visibleThreadCounts[projectId] = 0x7fffffff;
      }
    }
    return CodexProjectSidebarPreferences(
      initialized: true,
      showAllProjects: json['showAllProjects'] == true,
      expandedProjects: _stringSet(json['expandedProjects']),
      visibleThreadCounts: Map.unmodifiable(visibleThreadCounts),
    );
  }

  static Set<String> _stringSet(Object? value) => value is List
      ? Set.unmodifiable(
          value.whereType<String>().where((item) => item.isNotEmpty),
        )
      : const {};

  static Map<String, int> _positiveIntMap(Object? value) {
    if (value is! Map) return {};
    return {
      for (final entry in value.entries)
        if (entry.key is String &&
            (entry.key as String).isNotEmpty &&
            entry.value is num &&
            (entry.value as num).toInt() > 0)
          entry.key as String: (entry.value as num).toInt(),
    };
  }
}

/// Process-wide Codex UI preferences.
///
/// Connection and conversation state live in server-scoped service instances.
/// This object stores lightweight preferences plus the Side Chat IDs needed to
/// recover ephemeral conversations while the server's app-server stays alive.
@ObservableModel()
class CodexState extends _$CodexState {
  static const _projectSidebarKey = 'motif.codex.projectSidebar.v1';
  static const _selectedModelsKey = 'motif.codex.selectedModels.v1';
  static const _selectedReasoningEffortsKey =
      'motif.codex.selectedReasoningEfforts.v1';
  static const _selectedPermissionsKey = 'motif.codex.selectedPermissions.v1';
  static const _sideChatIndexesKey = 'motif.codex.sideChatIndexes.v1';
  static const _lastOpenedThreadsKey = 'motif.codex.lastOpenedThreads.v1';
  static const _composerDraftsKey = 'motif.codex.composerDrafts.v1';
  static const _composerDraftPersistenceDelay = Duration(milliseconds: 250);

  CodexState({
    CodexSidebarMode sidebarMode = CodexSidebarMode.projects,
    bool desktopSidebarVisible = true,
    double sidebarWidth = 340,
    @ObservationIgnored() @ObservationReadOnly() SharedPreferences? preferences,
  }) : _projectSidebars = _loadProjectSidebars(preferences),
       _selectedModels = _loadSelectedModels(preferences),
       _selectedReasoningEfforts = _loadSelectedReasoningEfforts(preferences),
       _selectedPermissions = _loadSelectedPermissions(preferences),
       _sideChatIndexes = _loadSideChatIndexes(preferences),
       _lastOpenedThreads = _loadStringMap(preferences, _lastOpenedThreadsKey),
       _composerDrafts = _loadComposerDrafts(preferences),
       super(sidebarMode, desktopSidebarVisible, sidebarWidth, preferences);

  final Map<String, CodexProjectSidebarPreferences> _projectSidebars;
  final Map<String, String> _selectedModels;
  final Map<String, String> _selectedReasoningEfforts;
  final Map<String, String?> _selectedPermissions;
  final Map<String, Map<String, CodexSideChatIndex>> _sideChatIndexes;
  final Map<String, String> _lastOpenedThreads;
  final Map<String, Map<String, String>> _composerDrafts;
  final Map<String, Map<CodexSidebarMode, double>> _sidebarScrollOffsets = {};
  Future<void> _persistProjectSidebars = Future.value();
  Future<void> _persistSelectedModels = Future.value();
  Future<void> _persistSelectedReasoningEfforts = Future.value();
  Future<void> _persistSelectedPermissions = Future.value();
  Future<void> _persistSideChatIndexes = Future.value();
  Future<void> _persistLastOpenedThreads = Future.value();
  Future<void> _persistComposerDrafts = Future.value();
  Timer? _composerDraftPersistTimer;

  static Future<CodexState> load() async =>
      CodexState(preferences: await SharedPreferences.getInstance());

  CodexProjectSidebarPreferences projectSidebar(String serverId) =>
      _projectSidebars[serverId] ?? const CodexProjectSidebarPreferences();

  double sidebarScrollOffset(String serverId, CodexSidebarMode mode) =>
      _sidebarScrollOffsets[serverId]?[mode] ?? 0;

  void setSidebarScrollOffset(
    String serverId,
    CodexSidebarMode mode,
    double offset,
  ) {
    if (serverId.isEmpty) return;
    final normalized = offset.isFinite && offset > 0 ? offset : 0.0;
    if (normalized == 0) {
      final offsets = _sidebarScrollOffsets[serverId];
      offsets?.remove(mode);
      if (offsets?.isEmpty == true) _sidebarScrollOffsets.remove(serverId);
      return;
    }
    _sidebarScrollOffsets.putIfAbsent(serverId, () => {})[mode] = normalized;
  }

  Future<void> flushProjectSidebarPreferences() => _persistProjectSidebars;

  String? selectedModelId(String serverId) => _selectedModels[serverId];

  void setSelectedModelId(String serverId, String? modelId) {
    if (serverId.isEmpty) return;
    final normalized = modelId?.trim();
    if (normalized == null || normalized.isEmpty) {
      if (_selectedModels.remove(serverId) == null) return;
    } else {
      if (_selectedModels[serverId] == normalized) return;
      _selectedModels[serverId] = normalized;
    }
    final store = preferences;
    if (store == null) return;
    final payload = jsonEncode(_selectedModels);
    unawaited(
      _persistSelectedModels = _persistSelectedModels.then((_) async {
        await store.setString(_selectedModelsKey, payload);
      }),
    );
  }

  Future<void> flushSelectedModelPreferences() => _persistSelectedModels;

  String? selectedReasoningEffort(String serverId) =>
      _selectedReasoningEfforts[serverId];

  void setSelectedReasoningEffort(String serverId, String? effort) {
    if (serverId.isEmpty) return;
    final normalized = effort?.trim();
    if (normalized == null || normalized.isEmpty) {
      if (_selectedReasoningEfforts.remove(serverId) == null) return;
    } else {
      if (_selectedReasoningEfforts[serverId] == normalized) return;
      _selectedReasoningEfforts[serverId] = normalized;
    }
    final store = preferences;
    if (store == null) return;
    final payload = jsonEncode(_selectedReasoningEfforts);
    unawaited(
      _persistSelectedReasoningEfforts = _persistSelectedReasoningEfforts.then((
        _,
      ) async {
        await store.setString(_selectedReasoningEffortsKey, payload);
      }),
    );
  }

  void clearSelectedReasoningEffort(String serverId) =>
      setSelectedReasoningEffort(serverId, null);

  Future<void> flushSelectedReasoningEffortPreferences() =>
      _persistSelectedReasoningEfforts;

  bool hasSelectedPermissionPreference(String serverId) =>
      _selectedPermissions.containsKey(serverId);

  String? selectedPermissionId(String serverId) =>
      _selectedPermissions[serverId];

  void setSelectedPermissionId(String serverId, String? permissionId) {
    if (serverId.isEmpty) return;
    final normalized = permissionId?.trim();
    final value = normalized == null || normalized.isEmpty ? null : normalized;
    if (_selectedPermissions.containsKey(serverId) &&
        _selectedPermissions[serverId] == value) {
      return;
    }
    _selectedPermissions[serverId] = value;
    _persistPermissionPreferences();
  }

  void clearSelectedPermissionId(String serverId) {
    if (!_selectedPermissions.containsKey(serverId)) return;
    _selectedPermissions.remove(serverId);
    _persistPermissionPreferences();
  }

  Future<void> flushSelectedPermissionPreferences() =>
      _persistSelectedPermissions;

  CodexSideChatIndex sideChatIndex(String serverId, String parentThreadId) =>
      _sideChatIndexes[serverId]?[parentThreadId] ?? const CodexSideChatIndex();

  void setSideChatIndex(
    String serverId,
    String parentThreadId, {
    required Iterable<String> threadIds,
    String? selectedThreadId,
  }) {
    if (serverId.isEmpty || parentThreadId.isEmpty) return;
    final ids = <String>[];
    final seen = <String>{};
    for (final value in threadIds) {
      final id = value.trim();
      if (id.isNotEmpty && seen.add(id)) ids.add(id);
    }
    final selected = selectedThreadId != null && ids.contains(selectedThreadId)
        ? selectedThreadId
        : null;
    if (ids.isEmpty) {
      final byParent = _sideChatIndexes[serverId];
      if (byParent == null) return;
      if (byParent.remove(parentThreadId) == null) return;
      if (byParent.isEmpty) _sideChatIndexes.remove(serverId);
    } else {
      final byParent = _sideChatIndexes.putIfAbsent(serverId, () => {});
      final current = byParent[parentThreadId];
      if (current != null &&
          listEquals(current.threadIds, ids) &&
          current.selectedThreadId == selected) {
        return;
      }
      byParent[parentThreadId] = CodexSideChatIndex(
        threadIds: List.unmodifiable(ids),
        selectedThreadId: selected,
      );
    }
    final store = preferences;
    if (store == null) return;
    final payload = jsonEncode({
      for (final server in _sideChatIndexes.entries)
        server.key: {
          for (final parent in server.value.entries)
            parent.key: parent.value.toJson(),
        },
    });
    unawaited(
      _persistSideChatIndexes = _persistSideChatIndexes.then((_) async {
        await store.setString(_sideChatIndexesKey, payload);
      }),
    );
  }

  Future<void> flushSideChatIndexes() => _persistSideChatIndexes;

  String? lastOpenedThreadId(String serverId) => _lastOpenedThreads[serverId];

  void setLastOpenedThreadId(String serverId, String? threadId) {
    if (serverId.isEmpty) return;
    final normalized = threadId?.trim();
    if (normalized == null || normalized.isEmpty) {
      if (_lastOpenedThreads.remove(serverId) == null) return;
    } else {
      if (_lastOpenedThreads[serverId] == normalized) return;
      _lastOpenedThreads[serverId] = normalized;
    }
    final store = preferences;
    if (store == null) return;
    final payload = jsonEncode(_lastOpenedThreads);
    unawaited(
      _persistLastOpenedThreads = _persistLastOpenedThreads.then((_) async {
        await store.setString(_lastOpenedThreadsKey, payload);
      }),
    );
  }

  Future<void> flushLastOpenedThreadPreferences() => _persistLastOpenedThreads;

  String? composerDraft(String serverId, String threadId) =>
      _composerDrafts[serverId]?[threadId];

  void setComposerDraft(String serverId, String threadId, String value) {
    if (serverId.isEmpty || threadId.isEmpty) return;
    if (value.isEmpty) {
      final byThread = _composerDrafts[serverId];
      if (byThread == null || byThread.remove(threadId) == null) return;
      if (byThread.isEmpty) _composerDrafts.remove(serverId);
    } else {
      final byThread = _composerDrafts.putIfAbsent(serverId, () => {});
      if (byThread[threadId] == value) return;
      byThread[threadId] = value;
    }
    _scheduleComposerDraftPersistence();
  }

  void clearComposerDraft(String serverId, String threadId) =>
      setComposerDraft(serverId, threadId, '');

  Future<void> flushComposerDraftPreferences() {
    if (_composerDraftPersistTimer != null) {
      _composerDraftPersistTimer!.cancel();
      _composerDraftPersistTimer = null;
      _queueComposerDraftPersistence();
    }
    return _persistComposerDrafts;
  }

  void _scheduleComposerDraftPersistence() {
    if (preferences == null) return;
    _composerDraftPersistTimer?.cancel();
    _composerDraftPersistTimer = Timer(
      _composerDraftPersistenceDelay,
      _queueComposerDraftPersistence,
    );
  }

  void _queueComposerDraftPersistence() {
    _composerDraftPersistTimer = null;
    final store = preferences;
    if (store == null) return;
    final payload = jsonEncode(_composerDrafts);
    unawaited(
      _persistComposerDrafts = _persistComposerDrafts.then((_) async {
        await store.setString(_composerDraftsKey, payload);
      }),
    );
  }

  void _persistPermissionPreferences() {
    final store = preferences;
    if (store == null) return;
    final payload = jsonEncode(_selectedPermissions);
    unawaited(
      _persistSelectedPermissions = _persistSelectedPermissions.then((_) async {
        await store.setString(_selectedPermissionsKey, payload);
      }),
    );
  }

  void setShowAllProjects(String serverId, bool value) {
    _updateProjectSidebar(
      serverId,
      projectSidebar(serverId).copyWith(showAllProjects: value),
    );
  }

  void setProjectExpanded(String serverId, String projectId, bool expanded) {
    final current = projectSidebar(serverId);
    final projects = {...current.expandedProjects};
    expanded ? projects.add(projectId) : projects.remove(projectId);
    _updateProjectSidebar(
      serverId,
      current.copyWith(expandedProjects: Set.unmodifiable(projects)),
    );
  }

  void setVisibleThreadCount(String serverId, String projectId, int? count) {
    final current = projectSidebar(serverId);
    final counts = {...current.visibleThreadCounts};
    if (count == null) {
      counts.remove(projectId);
    } else {
      counts[projectId] = count;
    }
    _updateProjectSidebar(
      serverId,
      current.copyWith(visibleThreadCounts: Map.unmodifiable(counts)),
    );
  }

  void _updateProjectSidebar(
    String serverId,
    CodexProjectSidebarPreferences value,
  ) {
    if (serverId.isEmpty) return;
    _projectSidebars[serverId] = value;
    final store = preferences;
    if (store == null) return;
    final payload = jsonEncode({
      for (final entry in _projectSidebars.entries)
        entry.key: entry.value.toJson(),
    });
    unawaited(
      _persistProjectSidebars = _persistProjectSidebars.then((_) async {
        await store.setString(_projectSidebarKey, payload);
      }),
    );
  }

  static Map<String, CodexProjectSidebarPreferences> _loadProjectSidebars(
    SharedPreferences? preferences,
  ) {
    final raw = preferences?.getString(_projectSidebarKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final entry in json.entries)
          if (entry.key is String && (entry.key as String).isNotEmpty)
            entry.key as String: CodexProjectSidebarPreferences.fromJson(
              entry.value,
            ),
      };
    } catch (_) {
      return {};
    }
  }

  static Map<String, String> _loadSelectedModels(
    SharedPreferences? preferences,
  ) => _loadStringMap(preferences, _selectedModelsKey);

  static Map<String, String> _loadStringMap(
    SharedPreferences? preferences,
    String key,
  ) {
    final raw = preferences?.getString(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final entry in json.entries)
          if (entry.key is String &&
              entry.value is String &&
              (entry.key as String).isNotEmpty &&
              (entry.value as String).isNotEmpty)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  static Map<String, String?> _loadSelectedPermissions(
    SharedPreferences? preferences,
  ) {
    final raw = preferences?.getString(_selectedPermissionsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final entry in json.entries)
          if (entry.key is String &&
              (entry.key as String).isNotEmpty &&
              (entry.value == null || entry.value is String) &&
              (entry.value == null || (entry.value as String).isNotEmpty))
            entry.key as String: entry.value as String?,
      };
    } catch (_) {
      return {};
    }
  }

  static Map<String, String> _loadSelectedReasoningEfforts(
    SharedPreferences? preferences,
  ) {
    final raw = preferences?.getString(_selectedReasoningEffortsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final entry in json.entries)
          if (entry.key is String &&
              entry.value is String &&
              (entry.key as String).isNotEmpty &&
              (entry.value as String).isNotEmpty)
            entry.key as String: entry.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  static Map<String, Map<String, CodexSideChatIndex>> _loadSideChatIndexes(
    SharedPreferences? preferences,
  ) {
    final raw = preferences?.getString(_sideChatIndexesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      final result = <String, Map<String, CodexSideChatIndex>>{};
      for (final server in json.entries) {
        if (server.key is! String ||
            (server.key as String).isEmpty ||
            server.value is! Map) {
          continue;
        }
        final byParent = <String, CodexSideChatIndex>{};
        for (final parent in (server.value as Map).entries) {
          if (parent.key is! String || (parent.key as String).isEmpty) continue;
          final index = CodexSideChatIndex.fromJson(parent.value);
          if (index.threadIds.isNotEmpty) {
            byParent[parent.key as String] = index;
          }
        }
        if (byParent.isNotEmpty) result[server.key as String] = byParent;
      }
      return result;
    } catch (_) {
      return {};
    }
  }

  static Map<String, Map<String, String>> _loadComposerDrafts(
    SharedPreferences? preferences,
  ) {
    final raw = preferences?.getString(_composerDraftsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      final result = <String, Map<String, String>>{};
      for (final server in json.entries) {
        if (server.key is! String ||
            (server.key as String).isEmpty ||
            server.value is! Map) {
          continue;
        }
        final byThread = <String, String>{};
        for (final thread in (server.value as Map).entries) {
          if (thread.key is String &&
              (thread.key as String).isNotEmpty &&
              thread.value is String &&
              (thread.value as String).isNotEmpty) {
            byThread[thread.key as String] = thread.value as String;
          }
        }
        if (byThread.isNotEmpty) result[server.key as String] = byThread;
      }
      return result;
    } catch (_) {
      return {};
    }
  }
}
