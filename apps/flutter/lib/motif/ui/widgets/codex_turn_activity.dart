import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../codex/codex_session_state.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../theme/motif_theme.dart';
import 'codex_markdown.dart';

const _activityDensity = VisualDensity(vertical: -4);
const _activityTileHeight = 36.0;
const _activityGroupMaxHeight = 360.0;
const _activityDetailMaxHeight = 300.0;
const _diffBodyMaxHeight = 280.0;

/// One chronological group of non-text items located between two text items.
/// The group is collapsed by default; expanding it never changes or merges the
/// order of the original protocol items.
class CodexTurnActivityGroup extends StatelessWidget {
  const CodexTurnActivityGroup({
    required this.state,
    required this.items,
    this.boundedDetails = true,
    super.key,
  });

  final CodexSessionState state;
  final List<CodexThreadItem> items;
  final bool boundedDetails;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final running = items.any(_isRunning);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: false,
        dense: true,
        visualDensity: _activityDensity,
        minTileHeight: _activityTileHeight,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: MotifSpacing.lg),
        leading: running
            ? SizedBox.square(
                dimension: MotifIconSize.sm,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                ),
              )
            : Icon(
                _groupIcon(items),
                size: MotifIconSize.sm,
                color: c.textTertiary,
              ),
        title: Text(
          _groupTitle(items),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: MotifType.subhead.copyWith(color: c.textSecondary),
        ),
        children: [
          if (boundedDetails)
            _BoundedScrollable(
              key: const ValueKey('codex-activity-group-scroll'),
              maxHeight: _activityGroupMaxHeight,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final item in items)
                    _ActivityItem(state: state, item: item),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in items)
                  _ActivityItem(state: state, item: item),
              ],
            ),
        ],
      ),
    );
  }
}

/// The single transient progress slot shown only for an in-progress turn.
class CodexTurnProgress extends StatelessWidget {
  const CodexTurnProgress({required this.reasoning, super.key});

  final CodexReasoningThreadItem? reasoning;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final text = _reasoningText(reasoning) ?? 'Codex is working…';
    return Row(
      key: const ValueKey('codex-turn-progress'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: c.accent),
          ),
        ),
        const SizedBox(width: MotifSpacing.sm),
        Expanded(
          child: CodexMarkdown(
            text,
            style: MotifType.subhead.copyWith(color: c.textTertiary),
          ),
        ),
      ],
    );
  }
}

/// Aggregates every file change emitted by one completed turn into a single
/// footer card. Repeated paths keep one row and their line counts are summed in
/// protocol order.
class CodexTurnDiffSummary extends StatefulWidget {
  const CodexTurnDiffSummary({
    required this.turnId,
    required this.items,
    this.cwd,
    super.key,
  });

  final String turnId;
  final List<CodexFileChangeThreadItem> items;
  final String? cwd;

  @override
  State<CodexTurnDiffSummary> createState() => _CodexTurnDiffSummaryState();
}

class _CodexTurnDiffSummaryState extends State<CodexTurnDiffSummary> {
  static const _collapsedFileCount = 3;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final files = _mergeTurnDiffs(widget.items, widget.cwd);
    if (files.isEmpty) return const SizedBox.shrink();
    final c = context.motif;
    final totalAdded = files.fold(0, (total, file) => total + file.added);
    final totalRemoved = files.fold(0, (total, file) => total + file.removed);
    final hiddenCount = files.length - _collapsedFileCount;
    final visibleFiles = _expanded
        ? files
        : files.take(_collapsedFileCount).toList(growable: false);

