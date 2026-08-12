import 'package:flutter/material.dart';

import '../../codex/codex_session_state.dart';
import '../../codex/codex_state.dart';
import '../../codex/codex_thread_catalog.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../theme/motif_theme.dart';

class CodexThreadSidebar extends StatefulWidget {
  const CodexThreadSidebar({
    required this.sessionState,
    required this.mode,
    required this.onModeChanged,
    required this.onThreadSelected,
    super.key,
  });

  final CodexSessionState sessionState;
  final CodexSidebarMode mode;
  final ValueChanged<CodexSidebarMode> onModeChanged;
  final ValueChanged<String> onThreadSelected;

  @override
  State<CodexThreadSidebar> createState() => _CodexThreadSidebarState();
}

class _CodexThreadSidebarState extends State<CodexThreadSidebar> {
  static const int _initialProjectCount = 6;
  static const int _initialThreadCount = 5;

  final Set<String> _expandedProjects = {};
  final Set<String> _expandedThreadLists = {};
  String? _seededSelectedProject;
  bool _showAllProjects = false;

  @override
  void didUpdateWidget(covariant CodexThreadSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _seedSelectedProject();
  }

  @override
  Widget build(BuildContext context) {
    _seedSelectedProject();
    final c = context.motif;
    final state = widget.sessionState;
    return ColoredBox(
      color: c.surface,
      child: SafeArea(
        child: Column(
          children: [
            _ModeHeader(mode: widget.mode, onChanged: widget.onModeChanged),
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
    final state = widget.sessionState;
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
    final snapshot = widget.sessionState.catalog;
    final children = <Widget>[];
    if (snapshot.pinnedThreads.isNotEmpty) {
      children.add(const _SectionHeading('Pinned'));
      children.addAll(
        snapshot.pinnedThreads.map(
          (thread) => _threadRow(thread, pinned: true),
        ),
      );
    }

    children.add(const _SectionHeading('Projects'));
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
          creating: widget.sessionState.creatingProjectId == projectId,
          onTap: () => setState(() {
            expanded
                ? _expandedProjects.remove(projectId)
                : _expandedProjects.add(projectId);
          }),
          onNewThread: () async {
            final created = await widget.sessionState.createThreadForProject(
              group.project,
            );
            if (!mounted || !created) return;
            setState(() => _expandedProjects.add(projectId));
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
            onTap: () => setState(() {
              showAllThreads
                  ? _expandedThreadLists.remove(projectId)
                  : _expandedThreadLists.add(projectId);
            }),
          ),
        );
      }
    }
    if (snapshot.projects.length > _initialProjectCount) {
      children.add(
        _ShowMoreRow(
          key: const ValueKey('codex-projects-more'),
          label: _showAllProjects ? 'Show less' : 'Show more',
          onTap: () => setState(() => _showAllProjects = !_showAllProjects),
        ),
      );
    }

    if (snapshot.projectlessThreads.isNotEmpty) {
      children.add(const _SectionHeading('Recents'));
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
    final snapshot = widget.sessionState.catalog;
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
      children.add(const _SectionHeading('Priority'));
      children.addAll(priority.map(_timelineThreadRow));
    }
    for (final entry in groups.entries) {
      children.add(_SectionHeading(entry.key));
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
    final catalog = widget.sessionState.catalog;
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
  }) => _ThreadRow(
    key: ValueKey('codex-thread-${thread.id}'),
    thread: thread,
    selected: widget.sessionState.selectedThread?.id == thread.id,
    loading: widget.sessionState.readingThreadId == thread.id,
    pinned: pinned,
    indented: indented,
    subtitle: subtitle,
    onTap: () => widget.onThreadSelected(thread.id),
  );

  void _seedSelectedProject() {
    final selected = widget.sessionState.catalog.selectedProjectId;
    if (selected == null || selected == _seededSelectedProject) return;
    _seededSelectedProject = selected;
    _expandedProjects.add(selected);
  }
}

class _ModeHeader extends StatelessWidget {
  const _ModeHeader({required this.mode, required this.onChanged});

  final CodexSidebarMode mode;
  final ValueChanged<CodexSidebarMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      child: Row(
        children: [
          _ModeButton(
            key: const ValueKey('codex-mode-projects'),
            icon: Icons.folder_outlined,
            tooltip: 'Projects',
            selected: mode == CodexSidebarMode.projects,
            onTap: () => onChanged(CodexSidebarMode.projects),
          ),
          const SizedBox(width: MotifSpacing.xs),
          _ModeButton(
            key: const ValueKey('codex-mode-timeline'),
            icon: Icons.schedule_outlined,
            tooltip: 'Timeline',
            selected: mode == CodexSidebarMode.timeline,
            onTap: () => onChanged(CodexSidebarMode.timeline),
          ),
          const Spacer(),
          Text('Threads', style: MotifType.caption),
        ],
      ),
    );
  }
}

class _ModeButton extends StatelessWidget {
  const _ModeButton({
    required this.icon,
    required this.tooltip,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: selected ? c.accentFill() : Colors.transparent,
        borderRadius: BorderRadius.circular(MotifRadius.xs),
        child: InkWell(
          borderRadius: BorderRadius.circular(MotifRadius.xs),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(MotifSpacing.sm),
            child: Icon(
              icon,
              size: MotifIconSize.md,
              color: selected ? c.accent : c.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        MotifSpacing.lg,
        MotifSpacing.xl,
        MotifSpacing.lg,
        MotifSpacing.sm,
      ),
      child: Text(
        label,
        style: MotifType.headline.copyWith(color: c.textTertiary),
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
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MotifSpacing.lg,
          vertical: MotifSpacing.md,
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

class _ThreadRow extends StatelessWidget {
  const _ThreadRow({
    required this.thread,
    required this.selected,
    required this.loading,
    required this.pinned,
    required this.indented,
    required this.subtitle,
    required this.onTap,
    super.key,
  });

  final CodexThread thread;
  final bool selected;
  final bool loading;
  final bool pinned;
  final bool indented;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final active = codexThreadIsActive(thread);
    return Padding(
      padding: EdgeInsets.only(
        left: indented ? MotifSpacing.xl : MotifSpacing.sm,
        right: MotifSpacing.sm,
        bottom: 2,
      ),
      child: Material(
        color: selected ? c.accentFill() : Colors.transparent,
        borderRadius: BorderRadius.circular(MotifRadius.xs),
        child: InkWell(
          borderRadius: BorderRadius.circular(MotifRadius.xs),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MotifSpacing.md,
              vertical: 10,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        codexThreadTitle(thread),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: MotifType.body.copyWith(color: c.textPrimary),
                      ),
                      if (subtitle?.isNotEmpty == true) ...[
                        const SizedBox(height: 3),
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MotifType.subhead.copyWith(
                            color: c.textTertiary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (pinned) ...[
                  const SizedBox(width: MotifSpacing.xs),
                  Icon(
                    Icons.push_pin_outlined,
                    size: MotifIconSize.sm,
                    color: c.textTertiary,
                  ),
                ],
                if (loading || active) ...[
                  const SizedBox(width: MotifSpacing.sm),
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.accent,
                    ),
                  ),
                ],
              ],
            ),
          ),
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
          MotifSpacing.sm,
          MotifSpacing.lg,
          MotifSpacing.sm,
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
      padding: const EdgeInsets.fromLTRB(56, 4, MotifSpacing.lg, 12),
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
