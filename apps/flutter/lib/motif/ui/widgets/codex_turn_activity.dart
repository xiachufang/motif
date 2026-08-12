import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/services.dart';

import '../../codex/codex_navigation.dart';
import '../../codex/codex_service_state.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../../models/resource_documents.dart';
import '../theme/motif_theme.dart';
import 'codex_markdown.dart';
import 'observation_select.dart';

part 'codex_turn_activity.g.dart';

const _activityDensity = VisualDensity(vertical: -4);
const _activityTileHeight = 32.0;
const _activityGroupMaxHeight = 360.0;
const _activityDetailMaxHeight = 300.0;
const _diffBodyMaxHeight = 280.0;
const _activityTitleGap = 4.0;

/// One chronological group of non-text items located between two text items.
/// The group is collapsed by default; expanding it never changes or merges the
/// order of the original protocol items.
class CodexTurnActivityGroup extends StatelessWidget {
  const CodexTurnActivityGroup({
    required this.state,
    required this.items,
    this.showLatestItemTitle = false,
    this.processingLatestItem = false,
    this.boundedDetails = true,
    this.onOpenFile,
    this.onOpenImage,
    this.onOpenTurnDiff,
    super.key,
  });

  final CodexConversationState state;
  final List<CodexThreadItem> items;
  final bool showLatestItemTitle;
  final bool processingLatestItem;
  final bool boundedDetails;
  final CodexOpenFile? onOpenFile;
  final CodexOpenImage? onOpenImage;
  final CodexOpenTurnDiff? onOpenTurnDiff;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final running = items.any(_isRunning);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: _InlineExpansionTile(
        initiallyExpanded: false,
        childrenPadding: const EdgeInsets.only(left: MotifSpacing.md),
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
        title: CodexActivityTitle(
          state: state,
          item: items.last,
          groupTitle: _groupTitle(items),
          showLatestItemTitle: showLatestItemTitle,
          processingLatestItem: processingLatestItem,
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
                    _ActivityItem(
                      state: state,
                      item: item,
                      onOpenFile: onOpenFile,
                      onOpenImage: onOpenImage,
                      onOpenTurnDiff: onOpenTurnDiff,
                    ),
                ],
              ),
            )
          else
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final item in items)
                  _ActivityItem(
                    state: state,
                    item: item,
                    onOpenFile: onOpenFile,
                    onOpenImage: onOpenImage,
                    onOpenTurnDiff: onOpenTurnDiff,
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class CodexActivityTitle extends StatelessWidget {
  const CodexActivityTitle({
    required this.state,
    required this.item,
    required this.groupTitle,
    required this.showLatestItemTitle,
    required this.processingLatestItem,
    super.key,
  });

  final CodexConversationState state;
  final CodexThreadItem item;
  final String groupTitle;
  final bool showLatestItemTitle;
  final bool processingLatestItem;

  @override
  Widget build(BuildContext context) {
    return ObservationSelect<CodexThreadItem>(
      // Ensure the title is attached to the stable item-scoped model even
      // when the protocol first inserts an empty reasoning shell. Subsequent
      // summaryTextDelta/textDelta notifications update this same model.
      selector: () => state.itemViewModel(item).item,
      builder: (context, liveItem, _) {
        final c = context.motif;
        final style = MotifType.subhead.copyWith(color: c.textSecondary);
        final latestTitle = _activityTitle(liveItem);
        if (processingLatestItem && latestTitle.isNotEmpty) {
          return _ProcessingSweepText(latestTitle, style: style);
        }
        return Text(
          showLatestItemTitle ? latestTitle : groupTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style,
        );
      },
    );
  }
}

class _ProcessingSweepText extends StatefulWidget {
  const _ProcessingSweepText(this.text, {required this.style});

  final String text;
  final TextStyle style;

  @override
  State<_ProcessingSweepText> createState() => _ProcessingSweepTextState();
}

class _ProcessingSweepTextState extends State<_ProcessingSweepText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    if (MediaQuery.disableAnimationsOf(context)) {
      return Text(
        widget.text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: widget.style,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: RepaintBoundary(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) => ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (bounds) {
                  final bandWidth = bounds.width.clamp(72.0, 140.0).toDouble();
                  final left =
                      -bandWidth +
                      _controller.value * (bounds.width + bandWidth);
                  final base = widget.style.color ?? c.textSecondary;
                  final highlight = Color.lerp(base, Colors.white, 0.78)!;
                  return LinearGradient(
                    colors: [base, highlight, base],
                    stops: const [0, 0.5, 1],
                    tileMode: TileMode.clamp,
                  ).createShader(
                    Rect.fromLTWH(left, 0, bandWidth, bounds.height),
                  );
                },
                child: child,
              ),
              child: Text(
                widget.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: widget.style,
              ),
            ),
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
    this.onOpenDiff,
    super.key,
  });

  final String turnId;
  final List<CodexFileChangeThreadItem> items;
  final String? cwd;
  final CodexOpenTurnDiff? onOpenDiff;

  @override
  State<CodexTurnDiffSummary> createState() => _CodexTurnDiffSummaryState();
}

