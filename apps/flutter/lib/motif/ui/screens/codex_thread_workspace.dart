import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/services.dart';

import '../../codex/codex_agent_output_parser.dart';
import '../../codex/codex_composer_models.dart';
import '../../codex/codex_navigation.dart';
import '../../codex/codex_observation_view_models.dart';
import '../../codex/codex_service_state.dart';
import '../../codex/codex_user_input_parser.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../theme/motif_theme.dart';
import '../widgets/codex_markdown.dart';
import '../widgets/codex_turn_activity.dart';

part 'codex_thread_workspace.g.dart';

const _turnTopLevelItemSpacing = MotifSpacing.lg;

typedef CodexTurnActionBuilder =
    Widget Function(
      BuildContext context,
      CodexConversationState state,
      CodexTurn turn,
    );
typedef _ConversationScrollSnapshot = ({
  int stream,
  int structure,
  String? threadId,
});

class CodexThreadWorkspace extends StatefulWidget {
  const CodexThreadWorkspace({
    required this.state,
    this.turnActionBuilder = _persistentForkAction,
    this.onOpenFile,
    this.onOpenImage,
    this.onOpenTurnDiff,
    super.key,
  });

  final CodexConversationState state;
  final CodexTurnActionBuilder turnActionBuilder;
  final CodexOpenFile? onOpenFile;
  final CodexOpenImage? onOpenImage;
  final CodexOpenTurnDiff? onOpenTurnDiff;

  @override
  State<CodexThreadWorkspace> createState() => _CodexThreadWorkspaceState();
}

class _CodexThreadWorkspaceState extends State<CodexThreadWorkspace> {
  final TextEditingController _composer = TextEditingController();
  final TextEditingController _planFeedback = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final FocusNode _planFeedbackFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final Set<String> _resolvedPlanItems = <String>{};
  final Set<String> _expandedHistoryTurnIds = <String>{};
  List<CodexPendingAttachment> _attachments = const [];
  List<CodexComposerReference> _references = const [];
  ObservationSubscription<_ConversationScrollSnapshot>? _scrollSubscription;
  String? _scrollThreadId;
  bool _followTail = true;
  bool _scrollScheduled = false;

  @override
  void initState() {
    super.initState();
    _scrollThreadId = widget.state.viewModel.selectedThread?.id;
    _bindScrollUpdates();
    _scheduleScrollToBottom();
  }

  @override
  void didUpdateWidget(CodexThreadWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state, widget.state)) {
      _scrollThreadId = widget.state.viewModel.selectedThread?.id;
      _bindScrollUpdates();
      _followTail = true;
      _scheduleScrollToBottom();
    }
  }

  @override
  void dispose() {
    _composer.dispose();
    _planFeedback.dispose();
    _composerFocus.dispose();
    _planFeedbackFocus.dispose();
    _scrollSubscription?.dispose();
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
          Expanded(
            child: ListenableBuilder(
              listenable: state,
              builder: (context, _) => _CodexConversationViewport(
                key: const ValueKey('codex-conversation-viewport'),
                state: state,
                scrollController: _scroll,
                onScrollNotification: _onUserScroll,
                turnActionBuilder: widget.turnActionBuilder,
                expandedHistoryTurnIds: _expandedHistoryTurnIds,
                onToggleHistory: _toggleHistory,
                onOpenFile: widget.onOpenFile,
                onOpenImage: widget.onOpenImage,
                onOpenTurnDiff: widget.onOpenTurnDiff,
              ),
            ),
          ),
          ListenableBuilder(
            listenable: state,
            builder: (context, _) => _buildComposerArea(context, state),
          ),
        ],
      ),
    );
  }

  Widget _buildComposerArea(
    BuildContext context,
    CodexConversationState state,
  ) {
    final decisionPlan = _decisionPlan(state);
    return SafeArea(
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
                  _PlanChip(plan: state.activePlan!, diff: state.activeDiff),
                for (final message in state.queuedMessages)
                  _QueuedMessageCard(
                    message: message,
                    queueing: state.queueMessagesWhileActive,
                    onSteer: () => state.steerQueuedMessage(message.id),
                    onDelete: () => state.deleteQueuedMessage(message.id),
                    onEdit: () => _editQueued(message.id),
                    onQueueingChanged: state.setQueueing,
                  ),
                if (decisionPlan != null)
                  _PlanDecisionPanel(
                    sending: state.sending,
                    controller: _planFeedback,
                    focusNode: _planFeedbackFocus,
                    onImplement: () => _implementPlan(decisionPlan),
                    onRevise: () => _revisePlan(decisionPlan),
                    onSkip: () => _skipPlan(decisionPlan),
                  )
                else
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
                    onToggleGoal: _toggleGoalMode,
                    onTogglePlan: _togglePlanMode,
                    onRemoveGoal: _removeGoal,
                    onSubmit: _submit,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  CodexPlanThreadItem? _decisionPlan(CodexConversationState state) {
    final pendingItemId = state.awaitingPlanDecisionItemId;
    if (!state.planModeEnabled ||
        pendingItemId == null ||
        state.activeTurn != null) {
      return null;
    }
    final latestTurn = state.turns.lastOrNull;
    if (latestTurn == null || latestTurn.status != CodexTurnStatus.completed) {
      return null;
    }
    for (final item in latestTurn.items.reversed) {
      if (item is CodexPlanThreadItem &&
          item.id == pendingItemId &&
          item.text.trim().isNotEmpty &&
          !_resolvedPlanItems.contains(item.id)) {
        return item;
      }
    }
    return null;
  }

  Future<void> _implementPlan(CodexPlanThreadItem plan) async {
    final accepted = await widget.state.implementCurrentPlan();
    if (!mounted || !accepted) return;
    setState(() {
      _resolvedPlanItems.add(plan.id);
      _planFeedback.clear();
    });
  }

  Future<void> _revisePlan(CodexPlanThreadItem plan) async {
    final accepted = await widget.state.reviseCurrentPlan(_planFeedback.text);
    if (!mounted || !accepted) return;
    setState(() {
      _resolvedPlanItems.add(plan.id);
      _planFeedback.clear();
    });
  }

  void _skipPlan(CodexPlanThreadItem plan) {
    setState(() {
      _resolvedPlanItems.add(plan.id);
      _planFeedback.clear();
    });
    widget.state.skipCurrentPlan();
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
    if (widget.state.goalModeEnabled) {
      if (text.trim().isEmpty) return;
      final currentGoal = widget.state.goal;
      final accepted = await widget.state.saveGoal(
        objective: text,
        tokenBudget: currentGoal?.tokenBudget,
        status: currentGoal?.status ?? CodexThreadGoalStatus.active,
      );
      if (!accepted || !mounted) return;
      widget.state.setGoalMode(false);
      _composer.clear();
      _composerFocus.requestFocus();
      return;
    }
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

  void _toggleGoalMode() {
    final enabled = !widget.state.goalModeEnabled;
    if (enabled) {
      widget.state.setPlanMode(false);
      final objective = widget.state.goal?.objective;
      if (_composer.text.trim().isEmpty && objective != null) {
        _composer.text = objective;
        _composer.selection = TextSelection.collapsed(
          offset: _composer.text.length,
        );
      }
    }
    widget.state.setGoalMode(enabled);
    if (enabled) _composerFocus.requestFocus();
  }

  void _togglePlanMode() {
    final enabled = !widget.state.planModeEnabled;
    if (enabled) widget.state.setGoalMode(false);
    widget.state.setPlanMode(enabled);
    if (enabled) _composerFocus.requestFocus();
  }

  void _removeGoal() {
    if (widget.state.goalModeEnabled) {
      widget.state.setGoalMode(false);
      return;
    }
    unawaited(widget.state.clearGoal());
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
    _scroll.jumpTo(_scroll.position.minScrollExtent);
  }

  void _bindScrollUpdates() {
    _scrollSubscription?.dispose();
    _scrollSubscription = observe(
      () => (
        stream: widget.state.viewModel.streamRevision,
        structure: Object.hashAll([
          for (final turn in widget.state.viewModel.turns)
            Object.hash(
              identityHashCode(turn.turn),
              Object.hashAll(
                turn.items.map((item) => identityHashCode(item.structuralItem)),
              ),
            ),
        ]),
        threadId: widget.state.viewModel.selectedThread?.id,
      ),
      onChange: (snapshot) {
        if (_scrollThreadId != snapshot.threadId) {
          _scrollThreadId = snapshot.threadId;
          _followTail = true;
        }
        _scheduleScrollToBottom();
      },
      scheduler: ObservationSchedulers.frame,
    );
  }

  void _toggleHistory(String turnId) {
    setState(() {
      if (!_expandedHistoryTurnIds.add(turnId)) {
        _expandedHistoryTurnIds.remove(turnId);
      }
    });
  }

  void _scheduleScrollToBottom() {
    if (!_followTail || _scrollScheduled || !mounted) return;
    _scrollScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollScheduled = false;
      if (_followTail) _scrollToBottom();
    });
  }

  bool _onUserScroll(ScrollNotification notification) {
    if (notification is ScrollUpdateNotification &&
        notification.dragDetails != null) {
      _followTail =
          notification.metrics.pixels <=
          notification.metrics.minScrollExtent + 96;
    }
    return false;
  }
}

