import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../codex/codex_service_state.dart';
import '../../codex/codex_state.dart';
import '../../codex/codex_thread_catalog.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../theme/motif_theme.dart';
import '../widgets/codex_motion.dart';
import '../widgets/codex_sidebar_components.dart';
import '../widgets/rename_dialog.dart';
import '../widgets/top_toast.dart';

part 'codex_thread_sidebar.g.dart';

@ObservableModel()
class CodexThreadSidebarViewModel extends _$CodexThreadSidebarViewModel {
  CodexThreadSidebarViewModel({
    @ObservationReadOnly() required ObservableSet<String> expandedProjects,
    @ObservationReadOnly()
    required ObservableMap<String, int> visibleThreadCounts,
    @ObservationReadOnly() required ObservableList<CodexThread> queryResults,
    String? seededSelectedProject,
    bool showAllProjects = false,
    bool showSearch = false,
    bool showArchived = false,
    String query = '',
    bool queryLoading = false,
    String? queryError,
    required this.projectsScrollController,
    required this.timelineScrollController,
  }) : super(
         expandedProjects,
         visibleThreadCounts,
         queryResults,
         seededSelectedProject,
         showAllProjects,
         showSearch,
         showArchived,
         query,
         queryLoading,
         queryError,
       );

  final ScrollController projectsScrollController;
  final ScrollController timelineScrollController;
  Timer? searchTimer;
  int queryGeneration = 0;
}

@ObservationWidget()
class CodexThreadSidebar extends _$CodexThreadSidebar {
  const CodexThreadSidebar({
    required this.serviceState,
    required this.codexState,
    required this.mode,
    required this.onModeChanged,
    required this.onThreadSelected,
    this.onThreadCreated,
    super.key,
  });

  final CodexServiceState serviceState;
  final CodexState codexState;
  final CodexSidebarMode mode;
  final ValueChanged<CodexSidebarMode> onModeChanged;
  final ValueChanged<String> onThreadSelected;
  final VoidCallback? onThreadCreated;

  static const int _initialProjectCount = 6;
  static const int _initialThreadCount = 5;
  static const int _threadPageSize = 10;

  String get _serverId => serviceState.serverId;

  @ObservableState(name: 'viewModel')
  CodexThreadSidebarViewModel createViewModel() {
    final preferences = codexState.projectSidebar(_serverId);
    return CodexThreadSidebarViewModel(
      expandedProjects: ObservableSet(preferences.expandedProjects),
      visibleThreadCounts: ObservableMap(preferences.visibleThreadCounts),
      queryResults: ObservableList<CodexThread>(),
      projectsScrollController: _createScrollController(
        CodexSidebarMode.projects,
      ),
      timelineScrollController: _createScrollController(
        CodexSidebarMode.timeline,
      ),
      seededSelectedProject: preferences.initialized
          ? serviceState.catalog.selectedProjectId
          : null,
      showAllProjects: preferences.showAllProjects,
    );
  }

  ScrollController _createScrollController(CodexSidebarMode mode) {
    final controller = ScrollController(
      initialScrollOffset: codexState.sidebarScrollOffset(_serverId, mode),
    );
    controller.addListener(() {
      if (controller.hasClients) {
        codexState.setSidebarScrollOffset(_serverId, mode, controller.offset);
      }
    });
    return controller;
  }

  @override
  bool shouldRecreateStates(covariant CodexThreadSidebar oldWidget) =>
      oldWidget.serviceState.serverId != serviceState.serverId ||
      !identical(oldWidget.codexState, codexState);

  @override
  void disposeStates({required CodexThreadSidebarViewModel viewModel}) {
    viewModel.searchTimer?.cancel();
    viewModel.queryGeneration++;
    _disposeScrollController(
      viewModel.projectsScrollController,
      CodexSidebarMode.projects,
    );
    _disposeScrollController(
      viewModel.timelineScrollController,
      CodexSidebarMode.timeline,
    );
  }

  void _disposeScrollController(
    ScrollController controller,
    CodexSidebarMode mode,
  ) {
    if (controller.hasClients) {
      codexState.setSidebarScrollOffset(_serverId, mode, controller.offset);
    }
    controller.dispose();
  }