class _CodexTurnDiffSummaryState extends State<CodexTurnDiffSummary> {
  static const _collapsedFileCount = 3;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final document = codexTurnDiffDocument(widget.items, widget.cwd);
    final files = document.files;
    if (files.isEmpty) return const SizedBox.shrink();
    final c = context.motif;
    final totalAdded = files.fold(0, (total, file) => total + file.additions);
    final totalRemoved = files.fold(0, (total, file) => total + file.deletions);
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
          InkWell(
            key: ValueKey('codex-turn-diff-open-${widget.turnId}'),
            onTap: widget.onOpenDiff == null
                ? null
                : () => widget.onOpenDiff!(document),
            child: Padding(
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
          ),
          Divider(height: 1, color: c.border),
          for (final file in visibleFiles)
            _TurnDiffFileRow(
              file: file,
              onOpen: widget.onOpenDiff == null
                  ? null
                  : () => widget.onOpenDiff!(document, initialPath: file.path),
            ),
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
  const _TurnDiffFileRow({required this.file, required this.onOpen});

  final DiffDocumentFile file;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return InkWell(
      key: ValueKey('codex-turn-diff-file-${file.path}'),
      onTap: onOpen,
      child: Padding(
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
            _DiffStats(added: file.additions, removed: file.deletions),
          ],
        ),
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

DiffDocument codexTurnDiffDocument(
  Iterable<CodexFileChangeThreadItem> items,
  String? cwd,
) => DiffDocument.fromFilePatches([
  for (final item in items)
    for (final change in item.changes)
      FilePatch(
        path: _pathWithoutCwd(change.path, cwd),
        sourcePath: change.path,
        patch: change.diff,
      ),
]);

class _ActivityItem extends StatelessWidget {
  const _ActivityItem({
    required this.state,
    required this.item,
    required this.onOpenFile,
    required this.onOpenImage,
    required this.onOpenTurnDiff,
  });

  final CodexConversationState state;
  final CodexThreadItem item;
  final CodexOpenFile? onOpenFile;
  final CodexOpenImage? onOpenImage;
  final CodexOpenTurnDiff? onOpenTurnDiff;

  @override
  Widget build(BuildContext context) => switch (item) {
    CodexReasoningThreadItem() => const SizedBox.shrink(),
    CodexCommandExecutionThreadItem value => _CommandActivity(
      key: ValueKey('codex-command-activity-${value.id}'),
      state: state,
      item: value,
    ),
    CodexFileChangeThreadItem value => _FileChangeActivity(
      item: value,
      cwd: state.selectedThread?.cwd.value,
      onOpenFile: onOpenFile,
      onOpenTurnDiff: onOpenTurnDiff,
    ),
    CodexWebSearchThreadItem value => _DetailActivity(
      icon: Icons.search,
      title: 'Searched for ${value.query}',
      detail: value.results?.isNotEmpty == true
          ? _jsonMarkdown(value.results)
          : null,
    ),
    CodexImageViewThreadItem value => _ImageActivity(
      state: state,
      item: value,
      onOpenImage: onOpenImage,
    ),
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
    CodexImageGenerationThreadItem value => _ImageGenerationActivity(
      state: state,
      item: value,
      onOpenImage: onOpenImage,
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

@ObservationWidget()
class _CommandActivity extends _$_CommandActivity {
  const _CommandActivity({required this.state, required this.item, super.key});

  final CodexConversationState state;
  final CodexCommandExecutionThreadItem item;

  @override
  Widget build(BuildContext context) {
    final model = state.observedItemViewModel(item);
    final live = model?.item;
    return _buildCommand(
      context,
      live is CodexCommandExecutionThreadItem ? live : item,
      streaming: model?.streaming ?? false,
    );
  }

  Widget _buildCommand(
    BuildContext context,
    CodexCommandExecutionThreadItem item, {
    required bool streaming,
  }) {
    final output = item.aggregatedOutput?.trim() ?? '';
    final detail = [
      if (item.cwd.value.trim().isNotEmpty) '`cwd: ${item.cwd.value}`',
      _fenced(
        'shell',
        '\$ ${item.command}${output.isEmpty ? '' : '\n$output'}',
      ),
    ].join('\n\n');
    return _DetailActivity(
      icon: Icons.terminal_rounded,
      title: _commandActivityTitle(item),
      running: item.status == CodexCommandExecutionStatus.inProgress,
      detail: streaming ? null : detail,
      child: streaming
          ? CodexStreamingText(
              detail,
              style: MotifType.monoSmall.copyWith(
                color: context.motif.textSecondary,
              ),
            )
          : null,
    );
  }
}

class _FileChangeActivity extends StatelessWidget {
  const _FileChangeActivity({
    required this.item,
    required this.cwd,
    required this.onOpenFile,
    required this.onOpenTurnDiff,
  });

  final CodexFileChangeThreadItem item;
  final String? cwd;
  final CodexOpenFile? onOpenFile;
  final CodexOpenTurnDiff? onOpenTurnDiff;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final count = item.changes.length;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: _InlineExpansionTile(
        key: ValueKey('codex-file-change-${item.id}'),
        initiallyExpanded: false,
        childrenPadding: const EdgeInsets.only(left: MotifSpacing.sm),
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
                  _FileDiffTile(
                    change: change,
                    cwd: cwd,
                    onOpenFile: onOpenFile,
                    onOpenTurnDiff: onOpenTurnDiff,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FileDiffTile extends StatelessWidget {
  const _FileDiffTile({
    required this.change,
    required this.cwd,
    required this.onOpenFile,
    required this.onOpenTurnDiff,
  });

  final CodexFileUpdateChange change;
  final String? cwd;
  final CodexOpenFile? onOpenFile;
  final CodexOpenTurnDiff? onOpenTurnDiff;

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
      child: _InlineExpansionTile(
        key: ValueKey('codex-file-diff-$path'),
        initiallyExpanded: false,
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
                style: MotifType.subhead.copyWith(color: c.textSecondary),
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
        action: onOpenFile == null && onOpenTurnDiff == null
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (onOpenFile != null)
                    IconButton(
                      key: ValueKey('codex-open-file-$path'),
                      tooltip: 'View file',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: MotifControlSize.sm,
                        height: MotifControlSize.sm,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: MotifIconSize.sm,
                      onPressed: () => onOpenFile!(change.path),
                      icon: const Icon(Icons.description_outlined),
                    ),
                  if (onOpenTurnDiff != null)
                    IconButton(
                      key: ValueKey('codex-open-diff-$path'),
                      tooltip: 'View turn diff',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: MotifControlSize.sm,
                        height: MotifControlSize.sm,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: MotifIconSize.sm,
                      onPressed: () => onOpenTurnDiff!(
                        DiffDocument.fromFilePatches([
                          FilePatch(
                            path: path,
                            sourcePath: change.path,
                            patch: change.diff,
                          ),
                        ]),
                        initialPath: path,
                      ),
                      icon: const Icon(Icons.difference_outlined),
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
                      child: _SelectionAwareText(
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

class _SelectionAwareText extends StatelessWidget {
  const _SelectionAwareText(this.data, {required this.style});

  final String data;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    if (SelectionContainer.maybeOf(context) != null) {
      return Text(data, style: style);
    }
    return SelectableText(data, style: style);
  }
}

class _ImageActivity extends StatelessWidget {
  const _ImageActivity({
    required this.state,
    required this.item,
    required this.onOpenImage,
  });

  final CodexConversationState state;
  final CodexImageViewThreadItem item;
  final CodexOpenImage? onOpenImage;

  @override
  Widget build(BuildContext context) => _DetailActivity(
    icon: Icons.image_outlined,
    title: 'Viewed ${_leaf(item.path.value)}',
    action: onOpenImage == null
        ? null
        : IconButton(
            key: ValueKey('codex-open-image-${item.path.value}'),
            tooltip: 'View image',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints.tightFor(
              width: MotifControlSize.sm,
              height: MotifControlSize.sm,
            ),
            padding: EdgeInsets.zero,
            iconSize: MotifIconSize.sm,
            onPressed: () => onOpenImage!(item.path.value),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
    child: FutureBuilder<Uint8List>(
      future: state.readRemoteFile(item.path.value),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const LinearProgressIndicator();
        return Align(
          alignment: Alignment.centerLeft,
          child: GestureDetector(
            key: ValueKey('codex-image-thumbnail-${item.path.value}'),
            onTap: onOpenImage == null
                ? null
                : () => onOpenImage!(item.path.value),
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
          ),
        );
      },
    ),
  );
}

class _ImageGenerationActivity extends StatelessWidget {
  const _ImageGenerationActivity({
    required this.state,
    required this.item,
    required this.onOpenImage,
  });

  final CodexConversationState state;
  final CodexImageGenerationThreadItem item;
  final CodexOpenImage? onOpenImage;

  @override
  Widget build(BuildContext context) {
    final path = item.savedPath?.value;
    return _DetailActivity(
      icon: Icons.auto_awesome_outlined,
      title: 'Generated an image',
      detail: item.revisedPrompt?.trim().isNotEmpty == true
          ? item.revisedPrompt
          : null,
      running: item.status == 'inProgress',
      action: path == null || onOpenImage == null
          ? null
          : IconButton(
              key: ValueKey('codex-open-generated-image-$path'),
              tooltip: 'View image',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(
                width: MotifControlSize.sm,
                height: MotifControlSize.sm,
              ),
              padding: EdgeInsets.zero,
              iconSize: MotifIconSize.sm,
              onPressed: () => onOpenImage!(path),
              icon: const Icon(Icons.open_in_new_rounded),
            ),
      child: path == null
          ? null
          : FutureBuilder<Uint8List>(
              future: state.readRemoteFile(path),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const LinearProgressIndicator();
                return Align(
                  alignment: Alignment.centerLeft,
                  child: GestureDetector(
                    key: ValueKey('codex-generated-image-thumbnail-$path'),
                    onTap: onOpenImage == null
                        ? null
                        : () => onOpenImage!(path),
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
                  ),
                );
              },
            ),
    );
  }
}

class _DetailActivity extends StatelessWidget {
  const _DetailActivity({
    required this.icon,
    required this.title,
    this.detail,
    this.child,
    this.running = false,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final Widget? child;
  final bool running;
  final Widget? action;

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
      child: _InlineExpansionTile(
        initiallyExpanded: false,
        childrenPadding: const EdgeInsets.only(left: MotifSpacing.md),
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
        action: action,
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

/// Keeps the disclosure control beside the title instead of pinning it to the
/// far edge of the available row. Activity rows are intentionally compact, so
/// their leading glyph also uses a smaller gap than a regular list tile.
class _InlineExpansionTile extends StatefulWidget {
  const _InlineExpansionTile({
    required this.leading,
    required this.title,
    required this.children,
    required this.childrenPadding,
    this.initiallyExpanded = false,
    this.action,
    super.key,
  });

  final Widget leading;
  final Widget title;
  final List<Widget> children;
  final EdgeInsetsGeometry childrenPadding;
  final bool initiallyExpanded;
  final Widget? action;

  @override
  State<_InlineExpansionTile> createState() => _InlineExpansionTileState();
}

class _InlineExpansionTileState extends State<_InlineExpansionTile> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        dividerColor: Colors.transparent,
        listTileTheme: theme.listTileTheme.copyWith(
          horizontalTitleGap: _activityTitleGap,
          minLeadingWidth: MotifIconSize.sm,
          minVerticalPadding: 0,
        ),
      ),
      child: ExpansionTile(
        initiallyExpanded: widget.initiallyExpanded,
        onExpansionChanged: (expanded) => setState(() => _expanded = expanded),
        dense: true,
        visualDensity: _activityDensity,
        minTileHeight: _activityTileHeight,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        tilePadding: EdgeInsets.zero,
        childrenPadding: widget.childrenPadding,
        leading: widget.leading,
        trailing: const SizedBox.shrink(),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: widget.title),
            if (widget.action != null) ...[
              const SizedBox(width: MotifSpacing.xs),
              widget.action!,
            ],
            const SizedBox(width: MotifSpacing.xs),
            Icon(
              _expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: MotifIconSize.sm,
            ),
          ],
        ),
        children: widget.children,
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

String _activityTitle(CodexThreadItem item) => switch (item) {
  CodexReasoningThreadItem value => _reasoningText(value) ?? '',
  CodexCommandExecutionThreadItem value => _commandActivityTitle(value),
  CodexFileChangeThreadItem value =>
    '${value.status == CodexPatchApplyStatus.inProgress ? 'Editing' : 'Edited'} '
        '${value.changes.length} ${value.changes.length == 1 ? 'file' : 'files'}',
  CodexWebSearchThreadItem value => 'Searched for ${value.query}',
  CodexImageViewThreadItem value => 'Viewed ${_leaf(value.path.value)}',
  CodexMcpToolCallThreadItem value => 'Used ${value.server} · ${value.tool}',
  CodexDynamicToolCallThreadItem value =>
    'Used ${value.namespace == null ? '' : '${value.namespace} · '}${value.tool}',
  CodexCollabAgentToolCallThreadItem value =>
    'Agent collaboration · ${value.tool.toJson()}',
  CodexSubAgentActivityThreadItem value => 'Sub-agent ${value.kind.toJson()}',
  CodexImageGenerationThreadItem() => 'Generated an image',
  CodexSleepThreadItem value => 'Waited ${_duration(value.durationMs)}',
  _ => _itemType(item),
};

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

String _commandActivityTitle(CodexCommandExecutionThreadItem value) {
  final suffix = <String>[
    if (value.durationMs != null) 'in ${_duration(value.durationMs!)}',
    if (value.exitCode != null) 'exit ${value.exitCode}',
  ].join(' · ');
  return '${_commandTitle(value)}${suffix.isEmpty ? '' : ' · $suffix'}';
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