/// Virtualized conversation surface. It owns the broad structural observation
/// boundary while individual streaming items observe their own view models.
@ObservationWidget()
class _CodexConversationViewport extends _$_CodexConversationViewport {
  const _CodexConversationViewport({
    required this.state,
    required this.scrollController,
    required this.onScrollNotification,
    required this.turnActionBuilder,
    required this.expandedHistoryTurnIds,
    required this.onToggleHistory,
    required this.onOpenFile,
    required this.onOpenImage,
    required this.onOpenTurnDiff,
    super.key,
  });

  final CodexConversationState state;
  final ScrollController scrollController;
  final NotificationListenerCallback<ScrollNotification> onScrollNotification;
  final CodexTurnActionBuilder turnActionBuilder;
  final Set<String> expandedHistoryTurnIds;
  final ValueChanged<String> onToggleHistory;
  final CodexOpenFile? onOpenFile;
  final CodexOpenImage? onOpenImage;
  final CodexOpenTurnDiff? onOpenTurnDiff;

  @override
  Widget build(BuildContext context) {
    final turns = state.viewModel.turns;
    final conversationChildren = <Widget>[
      if (state.readError != null)
        _InlineError(message: state.readError!, onRetry: state.retryRead),
      if (turns.isEmpty) const _EmptyConversation(),
      for (final turn in turns)
        ..._turnSliverChildren(
          state: state,
          turnModel: turn,
          actionBuilder: turnActionBuilder,
          historyExpanded: expandedHistoryTurnIds.contains(turn.id),
          onToggleHistory: () => onToggleHistory(turn.id),
          onOpenFile: onOpenFile,
          onOpenImage: onOpenImage,
          onOpenTurnDiff: onOpenTurnDiff,
        ),
      for (final request in state.pendingServerRequests)
        _ServerRequestCard(
          key: ValueKey(request.toJson().toString()),
          state: state,
          request: request,
        ),
      if (state.sendError != null) _InlineError(message: state.sendError!),
      if (state.forkError != null) _InlineError(message: state.forkError!),
    ];
    return NotificationListener<ScrollNotification>(
      onNotification: onScrollNotification,
      child: SelectionArea(
        child: CustomScrollView(
          key: const ValueKey('codex-turn-stream'),
          controller: scrollController,
          reverse: true,
          // TODO(flutter): use ScrollCacheExtent.pixels when the native-assets
          // test frontend catches up with the SDK API.
          // ignore: deprecated_member_use
          cacheExtent: 1600,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                MotifSpacing.xl,
                MotifSpacing.lg,
                MotifSpacing.xl,
                MotifSpacing.xxl,
              ),
              sliver: SliverList.builder(
                itemCount: conversationChildren.length,
                itemBuilder: (context, index) {
                  final child =
                      conversationChildren[conversationChildren.length -
                          index -
                          1];
                  return Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 860),
                      child: SizedBox(width: double.infinity, child: child),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

List<Widget> _turnSliverChildren({
  required CodexConversationState state,
  required CodexTurnViewModel turnModel,
  required CodexTurnActionBuilder actionBuilder,
  required bool historyExpanded,
  required VoidCallback onToggleHistory,
  CodexOpenFile? onOpenFile,
  CodexOpenImage? onOpenImage,
  CodexOpenTurnDiff? onOpenTurnDiff,
}) {
  final turn = turnModel.turn;
  final items = turnModel.items
      .map((model) => model.structuralItem)
      .toList(growable: false);
  final result = <Widget>[];
  final response = items
      .whereType<CodexAgentMessageThreadItem>()
      .where((item) => item.text.trim().isNotEmpty)
      .lastOrNull;

  if (turn.status == CodexTurnStatus.inProgress && turn.startedAt != null) {
    result.add(_TurnDivider(turn: turn));
  }
  result.add(const SizedBox(height: MotifSpacing.md));

  if (turn.status == CodexTurnStatus.inProgress) {
    result.addAll(
      _turnContent(
        state,
        turn,
        items,
        onOpenFile: onOpenFile,
        onOpenImage: onOpenImage,
        onOpenTurnDiff: onOpenTurnDiff,
      ),
    );
  } else {
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
    if (responseIndex == -1) {
      for (var index = items.length - 1; index >= leadingEnd; index--) {
        final item = items[index];
        if (item is CodexPlanThreadItem && item.text.trim().isNotEmpty) {
          responseIndex = index;
          break;
        }
      }
    }
    final historyEnd = responseIndex == -1 ? items.length : responseIndex;
    final leading = items.take(leadingEnd).toList(growable: false);
    final history = items
        .skip(leadingEnd)
        .take(historyEnd - leadingEnd)
        .toList(growable: false);
    final responseItems = responseIndex == -1
        ? const <CodexThreadItem>[]
        : items.skip(responseIndex).toList(growable: false);
    result
      ..addAll(
        _turnContent(
          state,
          turn,
          leading,
          groupKeyPrefix: 'leading',
          onOpenFile: onOpenFile,
          onOpenImage: onOpenImage,
          onOpenTurnDiff: onOpenTurnDiff,
        ),
      )
      ..add(
        _WorkedHeader(
          turn: turn,
          expanded: historyExpanded,
          onTap: history.isEmpty ? null : onToggleHistory,
        ),
      );
    if (historyExpanded) {
      result.addAll(
        _turnContent(
          state,
          turn,
          history,
          groupKeyPrefix: 'history',
          boundedActivity: false,
          onOpenFile: onOpenFile,
          onOpenImage: onOpenImage,
          onOpenTurnDiff: onOpenTurnDiff,
        ),
      );
    }
    result.addAll(
      _turnContent(
        state,
        turn,
        responseItems,
        groupKeyPrefix: 'response',
        onOpenFile: onOpenFile,
        onOpenImage: onOpenImage,
        onOpenTurnDiff: onOpenTurnDiff,
      ),
    );
  }

  if (turn.error != null) {
    result.add(_InlineError(message: turn.error!.message));
  }
  if (turn.status == CodexTurnStatus.completed) {
    result
      ..add(
        CodexTurnDiffSummary(
          turnId: turn.id,
          items: items.whereType<CodexFileChangeThreadItem>().toList(),
          cwd: state.selectedThread?.cwd.value,
          onOpenDiff: onOpenTurnDiff,
        ),
      )
      ..add(
        _ResponseActions(
          state: state,
          turn: turn,
          response: response,
          actionBuilder: actionBuilder,
        ),
      );
  }
  result.add(const SizedBox(height: MotifSpacing.xl));
  return result;
}

class _TurnDivider extends StatelessWidget {
  const _TurnDivider({required this.turn});

  final CodexTurn turn;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Row(
      children: [
        Expanded(child: Divider(color: c.border)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.md),
          child: Text(
            _turnLabel(turn),
            style: MotifType.caption.copyWith(color: c.textTertiary),
          ),
        ),
        Expanded(child: Divider(color: c.border)),
      ],
    );
  }
}

List<Widget> _turnContent(
  CodexConversationState state,
  CodexTurn turn,
  Iterable<CodexThreadItem> items, {
  String groupKeyPrefix = 'active',
  bool boundedActivity = true,
  CodexOpenFile? onOpenFile,
  CodexOpenImage? onOpenImage,
  CodexOpenTurnDiff? onOpenTurnDiff,
}) {
  final itemList = items.toList(growable: false);
  final latestVisibleItem = itemList.lastOrNull;
  final result = <Widget>[];
  final activity = <CodexThreadItem>[];
  var groupIndex = 0;
  var bottomHasProgressOrAssistant = false;

  void flushActivity() {
    if (activity.isEmpty) return;
    final reasoningIsLatest =
        turn.status == CodexTurnStatus.inProgress &&
        latestVisibleItem is CodexReasoningThreadItem &&
        identical(activity.last, latestVisibleItem);
    final visibleActivity = [
      for (final item in activity)
        if (item is! CodexReasoningThreadItem || reasoningIsLatest) item,
    ];
    activity.clear();
    if (visibleActivity.isEmpty) return;
    if (visibleActivity.every((item) => item is CodexReasoningThreadItem)) {
      final reasoning = visibleActivity.last as CodexReasoningThreadItem;
      result.add(
        Padding(
          key: ValueKey('codex-reasoning-${reasoning.id}'),
          padding: const EdgeInsets.only(bottom: _turnTopLevelItemSpacing),
          child: CodexActivityTitle(
            state: state,
            item: reasoning,
            groupTitle: 'Thinking',
            showLatestItemTitle: true,
            processingLatestItem: reasoningIsLatest,
          ),
        ),
      );
      bottomHasProgressOrAssistant = true;
      return;
    }
    final currentGroup = groupIndex++;
    final groupKey = groupKeyPrefix == 'active' || groupKeyPrefix == 'history'
        ? 'codex-activity-${turn.id}-$currentGroup'
        : 'codex-activity-${turn.id}-$groupKeyPrefix-$currentGroup';
    result.add(
      Padding(
        padding: const EdgeInsets.only(bottom: _turnTopLevelItemSpacing),
        child: CodexTurnActivityGroup(
          key: ValueKey(groupKey),
          state: state,
          items: List.unmodifiable(visibleActivity),
          showLatestItemTitle: turn.status == CodexTurnStatus.inProgress,
          processingLatestItem:
              turn.status == CodexTurnStatus.inProgress &&
              identical(visibleActivity.last, latestVisibleItem),
          boundedDetails: boundedActivity,
          onOpenFile: onOpenFile,
          onOpenImage: onOpenImage,
          onOpenTurnDiff: onOpenTurnDiff,
        ),
      ),
    );
    bottomHasProgressOrAssistant = true;
  }

  for (final item in itemList) {
    // Reasoning participates in the active activity group's collapsed title,
    // but remains absent from completed turn history and has no expanded body.
    if (item is CodexReasoningThreadItem) {
      if (turn.status == CodexTurnStatus.inProgress) activity.add(item);
      continue;
    }
    if (item is CodexContextCompactionThreadItem) {
      flushActivity();
      result.add(
        Padding(
          padding: const EdgeInsets.only(bottom: _turnTopLevelItemSpacing),
          child: _ContextCompactionItem(item: item),
        ),
      );
      bottomHasProgressOrAssistant = false;
      continue;
    }
    if (item case CodexAgentMessageThreadItem(
      text: final text,
    ) when text.trim().isEmpty) {
      continue;
    }
    if (item case CodexPlanThreadItem(
      text: final text,
    ) when text.trim().isEmpty) {
      continue;
    }
    if (_isVisibleTextBoundary(item)) {
      flushActivity();
      result.add(
        Padding(
          padding: const EdgeInsets.only(bottom: _turnTopLevelItemSpacing),
          child: _ThreadItemView(
            state: state,
            item: item,
            onOpenFile: onOpenFile,
            onOpenImage: onOpenImage,
          ),
        ),
      );
      bottomHasProgressOrAssistant = item is CodexAgentMessageThreadItem;
    } else {
      activity.add(item);
    }
  }
  flushActivity();
  if (turn.status == CodexTurnStatus.inProgress &&
      !bottomHasProgressOrAssistant) {
    result.add(
      Padding(
        key: ValueKey('codex-turn-thinking-${turn.id}'),
        padding: const EdgeInsets.only(bottom: _turnTopLevelItemSpacing),
        child: const _ActiveTurnThinking(),
      ),
    );
  }
  return result;
}

class _ActiveTurnThinking extends StatelessWidget {
  const _ActiveTurnThinking();

  @override
  Widget build(BuildContext context) => Text(
    'Thinking',
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: MotifType.subhead.copyWith(color: context.motif.textSecondary),
  );
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
  const _ThreadItemView({
    required this.state,
    required this.item,
    required this.onOpenFile,
    required this.onOpenImage,
  });

  final CodexConversationState state;
  final CodexThreadItem item;
  final CodexOpenFile? onOpenFile;
  final CodexOpenImage? onOpenImage;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      CodexUserMessageThreadItem value => _UserMessage(
        state: state,
        item: value,
        onOpenFile: onOpenFile,
        onOpenImage: onOpenImage,
      ),
      CodexAgentMessageThreadItem value => _AgentMessage(
        key: ValueKey('codex-agent-message-${value.id}'),
        state: state,
        item: value,
        onOpenFile: onOpenFile,
        onOpenImage: onOpenImage,
      ),
      CodexPlanThreadItem value => _CollapsedPlanCard(
        key: ValueKey('codex-plan-card-${value.id}'),
        state: state,
        plan: value,
      ),
      _ => const SizedBox.shrink(),
    };
  }
}

@ObservationWidget()
class _CollapsedPlanCard extends _$_CollapsedPlanCard {
  const _CollapsedPlanCard({
    required this.state,
    required this.plan,
    super.key,
  });

