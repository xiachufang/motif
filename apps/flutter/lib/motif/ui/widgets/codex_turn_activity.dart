import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/services.dart';

import '../../codex/codex_navigation.dart';
import '../../codex/codex_service_state.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../../models/resource_documents.dart';
import '../theme/motif_theme.dart';
import 'codex_markdown.dart';
import 'codex_motion.dart';
import 'diff_text_view.dart';
import 'observation_select.dart';

part 'codex_turn_activity.g.dart';

const _activityDensity = VisualDensity(vertical: -4);
const _activityTileHeight = 32.0;
const _activityGroupMaxHeight = 360.0;
const _activityDetailMaxHeight = 300.0;
const _inlineDiffMaxHeight = _activityDetailMaxHeight - MotifSpacing.md;
const _inlineDiffHeaderHeight = MotifControlSize.md;
const _inlineDiffVerticalBorder = 2.0;
const _diffBodyMaxHeight =
    _inlineDiffMaxHeight - _inlineDiffHeaderHeight - _inlineDiffVerticalBorder;
const _activityTitleGap = 4.0;
const _activityTitleMaxLines = 1;
const _processingSweepDuration = Duration(milliseconds: 1600);
const _processingSweepPause = Duration(milliseconds: 450);
final _processingSweepPeriod = _processingSweepDuration + _processingSweepPause;

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
    final groupTitle = _groupTitle(items);
    final fallbackTitle = showLatestItemTitle
        ? _latestNonReasoningTitle(items) ?? groupTitle
        : groupTitle;
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
          groupTitle: fallbackTitle,
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
        final latestTitle = _latestActivityTitle(liveItem);
        final title = showLatestItemTitle && latestTitle.isNotEmpty
            ? latestTitle
            : groupTitle;
        return Tooltip(
          message: title,
          child: processingLatestItem
              ? CodexProcessingSweepText(title, style: style)
              : Text(
                  title,
                  maxLines: _activityTitleMaxLines,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
        );
      },
    );
  }
}

class CodexProcessingSweepText extends StatefulWidget {
  const CodexProcessingSweepText(this.text, {required this.style, super.key});

  final String text;
  final TextStyle style;

  @override
  State<CodexProcessingSweepText> createState() =>
      _CodexProcessingSweepTextState();
}

