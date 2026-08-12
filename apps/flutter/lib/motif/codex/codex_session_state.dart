import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'codex_connection_controller.dart';
import 'codex_composer_models.dart';
import 'codex_thread_catalog.dart';
import 'protocol/generated/codex_app_server_protocol.dart';

enum CodexCatalogPhase { idle, loading, ready, failed }

/// Runtime state for exactly one Motif Codex session.
final class CodexSessionState extends ChangeNotifier {
  CodexSessionState({
    required this.serverId,
    required this.session,
    required this.connection,
  }) {
    connection.addListener(_onConnectionChanged);
    _typedSubscription = connection.typedMessages.listen(
      _onTypedMessage,
      onError: (_) {},
    );
  }

  static const String globalStateWatchId = 'motif-codex-global-state-sidebar';

  final String serverId;
  final String session;
  final CodexAppServerClient connection;

  CodexCatalogPhase catalogPhase = CodexCatalogPhase.idle;
  String? catalogError;
  CodexCatalogSnapshot catalog = const CodexCatalogSnapshot.empty();
  CodexThread? selectedThread;
  String? readingThreadId;
  String? readError;
  String? forkingTurnId;
  String? forkError;
  String? creatingProjectId;
  String? createThreadError;
  List<CodexTurn> turns = const [];
  List<CodexModel> models = const [];
  List<CodexPermissionProfileSummary> permissionProfiles = const [];
  List<CodexCollaborationModeMask> collaborationModes = const [];
  List<CodexSkillMetadata> skills = const [];
  List<CodexPluginSummary> plugins = const [];
  String? selectedModelId;
  String? selectedReasoningEffort;
  String? selectedPermissionId;
  bool planModeEnabled = false;
  String? configurationError;
  CodexThreadGoal? goal;
  bool goalLoading = false;
  String? goalError;
  bool sending = false;
  String? sendError;
  CodexTurnPlanUpdatedNotification? activePlan;
  String? activeDiff;
  bool queueMessagesWhileActive = true;
  List<CodexQueuedMessage> queuedMessages = const [];
  List<CodexServerRequest> pendingServerRequests = const [];

  final Map<String, CodexThread> _threads = {};
  final Map<String, CodexThread> _resumedThreads = {};
  final Map<String, Future<CodexThread>> _pendingThreadResumes = {};
  final Map<String, CodexServerRequest> _serverRequests = {};
  final Map<String, Future<Uint8List>> _remoteFileCache = {};
  late final StreamSubscription<CodexJsonEncodable> _typedSubscription;
  CodexGlobalStateData? _globalState;
  CodexInitializeResponse? _loadedInitializeResponse;
  Timer? _globalStateDebounce;
  bool _watchingGlobalState = false;
  int _refreshGeneration = 0;
  int _queueSequence = 0;
  int _attachmentSequence = 0;
  bool _closed = false;
  bool _attachmentDirectoryReady = false;
  bool _drainingQueue = false;
  bool _modelSelectionTouched = false;
  bool _effortSelectionTouched = false;
  bool _permissionSelectionTouched = false;
  String? _failedReadThreadId;

  CodexConnectionState get connectionState => connection.state;

  CodexTurn? get activeTurn {
    for (final turn in turns.reversed) {
      if (turn.status == CodexTurnStatus.inProgress) return turn;
    }
    return null;
  }

  CodexModel? get selectedModel {
    final id = selectedModelId;
    if (id == null) return null;
    for (final model in models) {
      if (model.id == id) return model;
    }
    return null;
  }

  List<CodexReasoningEffortOption> get supportedReasoningEfforts =>
      selectedModel?.supportedReasoningEfforts ?? const [];

  Future<void> start() => connection.start();

  Future<void> retryConnection() async {
    catalogError = null;
    catalogPhase = CodexCatalogPhase.idle;
    _loadedInitializeResponse = null;
    _watchingGlobalState = false;
    _notify();
    await connection.retry();
  }

  Future<void> retryCatalog() => refreshCatalog(showLoading: true);

  Future<void> refreshCatalog({bool showLoading = true}) async {
    final response = connection.state.response;
    if (_closed ||
        connection.state.phase != CodexConnectionPhase.connected ||
        response == null) {
      return;
    }
    final generation = ++_refreshGeneration;
    if (showLoading || _threads.isEmpty) {
      catalogPhase = CodexCatalogPhase.loading;
      catalogError = null;
      _notify();
    }

    final path = _joinCodexPath(
      response.codexHome.value,
      '.codex-global-state.json',
    );
    final globalFuture = _readGlobalState(path);
    try {
      final loadedThreads = await _loadAllThreads();
      final globalState = await globalFuture;
      if (_closed || generation != _refreshGeneration) return;
      _threads
        ..clear()
        ..addEntries(
          loadedThreads
              .where((thread) => !thread.ephemeral)
              .map((thread) => MapEntry(thread.id, thread)),
        );
      _globalState = globalState;
      _rebuildCatalog();
      catalogPhase = CodexCatalogPhase.ready;
      catalogError = null;
      _syncSelectedThread();
      _notify();
      if (globalState != null) unawaited(_ensureGlobalStateWatch(path));
    } catch (error) {
      if (_closed || generation != _refreshGeneration) return;
      catalogPhase = CodexCatalogPhase.failed;
      catalogError = '$error';
      _notify();
    }
  }

