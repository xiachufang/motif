import 'dart:async';
import 'dart:convert';

import 'package:flutter_observation/flutter_observation.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'codex_state.g.dart';

enum CodexSidebarMode { projects, timeline }

final class CodexProjectSidebarPreferences {
  const CodexProjectSidebarPreferences({
    this.initialized = false,
    this.showAllProjects = false,
    this.expandedProjects = const {},
    this.expandedThreadLists = const {},
  });

  final bool initialized;
  final bool showAllProjects;
  final Set<String> expandedProjects;
  final Set<String> expandedThreadLists;

  CodexProjectSidebarPreferences copyWith({
    bool? showAllProjects,
    Set<String>? expandedProjects,
    Set<String>? expandedThreadLists,
  }) => CodexProjectSidebarPreferences(
    initialized: true,
    showAllProjects: showAllProjects ?? this.showAllProjects,
    expandedProjects: expandedProjects ?? this.expandedProjects,
    expandedThreadLists: expandedThreadLists ?? this.expandedThreadLists,
  );

  Map<String, Object?> toJson() => {
    'showAllProjects': showAllProjects,
    'expandedProjects': expandedProjects.toList()..sort(),
    'expandedThreadLists': expandedThreadLists.toList()..sort(),
  };

  static CodexProjectSidebarPreferences fromJson(Object? json) {
    if (json is! Map) return const CodexProjectSidebarPreferences();
    return CodexProjectSidebarPreferences(
      initialized: true,
      showAllProjects: json['showAllProjects'] == true,
      expandedProjects: _stringSet(json['expandedProjects']),
      expandedThreadLists: _stringSet(json['expandedThreadLists']),
    );
  }

  static Set<String> _stringSet(Object? value) => value is List
      ? Set.unmodifiable(
          value.whereType<String>().where((item) => item.isNotEmpty),
        )
      : const {};
}

/// Process-wide Codex UI preferences.
///
/// Connection and thread state intentionally live in server-scoped service
/// state instances instead of this object. Thread workspaces remain isolated
/// by their hidden ordinary Sessions.
@ObservableModel()
class CodexState extends _$CodexState {
  static const _projectSidebarKey = 'motif.codex.projectSidebar.v1';

  CodexState({
    CodexSidebarMode sidebarMode = CodexSidebarMode.projects,
    bool desktopSidebarVisible = true,
    double sidebarWidth = 340,
    SharedPreferences? preferences,
  }) : _preferences = preferences,
       _projectSidebars = _loadProjectSidebars(preferences),
       super(sidebarMode, desktopSidebarVisible, sidebarWidth);

  final SharedPreferences? _preferences;
  final Map<String, CodexProjectSidebarPreferences> _projectSidebars;
  Future<void> _persistProjectSidebars = Future.value();

  static Future<CodexState> load() async =>
      CodexState(preferences: await SharedPreferences.getInstance());

  CodexProjectSidebarPreferences projectSidebar(String serverId) =>
      _projectSidebars[serverId] ?? const CodexProjectSidebarPreferences();

  Future<void> flushProjectSidebarPreferences() => _persistProjectSidebars;

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

  void setThreadListExpanded(String serverId, String projectId, bool expanded) {
    final current = projectSidebar(serverId);
    final projects = {...current.expandedThreadLists};
    expanded ? projects.add(projectId) : projects.remove(projectId);
    _updateProjectSidebar(
      serverId,
      current.copyWith(expandedThreadLists: Set.unmodifiable(projects)),
    );
  }

  void _updateProjectSidebar(
    String serverId,
    CodexProjectSidebarPreferences value,
  ) {
    if (serverId.isEmpty) return;
    _projectSidebars[serverId] = value;
    final preferences = _preferences;
    if (preferences == null) return;
    final payload = jsonEncode({
      for (final entry in _projectSidebars.entries)
        entry.key: entry.value.toJson(),
    });
    unawaited(
      _persistProjectSidebars = _persistProjectSidebars.then((_) async {
        await preferences.setString(_projectSidebarKey, payload);
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
}