  final CodexConversationState state;
  final CodexPlanThreadItem plan;

  @override
  Widget build(BuildContext context) {
    final model = state.observedItemViewModel(plan);
    final live = model?.item;
    return _buildCard(
      context,
      live is CodexPlanThreadItem ? live : plan,
      streaming: model?.streaming ?? false,
    );
  }

  Widget _buildCard(
    BuildContext context,
    CodexPlanThreadItem plan, {
    required bool streaming,
  }) {
    final c = context.motif;
    return Material(
      key: ValueKey('codex-plan-item-${plan.id}'),
      color: c.surface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: c.border),
        borderRadius: BorderRadius.circular(MotifRadius.sm),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            settings: RouteSettings(name: 'codex-plan/${plan.id}'),
            builder: (_) => _PlanDetailScreen(plan: plan),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(MotifSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.lightbulb_outline_rounded,
                    size: MotifIconSize.md,
                    color: c.textTertiary,
                  ),
                  const SizedBox(width: MotifSpacing.md),
                  Expanded(
                    child: Text(
                      'Plan',
                      style: MotifType.body.copyWith(color: c.textSecondary),
                    ),
                  ),
                  Icon(
                    Icons.open_in_full_rounded,
                    size: MotifIconSize.sm,
                    color: c.textTertiary,
                  ),
                ],
              ),
              const SizedBox(height: MotifSpacing.lg),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 176),
                child: ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.white, Colors.white, Colors.transparent],
                    stops: [0, 0.82, 1],
                  ).createShader(bounds),
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: IgnorePointer(
                      child: streaming
                          ? CodexStreamingText(
                              plan.text,
                              key: ValueKey('codex-plan-preview-${plan.id}'),
                              style: MotifType.body.copyWith(
                                color: c.textPrimary,
                                height: 1.55,
                              ),
                            )
                          : CodexMarkdown(
                              plan.text,
                              key: ValueKey('codex-plan-preview-${plan.id}'),
                              style: MotifType.body.copyWith(
                                color: c.textPrimary,
                                height: 1.55,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlanDetailScreen extends StatelessWidget {
  const _PlanDetailScreen({required this.plan});

  final CodexPlanThreadItem plan;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Scaffold(
      key: const ValueKey('codex-plan-detail'),
      backgroundColor: c.surface,
      appBar: AppBar(title: const Text('Plan')),
      body: SelectionArea(
        child: ListView(
          padding: const EdgeInsets.all(MotifSpacing.xl),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: CodexMarkdown(
                  plan.text,
                  style: MotifType.body.copyWith(
                    color: c.textPrimary,
                    height: 1.55,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserMessage extends StatelessWidget {
  const _UserMessage({
    required this.state,
    required this.item,
    required this.onOpenFile,
    required this.onOpenImage,
  });

  final CodexConversationState state;
  final CodexUserMessageThreadItem item;
  final CodexOpenFile? onOpenFile;
  final CodexOpenImage? onOpenImage;

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
                        _RemoteImage(
                          state: state,
                          path: image.path,
                          onTap: onOpenImage == null
                              ? null
                              : () => onOpenImage!(image.path),
                        ),
                      for (final image in remoteImages)
                        GestureDetector(
                          key: ValueKey('codex-user-remote-image-${image.url}'),
                          onTap: onOpenImage == null
                              ? null
                              : () => onOpenImage!(image.url),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(MotifRadius.xs),
                            child: _RemoteUrlImage(
                              url: image.url,
                              width: 160,
                              height: 120,
                              fit: BoxFit.cover,
                            ),
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
                    onTapFileLink: onOpenFile == null
                        ? null
                        : (href) => _openMarkdownFile(state, onOpenFile!, href),
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
  const _RemoteImage({required this.state, required this.path, this.onTap});

  final CodexConversationState state;
  final String path;
  final VoidCallback? onTap;

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
        return GestureDetector(
          key: ValueKey('codex-user-local-image-$path'),
          onTap: onTap,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(MotifRadius.xs),
            child: Image.memory(
              snapshot.data!,
              width: 160,
              height: 120,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.broken_image_outlined),
            ),
          ),
        );
      },
    );
  }
}

class _CodexMarkdownImage extends StatelessWidget {
  const _CodexMarkdownImage({
    required this.state,
    required this.uri,
    required this.onOpenImage,
  });

  final CodexConversationState state;
  final Uri uri;
  final CodexOpenImage? onOpenImage;

  @override
  Widget build(BuildContext context) {
    final source = uri.toString();
    final remote = const {'http', 'https', 'data'}.contains(uri.scheme);
    final path = remote
        ? source
        : codexFilePathFromMarkdownLink(
            source,
            cwd: state.selectedThread?.cwd.value,
          );
    if (path == null) return const Icon(Icons.broken_image_outlined);
    final image = remote
        ? _RemoteUrlImage(url: path, fit: BoxFit.contain)
        : FutureBuilder<Uint8List>(
            future: state.readRemoteFile(path),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const LinearProgressIndicator();
              return Image.memory(
                snapshot.data!,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.broken_image_outlined),
              );
            },
          );
    return GestureDetector(
      key: ValueKey('codex-markdown-image-$path'),
      onTap: onOpenImage == null
          ? null
          : () => _invokeOpenImage(onOpenImage!, path),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
        child: image,
      ),
    );
  }
}

class _RemoteUrlImage extends StatelessWidget {
  const _RemoteUrlImage({required this.url, this.width, this.height, this.fit});

  final String url;
  final double? width;
  final double? height;
  final BoxFit? fit;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(url);
    final data = uri?.data;
    if (data != null) {
      return Image.memory(
        data.contentAsBytes(),
        width: width,
        height: height,
        fit: fit,
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      );
    }
    return Image.network(
      url,
      width: width,
      height: height,
      fit: fit,
      errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
    );
  }
}

void _openMarkdownFile(
  CodexConversationState state,
  CodexOpenFile openFile,
  String href,
) {
  final path = codexFilePathFromMarkdownLink(
    href,
    cwd: state.selectedThread?.cwd.value,
  );
  if (path == null) return;
  final result = openFile(path);
  if (result is Future<void>) unawaited(result);
}

void _invokeOpenImage(CodexOpenImage openImage, String source) {
  final result = openImage(source);
  if (result is Future<void>) unawaited(result);
}

@ObservationWidget()
class _AgentMessage extends _$_AgentMessage {
  const _AgentMessage({
    required this.state,
    required this.item,
    required this.onOpenFile,
    required this.onOpenImage,
    super.key,
  });

  final CodexConversationState state;
  final CodexAgentMessageThreadItem item;
  final CodexOpenFile? onOpenFile;
  final CodexOpenImage? onOpenImage;

  @override
  Widget build(BuildContext context) {
    final model = state.observedItemViewModel(item);
    final live = model?.item;
    return _buildMessage(
      context,
      live is CodexAgentMessageThreadItem ? live : item,
      streaming: model?.streaming ?? false,
    );
  }

  Widget _buildMessage(
    BuildContext context,
    CodexAgentMessageThreadItem item, {
    required bool streaming,
  }) {
    final c = context.motif;
    final visibleText = const CodexAgentOutputParser().parse(item.text);
    if (visibleText.trim().isEmpty) return const SizedBox.shrink();
    final style = MotifType.body.copyWith(color: c.textPrimary, height: 1.55);
    if (streaming) return CodexStreamingText(visibleText, style: style);
    return CodexMarkdown(
      visibleText,
      style: style,
      onTapFileLink: onOpenFile == null
          ? null
          : (href) => _openMarkdownFile(state, onOpenFile!, href),
      imageBuilder: (uri, _, _) =>
          _CodexMarkdownImage(state: state, uri: uri, onOpenImage: onOpenImage),
    );
  }
}

class _ResponseActions extends StatelessWidget {
  const _ResponseActions({
    required this.state,
    required this.turn,
    required this.response,
    required this.actionBuilder,
  });

  final CodexConversationState state;
  final CodexTurn turn;
  final CodexAgentMessageThreadItem? response;
  final CodexTurnActionBuilder actionBuilder;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
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
              await Clipboard.setData(
                ClipboardData(
                  text: const CodexAgentOutputParser().parse(response.text),
                ),
              );
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
        actionBuilder(context, state, turn),
      ],
    );
  }
}