  /// Reads persisted history for display without loading or subscribing to it.
  Future<void> readThread(String threadId) async {
    if (_closed || readingThreadId != null) return;
    final changingSelection = selectedThread?.id != threadId;
    readingThreadId = threadId;
    _failedReadThreadId = null;
    readError = null;
    _notify();
    try {
      final response = await connection.readThread(
        threadId,
        includeTurns: true,
      );
      if (_closed) return;
      _threads[response.thread.id] = response.thread;
      selectedThread = response.thread;
      turns = response.thread.turns;
      activePlan = null;
      activeDiff = null;
      sendError = null;
      if (changingSelection) queuedMessages = const [];
      _serverRequests.clear();
      pendingServerRequests = const [];
      _rebuildCatalog();
      _notify();
      unawaited(_loadThreadConfiguration(response.thread));
    } catch (error) {
      if (_closed) return;
      _failedReadThreadId = threadId;
      readError = '$error';
    } finally {
      if (!_closed) {
        readingThreadId = null;
        _notify();
      }
    }
  }

  Future<void> retryRead() async {
    final threadId = _failedReadThreadId;
    if (threadId != null) await readThread(threadId);
  }

  /// Starts and opens a new thread rooted in [project].
  Future<bool> createThreadForProject(CodexLocalProject project) async {
    if (_closed || creatingProjectId != null) return false;
    creatingProjectId = project.id;
    createThreadError = null;
    _notify();
    try {
      final response = await connection.startThread(
        CodexThreadStartParams(
          cwd: project.rootPaths.firstOrNull,
          model: selectedModel?.model,
          permissions: selectedPermissionId,
        ),
      );
      if (_closed) return false;
      final thread = response.thread;
      _threads[thread.id] = thread;
      _resumedThreads[thread.id] = thread;
      _assignThreadToProject(thread, project);
      selectedThread = thread;
      turns = thread.turns;
      readingThreadId = null;
      readError = null;
      _failedReadThreadId = null;
      goal = null;
      goalError = null;
      activePlan = null;
      activeDiff = null;
      sendError = null;
      queuedMessages = const [];
      _serverRequests.clear();
      pendingServerRequests = const [];
      if (!_modelSelectionTouched) {
        selectedModelId = models
            .where(
              (candidate) =>
                  candidate.model == response.model ||
                  candidate.id == response.model,
            )
            .firstOrNull
            ?.id;
      }
      if (!_effortSelectionTouched) {
        selectedReasoningEffort = response.reasoningEffort?.value;
      }
      if (!_permissionSelectionTouched) {
        selectedPermissionId = response.activePermissionProfile?.id;
      }
      _rebuildCatalog();
      _notify();
      unawaited(_loadThreadConfiguration(thread));
      return true;
    } catch (error) {
      if (!_closed) createThreadError = '$error';
      return false;
    } finally {
      if (!_closed && creatingProjectId == project.id) {
        creatingProjectId = null;
        _notify();
      }
    }
  }

  void clearCreateThreadError() {
    if (createThreadError == null) return;
    createThreadError = null;
    _notify();
  }

  /// Forks the selected thread through [lastTurnId], then opens the new
  /// in-memory thread returned by app-server.
  Future<bool> forkThreadAtTurn(String lastTurnId) async {
    final source = selectedThread;
    if (_closed || source == null || forkingTurnId != null) return false;
    final turn = turns
        .where((candidate) => candidate.id == lastTurnId)
        .firstOrNull;
    if (turn?.status == CodexTurnStatus.inProgress) {
      forkError = 'Wait for this turn to finish before forking it.';
      _notify();
      return false;
    }

    forkingTurnId = lastTurnId;
    forkError = null;
    _notify();
    try {
      final response = await connection.forkThread(
        CodexThreadForkParams(threadId: source.id, lastTurnId: lastTurnId),
      );
      if (_closed) return false;
      final thread = response.thread;
      _threads[thread.id] = thread;
      _resumedThreads[thread.id] = thread;
      selectedThread = thread;
      turns = thread.turns;
      readingThreadId = null;
      readError = null;
      _failedReadThreadId = null;
      goal = null;
      goalError = null;
      activePlan = null;
      activeDiff = null;
      sendError = null;
      queuedMessages = const [];
      _serverRequests.clear();
      pendingServerRequests = const [];
      if (!_modelSelectionTouched) {
        selectedModelId = models
            .where(
              (candidate) =>
                  candidate.model == response.model ||
                  candidate.id == response.model,
            )
            .firstOrNull
            ?.id;
      }
      if (!_effortSelectionTouched) {
        selectedReasoningEffort = response.reasoningEffort?.value;
      }
      if (!_permissionSelectionTouched) {
        selectedPermissionId = response.activePermissionProfile?.id;
      }
      _rebuildCatalog();
      _notify();
      unawaited(_loadThreadConfiguration(thread));
      return true;
    } catch (error) {
      if (!_closed) forkError = '$error';
      return false;
    } finally {
      if (!_closed && forkingTurnId == lastTurnId) {
        forkingTurnId = null;
        _notify();
      }
    }
  }

  void selectModel(String modelId) {
    if (selectedModelId == modelId) return;
    _modelSelectionTouched = true;
    _effortSelectionTouched = true;
    selectedModelId = modelId;
    final model = selectedModel;
    selectedReasoningEffort = model?.defaultReasoningEffort.value;
    _notify();
  }

