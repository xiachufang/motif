import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart' as image_picker;

import '../../codex/codex_agent_output_parser.dart';
import '../../codex/codex_composer_models.dart';
import '../../codex/codex_connection_controller.dart';
import '../../codex/codex_navigation.dart';
import '../../codex/codex_observation_view_models.dart';
import '../../codex/codex_service_state.dart';
import '../../codex/codex_state.dart';
import '../../codex/codex_user_input_parser.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../../models/resource_documents.dart';
import '../../platform/services.dart';
import '../../platform/speech_locale.dart';
import '../theme/codex_typography.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/codex_markdown.dart';
import '../widgets/codex_motion.dart';
import '../widgets/codex_turn_activity.dart';
import '../widgets/observation_select.dart';
import '../widgets/top_toast.dart';

part 'codex_thread_workspace.g.dart';

const _turnTopLevelItemSpacing = MotifSpacing.lg;
const _imageTypes = XTypeGroup(
  label: 'Images',
  extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'],
  mimeTypes: ['image/png', 'image/jpeg', 'image/gif', 'image/webp'],
  uniformTypeIdentifiers: [
    'public.png',
    'public.jpeg',
    'com.compuserve.gif',
    'org.webmproject.webp',
  ],
);

bool get _isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.android);

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
    this.codexState,
    this.speechService,
    this.turnActionBuilder = _persistentForkAction,
    this.onOpenFile,
    this.onOpenImage,
    this.onOpenTurnDiff,
    super.key,
  });

  final CodexConversationState state;
  final CodexState? codexState;
  final SpeechService? speechService;
  final CodexTurnActionBuilder turnActionBuilder;
  final CodexOpenFile? onOpenFile;
  final CodexOpenImage? onOpenImage;
  final CodexOpenTurnDiff? onOpenTurnDiff;

  @override
  State<CodexThreadWorkspace> createState() => _CodexThreadWorkspaceState();
}