class _CodexProcessingSweepTextState extends State<CodexProcessingSweepText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _processingSweepPeriod,
  )..repeat();
  late final Animation<double> _position = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 0.0,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeInOutCubic)),
      weight: _processingSweepDuration.inMilliseconds.toDouble(),
    ),
    TweenSequenceItem(
      tween: ConstantTween(1.0),
      weight: _processingSweepPause.inMilliseconds.toDouble(),
    ),
  ]).animate(_controller);

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
        maxLines: _activityTitleMaxLines,
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
                key: const ValueKey('codex-processing-sweep'),
                blendMode: BlendMode.srcIn,
                shaderCallback: (bounds) {
                  final bandWidth = bounds.width.clamp(72.0, 140.0).toDouble();
                  final left =
                      -bandWidth + _position.value * (bounds.width + bandWidth);
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
                maxLines: _activityTitleMaxLines,
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
    final visibleFiles = files
        .take(_collapsedFileCount)
        .toList(growable: false);
    final expandableFiles = files
        .skip(_collapsedFileCount)
        .toList(growable: false);

    return Container(
      key: ValueKey('codex-turn-diff-${widget.turnId}'),
      margin: const EdgeInsets.only(
        top: MotifSpacing.sm,
        bottom: MotifSpacing.lg,
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
          CodexMotionExpansion(
            expanded: _expanded,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final file in expandableFiles)
                  _TurnDiffFileRow(
                    file: file,
                    onOpen: widget.onOpenDiff == null
                        ? null
                        : () => widget.onOpenDiff!(
                            document,
                            initialPath: file.path,
                          ),
                  ),
              ],
            ),
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
                    CodexMotionSwitcher(
                      offset: const Offset(0, 0.12),
                      child: Text(
                        _expanded
                            ? 'Collapse files'
                            : 'Show $hiddenCount more ${hiddenCount == 1 ? 'file' : 'files'}',
                        key: ValueKey(_expanded ? 'collapse' : 'expand'),
                        style: MotifType.subhead.copyWith(color: c.textPrimary),
                      ),
                    ),
                    const SizedBox(width: MotifSpacing.sm),
                    AnimatedRotation(
                      turns: _expanded ? 0.5 : 0,
                      duration: codexExpansionDuration(context),
                      curve: codexExpansionCurve(context),
                      child: Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: MotifIconSize.md,
                        color: c.textSecondary,
                      ),
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
        '\$ ${_commandDisplayText(item)}${output.isEmpty ? '' : '\n$output'}',
      ),
    ].join('\n\n');
    return _DetailActivity(
      icon: Icons.terminal_rounded,
      title: _commandActivityTitle(item),
      detail: streaming ? null : detail,
      child: streaming
          ? CodexStreamingMarkdown(
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
          _fileChangeActivityTitle(item),
          maxLines: _activityTitleMaxLines,
          overflow: TextOverflow.ellipsis,
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
    final document = DiffDocument.fromFilePatches([
      FilePatch(path: path, patch: diff),
    ]);
    final lines = document.files.firstOrNull?.lines ?? const <String>[];
    return ConstrainedBox(
      key: ValueKey('codex-inline-diff-$path'),
      constraints: const BoxConstraints(maxHeight: _inlineDiffMaxHeight),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: c.subtleFill,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(MotifRadius.xs),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: _inlineDiffHeaderHeight,
              child: Padding(
                padding: const EdgeInsets.only(left: MotifSpacing.md),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: MotifType.monoSmall.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy diff',
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints.tightFor(
                        width: MotifControlSize.sm,
                        height: MotifControlSize.sm,
                      ),
                      padding: EdgeInsets.zero,
                      iconSize: MotifIconSize.sm,
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: diff)),
                      icon: const Icon(Icons.content_copy_outlined),
                    ),
                    const SizedBox(width: MotifSpacing.xs),
                  ],
                ),
              ),
            ),
            _BoundedScrollable(
              key: ValueKey('codex-diff-scroll-$path'),
              maxHeight: _diffBodyMaxHeight,
              child: DiffTextView(lines: lines),
            ),
          ],
        ),
      ),
    );
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
          maxLines: _activityTitleMaxLines,
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
    final c = context.motif;
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
        iconColor: c.textSecondary,
        collapsedIconColor: c.textSecondary,
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
              IconButtonTheme(
                data: IconButtonThemeData(
                  style: context.iconButtonStyle(
                    foregroundColor: c.textSecondary,
                  ),
                ),
                child: widget.action!,
              ),
            ],
            const SizedBox(width: MotifSpacing.xs),
            Icon(
              _expanded
                  ? Icons.keyboard_arrow_up_rounded
                  : Icons.keyboard_arrow_down_rounded,
              size: MotifIconSize.sm,
              color: c.textSecondary,
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
              maxLines: _activityTitleMaxLines,
              overflow: TextOverflow.ellipsis,
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
      CodexCommandExecutionThreadItem value => _commandGroupLabel(value),
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
  CodexFileChangeThreadItem value => _fileChangeActivityTitle(value),
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

String _latestActivityTitle(CodexThreadItem item) => switch (item) {
  CodexCommandExecutionThreadItem value => _fullCommandTitle(value),
  CodexFileChangeThreadItem value => _fullFileChangeTitle(value),
  CodexWebSearchThreadItem value => 'Searched the web for ${value.query}',
  CodexImageViewThreadItem value => 'Viewed image ${value.path.value}',
  CodexMcpToolCallThreadItem value => _mcpToolProgressTitle(value),
  CodexDynamicToolCallThreadItem value => _dynamicToolProgressTitle(value),
  CodexCollabAgentToolCallThreadItem value => _agentToolProgressTitle(value),
  CodexSubAgentActivityThreadItem value =>
    'Sub-agent ${value.kind.toJson()} · ${value.agentPath}',
  CodexImageGenerationThreadItem value => _imageGenerationProgressTitle(value),
  _ => _activityTitle(item),
};

String _fullFileChangeTitle(CodexFileChangeThreadItem value) {
  final verb = value.status == CodexPatchApplyStatus.inProgress
      ? 'Editing'
      : 'Edited';
  final paths = <String>[];
  for (final change in value.changes) {
    final path = change.path.trim();
    if (path.isNotEmpty && !paths.contains(path)) paths.add(path);
  }
  return paths.isEmpty ? '$verb files' : '$verb ${paths.join(', ')}';
}

String _mcpToolProgressTitle(CodexMcpToolCallThreadItem value) {
  final verb = switch (value.status) {
    CodexMcpToolCallStatus.inProgress => 'Using',
    CodexMcpToolCallStatus.completed => 'Used',
    CodexMcpToolCallStatus.failed => 'Tool failed',
  };
  return _withActivityDetail(
    '$verb ${value.server} · ${value.tool}',
    _inlineActivityValue(value.arguments),
  );
}

String _dynamicToolProgressTitle(CodexDynamicToolCallThreadItem value) {
  final verb = switch (value.status) {
    CodexDynamicToolCallStatus.inProgress => 'Using',
    CodexDynamicToolCallStatus.completed => 'Used',
    CodexDynamicToolCallStatus.failed => 'Tool failed',
  };
  final name =
      '${value.namespace == null ? '' : '${value.namespace} · '}${value.tool}';
  return _withActivityDetail(
    '$verb $name',
    _inlineActivityValue(value.arguments),
  );
}

String _agentToolProgressTitle(CodexCollabAgentToolCallThreadItem value) {
  final verb = switch (value.tool) {
    CodexCollabAgentTool.spawnAgent => 'Starting agent',
    CodexCollabAgentTool.sendInput => 'Sending input to agent',
    CodexCollabAgentTool.resumeAgent => 'Resuming agent',
    CodexCollabAgentTool.wait => 'Waiting for agents',
    CodexCollabAgentTool.closeAgent => 'Closing agent',
  };
  return _withActivityDetail(verb, value.prompt?.trim() ?? '');
}

String _imageGenerationProgressTitle(CodexImageGenerationThreadItem value) {
  final verb = value.status == 'inProgress'
      ? 'Generating an image'
      : 'Generated an image';
  final prompt = value.revisedPrompt?.trim() ?? '';
  if (prompt.isNotEmpty) return _withActivityDetail(verb, prompt);
  final path = value.savedPath?.value.trim() ?? '';
  return _withActivityDetail(verb, path);
}

String _withActivityDetail(String title, String detail) =>
    detail.isEmpty ? title : '$title — $detail';

String _inlineActivityValue(Object? value) {
  if (value == null) return '';
  if (value is String) return value.trim();
  if (value is Map && value.isEmpty || value is List && value.isEmpty) {
    return '';
  }
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    return '$value';
  }
}