Widget _persistentForkAction(
  BuildContext context,
  CodexConversationState state,
  CodexTurn turn,
) {
  final c = context.motif;
  if (state.forkingTurnId == turn.id) {
    return const Padding(
      padding: EdgeInsets.all(MotifSpacing.sm),
      child: SizedBox(
        width: MotifIconSize.sm,
        height: MotifIconSize.sm,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
  return IconButton(
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
  );
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

class _PlanDecisionPanel extends StatelessWidget {
  const _PlanDecisionPanel({
    required this.sending,
    required this.controller,
    required this.focusNode,
    required this.onImplement,
    required this.onRevise,
    required this.onSkip,
  });

  final bool sending;
  final TextEditingController controller;
  final FocusNode focusNode;
  final Future<void> Function() onImplement;
  final Future<void> Function() onRevise;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      key: const ValueKey('codex-plan-decision'),
      decoration: BoxDecoration(
        color: c.surfaceElevated,
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(MotifRadius.md),
        boxShadow: MotifElevation.overlay(c.shadow),
      ),
      padding: const EdgeInsets.all(MotifSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Implement this plan?',
                  style: MotifType.headline.copyWith(color: c.textPrimary),
                ),
              ),
              IconButton(
                key: const ValueKey('codex-plan-close'),
                tooltip: 'Skip plan',
                visualDensity: VisualDensity.compact,
                iconSize: MotifIconSize.sm,
                color: c.textTertiary,
                onPressed: sending ? null : onSkip,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: MotifSpacing.sm),
          Material(
            color: c.subtleFill,
            borderRadius: BorderRadius.circular(MotifRadius.pill),
            child: InkWell(
              key: const ValueKey('codex-plan-implement'),
              borderRadius: BorderRadius.circular(MotifRadius.pill),
              onTap: sending ? null : onImplement,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MotifSpacing.md,
                  vertical: MotifSpacing.sm,
                ),
                child: Row(
                  children: [
                    SizedBox.square(
                      dimension: MotifControlSize.sm,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: c.borderStrong),
                        ),
                        child: Center(
                          child: sending
                              ? SizedBox.square(
                                  dimension: MotifIconSize.sm,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: c.accent,
                                  ),
                                )
                              : Text(
                                  '1',
                                  style: MotifType.callout.copyWith(
                                    color: c.textSecondary,
                                  ),
                                ),
                        ),
                      ),
                    ),
                    const SizedBox(width: MotifSpacing.md),
                    Expanded(
                      child: Text(
                        'Yes, implement this plan',
                        style: MotifType.body.copyWith(color: c.textPrimary),
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: MotifIconSize.md,
                      color: c.textTertiary,
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: MotifSpacing.sm),
          Row(
            children: [
              Icon(
                Icons.edit_outlined,
                size: MotifIconSize.md,
                color: c.textTertiary,
              ),
              const SizedBox(width: MotifSpacing.sm),
              Expanded(
                child: TextField(
                  key: const ValueKey('codex-plan-feedback'),
                  controller: controller,
                  focusNode: focusNode,
                  enabled: !sending,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: TextInputAction.send,
                  style: MotifType.body.copyWith(color: c.textPrimary),
                  decoration: const InputDecoration(
                    hintText: 'No, tell Codex what to change',
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (_) {
                    if (controller.text.trim().isNotEmpty && !sending) {
                      onRevise();
                    }
                  },
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                valueListenable: controller,
                builder: (context, value, _) => IconButton(
                  key: const ValueKey('codex-plan-revise'),
                  tooltip: 'Revise plan',
                  visualDensity: VisualDensity.compact,
                  iconSize: MotifIconSize.md,
                  color: c.accent,
                  onPressed: sending || value.text.trim().isEmpty
                      ? null
                      : onRevise,
                  icon: const Icon(Icons.arrow_upward_rounded),
                ),
              ),
              TextButton(
                key: const ValueKey('codex-plan-skip'),
                onPressed: sending ? null : onSkip,
                child: const Text('Skip'),
              ),
            ],
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
    required this.onToggleGoal,
    required this.onTogglePlan,
    required this.onRemoveGoal,
    required this.onSubmit,
  });

  final CodexConversationState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final List<CodexPendingAttachment> attachments;
  final List<CodexComposerReference> references;
  final Future<void> Function() onAddImages;
  final Future<void> Function() onAddFiles;
  final ValueChanged<int> onRemoveAttachment;
  final ValueChanged<CodexComposerReference> onAddReference;
  final ValueChanged<CodexComposerReference> onRemoveReference;
  final VoidCallback onToggleGoal;
  final VoidCallback onTogglePlan;
  final VoidCallback onRemoveGoal;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final active = state.activeTurn != null && !state.goalModeEnabled;
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
                decoration: InputDecoration(
                  hintText: state.goalModeEnabled
                      ? state.goal == null
                            ? 'Describe your goal'
                            : 'Update your goal'
                      : 'Do anything',
                  border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(MotifRadius.sm),
                    ),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(MotifRadius.sm),
                    ),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(
                      Radius.circular(MotifRadius.sm),
                    ),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: MotifSpacing.sm),
          LayoutBuilder(
            builder: (context, constraints) {
              final compactActions = constraints.maxWidth < 540;
              final add = _ComposerAddButton(
                state: state,
                onAddImages: onAddImages,
                onAddFiles: onAddFiles,
                onAddReference: onAddReference,
                onToggleGoal: onToggleGoal,
                onTogglePlan: onTogglePlan,
              );
              final selections = _ComposerSelections(
                state: state,
                references: references,
                compact: compactActions,
                onRemoveReference: onRemoveReference,
                onRemoveGoal: onRemoveGoal,
              );
              final send = IconButton.filled(
                key: ValueKey(active ? 'codex-stop' : 'codex-send'),
                tooltip: active
                    ? 'Stop turn'
                    : state.goalModeEnabled
                    ? 'Save goal'
                    : 'Send',
                onPressed: state.sending || state.goalLoading
                    ? null
                    : active
                    ? state.interruptActiveTurn
                    : onSubmit,
                style: context.iconButtonStyle().copyWith(
                  foregroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.disabled)
                        ? c.textTertiary
                        : c.textOnAccent,
                  ),
                  backgroundColor: WidgetStateProperty.resolveWith(
                    (states) => states.contains(WidgetState.disabled)
                        ? c.subtleFill
                        : c.accent,
                  ),
                  shape: const WidgetStatePropertyAll(CircleBorder()),
                ),
                icon: Icon(
                  active ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                ),
              );
              if (compactActions) {
                return Row(
                  children: [
                    add,
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: selections,
                      ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * 0.46,
                      ),
                      child: _ModelSettingsSelector(state: state),
                    ),
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
                  const SizedBox(width: MotifSpacing.xs),
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
          if (state.goalError != null)
            CodexMarkdown(
              state.goalError!,
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
    required this.onToggleGoal,
    required this.onTogglePlan,
  });

  final CodexConversationState state;
  final Future<void> Function() onAddImages;
  final Future<void> Function() onAddFiles;
  final ValueChanged<CodexComposerReference> onAddReference;
  final VoidCallback onToggleGoal;
  final VoidCallback onTogglePlan;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      key: const ValueKey('codex-add-menu'),
      tooltip: 'Add',
      icon: const Icon(Icons.add),
      onSelected: (value) {
        if (value == 'image') unawaited(onAddImages());
        if (value == 'file') unawaited(onAddFiles());
        if (value == 'goal') onToggleGoal();
        if (value == 'plan') onTogglePlan();
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
        if (state.supports(CodexConversationFeature.goals))
          PopupMenuItem(
            key: const ValueKey('codex-add-goal'),
            value: 'goal',
            child: _ComposerMenuRow(
              icon: Icons.track_changes_rounded,
              label: 'Goal',
              description: state.goal == null
                  ? state.goalModeEnabled
                        ? 'Turn goal mode off'
                        : 'Set a goal to keep pursuing'
                  : state.goal!.objective,
              selected: state.goalModeEnabled,
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
    required this.compact,
    required this.onRemoveReference,
    required this.onRemoveGoal,
  });

  final CodexConversationState state;
  final List<CodexComposerReference> references;
  final bool compact;
  final ValueChanged<CodexComposerReference> onRemoveReference;
  final VoidCallback onRemoveGoal;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _PermissionSelector(state: state, compact: compact),
        if (state.supports(CodexConversationFeature.goals) &&
            (state.goal != null || state.goalModeEnabled)) ...[
          const SizedBox(width: MotifSpacing.xs),
          _ComposerChip(
            key: const ValueKey('codex-goal-chip'),
            icon: Icons.track_changes_rounded,
            label: 'Goal',
            compact: compact,
            removable: true,
            onTap: onRemoveGoal,
          ),
        ],
        if (state.planModeEnabled) ...[
          const SizedBox(width: MotifSpacing.xs),
          _ComposerChip(
            key: const ValueKey('codex-plan-chip'),
            icon: Icons.lightbulb_outline_rounded,
            label: 'Plan',
            compact: compact,
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
            compact: compact,
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
    this.compact = false,
    this.removable = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool compact;
  final bool removable;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Tooltip(
      message: removable ? '$label · tap to remove' : label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(MotifRadius.pill),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: MotifSpacing.sm,
            vertical: compact ? MotifSpacing.sm : MotifSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: c.subtleFill,
            borderRadius: BorderRadius.circular(MotifRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                compact || !removable ? icon : Icons.cancel_rounded,
                size: MotifIconSize.sm,
                color: c.textTertiary,
              ),
              if (!compact) ...[
                const SizedBox(width: MotifSpacing.xs),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.callout.copyWith(color: c.textSecondary),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionSelector extends StatelessWidget {
  const _PermissionSelector({required this.state, this.compact = false});

  final CodexConversationState state;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final selected = state.permissionProfiles
        .where((profile) => profile.id == state.selectedPermissionId)
        .firstOrNull;
    final selectedAppearance = _permissionAppearance(selected);
    return PopupMenuButton<String>(
      key: const ValueKey('codex-permission-selector'),
      tooltip: 'Permissions',
      onSelected: (value) =>
          state.selectPermissionProfile(value == '__default__' ? null : value),
      itemBuilder: (_) => [
        PopupMenuItem(
          key: const ValueKey('codex-permission-option-default'),
          value: '__default__',
          child: _PermissionMenuRow(
            icon: Icons.shield_outlined,
            label: 'Default permissions',
            selected: selected == null,
          ),
        ),
        for (final profile in state.permissionProfiles.where(
          (value) => value.allowed,
        ))
          PopupMenuItem(
            key: ValueKey('codex-permission-option-${profile.id}'),
            value: profile.id,
            child: _PermissionMenuRow(
              icon: _permissionAppearance(profile).icon,
              label: _permissionAppearance(profile).label,
              selected: profile.id == state.selectedPermissionId,
              danger: _permissionAppearance(profile).danger,
            ),
          ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: compact ? MotifControlSize.sm : 0,
          maxWidth: compact ? MotifControlSize.sm : 140,
          minHeight: compact ? MotifControlSize.sm : 0,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: compact
              ? MainAxisAlignment.center
              : MainAxisAlignment.start,
          children: [
            Icon(
              selectedAppearance.icon,
              size: MotifIconSize.sm,
              color: selectedAppearance.danger ? c.danger : null,
            ),
            if (!compact) ...[
              const SizedBox(width: MotifSpacing.xs),
              Flexible(
                child: Text(
                  selectedAppearance.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.callout.copyWith(
                    color: selectedAppearance.danger ? c.danger : null,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PermissionMenuRow extends StatelessWidget {
  const _PermissionMenuRow({
    required this.icon,
    required this.label,
    required this.selected,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final color = danger ? c.danger : c.textSecondary;
    return Row(
      children: [
        Icon(icon, size: MotifIconSize.md, color: color),
        const SizedBox(width: MotifSpacing.md),
        Expanded(
          child: Text(
            label,
            style: MotifType.body.copyWith(
              color: danger ? c.danger : c.textPrimary,
            ),
          ),
        ),
        if (selected) ...[
          const SizedBox(width: MotifSpacing.md),
          Icon(Icons.check_rounded, size: MotifIconSize.md, color: color),
        ],
      ],
    );
  }
}

({IconData icon, bool danger, String label}) _permissionAppearance(
  CodexPermissionProfileSummary? profile,
) {
  if (profile == null) {
    return (icon: Icons.shield_outlined, danger: false, label: 'Default');
  }
  final value = '${profile.id} ${profile.description ?? ''}'.toLowerCase();
  if ((value.contains('ask') && value.contains('approval')) ||
      value.contains('on-request')) {
    return (
      icon: Icons.front_hand_outlined,
      danger: false,
      label: 'Ask for approval',
    );
  }
  if ((value.contains('approve') && value.contains('me')) ||
      value.contains('auto-approve')) {
    return (
      icon: Icons.verified_user_outlined,
      danger: false,
      label: 'Approve for me',
    );
  }
  if (value.contains('danger-full-access') ||
      value.contains('danger full access') ||
      value.contains('full-access') ||
      value.contains('full access')) {
    return (
      icon: Icons.error_outline_rounded,
      danger: true,
      label: 'Full access',
    );
  }
  if (value.contains('custom') || value.contains('config.toml')) {
    return (
      icon: Icons.settings_outlined,
      danger: false,
      label: 'Custom (config.toml)',
    );
  }
  if (value.contains('read-only') || value.contains('read only')) {
    return (
      icon: Icons.lock_outline_rounded,
      danger: false,
      label: 'Read only',
    );
  }
  if (value.contains('workspace-write') || value.contains('workspace write')) {
    return (
      icon: Icons.drive_file_rename_outline,
      danger: false,
      label: 'Workspace write',
    );
  }
  if (profile.id.toLowerCase().replaceFirst(RegExp(r'^:+'), '') ==
      'workspace') {
    return (
      icon: Icons.drive_file_rename_outline,
      danger: false,
      label: 'Workspace',
    );
  }
  return (
    icon: Icons.tune_rounded,
    danger: false,
    label: profile.description?.trim().isNotEmpty == true
        ? profile.description!.trim()
        : profile.id.replaceFirst(RegExp(r'^:+'), ''),
  );
}

class _ModelSettingsSelector extends StatelessWidget {
  const _ModelSettingsSelector({required this.state});

  final CodexConversationState state;

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
              horizontal: MotifSpacing.xs,
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
  const _ModelMenuChoice({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 256,
      child: Row(
        children: [
          Expanded(child: Text(label, style: MotifType.body)),
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

  final CodexConversationState state;
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

  final CodexConversationState state;
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

String _turnLabel(CodexTurn turn) {
  if (turn.status == CodexTurnStatus.inProgress) return 'Working';
  final duration = turn.durationMs;
  if (duration == null) return _titleCase(turn.status.value);
  final seconds = duration ~/ 1000;
  if (seconds < 60) return '${_titleCase(turn.status.value)} in ${seconds}s';
  return '${_titleCase(turn.status.value)} in ${seconds ~/ 60}m ${seconds % 60}s';
}

String _workedLabel(CodexTurn turn) {
  final prefix = switch (turn.status) {
    CodexTurnStatus.interrupted => 'You stopped after',
    CodexTurnStatus.failed => 'Failed after',
    _ => 'Worked for',
  };
  final duration =
      turn.durationMs ??
      (turn.startedAt != null && turn.completedAt != null
          ? _timestampMilliseconds(turn.completedAt!) -
                _timestampMilliseconds(turn.startedAt!)
          : null);
  if (duration == null) {
    return switch (turn.status) {
      CodexTurnStatus.interrupted => 'You stopped',
      CodexTurnStatus.failed => 'Failed',
      _ => 'Worked',
    };
  }
  final seconds = (duration < 0 ? 0 : duration) ~/ 1000;
  if (seconds < 60) return '$prefix ${seconds}s';
  final minutes = seconds ~/ 60;
  final remaining = seconds % 60;
  return remaining == 0
      ? '$prefix ${minutes}m'
      : '$prefix ${minutes}m ${remaining}s';
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