    return Container(
      key: ValueKey('codex-turn-diff-${widget.turnId}'),
      margin: const EdgeInsets.only(
        top: MotifSpacing.sm,
        bottom: MotifSpacing.xs,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(MotifRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(MotifSpacing.lg),
            child: Row(
              children: [
                Container(
                  width: MotifControlSize.lg,
                  height: MotifControlSize.lg,
                  decoration: BoxDecoration(
                    color: c.subtleFill,
                    borderRadius: BorderRadius.circular(MotifRadius.sm),
                  ),
                  child: Icon(
                    Icons.note_add_outlined,
                    size: MotifIconSize.lg,
                    color: c.textSecondary,
                  ),
                ),
                const SizedBox(width: MotifSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Edited ${files.length} ${files.length == 1 ? 'file' : 'files'}',
                        style: MotifType.headline.copyWith(
                          color: c.textPrimary,
                        ),
                      ),
                      _DiffStats(added: totalAdded, removed: totalRemoved),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.border),
          for (final file in visibleFiles) _TurnDiffFileRow(file: file),
          if (hiddenCount > 0)
            InkWell(
              key: ValueKey('codex-turn-diff-toggle-${widget.turnId}'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  MotifSpacing.lg,
                  MotifSpacing.sm,
                  MotifSpacing.lg,
                  MotifSpacing.md,
                ),
                child: Row(
                  children: [
                    Text(
                      _expanded
                          ? 'Collapse files'
                          : 'Show $hiddenCount more ${hiddenCount == 1 ? 'file' : 'files'}',
                      style: MotifType.subhead.copyWith(color: c.textPrimary),
                    ),
                    const SizedBox(width: MotifSpacing.sm),
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: MotifIconSize.md,
                      color: c.textSecondary,
                    ),
                  ],
                ),
              ),
            )
          else
            const SizedBox(height: MotifSpacing.sm),
        ],
      ),
    );
  }
}

class _TurnDiffFileRow extends StatelessWidget {
  const _TurnDiffFileRow({required this.file});

  final _TurnDiffFile file;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      key: ValueKey('codex-turn-diff-file-${file.path}'),
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.lg,
        vertical: MotifSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              file.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MotifType.subhead.copyWith(color: c.textSecondary),
            ),
          ),
          const SizedBox(width: MotifSpacing.md),
          _DiffStats(added: file.added, removed: file.removed),
        ],
      ),
    );
  }
}

class _DiffStats extends StatelessWidget {
  const _DiffStats({required this.added, required this.removed});

  final int added;
  final int removed;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('+$added', style: MotifType.subhead.copyWith(color: c.success)),
        const SizedBox(width: MotifSpacing.xs),
        Text('-$removed', style: MotifType.subhead.copyWith(color: c.danger)),
      ],
    );
  }
}

final class _TurnDiffFile {
  _TurnDiffFile(this.path);

  final String path;
  int added = 0;
  int removed = 0;
}

List<_TurnDiffFile> _mergeTurnDiffs(
  Iterable<CodexFileChangeThreadItem> items,
  String? cwd,
) {
  final files = <String, _TurnDiffFile>{};
  for (final item in items) {
    for (final change in item.changes) {
      final path = _pathWithoutCwd(change.path, cwd);
      final file = files.putIfAbsent(path, () => _TurnDiffFile(path));
      final stats = _diffStats(change.diff);
      file.added += stats.added;
      file.removed += stats.removed;
    }
  }
  return List.unmodifiable(files.values);
}

class _ActivityItem extends StatelessWidget {
  const _ActivityItem({required this.state, required this.item});

  final CodexSessionState state;
  final CodexThreadItem item;