class _CodexThreadWorkspaceState extends State<CodexThreadWorkspace>
    with WidgetsBindingObserver {
  final TextEditingController _composer = TextEditingController();
  final TextEditingController _planFeedback = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final FocusNode _planFeedbackFocus = FocusNode();
  // A newly selected thread should lay out at its tail immediately. Starting
  // at zero exposes the top of a long conversation for one frame before the
  // post-frame follow-tail correction runs.
  final ScrollController _scroll = ScrollController(
    initialScrollOffset: double.maxFinite,
  );
  final Set<String> _resolvedPlanItems = <String>{};
  final Set<String> _expandedHistoryTurnIds = <String>{};
  List<CodexPendingAttachment> _attachments = const [];
  List<CodexComposerReference> _references = const [];
  ObservationSubscription<_ConversationScrollSnapshot>? _scrollSubscription;
  String? _scrollThreadId;
  bool _followTail = true;
  bool _scrollScheduled = false;
  CodexState? _draftState;
  String? _draftServerId;
  String? _draftThreadId;
  bool _restoringDraft = false;
  bool _recording = false;
  bool _voiceBusy = false;
  bool _ignoreVoiceFinal = false;
  String _asrBase = '';
  String _lastAsrText = '';
  int _voiceSession = 0;
  Timer? _recordingTimer;
  Duration _recordingDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _bindComposerDraft();
    _composer.addListener(_onComposerChanged);
    _composerFocus.addListener(_onComposerFocusChanged);
    _scrollThreadId = widget.state.viewModel.selectedThread?.id;
    _bindScrollUpdates();
    _scheduleScrollToBottom();
  }

  @override
  void didUpdateWidget(CodexThreadWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rebindComposerDraftIfNeeded();
    if (!identical(oldWidget.state, widget.state)) {
      _scrollThreadId = widget.state.viewModel.selectedThread?.id;
      _bindScrollUpdates();
      _followTail = true;
      _scheduleScrollToBottom();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _voiceSession += 1;
    _recordingTimer?.cancel();
    if (_recording || _voiceBusy) {
      unawaited(widget.speechService?.stop());
    }
    _composer.removeListener(_onComposerChanged);
    _composerFocus.removeListener(_onComposerFocusChanged);
    _persistBoundComposerDraft();
    final draftState = _draftState;
    if (draftState != null) {
      unawaited(draftState.flushComposerDraftPreferences());
    }
    _composer.dispose();
    _planFeedback.dispose();
    _composerFocus.dispose();
    _planFeedbackFocus.dispose();
    _scrollSubscription?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _scheduleScrollToBottom();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (mounted) setState(() {});
  }

  void _rebindComposerDraftIfNeeded() {
    final nextState = widget.codexState;
    final nextServerId = widget.state.serverId;
    final nextThreadId = widget.state.selectedThread?.id;
    if (identical(nextState, _draftState) &&
        nextServerId == _draftServerId &&
        nextThreadId == _draftThreadId) {
      return;
    }
    _persistBoundComposerDraft();
    _bindComposerDraft();
  }

  void _bindComposerDraft() {
    _draftState = widget.codexState;
    _draftServerId = widget.state.serverId;
    _draftThreadId = widget.state.selectedThread?.id;
    final draft = switch ((_draftState, _draftServerId, _draftThreadId)) {
      (final state?, final serverId?, final threadId?) =>
        state.composerDraft(serverId, threadId) ?? '',
      _ => '',
    };
    _restoringDraft = true;
    _composer.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _restoringDraft = false;
  }

  void _onComposerChanged() {
    if (_restoringDraft) return;
    if (_recording && _composer.text != _lastAsrText) {
      _ignoreVoiceFinal = true;
      unawaited(_stopVoiceInput());
    }
    _persistBoundComposerDraft();
  }

  Future<void> _toggleVoiceInput() async {
    if (_voiceBusy) return;
    if (_recording) {
      await _stopVoiceInput();
      return;
    }

    if (!supportsDoubaoSpeechInput(
      WidgetsBinding.instance.platformDispatcher.locale,
    )) {
      return;
    }
    final speech = widget.speechService;
    if (speech == null || !speech.isAvailable) return;
    final session = ++_voiceSession;
    _asrBase = _composer.text;
    _lastAsrText = _composer.text;
    _ignoreVoiceFinal = false;
    setState(() => _voiceBusy = true);
    var failed = false;
    try {
      await speech.start(
        onPartial: (partial) {
          if (!mounted || session != _voiceSession || _ignoreVoiceFinal) return;
          _replaceAsrText(_mergeAsr(_asrBase, partial));
        },
        onError: (error) {
          if (!mounted || session != _voiceSession) return;
          failed = true;
          _ignoreVoiceFinal = true;
          if (_recording) unawaited(speech.stop());
          setState(() {
            _voiceBusy = false;
            _recording = false;
          });
          _stopRecordingClock();
          showMotifToast(context, 'Voice input: $error');
        },
      );
      if (!mounted || session != _voiceSession || failed) return;
      setState(() {
        _voiceBusy = false;
        _recording = true;
      });
      _startRecordingClock();
    } catch (error) {
      if (!mounted || session != _voiceSession) return;
      setState(() {
        _voiceBusy = false;
        _recording = false;
      });
      _stopRecordingClock();
      showMotifToast(context, 'Voice input unavailable: $error');
    }
  }

  Future<void> _cancelVoiceInput() async {
    _ignoreVoiceFinal = true;
    _replaceAsrText(_asrBase);
    await _stopVoiceInput();
  }

  Future<void> _stopVoiceInput() async {
    if (_voiceBusy || !_recording) return;
    final speech = widget.speechService;
    if (speech == null) return;
    final session = _voiceSession;
    setState(() => _voiceBusy = true);
    try {
      final finalText = await speech.stop();
      if (!mounted || session != _voiceSession) return;
      if (!_ignoreVoiceFinal && finalText.isNotEmpty) {
        _replaceAsrText(_mergeAsr(_asrBase, finalText));
      }
    } catch (error) {
      if (mounted && session == _voiceSession) {
        showMotifToast(context, 'Voice input: $error');
      }
    } finally {
      if (mounted && session == _voiceSession) {
        _voiceSession += 1;
        setState(() {
          _voiceBusy = false;
          _recording = false;
        });
        _stopRecordingClock();
        _ignoreVoiceFinal = false;
      }
    }
  }

  void _startRecordingClock() {
    _recordingTimer?.cancel();
    _recordingDuration = Duration.zero;
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _recordingDuration = Duration(seconds: timer.tick);
      });
    });
  }

  void _stopRecordingClock() {
    _recordingTimer?.cancel();
    _recordingTimer = null;
  }

  void _replaceAsrText(String text) {
    _lastAsrText = text;
    _composer.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  String _mergeAsr(String base, String text) {
    if (base.isEmpty) return text;
    if (text.isEmpty) return base;
    return base.codeUnits.last <= 0x20 ? '$base$text' : '$base $text';
  }

  void _onComposerFocusChanged() {
    if (_composerFocus.hasFocus) _showLatestContent();
  }

  void _persistBoundComposerDraft() {
    final state = _draftState;
    final serverId = _draftServerId;
    final threadId = _draftThreadId;
    if (state == null || serverId == null || threadId == null) return;
    state.setComposerDraft(serverId, threadId, _composer.text);
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
                onLoadOlderTurns: _loadOlderTurns,
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
    final projectedExternalActiveTurn = state.projectedExternalActiveTurn;
    final decisionPlan = _decisionPlan(state);
    final queueKey = Object.hashAll(
      state.queuedMessages.map((message) => message.id),
    );
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
                CodexMotionPresence(
                  visible: state.activePlan != null,
                  child: _PlanChip(
                    plan:
                        state.activePlan ??
                        const CodexTurnPlanUpdatedNotification(
                          plan: [],
                          threadId: '',
                          turnId: '',
                        ),
                    diff: state.activeDiff,
                    onOpenDiff: widget.onOpenTurnDiff,
                  ),
                ),
                CodexMotionSwitcher(
                  animateSize: true,
                  alignment: Alignment.topCenter,
                  child: state.queuedMessages.isEmpty
                      ? const SizedBox.shrink(
                          key: ValueKey('codex-queue-empty'),
                        )
                      : Column(
                          key: ValueKey('codex-queue-$queueKey'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (final message in state.queuedMessages)
                              _QueuedMessageCard(
                                key: ValueKey('codex-queued-${message.id}'),
                                message: message,
                                queueing: state.queueMessagesWhileActive,
                                onSteer: () =>
                                    state.steerQueuedMessage(message.id),
                                onDelete: () =>
                                    state.deleteQueuedMessage(message.id),
                                onEdit: () => _editQueued(message.id),
                                onQueueingChanged: state.setQueueing,
                              ),
                          ],
                        ),
                ),
                CodexMotionSwitcher(
                  animateSize: true,
                  alignment: Alignment.bottomCenter,
                  child:
                      state.connectionState.phase !=
                          CodexConnectionPhase.connected
                      ? _ConnectionStatusNotice(
                          key: const ValueKey('codex-connection-status'),
                          connection: state.connectionState,
                        )
                      : projectedExternalActiveTurn != null
                      ? const _ExternalThreadActiveNotice(
                          key: ValueKey('codex-external-thread-active'),
                        )
                      : decisionPlan != null
                      ? _PlanDecisionPanel(
                          key: const ValueKey('codex-plan-decision'),
                          sending: state.sending,
                          controller: _planFeedback,
                          focusNode: _planFeedbackFocus,
                          onImplement: () => _implementPlan(decisionPlan),
                          onRevise: () => _revisePlan(decisionPlan),
                          onSkip: () => _skipPlan(decisionPlan),
                        )
                      : _Composer(
                          key: const ValueKey('codex-composer'),
                          state: state,
                          controller: _composer,
                          focusNode: _composerFocus,
                          voiceAvailable:
                              supportsDoubaoSpeechInput(
                                WidgetsBinding
                                    .instance
                                    .platformDispatcher
                                    .locale,
                              ) &&
                              widget.speechService?.isAvailable == true,
                          recording: _recording,
                          voiceBusy: _voiceBusy,
                          recordingDuration: _recordingDuration,
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
                          onCancelVoiceInput: _cancelVoiceInput,
                          onToggleVoiceInput: _toggleVoiceInput,
                          onSubmit: _submit,
                        ),
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
    try {
      final files = _isMobilePlatform
          ? await image_picker.ImagePicker().pickMultiImage(
              requestFullMetadata: false,
            )
          : await openFiles(acceptedTypeGroups: const [_imageTypes]);
      await _addFiles(files, CodexAttachmentKind.image);
    } catch (error) {
      if (mounted) showMotifToast(context, 'Could not select images: $error');
    }
  }

  Future<void> _pickFiles() async {
    try {
      final files = await openFiles();
      await _addFiles(files, CodexAttachmentKind.file);
    } catch (error) {
      if (mounted) showMotifToast(context, 'Could not select files: $error');
    }
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
    if (!accepted) {
      if (!mounted ||
          widget.state.sendFailureKind != CodexSendFailureKind.activeWriter) {
        return;
      }
      final fork = await _confirmForkAfterWriterConflict();
      if (!mounted || !fork) return;
      final resent = await widget.state.forkThreadAndSubmitMessage(
        text,
        attachments,
        references,
      );
      if (!resent) return;
      _clearBoundComposerDraft();
      if (!mounted) return;
    } else if (!mounted) {
      return;
    }
    _composer.clear();
    setState(() {
      _attachments = const [];
      _references = const [];
    });
    _composerFocus.unfocus();
    _showLatestContent();
  }

  Future<bool> _confirmForkAfterWriterConflict() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('codex-active-writer-dialog'),
        title: const Text('Continue in a new thread?'),
        content: const Text(
          'Another Codex session is already writing to this thread. '
          'Fork a new thread and resend your message there?',
        ),
        actions: [
          TextButton(
            key: const ValueKey('codex-active-writer-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('codex-active-writer-fork'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Fork and send'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  void _clearBoundComposerDraft() {
    final state = _draftState;
    final serverId = _draftServerId;
    final threadId = _draftThreadId;
    if (state == null || serverId == null || threadId == null) return;
    state.clearComposerDraft(serverId, threadId);
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
    _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  void _showLatestContent() {
    _followTail = true;
    _scheduleScrollToBottom();
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

  Future<void> _loadOlderTurns() async {
    final state = widget.state;
    if (state.loadingOlderTurns || !state.hasOlderTurns) return;
    _followTail = false;
    final beforeMaxExtent = _scroll.hasClients
        ? _scroll.position.maxScrollExtent
        : 0.0;
    final beforePixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    final threadId = state.selectedThread?.id;
    final loaded = await state.loadOlderTurns();
    if (!loaded || !mounted || state.selectedThread?.id != threadId) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final addedExtent = _scroll.position.maxScrollExtent - beforeMaxExtent;
      final target = (beforePixels + addedExtent).clamp(
        _scroll.position.minScrollExtent,
        _scroll.position.maxScrollExtent,
      );
      _scroll.jumpTo(target);
    });
  }

  bool _onUserScroll(ScrollNotification notification) {
    if (notification is UserScrollNotification) {
      switch (notification.direction) {
        case ScrollDirection.forward:
          // Pause immediately on any user-initiated upward movement. Waiting
          // until the viewport is 96 px from the tail lets a fast stream undo
          // short touch and trackpad gestures before they can accumulate.
          _followTail = false;
        case ScrollDirection.reverse:
          if (notification.metrics.pixels >=
              notification.metrics.maxScrollExtent - 96) {
            _followTail = true;
          }
        case ScrollDirection.idle:
          if (notification.metrics.pixels >=
              notification.metrics.maxScrollExtent - 1) {
            _followTail = true;
          }
      }
      if (notification.direction != ScrollDirection.idle &&
          notification.metrics.pixels <= 240) {
        unawaited(_loadOlderTurns());
      }
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
    required this.onLoadOlderTurns,
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
  final Future<void> Function() onLoadOlderTurns;
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
      if (state.loadingOlderTurns ||
          state.olderTurnsError != null ||
          state.hasOlderTurns)
        _OlderTurnsControl(
          loading: state.loadingOlderTurns,
          error: state.olderTurnsError,
          onLoad: onLoadOlderTurns,
          onRetry: onLoadOlderTurns,
        ),
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
                  final child = conversationChildren[index];
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

class _OlderTurnsControl extends StatelessWidget {
  const _OlderTurnsControl({
    required this.loading,
    required this.error,
    required this.onLoad,
    required this.onRetry,
  });

  final bool loading;
  final String? error;
  final Future<void> Function() onLoad;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return _InlineError(message: error!, onRetry: onRetry);
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(bottom: MotifSpacing.md),
        child: loading
            ? const SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : TextButton.icon(
                key: const ValueKey('codex-load-older-turns'),
                onPressed: () => unawaited(onLoad()),
                icon: const Icon(Icons.expand_less),
                label: const Text('Load earlier messages'),
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
      .where(_isFinalAnswerMessage)
      .lastOrNull;
  final activeForDisplay =
      turn.status == CodexTurnStatus.inProgress ||
      state.projectedExternalActiveTurn?.id == turn.id;
  var leadingEnd = 0;
  while (leadingEnd < items.length &&
      items[leadingEnd] is CodexUserMessageThreadItem) {
    leadingEnd++;
  }

  result.add(const SizedBox(height: MotifSpacing.md));

  if (activeForDisplay) {
    result.addAll(
      _turnContent(
        state,
        turn,
        items.take(leadingEnd),
        groupKeyPrefix: 'leading',
        activeForDisplay: false,
        onOpenFile: onOpenFile,
        onOpenImage: onOpenImage,
        onOpenTurnDiff: onOpenTurnDiff,
      ),
    );
    result.add(
      _WorkingStatus(key: ValueKey('codex-turn-status-${turn.id}'), turn: turn),
    );
    result.addAll(
      _turnContent(
        state,
        turn,
        items.skip(leadingEnd),
        activeForDisplay: true,
        onOpenFile: onOpenFile,
        onOpenImage: onOpenImage,
        onOpenTurnDiff: onOpenTurnDiff,
      ),
    );
  } else if (response == null) {
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
    if (turn.status == CodexTurnStatus.interrupted) {
      result.add(
        _TurnTimingStatus(
          key: ValueKey('codex-turn-status-${turn.id}'),
          label: _workedLabel(turn),
          turnId: turn.id,
        ),
      );
    }
  } else {
    var responseIndex = -1;
    for (var index = items.length - 1; index >= leadingEnd; index--) {
      final item = items[index];
      if (item is CodexAgentMessageThreadItem && _isFinalAnswerMessage(item)) {
        responseIndex = index;
        break;
      }
    }
    final historyEnd = responseIndex;
    final leading = items.take(leadingEnd).toList(growable: false);
    final history = items
        .skip(leadingEnd)
        .take(historyEnd - leadingEnd)
        .toList(growable: false);
    final hasExpandableHistory = history.any(_isExpandableHistoryItem);
    final responseItems = items.skip(responseIndex).toList(growable: false);
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
          onTap: hasExpandableHistory ? onToggleHistory : null,
        ),
      );
    if (history.isNotEmpty) {
      final collapsedItems = <CodexThreadItem>[];
      var collapsedGroup = 0;

      void flushCollapsedItems() {
        if (!collapsedItems.any(_isExpandableHistoryItem)) {
          collapsedItems.clear();
          return;
        }
        final group = collapsedGroup++;
        result.add(
          CodexMotionExpansion(
            key: ValueKey(
              group == 0
                  ? 'codex-worked-history-${turn.id}'
                  : 'codex-worked-history-${turn.id}-$group',
            ),
            expanded: historyExpanded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _turnContent(
                state,
                turn,
                List.of(collapsedItems),
                groupKeyPrefix: group == 0 ? 'history' : 'history-$group',
                boundedActivity: false,
                onOpenFile: onOpenFile,
                onOpenImage: onOpenImage,
                onOpenTurnDiff: onOpenTurnDiff,
              ),
            ),
          ),
        );
        collapsedItems.clear();
      }

      for (final item in history) {
        if (item is CodexUserMessageThreadItem) {
          flushCollapsedItems();
          result.addAll(
            _turnContent(
              state,
              turn,
              [item],
              groupKeyPrefix: 'history-user',
              onOpenFile: onOpenFile,
              onOpenImage: onOpenImage,
              onOpenTurnDiff: onOpenTurnDiff,
            ),
          );
        } else {
          collapsedItems.add(item);
        }
      }
      flushCollapsedItems();
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

List<Widget> _turnContent(
  CodexConversationState state,
  CodexTurn turn,
  Iterable<CodexThreadItem> items, {
  String groupKeyPrefix = 'active',
  bool boundedActivity = true,
  bool? activeForDisplay,
  CodexOpenFile? onOpenFile,
  CodexOpenImage? onOpenImage,
  CodexOpenTurnDiff? onOpenTurnDiff,
}) {
  final itemList = items.toList(growable: false);
  final isActive =
      activeForDisplay ?? turn.status == CodexTurnStatus.inProgress;
  final latestVisibleItem = itemList.lastOrNull;
  final result = <Widget>[];
  final activity = <CodexThreadItem>[];
  var groupIndex = 0;
  var bottomHasProgressOrAssistant = false;

  void flushActivity() {
    if (activity.isEmpty) return;
    final reasoningIsLatest =
        isActive &&
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
          showLatestItemTitle: isActive,
          processingLatestItem:
              isActive && identical(visibleActivity.last, latestVisibleItem),
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
      if (isActive) activity.add(item);
      continue;
    }
    if (item is CodexContextCompactionThreadItem) {
      flushActivity();
      result.add(
        Padding(
          padding: const EdgeInsets.only(bottom: _turnTopLevelItemSpacing),
          child: _ContextCompactionItem(state: state, item: item),
        ),
      );
      bottomHasProgressOrAssistant = true;
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
  if (isActive && !bottomHasProgressOrAssistant) {
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
  Widget build(BuildContext context) => CodexProcessingSweepText(
    'Thinking',
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
              AnimatedRotation(
                turns: expanded ? 0.25 : 0,
                duration: codexExpansionDuration(context),
                curve: codexExpansionCurve(context),
                child: Icon(
                  Icons.keyboard_arrow_right_rounded,
                  size: MotifIconSize.sm,
                  color: c.textTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _WorkingStatus extends StatefulWidget {
  const _WorkingStatus({required this.turn, super.key});

  final CodexTurn turn;

  @override
  State<_WorkingStatus> createState() => _WorkingStatusState();
}

class _WorkingStatusState extends State<_WorkingStatus>
    with WidgetsBindingObserver {
  Timer? _timer;
  late int _fallbackStartedAtMs;
  late int _elapsedMs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resetElapsed();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void didUpdateWidget(covariant _WorkingStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.turn.id != widget.turn.id ||
        oldWidget.turn.startedAt != widget.turn.startedAt) {
      _resetElapsed();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _syncWithWallClock();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  void _resetElapsed() {
    _fallbackStartedAtMs = DateTime.now().millisecondsSinceEpoch;
    _elapsedMs = _wallClockElapsed();
  }

  void _tick() {
    if (!mounted) return;
    final tickElapsed = _elapsedMs + const Duration(seconds: 1).inMilliseconds;
    final wallElapsed = _wallClockElapsed();
    setState(() {
      _elapsedMs = wallElapsed > tickElapsed ? wallElapsed : tickElapsed;
    });
  }

  void _syncWithWallClock() {
    if (!mounted) return;
    setState(() => _elapsedMs = _wallClockElapsed());
  }

  int _wallClockElapsed() {
    final startedAtMs = widget.turn.startedAt == null
        ? _fallbackStartedAtMs
        : _timestampMilliseconds(widget.turn.startedAt!);
    final elapsed = DateTime.now().millisecondsSinceEpoch - startedAtMs;
    return elapsed < 0 ? 0 : elapsed;
  }

  @override
  Widget build(BuildContext context) => _TurnTimingStatus(
    label: _durationLabel('Working for', _elapsedMs),
    turnId: widget.turn.id,
  );
}

class _TurnTimingStatus extends StatelessWidget {
  const _TurnTimingStatus({
    required this.label,
    required this.turnId,
    super.key,
  });

  final String label;
  final String turnId;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: MotifSpacing.sm),
      margin: const EdgeInsets.only(
        top: MotifSpacing.xl,
        bottom: MotifSpacing.md,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Text(
        label,
        key: ValueKey('codex-turn-time-$turnId'),
        style: MotifType.subhead.copyWith(color: c.textTertiary),
      ),
    );
  }
}

class _ContextCompactionItem extends StatelessWidget {
  const _ContextCompactionItem({required this.state, required this.item});

  final CodexConversationState state;
  final CodexContextCompactionThreadItem item;

  @override
  Widget build(BuildContext context) {
    return ObservationSelect<bool>(
      selector: () => state.itemViewModel(item).streaming,
      builder: (context, streaming, _) {
        final c = context.motif;
        final style = MotifType.subhead.copyWith(color: c.textSecondary);
        return Row(
          key: ValueKey('codex-context-compaction-${item.id}'),
          children: [
            Icon(
              Icons.compress_rounded,
              size: MotifIconSize.md,
              color: c.textTertiary,
            ),
            const SizedBox(width: MotifSpacing.sm),
            CodexMotionSwitcher(
              offset: const Offset(0, 0.12),
              child: streaming
                  ? CodexProcessingSweepText(
                      'Context compacting',
                      key: const ValueKey('compacting'),
                      style: style,
                    )
                  : Text(
                      'Context compacted',
                      key: const ValueKey('compacted'),
                      style: style,
                    ),
            ),
          ],
        );
      },
    );
  }
}

bool _isVisibleTextBoundary(CodexThreadItem item) => switch (item) {
  CodexUserMessageThreadItem() => true,
  CodexAgentMessageThreadItem value => value.text.trim().isNotEmpty,
  CodexPlanThreadItem value => value.text.trim().isNotEmpty,
  _ => false,
};

bool _isFinalAnswerMessage(CodexAgentMessageThreadItem item) =>
    item.text.trim().isNotEmpty && item.phase?.value == 'final_answer';

bool _isExpandableHistoryItem(CodexThreadItem item) => switch (item) {
  CodexUserMessageThreadItem() || CodexReasoningThreadItem() => false,
  CodexAgentMessageThreadItem value => value.text.trim().isNotEmpty,
  CodexPlanThreadItem value => value.text.trim().isNotEmpty,
  _ => true,
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
                      style: CodexType.body.copyWith(color: c.textSecondary),
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
                          ? CodexStreamingMarkdown(
                              plan.text,
                              key: ValueKey('codex-plan-preview-${plan.id}'),
                              style: CodexType.body.copyWith(
                                color: c.textPrimary,
                                height: 1.55,
                              ),
                            )
                          : CodexMarkdown(
                              plan.text,
                              key: ValueKey('codex-plan-preview-${plan.id}'),
                              style: CodexType.body.copyWith(
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
                  style: CodexType.body.copyWith(
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
    final hasMessage =
        parsed.text.isNotEmpty ||
        localImages.isNotEmpty ||
        remoteImages.isNotEmpty;
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (parsed.responseAnnotations.isNotEmpty) ...[
              _ResponseAnnotationsButton(
                messageId: item.id,
                annotations: parsed.responseAnnotations,
              ),
              if (hasMessage) const SizedBox(height: MotifSpacing.sm),
            ],
            if (hasMessage)
              DecoratedBox(
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
                                key: ValueKey(
                                  'codex-user-remote-image-${image.url}',
                                ),
                                onTap: onOpenImage == null
                                    ? null
                                    : () => onOpenImage!(image.url),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(
                                    MotifRadius.xs,
                                  ),
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
                          style: CodexType.body.copyWith(color: c.textPrimary),
                          onTapFileLink: onOpenFile == null
                              ? null
                              : (href) =>
                                    _openMarkdownFile(state, onOpenFile!, href),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResponseAnnotationsButton extends StatelessWidget {
  const _ResponseAnnotationsButton({
    required this.messageId,
    required this.annotations,
  });

  final String messageId;
  final List<CodexResponseAnnotation> annotations;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final label = _annotationCountLabel(annotations.length);
    return Tooltip(
      message: 'View $label',
      child: Material(
        color: c.surface,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: c.border),
          borderRadius: BorderRadius.circular(MotifRadius.pill),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('codex-user-annotations-$messageId'),
          onTap: () => unawaited(
            showAdaptiveModal<void>(
              context,
              builder: (_) =>
                  _ResponseAnnotationsModal(annotations: annotations),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MotifSpacing.md,
              vertical: MotifSpacing.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.speaker_notes_outlined,
                  size: MotifIconSize.sm,
                  color: c.textTertiary,
                ),
                const SizedBox(width: MotifSpacing.sm),
                Text(
                  label,
                  style: MotifType.body.copyWith(color: c.textPrimary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResponseAnnotationsModal extends StatelessWidget {
  const _ResponseAnnotationsModal({required this.annotations});

  final List<CodexResponseAnnotation> annotations;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return AdaptiveModal(
      key: const ValueKey('codex-response-annotations-modal'),
      title: _annotationCountLabel(annotations.length),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < annotations.length; index++) ...[
            if (index > 0) const SizedBox(height: MotifSpacing.xl),
            if (annotations.length > 1) ...[
              Text(
                'Annotation ${index + 1}',
                style: MotifType.headline.copyWith(color: c.textPrimary),
              ),
              const SizedBox(height: MotifSpacing.sm),
            ],
            _ResponseAnnotationCard(
              key: ValueKey('codex-response-annotation-$index'),
              annotation: annotations[index],
            ),
          ],
        ],
      ),
    );
  }
}

class _ResponseAnnotationCard extends StatelessWidget {
  const _ResponseAnnotationCard({required this.annotation, super.key});

  final CodexResponseAnnotation annotation;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'SELECTED RESPONSE',
          style: MotifType.overline.copyWith(color: c.textTertiary),
        ),
        const SizedBox(height: MotifSpacing.xs),
        Container(
          padding: const EdgeInsets.all(MotifSpacing.md),
          decoration: BoxDecoration(
            color: c.subtleFill,
            borderRadius: BorderRadius.circular(MotifRadius.sm),
          ),
          child: Text(
            annotation.text,
            style: CodexType.body.copyWith(color: c.textPrimary, height: 1.45),
          ),
        ),
        if (annotation.annotation case final comment?) ...[
          const SizedBox(height: MotifSpacing.lg),
          Text(
            'COMMENT',
            style: MotifType.overline.copyWith(color: c.textTertiary),
          ),
          const SizedBox(height: MotifSpacing.xs),
          Text(
            comment,
            style: CodexType.body.copyWith(color: c.textPrimary, height: 1.45),
          ),
        ],
      ],
    );
  }
}

String _annotationCountLabel(int count) =>
    '$count ${count == 1 ? 'annotation' : 'annotations'}';

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
    final style = CodexType.body.copyWith(color: c.textPrimary, height: 1.55);
    if (streaming) {
      return CodexStreamingMarkdown(
        visibleText,
        style: style,
        onTapFileLink: onOpenFile == null
            ? null
            : (href) => _openMarkdownFile(state, onOpenFile!, href),
        imageBuilder: (uri, _, _) => _CodexMarkdownImage(
          state: state,
          uri: uri,
          onOpenImage: onOpenImage,
        ),
      );
    }
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
    return Transform.translate(
      offset: const Offset(-(MotifControlSize.md - MotifIconSize.sm) / 2, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (response case final response?)
            IconButton(
              key: ValueKey('codex-copy-${response.id}'),
              tooltip: 'Copy response',
              visualDensity: VisualDensity.compact,
              iconSize: MotifIconSize.sm,
              style: context.iconButtonStyle(foregroundColor: c.textTertiary),
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
      ),
    );
  }
}

Widget _persistentForkAction(
  BuildContext context,
  CodexConversationState state,
  CodexTurn turn,
) {
  final c = context.motif;
  final forking = state.forkingTurnId == turn.id;
  return CodexMotionSwitcher(
    offset: Offset.zero,
    child: forking
        ? const Padding(
            key: ValueKey('codex-fork-loading'),
            padding: EdgeInsets.all(MotifSpacing.sm),
            child: SizedBox(
              width: MotifIconSize.sm,
              height: MotifIconSize.sm,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        : IconButton(
            key: ValueKey('codex-fork-${turn.id}'),
            tooltip: 'Fork from this turn',
            visualDensity: VisualDensity.compact,
            iconSize: MotifIconSize.sm,
            style: context.iconButtonStyle(foregroundColor: c.textTertiary),
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
    super.key,
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
                  style: CodexType.headline.copyWith(color: c.textPrimary),
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
                        style: CodexType.body.copyWith(color: c.textPrimary),
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
                  style: CodexType.body.copyWith(color: c.textPrimary),
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
  const _PlanChip({
    required this.plan,
    required this.diff,
    required this.onOpenDiff,
  });

  final CodexTurnPlanUpdatedNotification plan;
  final String? diff;
  final CodexOpenTurnDiff? onOpenDiff;

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
    final diffDocument = diff == null || diff!.isEmpty
        ? null
        : DiffDocument.fromUnifiedPatch(patch: diff!, summary: const []);
    return Padding(
      padding: const EdgeInsets.only(bottom: MotifSpacing.sm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: c.surfaceElevated,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(MotifRadius.pill),
          boxShadow: MotifElevation.card(c.shadow),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(MotifRadius.pill),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopupMenuButton<void>(
                key: const ValueKey('codex-plan-details'),
                tooltip: 'Show plan',
                offset: const Offset(0, -12),
                itemBuilder: (_) => [_planDetailsMenuItem(context)],
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    MotifSpacing.md,
                    MotifSpacing.sm,
                    MotifSpacing.sm,
                    MotifSpacing.sm,
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
                        style: MotifType.callout.copyWith(
                          color: c.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (stats.files > 0)
                InkWell(
                  key: const ValueKey('codex-plan-diff'),
                  onTap: diffDocument == null || onOpenDiff == null
                      ? null
                      : () => onOpenDiff!(diffDocument),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      MotifSpacing.sm,
                      MotifSpacing.sm,
                      MotifSpacing.md,
                      MotifSpacing.sm,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '·  ${stats.files} ${stats.files == 1 ? 'file' : 'files'} changed',
                        ),
                        Text(
                          ' +${stats.added}',
                          style: TextStyle(color: c.success),
                        ),
                        Text(
                          ' -${stats.removed}',
                          style: TextStyle(color: c.danger),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<void> _planDetailsMenuItem(BuildContext context) {
    final c = context.motif;
    return PopupMenuItem<void>(
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
                padding: const EdgeInsets.symmetric(vertical: MotifSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      switch (step.status) {
                        CodexTurnPlanStepStatus.completed => Icons.check_circle,
                        CodexTurnPlanStepStatus.inProgress =>
                          Icons.radio_button_checked,
                        CodexTurnPlanStepStatus.pending =>
                          Icons.radio_button_unchecked,
                      },
                      size: MotifIconSize.sm,
                      color: step.status == CodexTurnPlanStepStatus.completed
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
    super.key,
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
              style: CodexType.body.copyWith(color: c.textPrimary),
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

class _ExternalThreadActiveNotice extends StatelessWidget {
  const _ExternalThreadActiveNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return _ComposerStatusNotice(
      leading: Icon(
        Icons.devices_rounded,
        size: MotifIconSize.md,
        color: c.textSecondary,
      ),
      title: 'This thread is active elsewhere',
      description:
          'Motif will update it automatically. You can send a message '
          'when the other turn finishes.',
    );
  }
}

class _ConnectionStatusNotice extends StatelessWidget {
  const _ConnectionStatusNotice({required this.connection, super.key});

  final CodexConnectionState connection;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final reconnecting = connection.phase != CodexConnectionPhase.failed;
    final title = switch (connection.phase) {
      CodexConnectionPhase.connecting => 'Reconnecting to Codex',
      CodexConnectionPhase.initializing => 'Restoring Codex session',
      CodexConnectionPhase.failed => 'Connection lost',
      CodexConnectionPhase.connected => '',
    };
    final description = switch (connection.phase) {
      CodexConnectionPhase.connecting =>
        'Your conversation stays available while Motif restores the connection.',
      CodexConnectionPhase.initializing =>
        'Connected to the server. Finishing Codex setup…',
      CodexConnectionPhase.failed =>
        'Motif will reconnect automatically. Your conversation is still available.',
      CodexConnectionPhase.connected => '',
    };
    return _ComposerStatusNotice(
      leading: reconnecting
          ? SizedBox.square(
              dimension: MotifIconSize.md,
              child: CircularProgressIndicator(
                color: c.textSecondary,
                strokeWidth: 2,
              ),
            )
          : Icon(
              Icons.wifi_off_rounded,
              size: MotifIconSize.md,
              color: c.textSecondary,
            ),
      title: title,
      description: description,
    );
  }
}

class _ComposerStatusNotice extends StatelessWidget {
  const _ComposerStatusNotice({
    required this.leading,
    required this.title,
    required this.description,
  });

  final Widget leading;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      padding: const EdgeInsets.all(MotifSpacing.md),
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: c.borderStrong),
        borderRadius: BorderRadius.circular(MotifRadius.lg),
        boxShadow: MotifElevation.overlay(c.shadow),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          leading,
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: MotifType.subhead.copyWith(color: c.textPrimary),
                ),
                const SizedBox(height: MotifSpacing.xs),
                Text(
                  description,
                  style: MotifType.callout.copyWith(color: c.textSecondary),
                ),
              ],
            ),
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
    required this.voiceAvailable,
    required this.recording,
    required this.voiceBusy,
    required this.recordingDuration,
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
    required this.onCancelVoiceInput,
    required this.onToggleVoiceInput,
    required this.onSubmit,
    super.key,
  });

  final CodexConversationState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool voiceAvailable;
  final bool recording;
  final bool voiceBusy;
  final Duration recordingDuration;
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
  final Future<void> Function() onCancelVoiceInput;
  final Future<void> Function() onToggleVoiceInput;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final turnActive = state.activeTurn != null && !state.goalModeEnabled;
    return Container(
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
          CodexMotionSwitcher(
            animateSize: true,
            alignment: Alignment.topCenter,
            child: attachments.isEmpty
                ? const SizedBox.shrink(
                    key: ValueKey('codex-attachments-empty'),
                  )
                : Padding(
                    key: ValueKey(
                      'codex-attachments-${Object.hashAll(attachments)}',
                    ),
                    padding: const EdgeInsets.only(bottom: MotifSpacing.sm),
                    child: Wrap(
                      spacing: MotifSpacing.sm,
                      runSpacing: MotifSpacing.sm,
                      children: [
                        for (var index = 0; index < attachments.length; index++)
                          _PendingAttachment(
                            key: ValueKey(
                              'codex-attachment-${attachments[index].name}-$index',
                            ),
                            attachment: attachments[index],
                            onRemove: () => onRemoveAttachment(index),
                          ),
                      ],
                    ),
                  ),
          ),
          Shortcuts(
            shortcuts: {
              _ComposerSubmitActivator(controller): const _SubmitIntent(),
              const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                  const _InsertNewlineIntent(),
            },
            child: Actions(
              actions: {
                _SubmitIntent: CallbackAction<_SubmitIntent>(
                  onInvoke: (_) {
                    unawaited(onSubmit());
                    return null;
                  },
                ),
                _InsertNewlineIntent: CallbackAction<_InsertNewlineIntent>(
                  onInvoke: (_) {
                    _insertNewline(controller);
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
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => LayoutBuilder(
              builder: (context, constraints) {
                final stopActiveTurn = turnActive && value.text.trim().isEmpty;
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
                  key: ValueKey(stopActiveTurn ? 'codex-stop' : 'codex-send'),
                  tooltip: stopActiveTurn
                      ? 'Stop turn'
                      : state.goalModeEnabled
                      ? 'Save goal'
                      : 'Send',
                  onPressed: state.sending || state.goalLoading
                      ? null
                      : stopActiveTurn
                      ? state.interruptActiveTurn
                      : onSubmit,
                  style: context
                      .iconButtonStyle(
                        fixedSize: const Size.square(MotifControlSize.sm),
                        minimumSize: const Size.square(MotifControlSize.sm),
                      )
                      .copyWith(
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
                  icon: CodexMotionSwitcher(
                    offset: Offset.zero,
                    child: state.sending || state.goalLoading
                        ? const SizedBox.square(
                            key: ValueKey('codex-submit-loading'),
                            dimension: MotifIconSize.md,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            key: ValueKey(
                              stopActiveTurn ? 'stop-icon' : 'send-icon',
                            ),
                            stopActiveTurn
                                ? Icons.stop_rounded
                                : Icons.arrow_upward_rounded,
                          ),
                  ),
                );
                final voice = voiceAvailable && !recording
                    ? IconButton(
                        key: const ValueKey('codex-voice-input'),
                        tooltip: voiceBusy
                            ? 'Starting voice input'
                            : 'Voice input',
                        onPressed: voiceBusy
                            ? null
                            : () => unawaited(onToggleVoiceInput()),
                        style: context.iconButtonStyle(
                          foregroundColor: c.textPrimary,
                          backgroundColor: Colors.transparent,
                          fixedSize: const Size.square(MotifControlSize.sm),
                          minimumSize: const Size.square(MotifControlSize.sm),
                        ),
                        icon: voiceBusy
                            ? SizedBox.square(
                                dimension: MotifIconSize.md,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: c.textSecondary,
                                ),
                              )
                            : const Icon(Icons.mic_none_rounded),
                      )
                    : null;
                final recordingControls = recording
                    ? _VoiceRecordingControls(
                        duration: recordingDuration,
                        busy: voiceBusy,
                        onCancel: onCancelVoiceInput,
                        onConfirm: onToggleVoiceInput,
                      )
                    : null;
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
                      if (recordingControls != null)
                        recordingControls
                      else ...[
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * 0.46,
                          ),
                          child: _ModelSettingsSelector(state: state),
                        ),
                        const SizedBox(width: MotifSpacing.xs),
                        if (voice != null) ...[
                          voice,
                          const SizedBox(width: MotifSpacing.xs),
                        ],
                        send,
                      ],
                    ],
                  );
                }
                return Row(
                  children: [
                    add,
                    selections,
                    const Spacer(),
                    if (recordingControls != null)
                      recordingControls
                    else ...[
                      _ModelSettingsSelector(state: state),
                      const SizedBox(width: MotifSpacing.xs),
                      if (voice != null) ...[
                        voice,
                        const SizedBox(width: MotifSpacing.xs),
                      ],
                      send,
                    ],
                  ],
                );
              },
            ),
          ),
          CodexMotionPresence(
            visible: state.configurationError != null,
            child: CodexMarkdown(
              state.configurationError ?? '',
              style: MotifType.caption.copyWith(color: c.warning),
            ),
          ),
          CodexMotionPresence(
            visible: state.goalError != null,
            child: CodexMarkdown(
              state.goalError ?? '',
              style: MotifType.caption.copyWith(color: c.warning),
            ),
          ),
        ],
      ),
    );
  }
}

class _VoiceRecordingControls extends StatelessWidget {
  const _VoiceRecordingControls({
    required this.duration,
    required this.busy,
    required this.onCancel,
    required this.onConfirm,
  });

  final Duration duration;
  final bool busy;
  final Future<void> Function() onCancel;
  final Future<void> Function() onConfirm;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final minutes = duration.inMinutes.toString().padLeft(2, '0');
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$minutes:$seconds',
          key: const ValueKey('codex-voice-duration'),
          style: MotifType.mono.copyWith(color: c.textSecondary),
        ),
        const SizedBox(width: MotifSpacing.sm),
        IconButton(
          key: const ValueKey('codex-voice-cancel'),
          tooltip: 'Cancel voice input',
          onPressed: busy ? null : () => unawaited(onCancel()),
          style: context.iconButtonStyle(
            fixedSize: const Size.square(MotifControlSize.sm),
            minimumSize: const Size.square(MotifControlSize.sm),
          ),
          icon: const Icon(Icons.close_rounded),
        ),
        const SizedBox(width: MotifSpacing.xs),
        IconButton.filled(
          key: const ValueKey('codex-voice-input'),
          tooltip: busy ? 'Finishing voice input' : 'Finish voice input',
          onPressed: busy ? null : () => unawaited(onConfirm()),
          style: context
              .iconButtonStyle(
                fixedSize: const Size.square(MotifControlSize.sm),
                minimumSize: const Size.square(MotifControlSize.sm),
              )
              .copyWith(
                foregroundColor: WidgetStatePropertyAll(c.textOnAccent),
                backgroundColor: WidgetStatePropertyAll(c.accent),
                shape: const WidgetStatePropertyAll(CircleBorder()),
              ),
          icon: busy
              ? const SizedBox.square(
                  dimension: MotifIconSize.md,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
        ),
      ],
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
                  TextSpan(text: label, style: CodexType.body),
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
    final signature = Object.hash(
      compact,
      state.goal != null,
      state.goalModeEnabled,
      state.planModeEnabled,
      Object.hashAll(references.map((reference) => reference.path)),
    );
    return CodexMotionSwitcher(
      animateSize: true,
      alignment: Alignment.centerLeft,
      offset: Offset.zero,
      child: Row(
        key: ValueKey('codex-composer-selections-$signature'),
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
      ),
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
            style: CodexType.body.copyWith(
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
          Expanded(child: Text(label, style: CodexType.body)),
          Flexible(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: CodexType.body.copyWith(color: c.textTertiary),
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
          Expanded(child: Text(label, style: CodexType.body)),
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
  const _PendingAttachment({
    required this.attachment,
    required this.onRemove,
    super.key,
  });

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
                Text('Codex has a question', style: CodexType.headline),
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
                style: CodexType.body.copyWith(color: c.textPrimary),
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
                child: CodexMotionSwitcher(
                  animateSize: true,
                  offset: Offset.zero,
                  child: _submitting
                      ? const Row(
                          key: ValueKey('questionnaire-submitting'),
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox.square(
                              dimension: MotifIconSize.sm,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: MotifSpacing.sm),
                            Text('Submitting…'),
                          ],
                        )
                      : const Text(
                          'Submit answers',
                          key: ValueKey('questionnaire-submit'),
                        ),
                ),
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
  String? _submittingDecision;

  bool get _submitting => _submittingDecision != null;

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
                Expanded(child: Text(widget.title, style: CodexType.headline)),
              ],
            ),
            if (widget.reason?.trim().isNotEmpty == true) ...[
              const SizedBox(height: MotifSpacing.sm),
              CodexMarkdown(
                widget.reason!,
                style: CodexType.body.copyWith(color: c.textPrimary),
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
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 420;
                final style = compact
                    ? ButtonStyle(
                        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
                        padding: const WidgetStatePropertyAll(
                          EdgeInsets.symmetric(horizontal: MotifSpacing.xs),
                        ),
                      )
                    : null;
                final decline = TextButton(
                  style: style,
                  onPressed: _submitting ? null : () => _decide('decline'),
                  child: _actionChild('decline', 'Decline', compact: compact),
                );
                final session = OutlinedButton(
                  style: style,
                  onPressed: _submitting
                      ? null
                      : () => _decide('acceptForSession'),
                  child: _actionChild(
                    'acceptForSession',
                    'Allow for session',
                    compact: compact,
                  ),
                );
                final once = FilledButton(
                  style: style,
                  onPressed: _submitting ? null : () => _decide('accept'),
                  child: _actionChild('accept', 'Allow once', compact: compact),
                );
                if (!compact) {
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      decline,
                      const SizedBox(width: MotifSpacing.sm),
                      session,
                      const SizedBox(width: MotifSpacing.sm),
                      once,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(flex: 2, child: decline),
                    const SizedBox(width: MotifSpacing.xs),
                    Expanded(flex: 4, child: session),
                    const SizedBox(width: MotifSpacing.xs),
                    Expanded(flex: 3, child: once),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _actionChild(String decision, String label, {required bool compact}) {
    Widget text = Text(label, maxLines: 1, softWrap: false);
    if (compact) text = FittedBox(fit: BoxFit.scaleDown, child: text);
    final active = _submittingDecision == decision;
    return Stack(
      alignment: Alignment.center,
      children: [
        Opacity(opacity: active ? 0 : 1, child: text),
        if (active)
          const SizedBox.square(
            key: ValueKey('approval-submitting'),
            dimension: MotifIconSize.sm,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
  }

  Future<void> _decide(String decision) async {
    setState(() => _submittingDecision = decision);
    try {
      await widget.onDecision(decision);
    } finally {
      if (mounted) setState(() => _submittingDecision = null);
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

class _ComposerSubmitActivator extends ShortcutActivator {
  const _ComposerSubmitActivator(this.controller);

  static const _enter = SingleActivator(LogicalKeyboardKey.enter);

  final TextEditingController controller;

  @override
  Iterable<LogicalKeyboardKey> get triggers => _enter.triggers;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    final composing = controller.value.composing;
    if (composing.isValid && !composing.isCollapsed) return false;
    return _enter.accepts(event, state);
  }

  @override
  String debugDescribeKeys() => _enter.debugDescribeKeys();
}

class _SubmitIntent extends Intent {
  const _SubmitIntent();
}

class _InsertNewlineIntent extends Intent {
  const _InsertNewlineIntent();
}

void _insertNewline(TextEditingController controller) {
  final value = controller.value;
  final selection = value.selection;
  final range = selection.isValid
      ? TextRange(start: selection.start, end: selection.end)
      : TextRange.collapsed(value.text.length);
  controller.value = value.copyWith(
    text: value.text.replaceRange(range.start, range.end, '\n'),
    selection: TextSelection.collapsed(offset: range.start + 1),
    composing: TextRange.empty,
  );
}

String _workedLabel(CodexTurn turn) {
  final prefix = switch (turn.status) {
    CodexTurnStatus.interrupted => 'Stopped after',
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
      CodexTurnStatus.interrupted => 'Stopped',
      CodexTurnStatus.failed => 'Failed',
      _ => 'Worked',
    };
  }
  return _durationLabel(prefix, duration);
}

String _durationLabel(String prefix, int durationMs) {
  final seconds = (durationMs < 0 ? 0 : durationMs) ~/ 1000;
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
