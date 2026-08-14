import 'dart:async';

import 'package:flutter/foundation.dart';

import 'codex_connection_controller.dart';
import 'codex_feature_view_model.dart';
import 'codex_service_state.dart';
import 'codex_state.dart';
import 'side_chat_collection_controller.dart';

enum CodexServiceAction { restart, stop }

typedef CodexConnectionFactory = CodexAppServerClient Function();
typedef CodexServiceFactory = CodexServiceState Function();
typedef CodexServiceControl = Future<void> Function(CodexServiceAction action);

/// Owns the complete Codex feature lifecycle without knowing the application
/// shell, navigation, Session, or workspace implementation.
final class CodexFeatureController extends ChangeNotifier {
  CodexFeatureController({
    required this.serverId,
    required this.preferences,
    required this.connectionFactory,
    required this.controlService,
    this.serviceFactory,
  });

  final String serverId;
  final CodexState preferences;
  final CodexConnectionFactory connectionFactory;
  final CodexServiceControl controlService;
  final CodexServiceFactory? serviceFactory;
  final CodexFeatureViewModel viewModel = CodexFeatureViewModel();

  CodexServiceState? _service;
  final Map<String, SideChatCollectionController> _sideChatsByParentThread = {};
  String? setupError;
  bool operationInFlight = false;
  bool sideChatOpening = false;
  bool _started = false;
  bool _closed = false;
  String? _lastObservedThreadId;
  String? _pendingRestoreThreadId;
  String? _failedRestoreThreadId;
  bool _restoringThread = false;
  String? _visibleSideChatParentId;