  void selectReasoningEffort(String effort) {
    if (selectedReasoningEffort == effort) return;
    _effortSelectionTouched = true;
    selectedReasoningEffort = effort;
    _notify();
  }

  void selectPermissionProfile(String? profileId) {
    if (selectedPermissionId == profileId) return;
    _permissionSelectionTouched = true;
    selectedPermissionId = profileId;
    _notify();
  }

  void setPlanMode(bool enabled) {
    if (planModeEnabled == enabled) return;
    planModeEnabled = enabled;
    _notify();
  }

  void setQueueing(bool enabled) {
    if (queueMessagesWhileActive == enabled) return;
    queueMessagesWhileActive = enabled;
    _notify();
  }

  Future<void> _loadThreadConfiguration(CodexThread thread) async {
    await Future.wait([
      _loadPermissionProfiles(thread),
      _loadGoal(thread.id),
      _loadSkills(thread),
      _loadPlugins(thread),
    ]);
  }

  Future<void> _loadCollaborationModes() async {
    try {
      final response = await connection.listCollaborationModes();
      if (_closed) return;
      collaborationModes = List.unmodifiable(response.data);
      _notify();
    } catch (_) {
      if (_closed) return;
      collaborationModes = const [];
      _notify();
    }
  }

  Future<void> _loadSkills(CodexThread thread) async {
    final cwd = thread.cwd.value.trim();
    try {
      final response = await connection.listSkills(
        CodexSkillsListParams(cwds: cwd.isEmpty ? null : [cwd]),
      );
      if (_closed || selectedThread?.id != thread.id) return;
      final entries = cwd.isEmpty
          ? response.data
          : response.data.where((entry) => entry.cwd == cwd);
      skills = List.unmodifiable(
        entries
            .expand((entry) => entry.skills)
            .where((skill) => skill.enabled)
            .fold(<String, CodexSkillMetadata>{}, (values, skill) {
              values[skill.path.value] = skill;
              return values;
            })
            .values,
      );
      _notify();
    } catch (_) {
      if (_closed || selectedThread?.id != thread.id) return;
      skills = const [];
      _notify();
    }
  }

  Future<void> _loadPlugins(CodexThread thread) async {
    final cwd = thread.cwd.value.trim();
    try {
      final response = await connection.listPlugins(
        CodexPluginListParams(
          cwds: cwd.isEmpty ? null : [CodexV2AbsolutePathBuf(cwd)],
        ),
      );
      if (_closed || selectedThread?.id != thread.id) return;
      plugins = List.unmodifiable(
        response.marketplaces
            .expand((marketplace) => marketplace.plugins)
            .where((plugin) => plugin.enabled && plugin.installed)
            .fold(<String, CodexPluginSummary>{}, (values, plugin) {
              values[plugin.id] = plugin;
              return values;
            })
            .values,
      );
      _notify();
    } catch (_) {
      if (_closed || selectedThread?.id != thread.id) return;
      plugins = const [];
      _notify();
    }
  }

  Future<void> _loadModels() async {
    final loaded = <CodexModel>[];
    final cursors = <String>{};
    String? cursor;
    try {
      while (true) {
        final response = await connection.listModels(
          CodexModelListParams(
            cursor: cursor,
            includeHidden: false,
            limit: 100,
          ),
        );
        loaded.addAll(response.data.where((model) => !model.hidden));
        final next = response.nextCursor;
        if (next == null || next.isEmpty || !cursors.add(next)) break;
        cursor = next;
      }
      if (_closed) return;
      models = List.unmodifiable(loaded);
      if (selectedModelId == null || selectedModel == null) {
        final preferred = loaded.where((model) => model.isDefault).firstOrNull;
        final model = preferred ?? loaded.firstOrNull;
        selectedModelId = model?.id;
        selectedReasoningEffort = model?.defaultReasoningEffort.value;
      }
      configurationError = null;
      _notify();
    } catch (error) {
      if (_closed) return;
      configurationError = 'Could not load models: $error';
      _notify();
    }
  }

  Future<void> _loadPermissionProfiles(CodexThread thread) async {
    final loaded = <CodexPermissionProfileSummary>[];
    final cursors = <String>{};
    String? cursor;
    try {
      while (true) {
        final cwd = thread.cwd.value.trim();
        final response = await connection.listPermissionProfiles(
          CodexPermissionProfileListParams(
            cursor: cursor,
            cwd: cwd.isEmpty ? null : cwd,
            limit: 100,
          ),
        );
        loaded.addAll(response.data);
        final next = response.nextCursor;
        if (next == null || next.isEmpty || !cursors.add(next)) break;
        cursor = next;
      }
      if (_closed || selectedThread?.id != thread.id) return;
      permissionProfiles = List.unmodifiable(loaded);
      if (selectedPermissionId != null &&
          !loaded.any(
            (profile) => profile.id == selectedPermissionId && profile.allowed,
          )) {
        selectedPermissionId = null;
      }
      _notify();
    } catch (error) {
      if (_closed || selectedThread?.id != thread.id) return;
      permissionProfiles = const [];
      configurationError = 'Could not load permission profiles: $error';
      _notify();
    }
  }

