import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../codex/codex_composer_models.dart';
import '../../codex/codex_session_state.dart';
import '../../codex/codex_thread_catalog.dart';
import '../../codex/codex_user_input_parser.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../theme/motif_theme.dart';
import '../widgets/codex_markdown.dart';
import '../widgets/codex_turn_activity.dart';

class CodexThreadWorkspace extends StatefulWidget {
  const CodexThreadWorkspace({required this.state, super.key});

  final CodexSessionState state;

  @override
  State<CodexThreadWorkspace> createState() => _CodexThreadWorkspaceState();
}

class _CodexThreadWorkspaceState extends State<CodexThreadWorkspace> {
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  List<CodexPendingAttachment> _attachments = const [];
  List<CodexComposerReference> _references = const [];
  int _lastEventCount = 0;

  @override
  void didUpdateWidget(CodexThreadWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final count = _eventCount(widget.state);
    if (count != _lastEventCount) {
      _lastEventCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
  }

  @override
  void dispose() {
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final c = context.motif;
    return Material(
      key: const ValueKey('codex-thread-detail'),
      color: c.surface,
      child: Column(
        children: [
          _ThreadHeader(state: state),
          Expanded(
            child: SelectionArea(
              child: ListView(
                key: const ValueKey('codex-turn-stream'),
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(
                  MotifSpacing.xl,
                  MotifSpacing.lg,
                  MotifSpacing.xl,
                  MotifSpacing.xxl,
                ),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 860),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (state.readError != null)
                            _InlineError(
                              message: state.readError!,
                              onRetry: state.retryRead,
                            ),
                          if (state.turns.isEmpty) const _EmptyConversation(),
                          for (final turn in state.turns)
                            _TurnSection(state: state, turn: turn),
                          for (final request in state.pendingServerRequests)
                            _ServerRequestCard(
                              key: ValueKey(request.toJson().toString()),
                              state: state,
                              request: request,
                            ),
                          if (state.sendError != null)
                            _InlineError(message: state.sendError!),
                          if (state.forkError != null)
                            _InlineError(message: state.forkError!),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 900),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MotifSpacing.lg,
                    0,
                    MotifSpacing.lg,
                    MotifSpacing.md,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (state.activePlan != null)
                        _PlanChip(
                          plan: state.activePlan!,
                          diff: state.activeDiff,
                        ),
                      for (final message in state.queuedMessages)
                        _QueuedMessageCard(
                          message: message,
                          queueing: state.queueMessagesWhileActive,
                          onSteer: () => state.steerQueuedMessage(message.id),
                          onDelete: () => state.deleteQueuedMessage(message.id),
                          onEdit: () => _editQueued(message.id),
                          onQueueingChanged: state.setQueueing,
                        ),
                      _Composer(
                        state: state,
                        controller: _composer,
                        focusNode: _composerFocus,
                        attachments: _attachments,
                        references: _references,
                        onAddImages: _pickImages,
                        onAddFiles: _pickFiles,
                        onRemoveAttachment: _removeAttachment,
                        onAddReference: _addReference,
                        onRemoveReference: _removeReference,
                        onSubmit: _submit,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickImages() async {
    const images = XTypeGroup(
      label: 'Images',
      extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
      mimeTypes: ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
    );
    final files = await openFiles(acceptedTypeGroups: const [images]);
    await _addFiles(files, CodexAttachmentKind.image);
  }

  Future<void> _pickFiles() async {
    final files = await openFiles();
    await _addFiles(files, CodexAttachmentKind.file);
  }

  Future<void> _addFiles(List<XFile> files, CodexAttachmentKind kind) async {
    if (files.isEmpty) return;
    final loaded = <CodexPendingAttachment>[];
    for (final file in files) {
      loaded.add(
        CodexPendingAttachment(
          name: file.name,
          bytes: await file.readAsBytes(),
          kind: kind,
        ),
      );
    }
    if (!mounted) return;
    setState(() => _attachments = [..._attachments, ...loaded]);
  }

  void _removeAttachment(int index) {
    setState(() {
      final updated = _attachments.toList()..removeAt(index);
      _attachments = updated;
    });
  }

  void _addReference(CodexComposerReference reference) {
    if (_references.any(
      (value) => value.kind == reference.kind && value.path == reference.path,
    )) {
      return;
    }
    setState(() => _references = [..._references, reference]);
  }

  void _removeReference(CodexComposerReference reference) {
    setState(() {
      _references = _references
          .where(
            (value) =>
                value.kind != reference.kind || value.path != reference.path,
          )
          .toList(growable: false);
    });
  }

  Future<void> _submit() async {
    final text = _composer.text;
    final attachments = _attachments;
    final references = _references;
    if (text.trim().isEmpty && attachments.isEmpty && references.isEmpty) {
      return;
    }
    final accepted = await widget.state.submitMessage(
      text,
      attachments,
      references,
    );
    if (!accepted || !mounted) return;
    _composer.clear();
    setState(() {
      _attachments = const [];
      _references = const [];
    });
    _composerFocus.requestFocus();
  }

  void _editQueued(String id) {
    final message = widget.state.takeQueuedMessage(id);
    if (message == null) return;
    _composer.text = message.text;
    _composer.selection = TextSelection.collapsed(
      offset: _composer.text.length,
    );
    setState(() {
      _attachments = message.attachments;
      _references = message.references;
    });
    _composerFocus.requestFocus();
  }

  void _scrollToBottom() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }
}

class _ThreadHeader extends StatelessWidget {
  const _ThreadHeader({required this.state});

  final CodexSessionState state;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final thread = state.selectedThread!;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.lg,
        vertical: MotifSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.folder_outlined,
            size: MotifIconSize.sm,
            color: c.textSecondary,
          ),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  codexThreadTitle(thread),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.headline.copyWith(color: c.textPrimary),
                ),
                if (thread.cwd.value.trim().isNotEmpty)
                  Text(
                    thread.cwd.value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MotifType.caption.copyWith(color: c.textTertiary),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TurnSection extends StatefulWidget {
  const _TurnSection({required this.state, required this.turn});

  final CodexSessionState state;
  final CodexTurn turn;

  @override
  State<_TurnSection> createState() => _TurnSectionState();
}

class _TurnSectionState extends State<_TurnSection> {
  bool _historyExpanded = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final turn = widget.turn;
    final c = context.motif;
    final response = turn.items
        .whereType<CodexAgentMessageThreadItem>()
        .where((item) => item.text.trim().isNotEmpty)
        .lastOrNull;
    final latestReasoning = turn.items
        .whereType<CodexReasoningThreadItem>()
        .lastOrNull;
    return Padding(
      padding: const EdgeInsets.only(bottom: MotifSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (turn.status == CodexTurnStatus.inProgress &&
              turn.startedAt != null)
            Row(
              children: [
                Expanded(child: Divider(color: c.border)),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MotifSpacing.md,
                  ),
                  child: Text(
                    _turnLabel(turn),
                    style: MotifType.caption.copyWith(color: c.textTertiary),
                  ),
                ),
                Expanded(child: Divider(color: c.border)),
              ],
            ),
          const SizedBox(height: MotifSpacing.md),
          if (turn.status == CodexTurnStatus.inProgress)
            ..._turnContent(state, turn, turn.items)
          else
            ..._completedTurnContent(state, turn),
          if (turn.error != null) _InlineError(message: turn.error!.message),
          if (turn.status != CodexTurnStatus.inProgress) ...[
            CodexTurnDiffSummary(
              turnId: turn.id,
              items: turn.items.whereType<CodexFileChangeThreadItem>().toList(),
              cwd: state.selectedThread?.cwd.value,
            ),
            _ResponseActions(state: state, turn: turn, response: response),
          ],
          if (turn.status == CodexTurnStatus.inProgress)
            CodexTurnProgress(reasoning: latestReasoning),
        ],
      ),
    );
  }

  List<Widget> _completedTurnContent(CodexSessionState state, CodexTurn turn) {
    final items = turn.items;
    var leadingEnd = 0;
    while (leadingEnd < items.length &&
        items[leadingEnd] is CodexUserMessageThreadItem) {
      leadingEnd++;
    }
    var responseIndex = -1;
    for (var index = items.length - 1; index >= leadingEnd; index--) {
      final item = items[index];
      if (item is CodexAgentMessageThreadItem && item.text.trim().isNotEmpty) {
        responseIndex = index;
        break;
      }
    }
    final historyEnd = responseIndex == -1 ? items.length : responseIndex;
    final leading = items.take(leadingEnd).toList(growable: false);
    final history = items
        .skip(leadingEnd)
        .take(historyEnd - leadingEnd)
        .toList(growable: false);
    final response = responseIndex == -1
        ? const <CodexThreadItem>[]
        : items.skip(responseIndex).toList(growable: false);
    return [
      ..._turnContent(state, turn, leading, groupKeyPrefix: 'leading'),
      _WorkedHeader(
        turn: turn,
        expanded: _historyExpanded,
        onTap: history.isEmpty
            ? null
            : () => setState(() => _historyExpanded = !_historyExpanded),
      ),
      if (_historyExpanded)
        ..._turnContent(
          state,
          turn,
          history,
          groupKeyPrefix: 'history',
          boundedActivity: false,
        ),
      ..._turnContent(state, turn, response, groupKeyPrefix: 'response'),
    ];
  }
}

List<Widget> _turnContent(
  CodexSessionState state,
  CodexTurn turn,
  Iterable<CodexThreadItem> items, {
  String groupKeyPrefix = 'active',
  bool boundedActivity = true,
}) {
  final result = <Widget>[];
  final activity = <CodexThreadItem>[];
  var groupIndex = 0;

  void flushActivity() {
    if (activity.isEmpty) return;
    final currentGroup = groupIndex++;
    final groupKey = groupKeyPrefix == 'active' || groupKeyPrefix == 'history'
        ? 'codex-activity-${turn.id}-$currentGroup'
        : 'codex-activity-${turn.id}-$groupKeyPrefix-$currentGroup';
    result.add(
      Padding(
        padding: const EdgeInsets.only(bottom: MotifSpacing.xs),
        child: CodexTurnActivityGroup(
          key: ValueKey(groupKey),
          state: state,
          items: List.unmodifiable(activity),
          boundedDetails: boundedActivity,
        ),
      ),
    );
    activity.clear();
  }

  for (final item in items) {
    // Reasoning is transient progress. It is represented once at the bottom of
    // an active turn and is deliberately absent from persisted history.
    if (item is CodexReasoningThreadItem) continue;
    if (item is CodexContextCompactionThreadItem) {
      flushActivity();
      result.add(
        Padding(
          padding: const EdgeInsets.only(bottom: MotifSpacing.xs),
          child: _ContextCompactionItem(item: item),
        ),
      );
      continue;
    }
    if (_isVisibleTextBoundary(item)) {
      flushActivity();
      result.add(
        Padding(
          padding: const EdgeInsets.only(bottom: MotifSpacing.md),
          child: _ThreadItemView(state: state, item: item),
        ),
      );
    } else {
      activity.add(item);
    }
  }
  flushActivity();
  return result;
}

class _WorkedHeader extends StatelessWidget {
  const _WorkedHeader({
    required this.turn,
    required this.expanded,
    required this.onTap,
  });

  final CodexTurn turn;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return InkWell(
      key: ValueKey('codex-worked-toggle-${turn.id}'),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: MotifSpacing.sm),
        margin: const EdgeInsets.only(
          top: MotifSpacing.xl,
          bottom: MotifSpacing.md,
        ),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: c.border)),
        ),
        child: Row(
          children: [
            Text(
              _workedLabel(turn),
              key: ValueKey('codex-turn-time-${turn.id}'),
              style: MotifType.subhead.copyWith(color: c.textTertiary),
            ),
            if (onTap != null) ...[
              const SizedBox(width: MotifSpacing.xs),
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down_rounded
                    : Icons.keyboard_arrow_right_rounded,
                size: MotifIconSize.sm,
                color: c.textTertiary,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ContextCompactionItem extends StatelessWidget {
  const _ContextCompactionItem({required this.item});

  final CodexContextCompactionThreadItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Row(
      key: ValueKey('codex-context-compaction-${item.id}'),
      children: [
        Icon(
          Icons.compress_rounded,
          size: MotifIconSize.md,
          color: c.textTertiary,
        ),
        const SizedBox(width: MotifSpacing.sm),
        Text(
          'Context compacted',
          style: MotifType.subhead.copyWith(color: c.textSecondary),
        ),
      ],
    );
  }
}

bool _isVisibleTextBoundary(CodexThreadItem item) => switch (item) {
  CodexUserMessageThreadItem() => true,
  CodexAgentMessageThreadItem value => value.text.trim().isNotEmpty,
  CodexPlanThreadItem value => value.text.trim().isNotEmpty,
  _ => false,
};

class _ThreadItemView extends StatelessWidget {
  const _ThreadItemView({required this.state, required this.item});

  final CodexSessionState state;
  final CodexThreadItem item;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      CodexUserMessageThreadItem value => _UserMessage(
        state: state,
        item: value,
      ),
      CodexAgentMessageThreadItem value => _AgentMessage(item: value),
      CodexPlanThreadItem value => CodexMarkdown(
        value.text,
        style: MotifType.body.copyWith(
          color: context.motif.textPrimary,
          height: 1.55,
        ),
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

class _UserMessage extends StatelessWidget {
  const _UserMessage({required this.state, required this.item});

  final CodexSessionState state;
  final CodexUserMessageThreadItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final parsed = const CodexUserInputParser().parse(item.content);
    final localImages = parsed.localImages;
    final remoteImages = parsed.remoteImages;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: DecoratedBox(
          key: ValueKey('codex-user-message-${item.id}'),
          decoration: BoxDecoration(
            color: c.subtleFill,
            borderRadius: BorderRadius.circular(MotifRadius.md),
          ),
          child: Padding(
            padding: const EdgeInsets.all(MotifSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (localImages.isNotEmpty || remoteImages.isNotEmpty)
                  Wrap(
                    spacing: MotifSpacing.sm,
                    runSpacing: MotifSpacing.sm,
                    children: [
                      for (final image in localImages)
                        _RemoteImage(state: state, path: image.path),
                      for (final image in remoteImages)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(MotifRadius.xs),
                          child: Image.network(
                            image.url,
                            width: 160,
                            height: 120,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) =>
                                const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                    ],
                  ),
                if (parsed.text.isNotEmpty) ...[
                  if (localImages.isNotEmpty || remoteImages.isNotEmpty)
                    const SizedBox(height: MotifSpacing.sm),
                  CodexMarkdown(
                    parsed.text,
                    fitContent: true,
                    style: MotifType.body.copyWith(color: c.textPrimary),
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

class _RemoteImage extends StatelessWidget {
  const _RemoteImage({required this.state, required this.path});

  final CodexSessionState state;
  final String path;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      future: state.readRemoteFile(path),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SizedBox(
            width: 160,
            height: 120,
            child: Center(child: CircularProgressIndicator()),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(MotifRadius.xs),
          child: Image.memory(
            snapshot.data!,
            width: 160,
            height: 120,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
          ),
        );
      },
    );
  }
}

class _AgentMessage extends StatelessWidget {
  const _AgentMessage({required this.item});

  final CodexAgentMessageThreadItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    if (item.text.trim().isEmpty) return const SizedBox.shrink();
    return CodexMarkdown(
      item.text,
      style: MotifType.body.copyWith(color: c.textPrimary, height: 1.55),
    );
  }
}

class _ResponseActions extends StatelessWidget {
  const _ResponseActions({
    required this.state,
    required this.turn,
    required this.response,
  });

  final CodexSessionState state;
  final CodexTurn turn;
  final CodexAgentMessageThreadItem? response;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final forking = state.forkingTurnId == turn.id;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (response case final response?)
          IconButton(
            key: ValueKey('codex-copy-${response.id}'),
            tooltip: 'Copy response',
            visualDensity: VisualDensity.compact,
            iconSize: MotifIconSize.sm,
            color: c.textTertiary,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: response.text));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('Response copied'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            icon: const Icon(Icons.content_copy_rounded),
          ),
        if (forking)
          const Padding(
            padding: EdgeInsets.all(MotifSpacing.sm),
            child: SizedBox(
              width: MotifIconSize.sm,
              height: MotifIconSize.sm,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          IconButton(
            key: ValueKey('codex-fork-${turn.id}'),
            tooltip: 'Fork from this turn',
            visualDensity: VisualDensity.compact,
            iconSize: MotifIconSize.sm,
            color: c.textTertiary,
            onPressed: () async {
              final forked = await state.forkThreadAtTurn(turn.id);
              if (!context.mounted || !forked) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('Fork created'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
            icon: const Icon(Icons.call_split_rounded),
          ),
      ],
    );
  }
}

class _CollapsedItem extends StatelessWidget {
  const _CollapsedItem({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(
          left: MotifSpacing.xl,
          bottom: MotifSpacing.sm,
        ),
        leading: Icon(icon, size: MotifIconSize.md, color: c.textTertiary),
        title: Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: MotifType.subhead.copyWith(color: c.textSecondary),
        ),
        children: [
          if (body.trim().isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(MotifSpacing.md),
              decoration: BoxDecoration(
                color: c.subtleFill,
                borderRadius: BorderRadius.circular(MotifRadius.xs),
              ),
              child: CodexMarkdown(
                body,
                style: MotifType.mono.copyWith(color: c.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _PlanChip extends StatelessWidget {
  const _PlanChip({required this.plan, required this.diff});

  final CodexTurnPlanUpdatedNotification plan;
  final String? diff;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final completed = plan.plan
        .where((step) => step.status == CodexTurnPlanStepStatus.completed)
        .length;
    final current = plan.plan.indexWhere(
      (step) => step.status == CodexTurnPlanStepStatus.inProgress,
    );
    final position = current == -1
        ? completed.clamp(0, plan.plan.length)
        : current + 1;
    final stats = _diffStats(diff);
    return Padding(
      padding: const EdgeInsets.only(bottom: MotifSpacing.sm),
      child: PopupMenuButton<void>(
        tooltip: 'Show plan',
        offset: const Offset(0, -12),
        itemBuilder: (_) => [
          PopupMenuItem<void>(
            enabled: false,
            child: SizedBox(
              width: 400,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (plan.explanation?.trim().isNotEmpty == true) ...[
                    CodexMarkdown(
                      plan.explanation!,
                      style: MotifType.subhead.copyWith(color: c.textSecondary),
                    ),
                    const SizedBox(height: MotifSpacing.md),
                  ],
                  for (final step in plan.plan)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: MotifSpacing.xs,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            switch (step.status) {
                              CodexTurnPlanStepStatus.completed =>
                                Icons.check_circle,
                              CodexTurnPlanStepStatus.inProgress =>
                                Icons.radio_button_checked,
                              CodexTurnPlanStepStatus.pending =>
                                Icons.radio_button_unchecked,
                            },
                            size: MotifIconSize.sm,
                            color:
                                step.status == CodexTurnPlanStepStatus.completed
                                ? c.success
                                : c.textTertiary,
                          ),
                          const SizedBox(width: MotifSpacing.sm),
                          Expanded(
                            child: CodexMarkdown(
                              step.step,
                              style: MotifType.subhead.copyWith(
                                color: c.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.surfaceElevated,
            border: Border.all(color: c.border),
            borderRadius: BorderRadius.circular(MotifRadius.pill),
            boxShadow: MotifElevation.card(c.shadow),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MotifSpacing.md,
              vertical: MotifSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    value: plan.plan.isEmpty
                        ? null
                        : completed / plan.plan.length,
                    strokeWidth: 2,
                    color: c.accent,
                  ),
                ),
                const SizedBox(width: MotifSpacing.sm),
                Text(
                  'Step $position / ${plan.plan.length}',
                  style: MotifType.callout.copyWith(color: c.textSecondary),
                ),
                if (stats.files > 0) ...[
                  Text(
                    '  ·  ${stats.files} ${stats.files == 1 ? 'file' : 'files'} changed',
                  ),
                  Text(' +${stats.added}', style: TextStyle(color: c.success)),
                  Text(' -${stats.removed}', style: TextStyle(color: c.danger)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QueuedMessageCard extends StatelessWidget {
  const _QueuedMessageCard({
    required this.message,
    required this.queueing,
    required this.onSteer,
    required this.onDelete,
    required this.onEdit,
    required this.onQueueingChanged,
  });

  final CodexQueuedMessage message;
  final bool queueing;
  final Future<bool> Function() onSteer;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final ValueChanged<bool> onQueueingChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      margin: const EdgeInsets.only(bottom: MotifSpacing.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: c.surfaceElevated,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(MotifRadius.md),
      ),
      child: Row(
        children: [
          Icon(
            Icons.low_priority_rounded,
            size: MotifIconSize.sm,
            color: c.textTertiary,
          ),
          if (message.attachments.isNotEmpty) ...[
            const SizedBox(width: MotifSpacing.sm),
            _AttachmentThumbnail(attachment: message.attachments.first),
          ],
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: CodexMarkdown(
              message.text.trim().isEmpty ? 'Attachment' : message.text,
              style: MotifType.body.copyWith(color: c.textPrimary),
            ),
          ),
          TextButton.icon(
            onPressed: () => unawaited(onSteer()),
            icon: const Icon(
              Icons.subdirectory_arrow_left,
              size: MotifIconSize.sm,
            ),
            label: const Text('Steer'),
          ),
          IconButton(
            tooltip: 'Delete queued message',
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: MotifIconSize.md),
          ),
          PopupMenuButton<String>(
            tooltip: 'Message actions',
            onSelected: (value) {
              if (value == 'edit') onEdit();
              if (value == 'queueing') onQueueingChanged(!queueing);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'edit', child: Text('Edit message')),
              PopupMenuItem(
                value: 'queueing',
                child: Text(
                  queueing ? 'Turn off queueing' : 'Turn on queueing',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.attachments,
    required this.references,
    required this.onAddImages,
    required this.onAddFiles,
    required this.onRemoveAttachment,
    required this.onAddReference,
    required this.onRemoveReference,
    required this.onSubmit,
  });

  final CodexSessionState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<CodexPendingAttachment> attachments;
  final List<CodexComposerReference> references;
  final Future<void> Function() onAddImages;
  final Future<void> Function() onAddFiles;
  final ValueChanged<int> onRemoveAttachment;
  final ValueChanged<CodexComposerReference> onAddReference;
  final ValueChanged<CodexComposerReference> onRemoveReference;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final active = state.activeTurn != null;
    return Container(
      key: const ValueKey('codex-composer'),
      padding: const EdgeInsets.all(MotifSpacing.md),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.borderStrong),
        borderRadius: BorderRadius.circular(MotifRadius.lg),
        boxShadow: MotifElevation.overlay(c.shadow),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: MotifSpacing.sm),
              child: Wrap(
                spacing: MotifSpacing.sm,
                runSpacing: MotifSpacing.sm,
                children: [
                  for (var index = 0; index < attachments.length; index++)
                    _PendingAttachment(
                      attachment: attachments[index],
                      onRemove: () => onRemoveAttachment(index),
                    ),
                ],
              ),
            ),
          Shortcuts(
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter): _SubmitIntent(),
            },
            child: Actions(
              actions: {
                _SubmitIntent: CallbackAction<_SubmitIntent>(
                  onInvoke: (_) {
                    unawaited(onSubmit());
                    return null;
                  },
                ),
              },
              child: TextField(
                key: const ValueKey('codex-composer-input'),
                controller: controller,
                focusNode: focusNode,
                minLines: 2,
                maxLines: 8,
                textInputAction: TextInputAction.newline,
                decoration: const InputDecoration(
                  hintText: 'Do anything',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
          ),
          const SizedBox(height: MotifSpacing.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final add = _ComposerAddButton(
                state: state,
                onAddImages: onAddImages,
                onAddFiles: onAddFiles,
                onAddReference: onAddReference,
              );
              final selections = _ComposerSelections(
                state: state,
                references: references,
                onRemoveReference: onRemoveReference,
              );
              final send = IconButton.filled(
                key: ValueKey(active ? 'codex-stop' : 'codex-send'),
                tooltip: active ? 'Stop turn' : 'Send',
                onPressed: state.sending
                    ? null
                    : active
                    ? state.interruptActiveTurn
                    : onSubmit,
                icon: Icon(
                  active ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                ),
              );
              if (constraints.maxWidth < 540) {
                return Row(
                  children: [
                    add,
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: selections,
                      ),
                    ),
                    Flexible(child: _ModelSettingsSelector(state: state)),
                    const SizedBox(width: MotifSpacing.xs),
                    send,
                  ],
                );
              }
              return Row(
                children: [
                  add,
                  selections,
                  const Spacer(),
                  _ModelSettingsSelector(state: state),
                  const SizedBox(width: MotifSpacing.sm),
                  send,
                ],
              );
            },
          ),
          if (state.configurationError != null)
            CodexMarkdown(
              state.configurationError!,
              style: MotifType.caption.copyWith(color: c.warning),
            ),
        ],
      ),
    );
  }
}

class _ComposerAddButton extends StatelessWidget {
  const _ComposerAddButton({
    required this.state,
    required this.onAddImages,
    required this.onAddFiles,
    required this.onAddReference,
  });

  final CodexSessionState state;
  final Future<void> Function() onAddImages;
  final Future<void> Function() onAddFiles;
  final ValueChanged<CodexComposerReference> onAddReference;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const ValueKey('codex-add-menu'),
      tooltip: 'Add',
      icon: const Icon(Icons.add),
      onSelected: (value) {
        if (value == 'image') unawaited(onAddImages());
        if (value == 'file') unawaited(onAddFiles());
        if (value == 'goal') unawaited(_showGoalDialog(context, state));
        if (value == 'plan') state.setPlanMode(!state.planModeEnabled);
        if (value.startsWith('skill:')) {
          final index = int.tryParse(value.substring('skill:'.length));
          if (index != null && index < state.skills.length) {
            final skill = state.skills[index];
            onAddReference(
              CodexComposerReference(
                kind: CodexComposerReferenceKind.skill,
                name: skill.interfaceValue?.displayName ?? skill.name,
                path: skill.path.value,
              ),
            );
          }
        }
        if (value.startsWith('plugin:')) {
          final index = int.tryParse(value.substring('plugin:'.length));
          if (index != null && index < state.plugins.length) {
            final plugin = state.plugins[index];
            onAddReference(
              CodexComposerReference(
                kind: CodexComposerReferenceKind.plugin,
                name: plugin.interfaceValue?.displayName ?? plugin.name,
                path: plugin.id,
              ),
            );
          }
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(enabled: false, child: Text('Add')),
        const PopupMenuItem(
          value: 'file',
          child: _ComposerMenuRow(
            icon: Icons.attach_file_rounded,
            label: 'Files and folders',
          ),
        ),
        const PopupMenuItem(
          value: 'image',
          child: _ComposerMenuRow(icon: Icons.image_outlined, label: 'Images'),
        ),
        PopupMenuItem(
          key: const ValueKey('codex-add-goal'),
          value: 'goal',
          child: _ComposerMenuRow(
            icon: Icons.track_changes_rounded,
            label: 'Goal',
            description: state.goal == null
                ? 'Set a goal to keep pursuing'
                : state.goal!.objective,
          ),
        ),
        PopupMenuItem(
          key: const ValueKey('codex-add-plan'),
          value: 'plan',
          child: _ComposerMenuRow(
            icon: Icons.lightbulb_outline_rounded,
            label: 'Plan mode',
            description: state.planModeEnabled
                ? 'Turn plan mode off'
                : 'Turn plan mode on',
            selected: state.planModeEnabled,
          ),
        ),
        const PopupMenuItem(enabled: false, child: Text('Skills')),
        if (state.skills.isEmpty)
          const PopupMenuItem(
            enabled: false,
            child: _ComposerMenuRow(
              icon: Icons.auto_awesome_outlined,
              label: 'No skills available',
            ),
          ),
        for (var index = 0; index < state.skills.length; index++)
          PopupMenuItem(
            key: ValueKey('codex-add-skill-$index'),
            value: 'skill:$index',
            child: _ComposerMenuRow(
              icon: Icons.auto_awesome_outlined,
              label:
                  state.skills[index].interfaceValue?.displayName ??
                  state.skills[index].name,
              description:
                  state.skills[index].shortDescription ??
                  state.skills[index].description,
            ),
          ),
        const PopupMenuItem(enabled: false, child: Text('Plugins')),
        if (state.plugins.isEmpty)
          const PopupMenuItem(
            enabled: false,
            child: _ComposerMenuRow(
              icon: Icons.extension_outlined,
              label: 'No plugins available',
            ),
          ),
        for (var index = 0; index < state.plugins.length; index++)
          PopupMenuItem(
            key: ValueKey('codex-add-plugin-$index'),
            value: 'plugin:$index',
            child: _ComposerMenuRow(
              icon: Icons.extension_outlined,
              label:
                  state.plugins[index].interfaceValue?.displayName ??
                  state.plugins[index].name,
              description:
                  state.plugins[index].interfaceValue?.shortDescription,
            ),
          ),
      ],
    );
  }
}

class _ComposerMenuRow extends StatelessWidget {
  const _ComposerMenuRow({
    required this.icon,
    required this.label,
    this.description,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final String? description;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return SizedBox(
      width: 360,
      child: Row(
        children: [
          Icon(icon, size: MotifIconSize.md, color: c.textSecondary),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: label, style: MotifType.body),
                  if (description != null && description!.trim().isNotEmpty)
                    TextSpan(
                      text: '  $description',
                      style: MotifType.subhead.copyWith(color: c.textTertiary),
                    ),
                ],
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (selected)
            Icon(Icons.check_rounded, size: MotifIconSize.sm, color: c.accent),
        ],
      ),
    );
  }
}

class _ComposerSelections extends StatelessWidget {
  const _ComposerSelections({
    required this.state,
    required this.references,
    required this.onRemoveReference,
  });

  final CodexSessionState state;
  final List<CodexComposerReference> references;
  final ValueChanged<CodexComposerReference> onRemoveReference;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PermissionSelector(state: state),
        if (state.goal != null) ...[
          const SizedBox(width: MotifSpacing.xs),
          _ComposerChip(
            key: const ValueKey('codex-goal-chip'),
            icon: Icons.track_changes_rounded,
            label: 'Goal',
            onTap: () => unawaited(_showGoalDialog(context, state)),
          ),
        ],
        if (state.planModeEnabled) ...[
          const SizedBox(width: MotifSpacing.xs),
          _ComposerChip(
            key: const ValueKey('codex-plan-chip'),
            icon: Icons.lightbulb_outline_rounded,
            label: 'Plan',
            removable: true,
            onTap: () => state.setPlanMode(false),
          ),
        ],
        for (final reference in references) ...[
          const SizedBox(width: MotifSpacing.xs),
          _ComposerChip(
            key: ValueKey(
              'codex-reference-${reference.kind.name}-${reference.path}',
            ),
            icon: reference.kind == CodexComposerReferenceKind.skill
                ? Icons.auto_awesome_outlined
                : Icons.extension_outlined,
            label: reference.name,
            removable: true,
            onTap: () => onRemoveReference(reference),
          ),
        ],
      ],
    );
  }
}

class _ComposerChip extends StatelessWidget {
  const _ComposerChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.removable = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool removable;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(MotifRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MotifSpacing.sm,
          vertical: MotifSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: c.subtleFill,
          borderRadius: BorderRadius.circular(MotifRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              removable ? Icons.cancel_rounded : icon,
              size: MotifIconSize.sm,
              color: c.textTertiary,
            ),
            const SizedBox(width: MotifSpacing.xs),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MotifType.callout.copyWith(color: c.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _PermissionSelector extends StatelessWidget {
  const _PermissionSelector({required this.state});

  final CodexSessionState state;

  @override
  Widget build(BuildContext context) {
    final selected = state.permissionProfiles
        .where((profile) => profile.id == state.selectedPermissionId)
        .firstOrNull;
    return PopupMenuButton<String>(
      key: const ValueKey('codex-permission-selector'),
      tooltip: 'Permissions',
      onSelected: (value) =>
          state.selectPermissionProfile(value == '__default__' ? null : value),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: '__default__',
          child: Text('Default permissions'),
        ),
        for (final profile in state.permissionProfiles.where(
          (value) => value.allowed,
        ))
          PopupMenuItem(
            value: profile.id,
            child: ListTile(
              title: Text(profile.description ?? profile.id),
              subtitle: profile.description == null ? null : Text(profile.id),
            ),
          ),
      ],
      child: SizedBox(
        width: 140,
        child: Row(
          children: [
            const Icon(Icons.shield_outlined, size: MotifIconSize.sm),
            const SizedBox(width: MotifSpacing.xs),
            Expanded(
              child: Text(
                selected?.description ?? selected?.id ?? 'Default',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: MotifType.callout,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelSettingsSelector extends StatelessWidget {
  const _ModelSettingsSelector({required this.state});

  final CodexSessionState state;

  @override
  Widget build(BuildContext context) {
    final selected = state.selectedModel;
    final selectedEffort = state.selectedReasoningEffort;
    final c = context.motif;
    final menuStyle = MenuStyle(
      minimumSize: const WidgetStatePropertyAll(Size(280, 0)),
      maximumSize: const WidgetStatePropertyAll(Size(340, double.infinity)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: MotifSpacing.xs),
      ),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(MotifRadius.lg),
          side: BorderSide(color: c.border),
        ),
      ),
    );
    return MenuAnchor(
      key: const ValueKey('codex-model-selector'),
      style: menuStyle,
      menuChildren: [
        SubmenuButton(
          key: const ValueKey('codex-model-submenu'),
          menuStyle: menuStyle,
          menuChildren: [
            for (final model in state.models)
              MenuItemButton(
                key: ValueKey('codex-model-option-${model.id}'),
                onPressed: () => state.selectModel(model.id),
                child: _ModelMenuChoice(
                  label: model.displayName,
                  description: model.description,
                  selected: model.id == state.selectedModelId,
                ),
              ),
          ],
          child: _ModelMenuCategory(
            label: 'Model',
            value: selected?.displayName ?? 'Default',
          ),
        ),
        SubmenuButton(
          key: const ValueKey('codex-effort-selector'),
          menuStyle: menuStyle,
          menuChildren: [
            for (final effort in state.supportedReasoningEfforts)
              MenuItemButton(
                key: ValueKey(
                  'codex-effort-option-${effort.reasoningEffort.value}',
                ),
                onPressed: () =>
                    state.selectReasoningEffort(effort.reasoningEffort.value),
                child: _ModelMenuChoice(
                  label: _titleCase(effort.reasoningEffort.value),
                  description: effort.description,
                  selected: effort.reasoningEffort.value == selectedEffort,
                ),
              ),
          ],
          child: _ModelMenuCategory(
            label: 'Effort',
            value: _titleCase(selectedEffort ?? 'Default'),
          ),
        ),
      ],
      builder: (context, controller, child) => Tooltip(
        message: 'Model and reasoning effort',
        child: InkWell(
          borderRadius: BorderRadius.circular(MotifRadius.pill),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MotifSpacing.sm,
              vertical: MotifSpacing.xs,
            ),
            child: Text(
              [
                if (selected != null) selected.displayName else 'Model',
                if (selectedEffort != null) _titleCase(selectedEffort),
              ].join('  '),
              key: const ValueKey('codex-model-settings-label'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: MotifType.callout.copyWith(color: c.textSecondary),
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelMenuCategory extends StatelessWidget {
  const _ModelMenuCategory({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return SizedBox(
      width: 236,
      child: Row(
        children: [
          Expanded(child: Text(label, style: MotifType.body)),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: MotifType.body.copyWith(color: c.textTertiary),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelMenuChoice extends StatelessWidget {
  const _ModelMenuChoice({
    required this.label,
    required this.description,
    required this.selected,
  });

  final String label;
  final String description;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final showDescription =
        description.trim().isNotEmpty &&
        description.trim().toLowerCase() != label.trim().toLowerCase();
    return SizedBox(
      width: 256,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: MotifType.body),
                if (showDescription)
                  Text(
                    description,
                    style: MotifType.caption.copyWith(color: c.textTertiary),
                  ),
              ],
            ),
          ),
          const SizedBox(width: MotifSpacing.sm),
          SizedBox(
            width: MotifIconSize.sm,
            child: selected
                ? const Icon(Icons.check, size: MotifIconSize.sm)
                : null,
          ),
        ],
      ),
    );
  }
}

class _PendingAttachment extends StatelessWidget {
  const _PendingAttachment({required this.attachment, required this.onRemove});

  final CodexPendingAttachment attachment;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _AttachmentThumbnail(attachment: attachment, large: true),
        Positioned(
          right: -6,
          top: -6,
          child: InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(MotifRadius.pill),
            child: const CircleAvatar(
              radius: 10,
              child: Icon(Icons.close, size: 14),
            ),
          ),
        ),
      ],
    );
  }
}

class _AttachmentThumbnail extends StatelessWidget {
  const _AttachmentThumbnail({required this.attachment, this.large = false});

  final CodexPendingAttachment attachment;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final size = large ? 72.0 : 36.0;
    if (attachment.isImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(MotifRadius.xs),
        child: Image.memory(
          attachment.bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }
    return Container(
      width: large ? 150 : size,
      height: size,
      padding: const EdgeInsets.all(MotifSpacing.sm),
      decoration: BoxDecoration(
        color: context.motif.subtleFill,
        borderRadius: BorderRadius.circular(MotifRadius.xs),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.description_outlined, size: MotifIconSize.sm),
          if (large) ...[
            const SizedBox(width: MotifSpacing.xs),
            Expanded(
              child: Text(
                attachment.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: MotifType.caption,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ServerRequestCard extends StatelessWidget {
  const _ServerRequestCard({
    required this.state,
    required this.request,
    super.key,
  });

  final CodexSessionState state;
  final CodexServerRequest request;

  @override
  Widget build(BuildContext context) {
    return switch (request) {
      CodexItemToolRequestUserInputRequest value => _QuestionnaireCard(
        state: state,
        request: value,
      ),
      CodexItemCommandExecutionRequestApprovalRequest value => _ApprovalCard(
        icon: Icons.terminal_rounded,
        title: 'Command approval required',
        reason: value.params.reason,
        detail: value.params.command,
        onDecision: (decision) => state.answerCommandApproval(value, decision),
      ),
      CodexItemFileChangeRequestApprovalRequest value => _ApprovalCard(
        icon: Icons.edit_outlined,
        title: 'File change approval required',
        reason: value.params.reason,
        detail: value.params.grantRoot,
        onDecision: (decision) => state.answerFileApproval(value, decision),
      ),
      CodexItemPermissionsRequestApprovalRequest value => _ApprovalCard(
        icon: Icons.shield_outlined,
        title: 'Additional permissions required',
        reason: value.params.reason,
        detail: _prettyJson(value.params.permissions.toJson()),
        onDecision: (decision) => state.answerPermissionsApproval(
          value,
          allow: decision != 'decline',
          scope: decision == 'acceptForSession'
              ? CodexPermissionGrantScope.session
              : CodexPermissionGrantScope.turn,
        ),
      ),
      _ => _CollapsedItem(
        icon: Icons.help_outline,
        title: 'Codex needs input',
        body: _prettyJson(request.toJson()),
      ),
    };
  }
}

class _QuestionnaireCard extends StatefulWidget {
  const _QuestionnaireCard({required this.state, required this.request});

  final CodexSessionState state;
  final CodexItemToolRequestUserInputRequest request;

  @override
  State<_QuestionnaireCard> createState() => _QuestionnaireCardState();
}

class _QuestionnaireCardState extends State<_QuestionnaireCard> {
  final Map<String, String> _answers = {};
  final Map<String, TextEditingController> _controllers = {};
  bool _submitting = false;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Card(
      margin: const EdgeInsets.only(bottom: MotifSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(MotifSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.quiz_outlined, color: c.accent),
                const SizedBox(width: MotifSpacing.sm),
                Text('Codex has a question', style: MotifType.headline),
              ],
            ),
            const SizedBox(height: MotifSpacing.md),
            for (final question in widget.request.params.questions) ...[
              CodexMarkdown(
                question.header,
                style: MotifType.callout.copyWith(color: c.textPrimary),
                selectable: false,
              ),
              const SizedBox(height: MotifSpacing.xs),
              CodexMarkdown(
                question.question,
                style: MotifType.body.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: MotifSpacing.sm),
              if (question.options case final options?)
                Wrap(
                  spacing: MotifSpacing.sm,
                  runSpacing: MotifSpacing.sm,
                  children: [
                    for (final option in options)
                      ChoiceChip(
                        label: CodexMarkdown(
                          option.label,
                          style: MotifType.subhead.copyWith(
                            color: c.textPrimary,
                          ),
                          selectable: false,
                        ),
                        selected: _answers[question.id] == option.label,
                        tooltip: option.description,
                        onSelected: (_) => setState(
                          () => _answers[question.id] = option.label,
                        ),
                      ),
                  ],
                ),
              if (question.options == null || question.isOther == true)
                TextField(
                  controller: _controllers.putIfAbsent(
                    question.id,
                    TextEditingController.new,
                  ),
                  obscureText: question.isSecret == true,
                  decoration: InputDecoration(
                    hintText: question.isSecret == true
                        ? 'Secret answer'
                        : 'Your answer',
                  ),
                ),
              const SizedBox(height: MotifSpacing.lg),
            ],
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _submitting ? null : _submit,
                child: Text(_submitting ? 'Submitting…' : 'Submit answers'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    final answers = <String, List<String>>{};
    for (final question in widget.request.params.questions) {
      final typed = _controllers[question.id]?.text.trim();
      final value = typed?.isNotEmpty == true ? typed! : _answers[question.id];
      answers[question.id] = value == null ? const [] : [value];
    }
    try {
      await widget.state.answerQuestionnaire(widget.request, answers);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _ApprovalCard extends StatefulWidget {
  const _ApprovalCard({
    required this.icon,
    required this.title,
    required this.reason,
    required this.detail,
    required this.onDecision,
  });

  final IconData icon;
  final String title;
  final String? reason;
  final String? detail;
  final Future<void> Function(Object decision) onDecision;

  @override
  State<_ApprovalCard> createState() => _ApprovalCardState();
}

class _ApprovalCardState extends State<_ApprovalCard> {
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Card(
      margin: const EdgeInsets.only(bottom: MotifSpacing.md),
      child: Padding(
        padding: const EdgeInsets.all(MotifSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(widget.icon, color: c.warning),
                const SizedBox(width: MotifSpacing.sm),
                Expanded(child: Text(widget.title, style: MotifType.headline)),
              ],
            ),
            if (widget.reason?.trim().isNotEmpty == true) ...[
              const SizedBox(height: MotifSpacing.sm),
              CodexMarkdown(
                widget.reason!,
                style: MotifType.body.copyWith(color: c.textPrimary),
              ),
            ],
            if (widget.detail?.trim().isNotEmpty == true) ...[
              const SizedBox(height: MotifSpacing.sm),
              Container(
                padding: const EdgeInsets.all(MotifSpacing.md),
                color: c.subtleFill,
                child: CodexMarkdown(
                  widget.detail!,
                  style: MotifType.mono.copyWith(color: c.textPrimary),
                ),
              ),
            ],
            const SizedBox(height: MotifSpacing.md),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: MotifSpacing.sm,
              children: [
                TextButton(
                  onPressed: _submitting ? null : () => _decide('decline'),
                  child: const Text('Decline'),
                ),
                OutlinedButton(
                  onPressed: _submitting
                      ? null
                      : () => _decide('acceptForSession'),
                  child: const Text('Allow for session'),
                ),
                FilledButton(
                  onPressed: _submitting ? null : () => _decide('accept'),
                  child: const Text('Allow once'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _decide(String decision) async {
    setState(() => _submitting = true);
    try {
      await widget.onDecision(decision);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, this.onRetry});

  final String message;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      margin: const EdgeInsets.only(bottom: MotifSpacing.md),
      padding: const EdgeInsets.all(MotifSpacing.md),
      decoration: BoxDecoration(
        color: c.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(MotifRadius.xs),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: c.danger),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: CodexMarkdown(
              message,
              style: MotifType.subhead.copyWith(color: c.danger),
            ),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: () => unawaited(onRetry!()),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: MotifSpacing.xxxl),
      child: Column(
        children: [
          Icon(Icons.chat_bubble_outline, size: 40, color: c.textTertiary),
          const SizedBox(height: MotifSpacing.md),
          Text(
            'No turns yet',
            style: MotifType.title.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}

class _SubmitIntent extends Intent {
  const _SubmitIntent();
}

Future<void> _showGoalDialog(
  BuildContext context,
  CodexSessionState state,
) async {
  final objective = TextEditingController(text: state.goal?.objective ?? '');
  final budget = TextEditingController(
    text: state.goal?.tokenBudget?.toString() ?? '',
  );
  var status = state.goal?.status ?? CodexThreadGoalStatus.active;
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Thread goal'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: objective,
                autofocus: true,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Objective'),
              ),
              const SizedBox(height: MotifSpacing.md),
              TextField(
                controller: budget,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Token budget (optional)',
                ),
              ),
              const SizedBox(height: MotifSpacing.md),
              DropdownButtonFormField<CodexThreadGoalStatus>(
                initialValue: status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  for (final value in CodexThreadGoalStatus.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(_titleCase(value.value)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => status = value);
                },
              ),
              if (state.goal != null) ...[
                const SizedBox(height: MotifSpacing.md),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${state.goal!.tokensUsed} tokens · ${state.goal!.timeUsedSeconds}s used',
                    style: MotifType.caption,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (state.goal != null)
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Clear'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: objective.text.trim().isEmpty
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
  if (result == true) {
    await state.saveGoal(
      objective: objective.text,
      tokenBudget: int.tryParse(budget.text.trim()),
      status: status,
    );
  } else if (result == false) {
    await state.clearGoal();
  }
  objective.dispose();
  budget.dispose();
}

int _eventCount(CodexSessionState state) => state.turns.fold<int>(
  state.pendingServerRequests.length + state.queuedMessages.length,
  (sum, turn) => sum + turn.items.length,
);

String _turnLabel(CodexTurn turn) {
  if (turn.status == CodexTurnStatus.inProgress) return 'Working';
  final duration = turn.durationMs;
  if (duration == null) return _titleCase(turn.status.value);
  final seconds = duration ~/ 1000;
  if (seconds < 60) return '${_titleCase(turn.status.value)} in ${seconds}s';
  return '${_titleCase(turn.status.value)} in ${seconds ~/ 60}m ${seconds % 60}s';
}

String _workedLabel(CodexTurn turn) {
  final duration =
      turn.durationMs ??
      (turn.startedAt != null && turn.completedAt != null
          ? _timestampMilliseconds(turn.completedAt!) -
                _timestampMilliseconds(turn.startedAt!)
          : null);
  if (duration == null) return 'Worked';
  final seconds = (duration < 0 ? 0 : duration) ~/ 1000;
  if (seconds < 60) return 'Worked for ${seconds}s';
  final minutes = seconds ~/ 60;
  final remaining = seconds % 60;
  return remaining == 0
      ? 'Worked for ${minutes}m'
      : 'Worked for ${minutes}m ${remaining}s';
}

int _timestampMilliseconds(int value) =>
    value.abs() < 100000000000 ? value * 1000 : value;

String _prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return '$value';
  }
}

({int files, int added, int removed}) _diffStats(String? diff) {
  if (diff == null || diff.isEmpty) return (files: 0, added: 0, removed: 0);
  var files = 0;
  var added = 0;
  var removed = 0;
  for (final line in const LineSplitter().convert(diff)) {
    if (line.startsWith('diff --git ')) files++;
    if (line.startsWith('+') && !line.startsWith('+++')) added++;
    if (line.startsWith('-') && !line.startsWith('---')) removed++;
  }
  return (files: files, added: added, removed: removed);
}

String _titleCase(String value) {
  if (value.isEmpty) return value;
  final spaced = value.replaceAllMapped(
    RegExp(r'([a-z0-9])([A-Z])'),
    (match) => '${match[1]} ${match[2]}',
  );
  return spaced[0].toUpperCase() + spaced.substring(1);
}