  CodexServiceState? get service => _service;
  SideChatCollectionController? get sideChats {
    final parentThreadId = _service?.selectedThread?.id;
    return parentThreadId == null
        ? null
        : _sideChatsByParentThread[parentThreadId];
  }

  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;
    _pendingRestoreThreadId = preferences.lastOpenedThreadId(serverId);
    try {
      final state =
          serviceFactory?.call() ??
          CodexServiceState(
            serverId: serverId,
            connection: connectionFactory(),
          );
      state.configureModelPreference(
        preferredModelId: preferences.selectedModelId(serverId),
        onSelected: (modelId) =>
            preferences.setSelectedModelId(serverId, modelId),
      );
      state.configureReasoningEffortPreference(
        preferredReasoningEffort: preferences.selectedReasoningEffort(serverId),
        onSelected: (effort) =>
            preferences.setSelectedReasoningEffort(serverId, effort),
        onInvalidated: () => preferences.clearSelectedReasoningEffort(serverId),
      );
      state.configurePermissionPreference(
        hasPreference: preferences.hasSelectedPermissionPreference(serverId),
        preferredPermissionId: preferences.selectedPermissionId(serverId),
        onSelected: (permissionId) =>
            preferences.setSelectedPermissionId(serverId, permissionId),
        onInvalidated: () => preferences.clearSelectedPermissionId(serverId),
      );
      state.synchronizeViewModel();
      _service = state;
      viewModel.service = state;
      viewModel.setupError = null;
      state.addListener(_onServiceChanged);
      _syncSelectedThreadPreference(state);
      _maybeRestoreLastOpenedThread(state);
      notifyListeners();
      await state.start();
      _maybeRestoreLastOpenedThread(state);
    } catch (error) {
      if (_closed) return;
      setupError = '$error';
      viewModel.setupError = setupError;
      notifyListeners();
    }
  }

  SideChatCollectionController? openSideChats() {
    if (_closed) return null;
    final state = _service;
    if (state == null) return null;
    final thread = state.selectedThread;
    if (thread == null) return null;
    var collection = _sideChatsByParentThread[thread.id];
    if (collection == null) {
      final stored = preferences.sideChatIndex(serverId, thread.id);
      collection = SideChatCollectionController(
        serverId: serverId,
        parentThreadId: thread.id,
        registry: state.conversations,
        initialThreadIds: stored.threadIds,
        initialSelectedThreadId: stored.selectedThreadId,
        onIndexChanged: (threadIds, selectedThreadId) =>
            preferences.setSideChatIndex(
              serverId,
              thread.id,
              threadIds: threadIds,
              selectedThreadId: selectedThreadId,
            ),
      );
      _sideChatsByParentThread[thread.id] = collection;
      notifyListeners();
    }
    _showSideChatCollection(collection);
    return collection;
  }

  void setSideChatOpening(bool value) {
    if (_closed) return;
    if (!value) {
      final parentId = _visibleSideChatParentId;
      if (parentId != null) {
        _sideChatsByParentThread[parentId]?.setVisible(false);
        _visibleSideChatParentId = null;
      }
    } else {
      final collection = sideChats;
      if (collection != null) _showSideChatCollection(collection);
    }
    if (sideChatOpening == value) return;
    sideChatOpening = value;
    viewModel.sideChatOpening = value;
    notifyListeners();
  }

  void _showSideChatCollection(SideChatCollectionController collection) {
    final previousId = _visibleSideChatParentId;
    if (previousId != null && previousId != collection.parentThreadId) {
      _sideChatsByParentThread[previousId]?.setVisible(false);
    }
    _visibleSideChatParentId = collection.parentThreadId;
    collection.setVisible(true);
  }

  Future<bool> runServiceAction(CodexServiceAction action) async {
    if (_closed || operationInFlight) return false;
    operationInFlight = true;
    viewModel.operationInFlight = true;
    notifyListeners();
    try {
      await controlService(action);
      if (_closed) return false;
      if (action == CodexServiceAction.restart) {
        await _service?.retryConnection();
      }
      return true;
    } finally {
      if (!_closed) {
        operationInFlight = false;
        viewModel.operationInFlight = false;
        notifyListeners();
      }
    }
  }

  void _onServiceChanged() {
    if (_closed) return;
    final state = _service;
    if (state != null) {
      _syncSelectedThreadPreference(state);
      _resolveFailedThreadRestore(state);
      _maybeRestoreLastOpenedThread(state);
    }
    notifyListeners();
  }

  void _syncSelectedThreadPreference(CodexServiceState state) {
    final threadId = state.selectedThread?.id;
    if (threadId == _lastObservedThreadId) return;
    if (threadId != null) {
      _lastObservedThreadId = threadId;
      _pendingRestoreThreadId = null;
      _failedRestoreThreadId = null;
      preferences.setLastOpenedThreadId(serverId, threadId);
    } else if (_lastObservedThreadId != null) {
      _lastObservedThreadId = null;
      preferences.setLastOpenedThreadId(serverId, null);
    }
  }

  void _maybeRestoreLastOpenedThread(CodexServiceState state) {
    final threadId = _pendingRestoreThreadId;
    if (threadId == null ||
        _restoringThread ||
        state.selectedThread != null ||
        state.connectionState.phase != CodexConnectionPhase.connected) {
      return;
    }
    _pendingRestoreThreadId = null;
    _restoringThread = true;
    unawaited(_restoreLastOpenedThread(state, threadId));
  }

  Future<void> _restoreLastOpenedThread(
    CodexServiceState state,
    String threadId,
  ) async {
    try {
      await state.readThread(threadId);
      if (_closed || preferences.lastOpenedThreadId(serverId) != threadId) {
        return;
      }
      if (state.selectedThread?.id != threadId) {
        _failedRestoreThreadId = threadId;
        _resolveFailedThreadRestore(state);
      }
    } finally {
      _restoringThread = false;
    }
  }

  void _resolveFailedThreadRestore(CodexServiceState state) {
    final threadId = _failedRestoreThreadId;
    if (threadId == null || state.catalogPhase != CodexCatalogPhase.ready) {
      return;
    }
    _failedRestoreThreadId = null;
    if (preferences.lastOpenedThreadId(serverId) == threadId &&
        !state.catalog.allThreads.any((thread) => thread.id == threadId)) {
      preferences.setLastOpenedThreadId(serverId, null);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final state = _service;
    state?.removeListener(_onServiceChanged);
    final sideChats = _sideChatsByParentThread.values.toList(growable: false);
    _sideChatsByParentThread.clear();
    for (final collection in sideChats) {
      await collection.close();
      collection.dispose();
    }
    await preferences.flushSideChatIndexes();
    await preferences.flushLastOpenedThreadPreferences();
    await state?.close();
    state?.dispose();
    _service = null;
    viewModel.service = null;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