  @override
  Widget build(BuildContext context) => switch (item) {
    CodexCommandExecutionThreadItem value => _CommandActivity(item: value),
    CodexFileChangeThreadItem value => _FileChangeActivity(
      item: value,
      cwd: state.selectedThread?.cwd.value,
    ),
    CodexWebSearchThreadItem value => _DetailActivity(
      icon: Icons.search,
      title: 'Searched for ${value.query}',
      detail: value.results?.isNotEmpty == true
          ? _jsonMarkdown(value.results)
          : null,
    ),
    CodexImageViewThreadItem value => _ImageActivity(state: state, item: value),
    CodexMcpToolCallThreadItem value => _DetailActivity(
      icon: Icons.extension_outlined,
      title: 'Used ${value.server} · ${value.tool}',
      detail: _jsonMarkdown({
        'arguments': value.arguments,
        if (value.result != null) 'result': value.result!.toJson(),
        if (value.error != null) 'error': value.error!.toJson(),
      }),
      running: value.status == CodexMcpToolCallStatus.inProgress,
    ),
    CodexDynamicToolCallThreadItem value => _DetailActivity(
      icon: Icons.build_outlined,
      title:
          'Used ${value.namespace == null ? '' : '${value.namespace} · '}${value.tool}',
      detail: _jsonMarkdown(value.toJson()),
      running: value.status == CodexDynamicToolCallStatus.inProgress,
    ),
    CodexCollabAgentToolCallThreadItem value => _DetailActivity(
      icon: Icons.hub_outlined,
      title: 'Agent collaboration · ${value.tool.toJson()}',
      detail: [
        if (value.prompt?.trim().isNotEmpty == true) value.prompt!,
        _jsonMarkdown(value.agentsStates),
      ].join('\n\n'),
      running: value.status == CodexCollabAgentToolCallStatus.inProgress,
    ),
    CodexSubAgentActivityThreadItem value => _DetailActivity(
      icon: Icons.account_tree_outlined,
      title: 'Sub-agent ${value.kind.toJson()}',
      detail: '`${value.agentPath}`\n\n`${value.agentThreadId}`',
    ),
    CodexImageGenerationThreadItem value => _DetailActivity(
      icon: Icons.auto_awesome_outlined,
      title: 'Generated an image',
      detail: [
        if (value.revisedPrompt?.trim().isNotEmpty == true)
          value.revisedPrompt!,
        if (value.savedPath != null) '`${value.savedPath!.value}`',
      ].join('\n\n'),
      running: value.status == 'inProgress',
    ),
    CodexSleepThreadItem value => _DetailActivity(
      icon: Icons.schedule_outlined,
      title: 'Waited ${_duration(value.durationMs)}',
    ),
    _ => _DetailActivity(
      icon: Icons.auto_awesome_outlined,
      title: _itemType(item),
      detail: _jsonMarkdown(item.toJson()),
    ),
  };
}

class _CommandActivity extends StatelessWidget {
  const _CommandActivity({required this.item});

  final CodexCommandExecutionThreadItem item;

  @override
  Widget build(BuildContext context) {
    final suffix = <String>[
      if (item.durationMs != null) 'in ${_duration(item.durationMs!)}',
      if (item.exitCode != null) 'exit ${item.exitCode}',
    ].join(' · ');
    final output = item.aggregatedOutput?.trim() ?? '';
    return _DetailActivity(
      icon: Icons.terminal_rounded,
      title: '${_commandTitle(item)}${suffix.isEmpty ? '' : ' · $suffix'}',
      running: item.status == CodexCommandExecutionStatus.inProgress,
      detail: [
        if (item.cwd.value.trim().isNotEmpty) '`cwd: ${item.cwd.value}`',
        _fenced(
          'shell',
          '\$ ${item.command}${output.isEmpty ? '' : '\n$output'}',
        ),
      ].join('\n\n'),
    );
  }
}

class _FileChangeActivity extends StatelessWidget {
  const _FileChangeActivity({required this.item, required this.cwd});