  @override
  Widget build(
    BuildContext context, {
    required CodexThreadSidebarViewModel viewModel,
  }) {
    final _ = serviceState.viewModel.catalogRevision;
    _scheduleSelectedProjectSeed(context, viewModel);
    final c = context.motif;
    final state = serviceState;
    return ColoredBox(
      color: c.surface,
      child: SafeArea(
        child: Column(
          children: [
            CodexSidebarHeader(
              label: viewModel.showArchived ? 'Archived' : 'Threads',
              actions: [
                if (!viewModel.showArchived)
                  CodexSidebarIconButton(
                    key: const ValueKey('codex-mode-timeline'),
                    icon: Icons.schedule_outlined,
                    tooltip: mode == CodexSidebarMode.timeline
                        ? 'Group by project'
                        : 'Group by time',
                    selected: mode == CodexSidebarMode.timeline,
                    onTap: () => onModeChanged(
                      mode == CodexSidebarMode.timeline
                          ? CodexSidebarMode.projects
                          : CodexSidebarMode.timeline,
                    ),
                  ),
                CodexSidebarIconButton(
                  key: const ValueKey('codex-threads-search'),
                  icon: Icons.search,
                  tooltip: viewModel.showSearch ? 'Close search' : 'Search',
                  selected: viewModel.showSearch,
                  onTap: () => _toggleSearch(viewModel),
                ),
                CodexSidebarIconButton(
                  key: const ValueKey('codex-threads-archived'),
                  icon: Icons.archive_outlined,
                  tooltip: viewModel.showArchived
                      ? 'Back to threads'
                      : 'Archived threads',
                  selected: viewModel.showArchived,
                  onTap: () => _toggleArchived(viewModel),
                ),
                CodexSidebarIconButton(
                  key: const ValueKey('codex-threads-refresh'),
                  icon: Icons.refresh,
                  tooltip:
                      viewModel.showArchived ||
                          viewModel.query.trim().isNotEmpty
                      ? 'Refresh results'
                      : 'Refresh threads',
                  selected: false,
                  busy:
                      viewModel.queryLoading ||
                      state.catalogPhase == CodexCatalogPhase.loading,
                  onTap:
                      viewModel.queryLoading ||
                          state.catalogPhase == CodexCatalogPhase.loading
                      ? null
                      : () {
                          if (_usesQueryResults(viewModel)) {
                            unawaited(_runThreadQuery(viewModel));
                          } else {
                            unawaited(state.refreshCatalog());
                          }
                        },
                ),
              ],
            ),
            Divider(height: 1, color: c.border),
            CodexMotionPresence(
              visible: viewModel.showSearch,
              child: _ThreadSearchField(
                key: const ValueKey('codex-thread-search-field'),
                initialValue: viewModel.query,
                archived: viewModel.showArchived,
                onChanged: (value) => _setQuery(viewModel, value),
                onClear: () => _setQuery(viewModel, ''),
              ),
            ),
            CodexMotionPresence(
              visible: viewModel.queryLoading,
              child: LinearProgressIndicator(
                key: const ValueKey('codex-thread-query-loading'),
                minHeight: 2,
                color: c.accent,
                backgroundColor: c.surface,
              ),
            ),
            CodexMotionPresence(
              visible:
                  state.catalogPhase == CodexCatalogPhase.loading &&
                  state.catalog.allThreads.isNotEmpty,
              child: LinearProgressIndicator(
                key: const ValueKey('codex-catalog-refresh-loading'),
                minHeight: 2,
                color: c.accent,
                backgroundColor: c.surface,
              ),
            ),
            CodexMotionPresence(
              visible:
                  state.catalogPhase == CodexCatalogPhase.failed &&
                  state.catalog.allThreads.isNotEmpty,
              child: _CatalogErrorBanner(
                error: state.catalogError ?? 'Could not refresh threads',
                onRetry: state.retryCatalog,
              ),
            ),
            CodexMotionPresence(
              visible: state.createThreadError != null,
              child: _CreateThreadErrorBanner(
                error: state.createThreadError ?? '',
                onDismiss: state.clearCreateThreadError,
              ),
            ),
            CodexMotionPresence(
              visible: viewModel.queryError != null,
              child: _CatalogErrorBanner(
                error: viewModel.queryError ?? '',
                onRetry: () => _runThreadQuery(viewModel),
              ),
            ),
            Expanded(
              child: CodexMotionSwitcher(child: _content(context, viewModel)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, CodexThreadSidebarViewModel viewModel) {
    final state = serviceState;
    if (_usesQueryResults(viewModel)) {
      return _queryList(context, viewModel);
    }
    if ((state.catalogPhase == CodexCatalogPhase.idle ||
            state.catalogPhase == CodexCatalogPhase.loading) &&
        state.catalog.allThreads.isEmpty) {
      return const Center(
        key: ValueKey('codex-sidebar-loading-state'),
        child: CircularProgressIndicator(
          key: ValueKey('codex-catalog-loading'),
        ),
      );
    }
    if (state.catalogPhase == CodexCatalogPhase.failed &&
        state.catalog.allThreads.isEmpty) {
      return _CatalogFailure(
        key: const ValueKey('codex-sidebar-failure-state'),
        error: state.catalogError ?? 'Could not load Codex threads',
        onRetry: state.retryCatalog,
      );
    }
    return switch (mode) {
      CodexSidebarMode.projects => _projectList(context, viewModel),
      CodexSidebarMode.timeline => _timelineList(context, viewModel),
    };
  }

  Widget _queryList(
    BuildContext context,
    CodexThreadSidebarViewModel viewModel,
  ) {
    if (viewModel.queryLoading && viewModel.queryResults.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (viewModel.queryError != null && viewModel.queryResults.isEmpty) {
      return _CatalogFailure(
        error: viewModel.queryError!,
        onRetry: () => _runThreadQuery(viewModel),
      );
    }
    final results = viewModel.queryResults;
    if (results.isEmpty) {
      return _EmptyCatalog(
        label: viewModel.showArchived
            ? 'No archived threads'
            : 'No matching threads',
      );
    }
    return ListView(
      key: ValueKey(
        viewModel.showArchived
            ? 'codex-archived-thread-list'
            : 'codex-thread-search-results',
      ),
      padding: const EdgeInsets.only(bottom: MotifSpacing.xl),
      children: [
        CodexSidebarSectionHeading(
          viewModel.showArchived
              ? (viewModel.query.trim().isEmpty
                    ? 'Archived threads'
                    : 'Archived results')
              : 'Search results',
        ),
        for (final thread in results)
          _threadRow(
            context,
            viewModel,
            thread,
            archived: viewModel.showArchived,
            subtitle: _managementThreadSubtitle(thread),
          ),
      ],
    );
  }

  Widget _projectList(
    BuildContext context,
    CodexThreadSidebarViewModel viewModel,
  ) {
    final snapshot = serviceState.catalog;
    final children = <Widget>[];
    if (snapshot.pinnedThreads.isNotEmpty) {
      children.add(const CodexSidebarSectionHeading('Pinned'));
      children.addAll(
        snapshot.pinnedThreads.map(
          (thread) => _threadRow(
            context,
            viewModel,
            thread,
            pinned: true,
            horizontalContentPadding: MotifSpacing.sm,
          ),
        ),
      );
    }

    children.add(const CodexSidebarSectionHeading('Projects'));
    children.addAll(
      snapshot.projects
          .take(_initialProjectCount)
          .map((group) => _projectSection(context, viewModel, group)),
    );
    final extraProjects = snapshot.projects
        .skip(_initialProjectCount)
        .toList(growable: false);
    if (extraProjects.isNotEmpty) {
      children.add(
        CodexMotionExpansion(
          expanded: viewModel.showAllProjects,
          child: Column(
            key: const ValueKey('codex-extra-projects'),
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final group in extraProjects)
                _projectSection(context, viewModel, group),
            ],
          ),
        ),
      );
      children.add(
        _ShowMoreRow(
          key: const ValueKey('codex-projects-more'),
          label: viewModel.showAllProjects ? 'Show less' : 'Show more',
          onTap: () =>
              _setShowAllProjects(viewModel, !viewModel.showAllProjects),
        ),
      );
    }

    children.add(
      CodexSidebarSectionHeading(
        'Recents',
        trailing: serviceState.creatingProjectlessThread
            ? const SizedBox.square(
                dimension: MotifControlSize.sm,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : IconButton(
                key: const ValueKey('codex-recents-new'),
                tooltip: 'New thread without a project',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: MotifControlSize.sm,
                  height: MotifControlSize.sm,
                ),
                style: const ButtonStyle(
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                visualDensity: VisualDensity.compact,
                iconSize: MotifIconSize.sm,
                color: context.motif.textTertiary,
                onPressed: () => unawaited(_createProjectlessThread(context)),
                icon: const Icon(Icons.edit_square),
              ),
      ),
    );
    children.addAll(
      snapshot.projectlessThreads.map(
        (thread) => _threadRow(
          context,
          viewModel,
          thread,
          horizontalContentPadding: MotifSpacing.sm,
        ),
      ),
    );
    if (snapshot.allThreads.isEmpty && snapshot.projects.isEmpty) {
      children.add(const _EmptyCatalog());
    }
    return ListView(
      key: const ValueKey('codex-project-list'),
      controller: viewModel.projectsScrollController,
      padding: const EdgeInsets.only(bottom: MotifSpacing.xl),
      children: children,
    );
  }

  Widget _projectSection(
    BuildContext context,
    CodexThreadSidebarViewModel viewModel,
    CodexProjectGroup group,
  ) {
    final projectId = group.project.id;
    final expanded = _projectIsExpanded(viewModel, projectId);
    final nested = <Widget>[];
    if (group.threads.isEmpty) {
      nested.add(const _EmptyProjectRow());
    } else {
      final visibleThreadCount =
          viewModel.visibleThreadCounts[projectId] ?? _initialThreadCount;
      final effectiveThreadCount = visibleThreadCount < group.threads.length
          ? visibleThreadCount
          : group.threads.length;
      final hasMoreThreads = effectiveThreadCount < group.threads.length;
      nested.addAll(
        group.threads
            .take(effectiveThreadCount)
            .map(
              (thread) => _threadRow(
                context,
                viewModel,
                thread,
                indented: true,
                horizontalContentPadding: MotifSpacing.lg,
              ),
            ),
      );
      if (group.threads.length > _initialThreadCount) {
        nested.add(
          _ShowMoreRow(
            key: ValueKey('codex-project-threads-more-$projectId'),
            label: hasMoreThreads ? 'Show more' : 'Show less',
            onTap: () => _setVisibleThreadCount(
              viewModel,
              projectId,
              hasMoreThreads
                  ? (effectiveThreadCount + _threadPageSize <
                            group.threads.length
                        ? effectiveThreadCount + _threadPageSize
                        : group.threads.length)
                  : _initialThreadCount,
            ),
          ),
        );
      }
    }
    return Column(
      key: ValueKey('codex-project-section-$projectId'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _ProjectRow(
          key: ValueKey('codex-project-$projectId'),
          group: group,
          expanded: expanded,
          creating: serviceState.creatingProjectId == projectId,
          onTap: () => _setProjectExpanded(viewModel, projectId, !expanded),
          onNewThread: () async {
            final created = await serviceState.createThreadForProject(
              group.project,
            );
            if (!context.mounted || !created) return;
            _setProjectExpanded(viewModel, projectId, true);
            onThreadCreated?.call();
          },
        ),
        CodexMotionExpansion(
          expanded: expanded,
          child: AnimatedSize(
            duration: codexExpansionDuration(context),
            curve: codexExpansionCurve(context),
            alignment: Alignment.topCenter,
            child: Column(mainAxisSize: MainAxisSize.min, children: nested),
          ),
        ),
      ],
    );
  }

  Future<void> _createProjectlessThread(BuildContext context) async {
    final created = await serviceState.createProjectlessThread();
    if (!context.mounted || !created) return;
    onThreadCreated?.call();
  }

  Widget _timelineList(
    BuildContext context,
    CodexThreadSidebarViewModel viewModel,
  ) {
    final snapshot = serviceState.catalog;
    final priority = snapshot.allThreads.where(codexThreadIsActive).toList()
      ..sort(compareCodexThreadsByRecency);
    final dated =
        snapshot.allThreads
            .where((thread) => !codexThreadIsActive(thread))
            .toList()
          ..sort(compareCodexThreadsByRecency);
    final groups = <String, List<CodexThread>>{};
    for (final thread in dated) {
      groups.putIfAbsent(codexThreadDateLabel(thread), () => []).add(thread);
    }

    final children = <Widget>[];
    if (priority.isNotEmpty) {
      children.add(const CodexSidebarSectionHeading('Priority'));
      children.addAll(
        priority.map(
          (thread) => _timelineThreadRow(context, viewModel, thread),
        ),
      );
    }
    for (final entry in groups.entries) {
      children.add(CodexSidebarSectionHeading(entry.key));
      children.addAll(
        entry.value.map(
          (thread) => _timelineThreadRow(context, viewModel, thread),
        ),
      );
    }
    if (children.isEmpty) children.add(const _EmptyCatalog());
    return ListView(
      key: const ValueKey('codex-timeline-list'),
      controller: viewModel.timelineScrollController,
      padding: const EdgeInsets.only(bottom: MotifSpacing.xl),
      children: children,
    );
  }

  Widget _timelineThreadRow(
    BuildContext context,
    CodexThreadSidebarViewModel viewModel,
    CodexThread thread,
  ) {
    final catalog = serviceState.catalog;
    final project = catalog.projectNameForThread(thread.id);
    final cwd = thread.cwd.value.trim();
    return _threadRow(
      context,
      viewModel,
      thread,
      pinned: catalog.isPinned(thread.id),
      subtitle: project ?? (cwd.isEmpty ? null : codexPathBasename(cwd)),
      subtitleIcon: Icons.folder_outlined,
      subtitleSpacing: MotifSpacing.xs,
      height: MotifControlSize.lg + MotifSpacing.sm,
      horizontalContentPadding: MotifSpacing.sm,
    );
  }

  Widget _threadRow(
    BuildContext context,
    CodexThreadSidebarViewModel viewModel,
    CodexThread thread, {
    bool pinned = false,
    bool indented = false,
    bool archived = false,
    String? subtitle,
    IconData? subtitleIcon,
    double subtitleSpacing = 0,
    double height = codexSidebarRowHeight,
    double horizontalContentPadding = MotifSpacing.md,
  }) => CodexSidebarThreadRow(
    key: ValueKey('codex-thread-${thread.id}'),
    title: codexThreadTitle(thread),
    indicator:
        codexThreadIsManagedWorktree(
          thread,
          serviceState.connection.state.response?.codexHome.value ?? '',
        )
        ? Tooltip(
            message: 'Worktree',
            child: Icon(
              Icons.account_tree_outlined,
              key: ValueKey('codex-thread-worktree-${thread.id}'),
              size: MotifIconSize.sm,
              color: context.motif.textTertiary,
            ),
          )
        : null,
    selected: !archived && serviceState.selectedThread?.id == thread.id,
    loading: !archived && serviceState.readingThreadId == thread.id,
    active: codexThreadIsActive(thread),
    pinned: pinned,
    indented: indented,
    subtitle: subtitle,
    subtitleIcon: subtitleIcon,
    subtitleSpacing: subtitleSpacing,
    height: height,
    horizontalContentPadding: horizontalContentPadding,
    rightContentPadding: MotifSpacing.sm,
    trailing: _ThreadActionsButton(
      thread: thread,
      archived: archived,
      onSelected: (action) =>
          _handleThreadAction(context, viewModel, thread, action),
    ),
    onTap: archived ? null : () => onThreadSelected(thread.id),
  );

  bool _usesQueryResults(CodexThreadSidebarViewModel viewModel) =>
      viewModel.showArchived || viewModel.query.trim().isNotEmpty;

  String? _managementThreadSubtitle(CodexThread thread) {
    final project = serviceState.catalog.projectNameForThread(thread.id);
    if (project != null) return project;
    final cwd = thread.cwd.value.trim();
    return cwd.isEmpty ? null : codexPathBasename(cwd);
  }

  void _toggleSearch(CodexThreadSidebarViewModel viewModel) {
    viewModel.showSearch = !viewModel.showSearch;
    if (!viewModel.showSearch && viewModel.query.isNotEmpty) {
      _setQuery(viewModel, '');
    }
  }

  void _toggleArchived(CodexThreadSidebarViewModel viewModel) {
    viewModel.showArchived = !viewModel.showArchived;
    viewModel.queryError = null;
    if (_usesQueryResults(viewModel)) {
      unawaited(_runThreadQuery(viewModel));
    } else {
      viewModel.searchTimer?.cancel();
      viewModel.queryGeneration++;
      viewModel.queryLoading = false;
      viewModel.queryResults.clear();
    }
  }

  void _setQuery(CodexThreadSidebarViewModel viewModel, String value) {
    viewModel.query = value;
    viewModel.queryError = null;
    viewModel.searchTimer?.cancel();
    if (!_usesQueryResults(viewModel)) {
      viewModel.queryGeneration++;
      viewModel.queryLoading = false;
      viewModel.queryResults.clear();
      return;
    }
    viewModel.queryLoading = true;
    viewModel.searchTimer = Timer(
      const Duration(milliseconds: 250),
      () => unawaited(_runThreadQuery(viewModel)),
    );
  }

  Future<void> _runThreadQuery(CodexThreadSidebarViewModel viewModel) async {
    viewModel.searchTimer?.cancel();
    final generation = ++viewModel.queryGeneration;
    viewModel.queryLoading = true;
    viewModel.queryError = null;
    try {
      final threads = await serviceState.listThreadsForManagement(
        archived: viewModel.showArchived,
        searchTerm: viewModel.query,
      );
      if (generation != viewModel.queryGeneration) return;
      viewModel.queryResults.replaceRange(
        0,
        viewModel.queryResults.length,
        threads,
      );
    } catch (error) {
      if (generation != viewModel.queryGeneration) return;
      viewModel.queryError = '$error';
    } finally {
      if (generation == viewModel.queryGeneration) {
        viewModel.queryLoading = false;
      }
    }
  }

  Future<void> _handleThreadAction(
    BuildContext context,
    CodexThreadSidebarViewModel viewModel,
    CodexThread thread,
    _ThreadAction action,
  ) async {
    try {
      switch (action) {
        case _ThreadAction.rename:
          final name = await showRenameDialog(
            context,
            title: 'Rename thread',
            initialValue: codexThreadTitle(thread),
            helperText: 'Shown in the Codex thread list',
            fieldKey: const ValueKey('codex-thread-rename-field'),
            saveKey: const ValueKey('codex-thread-rename-save'),
          );
          if (name == null) return;
          if (name.trim().isEmpty) {
            if (context.mounted) {
              showMotifToast(context, 'Thread name cannot be empty');
            }
            return;
          }
          await serviceState.renameThread(thread.id, name);
        case _ThreadAction.archive:
          await serviceState.archiveThread(thread.id);
        case _ThreadAction.restore:
          await serviceState.unarchiveThread(thread.id);
      }
      if (_usesQueryResults(viewModel)) {
        await _runThreadQuery(viewModel);
      }
    } catch (error) {
      if (context.mounted) {
        showMotifToast(context, 'Thread operation failed: $error');
      }
    }
  }

  bool _projectIsExpanded(
    CodexThreadSidebarViewModel viewModel,
    String projectId,
  ) {
    final selected = serviceState.catalog.selectedProjectId;
    return viewModel.expandedProjects.contains(projectId) ||
        (selected == projectId && selected != viewModel.seededSelectedProject);
  }

  void _scheduleSelectedProjectSeed(
    BuildContext context,
    CodexThreadSidebarViewModel viewModel,
  ) {
    final selected = serviceState.catalog.selectedProjectId;
    if (selected == null || selected == viewModel.seededSelectedProject) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted || selected == viewModel.seededSelectedProject) {
        return;
      }
      viewModel.seededSelectedProject = selected;
      viewModel.expandedProjects.add(selected);
      codexState.setProjectExpanded(_serverId, selected, true);
    });
  }

  void _setProjectExpanded(
    CodexThreadSidebarViewModel viewModel,
    String projectId,
    bool expanded,
  ) {
    if (!expanded) {
      _setVisibleThreadCount(viewModel, projectId, _initialThreadCount);
    }
    expanded
        ? viewModel.expandedProjects.add(projectId)
        : viewModel.expandedProjects.remove(projectId);
    codexState.setProjectExpanded(_serverId, projectId, expanded);
  }

  void _setVisibleThreadCount(
    CodexThreadSidebarViewModel viewModel,
    String projectId,
    int count,
  ) {
    if (count <= _initialThreadCount) {
      viewModel.visibleThreadCounts.remove(projectId);
      codexState.setVisibleThreadCount(_serverId, projectId, null);
      return;
    }
    viewModel.visibleThreadCounts[projectId] = count;
    codexState.setVisibleThreadCount(_serverId, projectId, count);
  }

  void _setShowAllProjects(CodexThreadSidebarViewModel viewModel, bool value) {
    viewModel.showAllProjects = value;
    codexState.setShowAllProjects(_serverId, value);
  }
}

enum _ThreadAction { rename, archive, restore }

class _ThreadActionsButton extends StatelessWidget {
  const _ThreadActionsButton({
    required this.thread,
    required this.archived,
    required this.onSelected,
  });

  final CodexThread thread;
  final bool archived;
  final ValueChanged<_ThreadAction> onSelected;

  @override
  Widget build(BuildContext context) {
    final canArchive = !codexThreadIsActive(thread);
    return PopupMenuButton<_ThreadAction>(
      key: ValueKey('codex-thread-actions-${thread.id}'),
      tooltip: 'Thread actions',
      padding: EdgeInsets.zero,
      onSelected: onSelected,
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: _ThreadAction.rename,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.edit_outlined),
            title: Text('Rename'),
          ),
        ),
        if (archived)
          const PopupMenuItem(
            value: _ThreadAction.restore,
            child: ListTile(
              dense: true,
              leading: Icon(Icons.unarchive_outlined),
              title: Text('Restore'),
            ),
          )
        else
          PopupMenuItem(
            value: _ThreadAction.archive,
            enabled: canArchive,
            child: const ListTile(
              dense: true,
              leading: Icon(Icons.archive_outlined),
              title: Text('Archive'),
            ),
          ),
      ],
      child: const SizedBox.square(
        dimension: 20,
        child: Align(
          alignment: Alignment.centerRight,
          child: Icon(Icons.more_horiz, size: MotifIconSize.sm),
        ),
      ),
    );
  }
}

