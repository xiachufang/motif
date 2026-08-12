import 'dart:async';

import 'package:flutter/material.dart';

import '../../codex/codex_service_state.dart';
import '../../codex/codex_state.dart';
import '../../codex/codex_thread_catalog.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../theme/motif_theme.dart';
import '../widgets/codex_sidebar_components.dart';

class CodexThreadSidebar extends StatefulWidget {
  const CodexThreadSidebar({
    required this.serviceState,
    required this.codexState,
    required this.mode,
    required this.onModeChanged,
    required this.onThreadSelected,
    super.key,
  });

  final CodexServiceState serviceState;
  final CodexState codexState;
  final CodexSidebarMode mode;
  final ValueChanged<CodexSidebarMode> onModeChanged;
  final ValueChanged<String> onThreadSelected;

  @override
  State<CodexThreadSidebar> createState() => _CodexThreadSidebarState();
}

class _CodexThreadSidebarState extends State<CodexThreadSidebar> {
  static const int _initialProjectCount = 6;
  static const int _initialThreadCount = 5;

  late Set<String> _expandedProjects;
  late Set<String> _expandedThreadLists;
  String? _seededSelectedProject;
  late bool _showAllProjects;

  String get _serverId => widget.serviceState.serverId;

  @override
  void initState() {
    super.initState();
    _restorePreferences();
  }