  final CodexFileChangeThreadItem item;
  final String? cwd;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final count = item.changes.length;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: ValueKey('codex-file-change-${item.id}'),
        initiallyExpanded: false,
        dense: true,
        visualDensity: _activityDensity,
        minTileHeight: _activityTileHeight,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: MotifSpacing.md),
        leading: item.status == CodexPatchApplyStatus.inProgress
            ? SizedBox.square(
                dimension: MotifIconSize.sm,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                ),
              )
            : Icon(
                Icons.edit_outlined,
                size: MotifIconSize.sm,
                color: c.textTertiary,
              ),
        title: Text(
          '${item.status == CodexPatchApplyStatus.inProgress ? 'Editing' : 'Edited'} $count ${count == 1 ? 'file' : 'files'}',
          style: MotifType.subhead.copyWith(color: c.textSecondary),
        ),
        children: [
          _BoundedScrollable(
            key: ValueKey('codex-file-change-scroll-${item.id}'),
            maxHeight: _activityDetailMaxHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final change in item.changes)
                  _FileDiffTile(change: change, cwd: cwd),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileDiffTile extends StatelessWidget {
  const _FileDiffTile({required this.change, required this.cwd});

  final CodexFileUpdateChange change;
  final String? cwd;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final stats = _diffStats(change.diff);
    final path = _pathWithoutCwd(change.path, cwd);
    final verb = switch (change.kind) {
      CodexAddPatchChangeKind() => 'Created',
      CodexDeletePatchChangeKind() => 'Deleted',
      CodexUpdatePatchChangeKind() => 'Edited',
      _ => 'Changed',
    };
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: ValueKey('codex-file-diff-$path'),
        initiallyExpanded: false,
        dense: true,
        visualDensity: _activityDensity,
        minTileHeight: _activityTileHeight,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        leading: Icon(
          Icons.edit_outlined,
          size: MotifIconSize.sm,
          color: c.textTertiary,
        ),
        title: Row(
          children: [
            Text(
              '$verb ',
              style: MotifType.subhead.copyWith(color: c.textSecondary),
            ),
            Flexible(
              child: Text(
                _leaf(path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MotifType.subhead.copyWith(
                  color: c.textSecondary,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
            Text(
              ' +${stats.added}',
              style: MotifType.caption.copyWith(color: c.success),
            ),
            Text(
              ' -${stats.removed}',
              style: MotifType.caption.copyWith(color: c.danger),
            ),
          ],
        ),
        children: [_UnifiedDiff(path: path, diff: change.diff)],
      ),
    );
  }
}

class _UnifiedDiff extends StatelessWidget {
  const _UnifiedDiff({required this.path, required this.diff});

  final String path;
  final String diff;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: c.subtleFill,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(MotifRadius.xs),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: MotifSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MotifType.monoSmall.copyWith(color: c.textSecondary),
                  ),
                ),
                IconButton(
                  tooltip: 'Copy diff',
                  visualDensity: VisualDensity.compact,
                  iconSize: MotifIconSize.sm,
                  onPressed: () => Clipboard.setData(ClipboardData(text: diff)),
                  icon: const Icon(Icons.content_copy_outlined),
                ),
              ],
            ),
          ),
          _BoundedScrollable(
            key: ValueKey('codex-diff-scroll-$path'),
            maxHeight: _diffBodyMaxHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final line in const LineSplitter().convert(diff))
                  ColoredBox(
                    color: line.startsWith('+') && !line.startsWith('+++')
                        ? c.success.withValues(alpha: 0.10)
                        : line.startsWith('-') && !line.startsWith('---')
                        ? c.danger.withValues(alpha: 0.10)
                        : Colors.transparent,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MotifSpacing.sm,
                      ),
                      child: SelectableText(
                        line.isEmpty ? ' ' : line,
                        style: MotifType.monoSmall.copyWith(
                          color: line.startsWith('+') && !line.startsWith('+++')
                              ? c.success
                              : line.startsWith('-') && !line.startsWith('---')
                              ? c.danger
                              : c.textSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageActivity extends StatelessWidget {
  const _ImageActivity({required this.state, required this.item});

  final CodexSessionState state;
  final CodexImageViewThreadItem item;

  @override
  Widget build(BuildContext context) => _DetailActivity(
    icon: Icons.image_outlined,
    title: 'Viewed ${_leaf(item.path.value)}',
    child: FutureBuilder<Uint8List>(
      future: state.readRemoteFile(item.path.value),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const LinearProgressIndicator();
        return Align(
          alignment: Alignment.centerLeft,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(MotifRadius.xs),
            child: Image.memory(
              snapshot.data!,
              width: 240,
              height: 180,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            ),
          ),
        );
      },
    ),
  );
}