  Future<void> _loadGoal(String threadId) async {
    goalLoading = true;
    goalError = null;
    _notify();
    try {
      final response = await connection.getThreadGoal(threadId);
      if (_closed || selectedThread?.id != threadId) return;
      goal = response.goal;
    } catch (error) {
      if (_closed || selectedThread?.id != threadId) return;
      goalError = '$error';
    } finally {
      if (!_closed && selectedThread?.id == threadId) {
        goalLoading = false;
        _notify();
      }
    }
  }

  Future<void> saveGoal({
    required String objective,
    int? tokenBudget,
    CodexThreadGoalStatus status = CodexThreadGoalStatus.active,
  }) async {
    final threadId = selectedThread?.id;
    if (threadId == null || goalLoading) return;
    goalLoading = true;
    goalError = null;
    _notify();
    try {
      final response = await connection.setThreadGoal(
        CodexThreadGoalSetParams(
          threadId: threadId,
          objective: objective.trim(),
          status: status,
          tokenBudget: tokenBudget,
        ),
      );
      if (!_closed && selectedThread?.id == threadId) goal = response.goal;
    } catch (error) {
      if (!_closed && selectedThread?.id == threadId) goalError = '$error';
    } finally {
      if (!_closed && selectedThread?.id == threadId) {
        goalLoading = false;
        _notify();
      }
    }
  }

  Future<void> clearGoal() async {
    final threadId = selectedThread?.id;
    if (threadId == null || goalLoading) return;
    goalLoading = true;
    goalError = null;
    _notify();
    try {
      await connection.clearThreadGoal(threadId);
      if (!_closed && selectedThread?.id == threadId) goal = null;
    } catch (error) {
      if (!_closed && selectedThread?.id == threadId) goalError = '$error';
    } finally {
      if (!_closed && selectedThread?.id == threadId) {
        goalLoading = false;
        _notify();
      }
    }
  }

  Future<bool> submitMessage(
    String text,
    List<CodexPendingAttachment> attachments, [
    List<CodexComposerReference> references = const [],
  ]) async {
    if (text.trim().isEmpty && attachments.isEmpty && references.isEmpty) {
      return false;
    }
    final message = CodexQueuedMessage(
      id: 'queued-${++_queueSequence}',
      text: text,
      attachments: List.unmodifiable(attachments),
      references: List.unmodifiable(references),
    );
    if (activeTurn != null && queueMessagesWhileActive) {
      try {
        await ensureThreadResumedForSend(selectedThread!.id);
      } catch (error) {
        sendError = '$error';
        _notify();
        return false;
      }
      queuedMessages = List.unmodifiable([...queuedMessages, message]);
      _notify();
      return true;
    }
    return _sendMessageNow(message, steer: activeTurn != null);
  }

  Future<bool> steerQueuedMessage(String messageId) async {
    final message = queuedMessages
        .where((candidate) => candidate.id == messageId)
        .firstOrNull;
    if (message == null || activeTurn == null) return false;
    final sent = await _sendMessageNow(message, steer: true);
    if (sent) deleteQueuedMessage(messageId);
    return sent;
  }

  CodexQueuedMessage? takeQueuedMessage(String messageId) {
    final message = queuedMessages
        .where((candidate) => candidate.id == messageId)
        .firstOrNull;
    if (message != null) deleteQueuedMessage(messageId);
    return message;
  }

  void deleteQueuedMessage(String messageId) {
    final updated = queuedMessages
        .where((message) => message.id != messageId)
        .toList(growable: false);
    if (updated.length == queuedMessages.length) return;
    queuedMessages = updated;
    _notify();
  }

  Future<bool> _sendMessageNow(
    CodexQueuedMessage message, {
    required bool steer,
  }) async {
    final thread = selectedThread;
    if (_closed || thread == null || sending) return false;
    sending = true;
    sendError = null;
    _notify();
    try {
      final input = await _prepareInputs(message);
      await ensureThreadResumedForSend(thread.id);
      final active = activeTurn;
      if (steer && active != null) {
        await connection.steerTurn(
          CodexTurnSteerParams(
            expectedTurnId: active.id,
            input: input,
            threadId: thread.id,
          ),
        );
      } else {
        final response = await connection.startTurn(
          CodexTurnStartParams(
            threadId: thread.id,
            input: input,
            model: selectedModel?.model,
            effort: selectedReasoningEffort == null
                ? null
                : CodexReasoningEffort(selectedReasoningEffort!),
            permissions: selectedPermissionId,
            collaborationMode: _collaborationMode(),
          ),
        );
        _upsertTurn(response.turn);
      }
      return true;
    } catch (error) {
      if (!_closed) sendError = '$error';
      return false;
    } finally {
      if (!_closed) {
        sending = false;
        _notify();
      }
    }
  }

  Future<List<CodexUserInput>> _prepareInputs(
    CodexQueuedMessage message,
  ) async {
    final inputs = <CodexUserInput>[];
    for (final reference in message.references) {
      inputs.add(switch (reference.kind) {
        CodexComposerReferenceKind.skill => CodexSkillUserInput(
          name: reference.name,
          path: reference.path,
        ),
        CodexComposerReferenceKind.plugin => CodexMentionUserInput(
          name: reference.name,
          path: reference.path,
        ),
      });
    }
    final filePaths = <String>[];
    for (final attachment in message.attachments) {
      final remotePath = await _uploadAttachment(attachment);
      if (attachment.isImage) {
        inputs.add(CodexLocalImageUserInput(path: remotePath));
      } else {
        filePaths.add(remotePath);
      }
    }
    final sections = <String>[];
    final text = message.text.trim();
    if (text.isNotEmpty) sections.add(text);
    if (filePaths.isNotEmpty) {
      sections.add(
        'Attached files:\n${filePaths.map((path) => '- $path').join('\n')}',
      );
    }
    if (sections.isNotEmpty) {
      inputs.insert(0, CodexTextUserInput(text: sections.join('\n\n')));
    }
    return inputs;
  }