  @override
  void didUpdateWidget(covariant CodexThreadSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serviceState.serverId != widget.serviceState.serverId ||
        !identical(oldWidget.codexState, widget.codexState)) {
      _restorePreferences();
    }
    _seedSelectedProject();
  }

  @override
  Widget build(BuildContext context) {
    _seedSelectedProject();
    final c = context.motif;
    final state = widget.serviceState;
    return ColoredBox(
      color: c.surface,
      child: SafeArea(
        child: Column(
          children: [
            CodexSidebarHeader(
              label: 'Threads',
              actions: [
                CodexSidebarIconButton(
                  key: const ValueKey('codex-mode-timeline'),
                  icon: Icons.schedule_outlined,
                  tooltip: widget.mode == CodexSidebarMode.timeline
                      ? 'Group by project'
                      : 'Group by time',
                  selected: widget.mode == CodexSidebarMode.timeline,
                  onTap: () => widget.onModeChanged(
                    widget.mode == CodexSidebarMode.timeline
                        ? CodexSidebarMode.projects
                        : CodexSidebarMode.timeline,
                  ),
                ),
                CodexSidebarIconButton(
                  key: const ValueKey('codex-threads-refresh'),
                  icon: Icons.refresh,
                  tooltip: 'Refresh threads',
                  selected: false,
                  busy: state.catalogPhase == CodexCatalogPhase.loading,
                  onTap: state.catalogPhase == CodexCatalogPhase.loading
                      ? null
                      : () => unawaited(state.refreshCatalog()),
                ),
              ],
            ),
            Divider(height: 1, color: c.border),
            if (state.catalogPhase == CodexCatalogPhase.loading &&
                state.catalog.allThreads.isNotEmpty)
              LinearProgressIndicator(
                minHeight: 2,
                color: c.accent,
                backgroundColor: c.surface,
              ),
            if (state.catalogPhase == CodexCatalogPhase.failed &&
                state.catalog.allThreads.isNotEmpty)
              _CatalogErrorBanner(
                error: state.catalogError ?? 'Could not refresh threads',
                onRetry: state.retryCatalog,
              ),
            if (state.createThreadError != null)
              _CreateThreadErrorBanner(
                error: state.createThreadError!,
                onDismiss: state.clearCreateThreadError,
              ),
            Expanded(child: _content(context)),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final state = widget.serviceState;
    if ((state.catalogPhase == CodexCatalogPhase.idle ||
            state.catalogPhase == CodexCatalogPhase.loading) &&
        state.catalog.allThreads.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(
          key: ValueKey('codex-catalog-loading'),
        ),
      );
    }
    if (state.catalogPhase == CodexCatalogPhase.failed &&
        state.catalog.allThreads.isEmpty) {
      return _CatalogFailure(
        error: state.catalogError ?? 'Could not load Codex threads',
        onRetry: state.retryCatalog,
      );
    }
    return switch (widget.mode) {
      CodexSidebarMode.projects => _projectList(context),
      CodexSidebarMode.timeline => _timelineList(context),
    };
  }

  Widget _projectList(BuildContext context) {
    final snapshot = widget.serviceState.catalog;
    final children = <Widget>[];
    if (snapshot.pinnedThreads.isNotEmpty) {
      children.add(const CodexSidebarSectionHeading('Pinned'));
      children.addAll(
        snapshot.pinnedThreads.map(
          (thread) => _threadRow(thread, pinned: true),
        ),
      );
    }

    children.add(const CodexSidebarSectionHeading('Projects'));
    final visibleProjects = _showAllProjects
        ? snapshot.projects
        : snapshot.projects.take(_initialProjectCount);
    for (final group in visibleProjects) {
      final projectId = group.project.id;
      final expanded = _expandedProjects.contains(projectId);
      children.add(
        _ProjectRow(
          key: ValueKey('codex-project-$projectId'),
          group: group,
          expanded: expanded,
          creating: widget.serviceState.creatingProjectId == projectId,
          onTap: () => _setProjectExpanded(projectId, !expanded),
          onNewThread: () async {
            final created = await widget.serviceState.createThreadForProject(
              group.project,
            );
            if (!mounted || !created) return;
            _setProjectExpanded(projectId, true);
          },
        ),
      );
      if (!expanded) continue;
      if (group.threads.isEmpty) {
        children.add(const _EmptyProjectRow());
        continue;
      }
      final showAllThreads = _expandedThreadLists.contains(projectId);
      final visibleThreads = showAllThreads
          ? group.threads
          : group.threads.take(_initialThreadCount);
      children.addAll(
        visibleThreads.map((thread) => _threadRow(thread, indented: true)),
      );
      if (group.threads.length > _initialThreadCount) {
        children.add(
          _ShowMoreRow(
            key: ValueKey('codex-project-threads-more-$projectId'),
            label: showAllThreads ? 'Show less' : 'Show more',
            indented: true,
            onTap: () => _setThreadListExpanded(projectId, !showAllThreads),
          ),
        );
      }
    }
    if (snapshot.projects.length > _initialProjectCount) {
      children.add(
        _ShowMoreRow(
          key: const ValueKey('codex-projects-more'),
          label: _showAllProjects ? 'Show less' : 'Show more',
          onTap: () => _setShowAllProjects(!_showAllProjects),
        ),
      );
    }

    if (snapshot.projectlessThreads.isNotEmpty) {
      children.add(const CodexSidebarSectionHeading('Recents'));
      children.addAll(snapshot.projectlessThreads.map(_threadRow));
    }
    if (snapshot.allThreads.isEmpty && snapshot.projects.isEmpty) {
      children.add(const _EmptyCatalog());
    }
    return ListView(
      key: const ValueKey('codex-project-list'),
      padding: const EdgeInsets.only(bottom: MotifSpacing.xl),
      children: children,
    );
  }

  Widget _timelineList(BuildContext context) {
    final snapshot = widget.serviceState.catalog;
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
      children.addAll(priority.map(_timelineThreadRow));
    }
    for (final entry in groups.entries) {
      children.add(CodexSidebarSectionHeading(entry.key));
      children.addAll(entry.value.map(_timelineThreadRow));
    }
    if (children.isEmpty) children.add(const _EmptyCatalog());
    return ListView(
      key: const ValueKey('codex-timeline-list'),
      padding: const EdgeInsets.only(bottom: MotifSpacing.xl),
      children: children,
    );
  }

  Widget _timelineThreadRow(CodexThread thread) {
    final catalog = widget.serviceState.catalog;
    final project = catalog.projectNameForThread(thread.id);
    final cwd = thread.cwd.value.trim();
    return _threadRow(
      thread,
      pinned: catalog.isPinned(thread.id),
      subtitle: project ?? (cwd.isEmpty ? null : codexPathBasename(cwd)),
    );
  }

  Widget _threadRow(
    CodexThread thread, {
    bool pinned = false,
    bool indented = false,
    String? subtitle,
  }) => CodexSidebarThreadRow(
    key: ValueKey('codex-thread-${thread.id}'),
    title: codexThreadTitle(thread),
    selected: widget.serviceState.selectedThread?.id == thread.id,
    loading: widget.serviceState.readingThreadId == thread.id,
    active: codexThreadIsActive(thread),
    pinned: pinned,
    indented: indented,
    subtitle: subtitle,
    onTap: () => widget.onThreadSelected(thread.id),
  );

  void _seedSelectedProject() {
    final selected = widget.serviceState.catalog.selectedProjectId;
    if (selected == null || selected == _seededSelectedProject) return;
    _seededSelectedProject = selected;
    _expandedProjects.add(selected);
    widget.codexState.setProjectExpanded(_serverId, selected, true);
  }

  void _restorePreferences() {
    final preferences = widget.codexState.projectSidebar(_serverId);
    _expandedProjects = {...preferences.expandedProjects};
    _expandedThreadLists = {...preferences.expandedThreadLists};
    _showAllProjects = preferences.showAllProjects;
    _seededSelectedProject = preferences.initialized
        ? widget.serviceState.catalog.selectedProjectId
        : null;
  }

  void _setProjectExpanded(String projectId, bool expanded) {
    setState(() {
      expanded
          ? _expandedProjects.add(projectId)
          : _expandedProjects.remove(projectId);
    });
    widget.codexState.setProjectExpanded(_serverId, projectId, expanded);
  }

  void _setThreadListExpanded(String projectId, bool expanded) {
    setState(() {
      expanded
          ? _expandedThreadLists.add(projectId)
          : _expandedThreadLists.remove(projectId);
    });
    widget.codexState.setThreadListExpanded(_serverId, projectId, expanded);
  }

  void _setShowAllProjects(bool value) {
    setState(() => _showAllProjects = value);
    widget.codexState.setShowAllProjects(_serverId, value);
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
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MotifSpacing.lg,
          vertical: MotifSpacing.xs,
        ),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.folder_open_outlined : Icons.folder_outlined,
              size: MotifIconSize.md,
              color: c.textSecondary,
            ),
            const SizedBox(width: MotifSpacing.md),
            Expanded(
              child: Text(
                group.project.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MotifType.body.copyWith(color: c.textPrimary),
              ),
            ),
            if (creating)
              const SizedBox.square(
                dimension: 32,
                child: Padding(
                  padding: EdgeInsets.all(8),
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              IconButton(
                key: ValueKey('codex-project-new-${group.project.id}'),
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
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: MotifIconSize.sm,
              color: c.textTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

class _ShowMoreRow extends StatelessWidget {
  const _ShowMoreRow({
    required this.label,
    required this.onTap,
    this.indented = false,
    super.key,
  });

  final String label;
  final VoidCallback onTap;
  final bool indented;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          indented ? 56 : MotifSpacing.lg,
          MotifSpacing.xs,
          MotifSpacing.lg,
          MotifSpacing.xs,
        ),
        child: Text(
          label,
          style: MotifType.body.copyWith(color: c.textTertiary),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        56,
        MotifSpacing.xs,
        MotifSpacing.lg,
        MotifSpacing.sm,
      ),
      child: Text(
        'No threads',
        style: MotifType.subhead.copyWith(color: c.textTertiary),
      ),
    );
  }
}

class _EmptyCatalog extends StatelessWidget {
  const _EmptyCatalog();

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.all(MotifSpacing.xl),
      child: Text(
        'No Codex threads',
        textAlign: TextAlign.center,
        style: MotifType.body.copyWith(color: c.textTertiary),
      ),
    );
  }
}

class _CatalogFailure extends StatelessWidget {
  const _CatalogFailure({required this.error, required this.onRetry});

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