class _ThreadSearchField extends StatefulWidget {
  const _ThreadSearchField({
    required this.initialValue,
    required this.archived,
    required this.onChanged,
    required this.onClear,
    super.key,
  });

  final String initialValue;
  final bool archived;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  State<_ThreadSearchField> createState() => _ThreadSearchFieldState();
}

class _ThreadSearchFieldState extends State<_ThreadSearchField> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialValue,
  );

  @override
  void didUpdateWidget(covariant _ThreadSearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialValue != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.initialValue,
        selection: TextSelection.collapsed(offset: widget.initialValue.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MotifSpacing.sm,
        MotifSpacing.sm,
        MotifSpacing.sm,
        MotifSpacing.xs,
      ),
      child: TextField(
        controller: _controller,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.archived
              ? 'Search archived threads'
              : 'Search threads',
          prefixIcon: const Icon(Icons.search, size: MotifIconSize.sm),
          suffixIcon: _controller.text.isEmpty
              ? null
              : IconButton(
                  key: const ValueKey('codex-thread-search-clear'),
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.close, size: MotifIconSize.sm),
                  onPressed: () {
                    _controller.clear();
                    widget.onClear();
                    setState(() {});
                  },
                ),
          filled: true,
          fillColor: c.surfaceElevated,
        ),
        onChanged: (value) {
          widget.onChanged(value);
          setState(() {});
        },
      ),
    );
  }
}