  CodexCollaborationMode? _collaborationMode() {
    if (!planModeEnabled) return null;
    final mask = collaborationModes
        .where((candidate) => candidate.mode == CodexModeKind.plan)
        .firstOrNull;
    final model = mask?.model ?? selectedModel?.model ?? selectedModelId;
    if (model == null || model.isEmpty) return null;
    final maskEffort = mask?.reasoningEffort;
    return CodexCollaborationMode(
      mode: CodexModeKind.plan,
      settings: CodexSettings(
        model: model,
        reasoningEffort: maskEffort is CodexReasoningEffort
            ? maskEffort
            : selectedReasoningEffort == null
            ? null
            : CodexReasoningEffort(selectedReasoningEffort!),
      ),
    );
  }

  Future<String> _uploadAttachment(CodexPendingAttachment attachment) async {
    final initialize = connection.state.response;
    if (initialize == null) throw StateError('Codex is not initialized');
    final root = _joinCodexPath(
      initialize.codexHome.value,
      '.motif-attachments',
    );
    if (!_attachmentDirectoryReady) {
      await connection.createDirectory(root);
      _attachmentDirectoryReady = true;
    }
    final name = _safeAttachmentName(attachment.name);
    final path = _joinCodexPath(
      root,
      '${DateTime.now().microsecondsSinceEpoch}-${++_attachmentSequence}-$name',
    );
    await connection.writeFile(path, base64Encode(attachment.bytes));
    return path;
  }

  Future<Uint8List> readRemoteFile(String path) =>
      _remoteFileCache.putIfAbsent(path, () async {
        final response = await connection.readFile(path);
        return base64Decode(response.dataBase64);
      });

  Future<void> interruptActiveTurn() async {
    final threadId = selectedThread?.id;
    final turn = activeTurn;
    if (threadId == null || turn == null) return;
    try {
      await connection.interruptTurn(threadId, turn.id);
    } catch (error) {
      sendError = '$error';
      _notify();
    }
  }

  Future<void> answerQuestionnaire(
    CodexItemToolRequestUserInputRequest request,
    Map<String, List<String>> answers,
  ) async {
    await connection.respondToServerRequest(
      request.id,
      CodexToolRequestUserInputResponse(
        answers: answers.map(
          (id, values) =>
              MapEntry(id, CodexToolRequestUserInputAnswer(answers: values)),
        ),
      ),
    );
    _removeServerRequest(request.id);
  }

  Future<void> answerCommandApproval(
    CodexItemCommandExecutionRequestApprovalRequest request,
    Object decision,
  ) async {
    await connection.respondToServerRequest(
      request.id,
      CodexCommandExecutionRequestApprovalResponse(
        decision: CodexCommandExecutionApprovalDecision(decision),
      ),
    );
    _removeServerRequest(request.id);
  }

  Future<void> answerFileApproval(
    CodexItemFileChangeRequestApprovalRequest request,
    Object decision,
  ) async {
    await connection.respondToServerRequest(
      request.id,
      CodexFileChangeRequestApprovalResponse(
        decision: CodexFileChangeApprovalDecision(decision),
      ),
    );
    _removeServerRequest(request.id);
  }

  Future<void> answerPermissionsApproval(
    CodexItemPermissionsRequestApprovalRequest request, {
    required bool allow,
    required CodexPermissionGrantScope scope,
  }) async {
    await connection.respondToServerRequest(
      request.id,
      CodexPermissionsRequestApprovalResponse(
        permissions: allow
            ? CodexGrantedPermissionProfile.fromJson(
                request.params.permissions.toJson(),
              )
            : const CodexGrantedPermissionProfile(),
        scope: scope,
      ),
    );
    _removeServerRequest(request.id);
  }

  /// Lazily resumes a thread for the future message-send path.
  ///
  /// Repeated or concurrent sends on the same connection share the first
  /// resume. A reconnect clears this cache because subscriptions belong to the
  /// app-server connection that performed the resume.
  Future<CodexThread> ensureThreadResumedForSend(String threadId) {
    if (_closed) {
      return Future<CodexThread>.error(
        StateError('Codex session state is closed'),
      );
    }
    final resumed = _resumedThreads[threadId];
    if (resumed != null) return Future<CodexThread>.value(resumed);
    return _pendingThreadResumes.putIfAbsent(
      threadId,
      () => _resumeThreadForSend(threadId),
    );
  }