class _DetailActivity extends StatelessWidget {
  const _DetailActivity({
    required this.icon,
    required this.title,
    this.detail,
    this.child,
    this.running = false,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? child;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final content =
        child ??
        (detail?.trim().isNotEmpty == true
            ? CodexMarkdown(
                detail!,
                style: MotifType.subhead.copyWith(color: c.textSecondary),
              )
            : null);
    if (content == null) {
      return _ActivityRow(icon: icon, title: title, running: running);
    }
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: false,
        dense: true,
        visualDensity: _activityDensity,
        minTileHeight: _activityTileHeight,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: MotifSpacing.lg),
        leading: running
            ? SizedBox.square(
                dimension: MotifIconSize.sm,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: c.accent,
                ),
              )
            : Icon(icon, size: MotifIconSize.sm, color: c.textTertiary),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: MotifType.subhead.copyWith(color: c.textSecondary),
        ),
        children: [
          _BoundedScrollable(
            key: const ValueKey('codex-activity-detail-scroll'),
            maxHeight: _activityDetailMaxHeight,
            child: content,
          ),
        ],
      ),
    );
  }
}

class _BoundedScrollable extends StatefulWidget {
  const _BoundedScrollable({
    required this.maxHeight,
    required this.child,
    super.key,
  });

  final double maxHeight;
  final Widget child;

  @override
  State<_BoundedScrollable> createState() => _BoundedScrollableState();
}