String? _latestNonReasoningTitle(List<CodexThreadItem> items) {
  for (final item in items.reversed) {
    if (item is CodexReasoningThreadItem) continue;
    final title = _latestActivityTitle(item);
    if (title.trim().isNotEmpty) return title;
  }
  return null;
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

String _fullCommandTitle(CodexCommandExecutionThreadItem value) {
  final command = _commandTitleText(value);
  final verb = value.status == CodexCommandExecutionStatus.inProgress
      ? 'Running'
      : 'Ran';
  return command.isEmpty ? '$verb command' : '$verb $command';
}

String _commandTitleText(CodexCommandExecutionThreadItem value) {
  final command = _commandDisplayText(
    value,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  return _shortenShellExecutablePaths(command);
}

String _commandDisplayText(CodexCommandExecutionThreadItem value) {
  final command = _unwrapShellCommand(value.command).trim();
  if (command.isNotEmpty) return command;
  return value.commandActions
          .map(_commandActionText)
          .where((candidate) => candidate.trim().isNotEmpty)
          .firstOrNull
          ?.trim() ??
      '';
}

String _commandGroupLabel(CodexCommandExecutionThreadItem value) {
  final running = value.status == CodexCommandExecutionStatus.inProgress;
  return switch (_commandActivityKind(value)) {
    _CommandActivityKind.read => running ? 'reading files' : 'read files',
    _CommandActivityKind.listFiles =>
      running ? 'listing files' : 'listed files',
    _CommandActivityKind.search => running ? 'searching code' : 'searched code',
    _CommandActivityKind.test => running ? 'running tests' : 'ran tests',
    _CommandActivityKind.build =>
      running ? 'building the project' : 'built the project',
    _CommandActivityKind.format =>
      running ? 'formatting code' : 'formatted code',
    _CommandActivityKind.commit =>
      running ? 'committing changes' : 'committed changes',
    _CommandActivityKind.generic =>
      running ? 'running a command' : 'ran a command',
  };
}

enum _CommandActivityKind {
  read,
  listFiles,
  search,
  test,
  build,
  format,
  commit,
  generic,
}

_CommandActivityKind _commandActivityKind(
  CodexCommandExecutionThreadItem value,
) {
  for (final action in value.commandActions) {
    switch (action) {
      case CodexReadCommandAction():
        return _CommandActivityKind.read;
      case CodexListFilesCommandAction():
        return _CommandActivityKind.listFiles;
      case CodexSearchCommandAction():
        return _CommandActivityKind.search;
      case CodexUnknownCommandAction() || CodexCommandActionUnknown():
        break;
    }
  }

  final command =
      value.commandActions
          .map(_commandActionText)
          .where((candidate) => candidate.trim().isNotEmpty)
          .firstOrNull ??
      _unwrapShellCommand(value.command);
  final normalized = command.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (_matchesCommand(normalized, r'(?:\S*/)?git\s+commit(?:\s|$)')) {
    return _CommandActivityKind.commit;
  }
  if (_matchesCommand(
    normalized,
    r'(?:(?:\S*/)?flutter\s+test|(?:\S*/)?dart\s+test|(?:\S*/)?cargo\s+test|(?:\S*/)?go\s+test|(?:\S*/)?swift\s+test|(?:\S*/)?dotnet\s+test|(?:\S*/)?(?:pytest|jest|vitest|mocha|rspec|phpunit))(?:\s|$)',
  )) {
    return _CommandActivityKind.test;
  }
  if (_matchesCommand(
    normalized,
    r'(?:(?:\S*/)?flutter\s+build|(?:\S*/)?dart\s+compile|(?:\S*/)?cargo\s+(?:build|check)|(?:\S*/)?go\s+build|(?:\S*/)?swift\s+build|(?:\S*/)?dotnet\s+build|(?:\S*/)?(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?build)(?:\s|$)',
  )) {
    return _CommandActivityKind.build;
  }
  if (_matchesCommand(
    normalized,
    r'(?:(?:\S*/)?dart\s+format|(?:\S*/)?ruff\s+format|(?:\S*/)?(?:prettier|black|rustfmt|gofmt|clang-format))(?:\s|$)',
  )) {
    return _CommandActivityKind.format;
  }
  return _CommandActivityKind.generic;
}

bool _matchesCommand(String command, String commandPattern) => RegExp(
  '(?:^|(?:&&|\\|\\||;)\\s*)$commandPattern',
  caseSensitive: false,
).hasMatch(command);

String _commandActivityTitle(CodexCommandExecutionThreadItem value) =>
    _fullCommandTitle(value);

String _fileChangeActivityTitle(CodexFileChangeThreadItem value) {
  final verb = value.status == CodexPatchApplyStatus.inProgress
      ? 'Editing'
      : 'Edited';
  final names = <String>[];
  for (final change in value.changes) {
    final name = _leaf(change.path);
    if (name.isNotEmpty && !names.contains(name)) names.add(name);
  }
  if (names.isEmpty) return '$verb files';
  final visible = names.take(2).join(', ');
  final remaining = names.length - 2;
  return '$verb $visible${remaining > 0 ? ' and $remaining more' : ''}';
}

String _commandActionText(CodexCommandAction action) => switch (action) {
  CodexReadCommandAction value => value.command,
  CodexListFilesCommandAction value => value.command,
  CodexSearchCommandAction value => value.command,
  CodexUnknownCommandAction value => value.command,
  _ => '',
};

String _unwrapShellCommand(String command) {
  final trimmed = command.trim();
  final match = RegExp(
    r'^(?:[^\s]*/)?(?:ba|z|k)?sh\s+-[^\s]*c[^\s]*\s+([\s\S]+)$',
  ).firstMatch(trimmed);
  if (match == null) return trimmed;
  final payload = match.group(1)!.trim();
  return _unquoteShellWord(payload) ?? payload;
}

/// Decodes a shell-quoted value only when the complete input is one word.
///
/// Shell launchers serialize the command passed to `-c` as a single argument.
/// Merely removing its first and last quote leaves sequences such as
/// `'"'"'` visible in activity text, while parsing multiple words here would
/// incorrectly discard meaningful argument quotes.
String? _unquoteShellWord(String input) {
  if (input.length < 2) return null;
  final output = StringBuffer();
  String? quote;
  var escaped = false;
  var encoded = false;

  for (var index = 0; index < input.length; index++) {
    final character = input[index];
    if (escaped) {
      if (quote == '"' && !r'"\$`'.contains(character)) {
        output.write(r'\');
      }
      if (character != '\n') output.write(character);
      escaped = false;
      continue;
    }
    if (quote == "'") {
      if (character == "'") {
        quote = null;
      } else {
        output.write(character);
      }
      continue;
    }
    if (quote == '"') {
      if (character == '"') {
        quote = null;
      } else if (character == r'\') {
        escaped = true;
      } else {
        output.write(character);
      }
      continue;
    }
    if (character == "'" || character == '"') {
      quote = character;
      encoded = true;
      continue;
    }
    if (character == r'\') {
      escaped = true;
      encoded = true;
      continue;
    }
    if (RegExp(r'\s').hasMatch(character)) return null;
    output.write(character);
  }

  if (!encoded || escaped || quote != null) return null;
  return output.toString();
}

String _shortenShellExecutablePaths(String command) {
  if (command.isEmpty) return command;
  // Keep arguments intact, but turn `/path/to/flutter test ...` into
  // `flutter test ...` for each command in a chain or pipeline.
  final replacements = <({int start, int end, String value})>[];
  var offset = 0;
  var expectsExecutable = true;

  while (offset < command.length) {
    final token = _nextShellDisplayToken(command, offset);
    if (token == null) break;
    offset = token.end;
    if (token.operator) {
      expectsExecutable =
          token.value == '&&' ||
          token.value == '||' ||
          token.value == ';' ||
          token.value == '|';
      continue;
    }
    if (!expectsExecutable) continue;
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(token.value)) {
      continue;
    }

    final normalized = token.value.replaceAll(r'\', '/');
    final executable = normalized.split('/').last;
    if (executable.isNotEmpty &&
        (normalized.contains('/') || token.source != executable)) {
      replacements.add((start: token.start, end: token.end, value: executable));
    }
    expectsExecutable = false;
  }

  if (replacements.isEmpty) return command;
  final result = StringBuffer();
  var copiedThrough = 0;
  for (final replacement in replacements) {
    result
      ..write(command.substring(copiedThrough, replacement.start))
      ..write(replacement.value);
    copiedThrough = replacement.end;
  }
  result.write(command.substring(copiedThrough));
  return result.toString();
}

({int start, int end, String source, String value, bool operator})?
_nextShellDisplayToken(String command, int offset) {
  while (offset < command.length && RegExp(r'\s').hasMatch(command[offset])) {
    offset++;
  }
  if (offset >= command.length) return null;

  final start = offset;
  if (_isShellDisplayOperator(command[offset])) {
    offset++;
    if (offset < command.length && command[offset] == command[start]) {
      offset++;
    }
    final source = command.substring(start, offset);
    return (
      start: start,
      end: offset,
      source: source,
      value: source,
      operator: true,
    );
  }

  final value = StringBuffer();
  String? quote;
  var escaped = false;
  while (offset < command.length) {
    final character = command[offset];
    if (escaped) {
      value.write(character);
      escaped = false;
      offset++;
      continue;
    }
    if (quote != null) {
      if (character == quote) {
        quote = null;
      } else if (quote == '"' && character == r'\') {
        escaped = true;
      } else {
        value.write(character);
      }
      offset++;
      continue;
    }
    if (character == "'" || character == '"') {
      quote = character;
      offset++;
      continue;
    }
    if (character == r'\') {
      escaped = true;
      offset++;
      continue;
    }
    if (RegExp(r'\s').hasMatch(character) ||
        _isShellDisplayOperator(character)) {
      break;
    }
    value.write(character);
    offset++;
  }
  if (escaped) value.write(r'\');
  return (
    start: start,
    end: offset,
    source: command.substring(start, offset),
    value: value.toString(),
    operator: false,
  );
}

bool _isShellDisplayOperator(String character) =>
    character == '&' || character == '|' || character == ';';

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