  Future<CodexThread> _resumeThreadForSend(String threadId) async {
    try {
      final response = await connection.resumeThread(threadId);
      if (_closed) throw StateError('Codex session state is closed');
      final thread = response.thread;
      if (!_modelSelectionTouched) {
        selectedModelId = models
            .where(
              (candidate) =>
                  candidate.model == response.model ||
                  candidate.id == response.model,
            )
            .firstOrNull
            ?.id;
      }
      if (!_effortSelectionTouched) {
        selectedReasoningEffort = response.reasoningEffort?.value;
      }
      if (!_permissionSelectionTouched) {
        selectedPermissionId = response.activePermissionProfile?.id;
      }
      _resumedThreads[thread.id] = thread;
      _threads[thread.id] = thread;
      if (selectedThread?.id == thread.id) selectedThread = thread;
      _rebuildCatalog();
      _notify();
      return thread;
    } finally {
      _pendingThreadResumes.remove(threadId);
    }
  }

  Future<List<CodexThread>> _loadAllThreads() async {
    final threads = <CodexThread>[];
    final seenCursors = <String>{};
    String? cursor;
    while (true) {
      final response = await connection.listThreads(
        CodexThreadListParams(
          archived: false,
          cursor: cursor,
          limit: 100,
          sortDirection: CodexSortDirection.desc,
          sortKey: CodexThreadSortKey.recencyAt,
        ),
      );
      threads.addAll(response.data);
      final next = response.nextCursor;
      if (next == null || next.isEmpty || !seenCursors.add(next)) break;
      cursor = next;
    }
    return threads;
  }