class _ProjectRow extends StatelessWidget {
  const _ProjectRow({
    required this.group,
    required this.expanded,
    required this.creating,
    required this.onTap,
    required this.onNewThread,
    super.key,
  });

  final CodexProjectGroup group;
  final bool expanded;
  final bool creating;
  final VoidCallback onTap;
  final VoidCallback onNewThread;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return SizedBox(
      height: codexSidebarRowHeight,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.lg),
          child: Row(
            children: [
              Icon(
                expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
                size: MotifIconSize.md,
                color: c.textSecondary,
              ),
              const SizedBox(width: MotifSpacing.xs),
              Expanded(
                child: Text(
                  group.project.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.sidebar.copyWith(color: c.textPrimary),
                ),
              ),
              SizedBox.square(
                dimension: MotifControlSize.sm,
                child: Center(
                  child: CodexMotionSwitcher(
                    offset: Offset.zero,
                    child: creating
                        ? SizedBox.square(
                            key: ValueKey(
                              'codex-project-new-loading-${group.project.id}',
                            ),
                            dimension: MotifIconSize.sm,
                            child: const CircularProgressIndicator(
                              strokeWidth: 2,
                            ),
                          )
                        : IconButton(
                            key: ValueKey(
                              'codex-project-new-${group.project.id}',
                            ),
                            tooltip: 'New thread in ${group.project.name}',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: MotifControlSize.sm,
                              height: MotifControlSize.sm,
                            ),
                            style: const ButtonStyle(
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            visualDensity: VisualDensity.compact,
                            iconSize: MotifIconSize.sm,
                            color: c.textTertiary,
                            onPressed: onNewThread,
                            icon: const Icon(Icons.edit_square),
                          ),
                  ),
                ),
              ),
              AnimatedRotation(
                turns: expanded ? 0.5 : 0,
                duration: codexExpansionDuration(context),
                curve: codexExpansionCurve(context),
                child: Icon(
                  Icons.expand_more,
                  key: ValueKey('codex-project-toggle-${group.project.id}'),
                  size: MotifIconSize.sm,
                  color: c.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ShowMoreRow extends StatelessWidget {
  const _ShowMoreRow({required this.label, required this.onTap, super.key});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return SizedBox(
      height: codexSidebarRowHeight,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.only(
            left: MotifSpacing.lg + MotifIconSize.md + MotifSpacing.xs,
            right: MotifSpacing.lg,
          ),
          child: Row(
            children: [
              Text(
                label,
                style: MotifType.sidebar.copyWith(color: c.textTertiary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyProjectRow extends StatelessWidget {
  const _EmptyProjectRow();

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return SizedBox(
      height: codexSidebarRowHeight,
      child: Padding(
        padding: const EdgeInsets.only(left: 56, right: MotifSpacing.lg),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'No threads',
            style: MotifType.subhead.copyWith(color: c.textTertiary),
          ),
        ),
      ),
    );
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog({this.label = 'No Codex threads'});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.all(MotifSpacing.xl),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: MotifType.body.copyWith(color: c.textTertiary),
      ),
    );
  }
}

class _CatalogFailure extends StatelessWidget {
  const _CatalogFailure({
    required this.error,
    required this.onRetry,
    super.key,
  });

  final String error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MotifSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error,
              textAlign: TextAlign.center,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: MotifType.subhead.copyWith(color: c.danger),
            ),
            const SizedBox(height: MotifSpacing.md),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

class _CatalogErrorBanner extends StatelessWidget {
  const _CatalogErrorBanner({required this.error, required this.onRetry});

  final String error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Material(
      color: c.danger.withValues(alpha: 0.08),
      child: InkWell(
        onTap: onRetry,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MotifSpacing.md,
            vertical: MotifSpacing.sm,
          ),
          child: Row(
            children: [
              Icon(
                Icons.error_outline,
                size: MotifIconSize.sm,
                color: c.danger,
              ),
              const SizedBox(width: MotifSpacing.sm),
              Expanded(
                child: Text(
                  error,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.caption.copyWith(color: c.danger),
                ),
              ),
              const SizedBox(width: MotifSpacing.sm),
              Text('Retry', style: MotifType.callout.copyWith(color: c.danger)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CreateThreadErrorBanner extends StatelessWidget {
  const _CreateThreadErrorBanner({
    required this.error,
    required this.onDismiss,
  });

  final String error;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Material(
      color: c.danger.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MotifSpacing.md,
          vertical: MotifSpacing.xs,
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: MotifIconSize.sm, color: c.danger),
            const SizedBox(width: MotifSpacing.sm),
            Expanded(
              child: Text(
                error,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: MotifType.caption.copyWith(color: c.danger),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              iconSize: MotifIconSize.sm,
              color: c.danger,
              onPressed: onDismiss,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
    );
  }
}