class _BoundedScrollableState extends State<_BoundedScrollable> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _controller,
          primary: false,
          child: widget.child,
        ),
      ),
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({
    required this.icon,
    required this.title,
    this.running = false,
  });

  final IconData icon;
  final String title;
  final bool running;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          running
              ? SizedBox.square(
                  dimension: MotifIconSize.sm,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.accent,
                  ),
                )
              : Icon(icon, size: MotifIconSize.sm, color: c.textTertiary),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: Text(
              title,
              style: MotifType.subhead.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

String _groupTitle(List<CodexThreadItem> items) {
  final labels = <String>[];
  for (final item in items) {
    final label = switch (item) {
      CodexCommandExecutionThreadItem value =>
        value.status == CodexCommandExecutionStatus.inProgress
            ? 'running a command'
            : 'ran a command',
      CodexFileChangeThreadItem value =>
        value.status == CodexPatchApplyStatus.inProgress
            ? 'editing files'
            : 'edited files',
      CodexWebSearchThreadItem() => 'searched the web',
      CodexImageViewThreadItem() => 'viewed an image',
      CodexMcpToolCallThreadItem() ||
      CodexDynamicToolCallThreadItem() => 'used a tool',
      CodexCollabAgentToolCallThreadItem() ||
      CodexSubAgentActivityThreadItem() => 'coordinated agents',
      CodexImageGenerationThreadItem() => 'generated an image',
      _ => 'worked',
    };
    if (!labels.contains(label)) labels.add(label);
  }
  if (labels.isEmpty) return 'Activity';
  final visible = labels.take(3).toList();
  final sentence = visible.join(', ');
  return '${sentence[0].toUpperCase()}${sentence.substring(1)}${labels.length > visible.length ? ', and more' : ''}';
}

IconData _groupIcon(List<CodexThreadItem> items) {
  if (items.every((item) => item is CodexFileChangeThreadItem)) {
    return Icons.edit_outlined;
  }
  if (items.every((item) => item is CodexCommandExecutionThreadItem)) {
    return Icons.terminal_rounded;
  }
  if (items.every((item) => item is CodexWebSearchThreadItem)) {
    return Icons.search_rounded;
  }
  if (items.every((item) => item is CodexImageViewThreadItem)) {
    return Icons.image_outlined;
  }
  if (items.every(
    (item) =>
        item is CodexMcpToolCallThreadItem ||
        item is CodexDynamicToolCallThreadItem,
  )) {
    return Icons.build_outlined;
  }
  if (items.every(
    (item) =>
        item is CodexCollabAgentToolCallThreadItem ||
        item is CodexSubAgentActivityThreadItem,
  )) {
    return Icons.hub_outlined;
  }
  if (items.every((item) => item is CodexImageGenerationThreadItem)) {
    return Icons.auto_awesome_outlined;
  }
  if (items.any((item) => item is CodexFileChangeThreadItem) ||
      items.any((item) => item is CodexCommandExecutionThreadItem)) {
    return Icons.construction_outlined;
  }
  return Icons.more_horiz_rounded;
}

bool _isRunning(CodexThreadItem item) => switch (item) {
  CodexCommandExecutionThreadItem value =>
    value.status == CodexCommandExecutionStatus.inProgress,
  CodexFileChangeThreadItem value =>
    value.status == CodexPatchApplyStatus.inProgress,
  CodexMcpToolCallThreadItem value =>
    value.status == CodexMcpToolCallStatus.inProgress,
  CodexDynamicToolCallThreadItem value =>
    value.status == CodexDynamicToolCallStatus.inProgress,
  CodexCollabAgentToolCallThreadItem value =>
    value.status == CodexCollabAgentToolCallStatus.inProgress,
  CodexImageGenerationThreadItem value => value.status == 'inProgress',
  _ => false,
};

String? _reasoningText(CodexReasoningThreadItem? reasoning) {
  if (reasoning == null) return null;
  for (final value in [...?reasoning.summary, ...?reasoning.content].reversed) {
    if (value.trim().isNotEmpty) return value;
  }
  return null;
}

String _commandTitle(CodexCommandExecutionThreadItem value) {
  final first = value.command.trim().split(RegExp(r'\s+')).firstOrNull;
  return value.status == CodexCommandExecutionStatus.inProgress
      ? 'Running ${first ?? 'command'}'
      : 'Ran ${first ?? 'command'}';
}

String _duration(int milliseconds) {
  if (milliseconds < 1000) return '${milliseconds}ms';
  final seconds = milliseconds / 1000;
  return seconds < 60
      ? '${seconds.toStringAsFixed(seconds < 10 ? 1 : 0)}s'
      : '${(seconds / 60).toStringAsFixed(1)}m';
}

({int added, int removed}) _diffStats(String diff) {
  var added = 0;
  var removed = 0;
  for (final line in const LineSplitter().convert(diff)) {
    if (line.startsWith('+') && !line.startsWith('+++')) added++;
    if (line.startsWith('-') && !line.startsWith('---')) removed++;
  }
  return (added: added, removed: removed);
}

String _jsonMarkdown(Object? value) =>
    _fenced('json', const JsonEncoder.withIndent('  ').convert(value));

String _fenced(String language, String value) =>
    '```$language\n${value.replaceAll('```', r'\`\`\`')}\n```';

String _leaf(String path) =>
    path
        .replaceAll('\\', '/')
        .split('/')
        .where((part) => part.isNotEmpty)
        .lastOrNull ??
    path;

String _pathWithoutCwd(String path, String? cwd) {
  final normalizedPath = path.trim().replaceAll('\\', '/');
  var normalizedCwd = cwd?.trim().replaceAll('\\', '/') ?? '';
  while (normalizedCwd.length > 1 && normalizedCwd.endsWith('/')) {
    normalizedCwd = normalizedCwd.substring(0, normalizedCwd.length - 1);
  }
  if (normalizedCwd.isEmpty) return normalizedPath;

  final windowsPath = RegExp(r'^[A-Za-z]:/').hasMatch(normalizedPath);
  final pathForComparison = windowsPath
      ? normalizedPath.toLowerCase()
      : normalizedPath;
  final cwdForComparison = windowsPath
      ? normalizedCwd.toLowerCase()
      : normalizedCwd;
  if (pathForComparison == cwdForComparison) return '.';
  final prefix = '$cwdForComparison/';
  if (pathForComparison.startsWith(prefix)) {
    return normalizedPath.substring(normalizedCwd.length + 1);
  }
  return normalizedPath;
}

String _itemType(CodexThreadItem item) {
  final json = item.toJson();
  return json is Map<String, Object?>
      ? json['type']?.toString() ?? item.runtimeType.toString()
      : item.runtimeType.toString();
}