  Future<CodexGlobalStateData?> _readGlobalState(String path) async {
    try {
      final response = await connection.readFile(path);
      final bytes = base64Decode(response.dataBase64);
      return CodexGlobalStateData.tryParse(
        utf8.decode(bytes, allowMalformed: true),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureGlobalStateWatch(String path) async {
    if (_closed || _watchingGlobalState) return;
    try {
      await connection.watchFile(path, globalStateWatchId);
      if (!_closed) _watchingGlobalState = true;
    } catch (_) {
      // The catalog remains usable when the private state file cannot be
      // watched (for example on an older app-server).
    }
  }

  void _onConnectionChanged() {
    if (_closed) return;
    final state = connection.state;
    if (state.phase != CodexConnectionPhase.connected) {
      _loadedInitializeResponse = null;
      _watchingGlobalState = false;
      _resumedThreads.clear();
      _pendingThreadResumes.clear();
      _serverRequests.clear();
      pendingServerRequests = const [];
      activePlan = null;
      activeDiff = null;
      _attachmentDirectoryReady = false;
      _remoteFileCache.clear();
      _notify();
      return;
    }
    final response = state.response;
    if (response != null && !identical(response, _loadedInitializeResponse)) {
      _resumedThreads.clear();
      _pendingThreadResumes.clear();
      _loadedInitializeResponse = response;
      unawaited(_loadModels());
      unawaited(_loadCollaborationModes());
      unawaited(refreshCatalog(showLoading: true));
    }
    _notify();
  }

  void _onTypedMessage(CodexJsonEncodable message) {
    if (_closed) return;
    switch (message) {
      case CodexThreadStartedNotification2(:final params):
        if (!params.thread.ephemeral) {
          _threads[params.thread.id] = params.thread;
        }
      case CodexThreadStatusChangedNotification2(:final params):
        final current = _threads[params.threadId];
        if (current != null) {
          _threads[params.threadId] = codexThreadWithStatus(
            current,
            params.status,
          );
        }
      case CodexThreadNameUpdatedNotification2(:final params):
        final current = _threads[params.threadId];
        if (current != null) {
          _threads[params.threadId] = codexThreadWithName(
            current,
            params.threadName,
          );
        }
      case CodexThreadArchivedNotification2(:final params):
        _removeThread(params.threadId);
      case CodexThreadClosedNotification2(:final params):
        _removeThread(params.threadId);
      case CodexThreadGoalUpdatedNotification2(:final params)
          when params.threadId == selectedThread?.id:
        goal = params.goal;
        goalError = null;
        _notify();
        return;
      case CodexThreadGoalClearedNotification2(:final params)
          when params.threadId == selectedThread?.id:
        goal = null;
        goalError = null;
        _notify();
        return;
      case CodexTurnStartedNotification2(:final params)
          when params.threadId == selectedThread?.id:
        _upsertTurn(params.turn);
        _notify();
        return;
      case CodexTurnCompletedNotification2(:final params)
          when params.threadId == selectedThread?.id:
        _completeTurn(params.turn);
        activePlan = null;
        activeDiff = null;
        _notify();
        unawaited(_drainQueuedMessages());
        return;
      case CodexTurnPlanUpdatedNotification2(:final params)
          when params.threadId == selectedThread?.id:
        activePlan = params;
        _notify();
        return;
      case CodexTurnDiffUpdatedNotification2(:final params)
          when params.threadId == selectedThread?.id:
        activeDiff = params.diff;
        _notify();
        return;
      case CodexItemStartedNotification2(:final params)
          when params.threadId == selectedThread?.id:
        _upsertItem(params.turnId, params.item);
        _notify();
        return;
      case CodexItemCompletedNotification2(:final params)
          when params.threadId == selectedThread?.id:
        _upsertItem(params.turnId, params.item);
        _notify();
        return;
      case CodexItemAgentMessageDeltaNotification(:final params)
          when params.threadId == selectedThread?.id:
        _appendAgentDelta(params.turnId, params.itemId, params.delta);
        _notify();
        return;
      case CodexItemPlanDeltaNotification(:final params)
          when params.threadId == selectedThread?.id:
        _appendPlanDelta(params.turnId, params.itemId, params.delta);
        _notify();
        return;
      case CodexItemCommandExecutionOutputDeltaNotification(:final params)
          when params.threadId == selectedThread?.id:
        _appendCommandDelta(params.turnId, params.itemId, params.delta);
        _notify();
        return;
      case CodexItemReasoningSummaryTextDeltaNotification(:final params)
          when params.threadId == selectedThread?.id:
        _appendReasoningDelta(
          params.turnId,
          params.itemId,
          params.summaryIndex,
          params.delta,
          summary: true,
        );
        _notify();
        return;
      case CodexItemReasoningTextDeltaNotification(:final params)
          when params.threadId == selectedThread?.id:
        _appendReasoningDelta(
          params.turnId,
          params.itemId,
          params.contentIndex,
          params.delta,
          summary: false,
        );
        _notify();
        return;
      case CodexItemToolRequestUserInputRequest(:final id, :final params)
          when params.threadId == selectedThread?.id:
        _addServerRequest(id, message);
        return;
      case CodexItemCommandExecutionRequestApprovalRequest(
            :final id,
            :final params,
          )
          when params.threadId == selectedThread?.id:
        _addServerRequest(id, message);
        return;
      case CodexItemFileChangeRequestApprovalRequest(:final id, :final params)
          when params.threadId == selectedThread?.id:
        _addServerRequest(id, message);
        return;
      case CodexItemPermissionsRequestApprovalRequest(:final id, :final params)
          when params.threadId == selectedThread?.id:
        _addServerRequest(id, message);
        return;
      case CodexServerRequestResolvedNotification2(:final params)
          when params.threadId == selectedThread?.id:
        _removeServerRequest(params.requestId);
        return;
      case CodexFsChangedNotification2(:final params)
          when params.watchId == globalStateWatchId:
        _globalStateDebounce?.cancel();
        _globalStateDebounce = Timer(const Duration(milliseconds: 200), () {
          unawaited(refreshCatalog(showLoading: false));
        });
        return;
      default:
        return;
    }
    _rebuildCatalog();
    _syncSelectedThread();
    _notify();
  }

  void _removeThread(String threadId) {
    _threads.remove(threadId);
    _resumedThreads.remove(threadId);
    _pendingThreadResumes.remove(threadId);
    if (selectedThread?.id == threadId) {
      selectedThread = null;
      turns = const [];
      goal = null;
      activePlan = null;
      activeDiff = null;
      queuedMessages = const [];
      _serverRequests.clear();
      pendingServerRequests = const [];
    }
  }

  void _upsertTurn(CodexTurn turn) {
    final index = turns.indexWhere((candidate) => candidate.id == turn.id);
    final updated = turns.toList(growable: true);
    if (index == -1) {
      updated.add(turn);
    } else {
      final existing = updated[index];
      updated[index] = _turnWith(
        turn,
        items: turn.items.isEmpty ? existing.items : turn.items,
      );
    }
    turns = List.unmodifiable(updated);
  }

  void _completeTurn(CodexTurn completed) {
    final existing = turns
        .where((candidate) => candidate.id == completed.id)
        .firstOrNull;
    _upsertTurn(
      _turnWith(
        completed,
        items: completed.items.isEmpty ? existing?.items : completed.items,
      ),
    );
  }

  void _upsertItem(String turnId, CodexThreadItem item) {
    _updateTurnItems(turnId, (items) {
      final updated = items.toList(growable: true);
      final index = updated.indexWhere(
        (candidate) => _threadItemId(candidate) == _threadItemId(item),
      );
      if (index == -1) {
        updated.add(item);
      } else {
        updated[index] = item;
      }
      return updated;
    });
  }

  void _appendAgentDelta(String turnId, String itemId, String delta) {
    _replaceItem(turnId, itemId, (item) {
      if (item is! CodexAgentMessageThreadItem) return item;
      return CodexAgentMessageThreadItem(
        id: item.id,
        memoryCitation: item.memoryCitation,
        phase: item.phase,
        text: '${item.text}$delta',
      );
    });
  }

  void _appendPlanDelta(String turnId, String itemId, String delta) {
    _replaceItem(turnId, itemId, (item) {
      if (item is! CodexPlanThreadItem) return item;
      return CodexPlanThreadItem(id: item.id, text: '${item.text}$delta');
    });
  }

  void _appendCommandDelta(String turnId, String itemId, String delta) {
    _replaceItem(turnId, itemId, (item) {
      if (item is! CodexCommandExecutionThreadItem) return item;
      return CodexCommandExecutionThreadItem(
        aggregatedOutput: '${item.aggregatedOutput ?? ''}$delta',
        command: item.command,
        commandActions: item.commandActions,
        cwd: item.cwd,
        durationMs: item.durationMs,
        exitCode: item.exitCode,
        id: item.id,
        pluginId: item.pluginId,
        processId: item.processId,
        scriptPath: item.scriptPath,
        source: item.source,
        status: item.status,
      );
    });
  }

  void _appendReasoningDelta(
    String turnId,
    String itemId,
    int index,
    String delta, {
    required bool summary,
  }) {
    _replaceItem(turnId, itemId, (item) {
      if (item is! CodexReasoningThreadItem) return item;
      final values = List<String>.of(
        summary ? item.summary ?? const [] : item.content ?? const [],
      );
      while (values.length <= index) {
        values.add('');
      }
      values[index] = '${values[index]}$delta';
      return CodexReasoningThreadItem(
        id: item.id,
        summary: summary ? values : item.summary,
        content: summary ? item.content : values,
      );
    });
  }

  void _replaceItem(
    String turnId,
    String itemId,
    CodexThreadItem Function(CodexThreadItem item) replace,
  ) {
    _updateTurnItems(turnId, (items) {
      final updated = items.toList(growable: true);
      final index = updated.indexWhere(
        (candidate) => _threadItemId(candidate) == itemId,
      );
      if (index != -1) updated[index] = replace(updated[index]);
      return updated;
    });
  }

  void _updateTurnItems(
    String turnId,
    List<CodexThreadItem> Function(List<CodexThreadItem> items) update,
  ) {
    final turnIndex = turns.indexWhere((turn) => turn.id == turnId);
    if (turnIndex == -1) return;
    final updatedTurns = turns.toList(growable: true);
    final turn = updatedTurns[turnIndex];
    updatedTurns[turnIndex] = _turnWith(turn, items: update(turn.items));
    turns = List.unmodifiable(updatedTurns);
  }

  void _addServerRequest(CodexV2RequestId id, CodexServerRequest request) {
    _serverRequests[_requestKey(id)] = request;
    pendingServerRequests = List.unmodifiable(_serverRequests.values);
    _notify();
  }

  void _removeServerRequest(CodexV2RequestId id) {
    _serverRequests.remove(_requestKey(id));
    pendingServerRequests = List.unmodifiable(_serverRequests.values);
    _notify();
  }

  Future<void> _drainQueuedMessages() async {
    if (_drainingQueue || _closed || activeTurn != null) return;
    _drainingQueue = true;
    try {
      while (!_closed && activeTurn == null && queuedMessages.isNotEmpty) {
        final message = queuedMessages.first;
        final sent = await _sendMessageNow(message, steer: false);
        if (!sent) break;
        deleteQueuedMessage(message.id);
        // turn/start returns the new in-progress turn, so the next message
        // remains queued until its completion notification arrives.
        if (activeTurn != null) break;
      }
    } finally {
      _drainingQueue = false;
    }
  }

  void _rebuildCatalog() {
    catalog = buildCodexCatalog(_threads.values, _globalState);
  }

  void _assignThreadToProject(CodexThread thread, CodexLocalProject project) {
    final global = _globalState;
    if (global == null || !global.projects.containsKey(project.id)) return;
    final assignments = Map<String, CodexThreadProjectAssignment>.of(
      global.assignments,
    );
    assignments[thread.id] = CodexThreadProjectAssignment(
      projectId: project.id,
      cwd: thread.cwd.value,
    );
    final orders = <String, List<String>>{
      for (final entry in global.projectThreadOrders.entries)
        entry.key: List<String>.of(entry.value),
    };
    final order = orders.putIfAbsent(project.id, () => <String>[]);
    order
      ..remove(thread.id)
      ..insert(0, thread.id);
    _globalState = CodexGlobalStateData(
      projects: global.projects,
      projectOrder: global.projectOrder,
      pinnedThreadIds: global.pinnedThreadIds,
      projectlessThreadIds: global.projectlessThreadIds
          .where((id) => id != thread.id)
          .toList(growable: false),
      assignments: Map.unmodifiable(assignments),
      projectThreadOrders: Map.unmodifiable(orders),
      selectedProjectId: global.selectedProjectId,
    );
  }

  void _syncSelectedThread() {
    final id = selectedThread?.id;
    if (id != null) selectedThread = _threads[id];
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _refreshGeneration++;
    _globalStateDebounce?.cancel();
    await _typedSubscription.cancel();
    connection.removeListener(_onConnectionChanged);
    if (_watchingGlobalState &&
        connection.state.phase == CodexConnectionPhase.connected) {
      try {
        await connection.unwatchFile(globalStateWatchId);
      } catch (_) {
        // The socket may have already closed.
      }
    }
    await connection.close();
    connection.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

String _joinCodexPath(String root, String child) {
  if (root.isEmpty) return child;
  final windowsStyle = root.contains('\\') && !root.contains('/');
  final separator = windowsStyle ? '\\' : '/';
  var normalized = root;
  while (normalized.endsWith('/') || normalized.endsWith('\\')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return '$normalized$separator$child';
}

CodexTurn _turnWith(CodexTurn turn, {List<CodexThreadItem>? items}) {
  return CodexTurn(
    completedAt: turn.completedAt,
    durationMs: turn.durationMs,
    error: turn.error,
    id: turn.id,
    items: List.unmodifiable(items ?? turn.items),
    itemsView: turn.itemsView,
    startedAt: turn.startedAt,
    status: turn.status,
  );
}

String? _threadItemId(CodexThreadItem item) {
  final json = item.toJson();
  return json is Map<String, Object?> ? json['id'] as String? : null;
}

String _requestKey(CodexV2RequestId id) => jsonEncode(id.toJson());

String _safeAttachmentName(String name) {
  final leaf = name.split(RegExp(r'[/\\]')).last.trim();
  final sanitized = leaf.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
  return sanitized.isEmpty ? 'attachment' : sanitized;
}
