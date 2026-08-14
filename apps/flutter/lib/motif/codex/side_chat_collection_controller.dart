import 'dart:async';

import 'package:flutter/foundation.dart';

import 'codex_connection_controller.dart';
import 'codex_service_state.dart';
import 'protocol/generated/codex_app_server_protocol.dart';

typedef SideChatIndexChanged =
    void Function(List<String> threadIds, String? selectedThreadId);

final class SideChatEntry {
  SideChatEntry({
    required this.id,
    required this.index,
    required this.registry,
    required this.lastActivityAt,
    required this.activitySignature,
  });

  final String id;
  final int index;
  final CodexConversationRegistry registry;
  DateTime lastActivityAt;
  String activitySignature;

  String get name => 'Side Chat $index';
  CodexConversationState? get conversationOrNull => registry.sessionFor(id);
  CodexConversationState get conversation =>
      conversationOrNull ??
      (throw StateError('Side Chat session is not currently loaded: $id'));
  CodexThreadStatus get status =>
      conversationOrNull?.selectedThread?.status ??
      registry.handleFor(id)?.thread.status ??
      const CodexNotLoadedThreadStatus();
}

/// Owns the lightweight Side Chat index for one parent thread. Conversation
/// sessions and app-server subscriptions belong to the shared registry.
final class SideChatCollectionController extends ChangeNotifier {
  factory SideChatCollectionController({
    required String serverId,
    required String parentThreadId,
    CodexConversationRegistry? registry,
    CodexAppServerClient? connection,
    String? preferredModelId,
    ValueChanged<String?>? onModelSelected,
    String? preferredReasoningEffort,
    ValueChanged<String?>? onReasoningEffortSelected,
    VoidCallback? onReasoningEffortPreferenceInvalidated,
    bool hasPermissionPreference = false,
    String? preferredPermissionId,
    ValueChanged<String?>? onPermissionSelected,
    VoidCallback? onPermissionPreferenceInvalidated,
    List<String> initialThreadIds = const [],
    String? initialSelectedThreadId,
    SideChatIndexChanged? onIndexChanged,
  }) {
    final resolvedConnection = registry?.connection ?? connection;
    if (resolvedConnection == null) {
      throw ArgumentError('A conversation registry or connection is required');
    }
    final ownsRegistry = registry == null;
    final resolvedRegistry =
        registry ??
        CodexConversationRegistry(
          serverId: serverId,
          connection: resolvedConnection,
          sessionFactory: (_) =>
              CodexConversationState(
                  serverId: serverId,
                  connection: resolvedConnection,
                  connectionLease: const CodexSharedConnectionLease(),
                  listenToConnectionMessages: false,
                  recoverOnReconnect: false,
                  features: const <CodexConversationFeature>{},
                )
                ..configureModelPreference(
                  preferredModelId: preferredModelId,
                  onSelected: onModelSelected,
                )
                ..configureReasoningEffortPreference(
                  preferredReasoningEffort: preferredReasoningEffort,
                  onSelected: onReasoningEffortSelected,
                  onInvalidated: onReasoningEffortPreferenceInvalidated,
                )
                ..configurePermissionPreference(
                  hasPreference: hasPermissionPreference,
                  preferredPermissionId: preferredPermissionId,
                  onSelected: onPermissionSelected,
                  onInvalidated: onPermissionPreferenceInvalidated,
                ),
        );
    return SideChatCollectionController._(
      ownsRegistry,
      serverId: serverId,
      parentThreadId: parentThreadId,
      registry: resolvedRegistry,
      initialThreadIds: initialThreadIds,
      initialSelectedThreadId: initialSelectedThreadId,
      onIndexChanged: onIndexChanged,
    );
  }

  SideChatCollectionController._(
    this._ownsRegistry, {
    required this.serverId,
    required this.parentThreadId,
    required this.registry,
    required List<String> initialThreadIds,
    required String? initialSelectedThreadId,
    required this.onIndexChanged,
  }) {
    _restorableThreadIds = _normalizedIds(initialThreadIds);
    _restorableSelectedId =
        _restorableThreadIds.contains(initialSelectedThreadId)
        ? initialSelectedThreadId
        : null;
    registry.addListener(_onRegistryChanged);
    connection.addListener(_onConnectionChanged);
  }

  final String serverId;
  final String parentThreadId;
  final CodexConversationRegistry registry;
  final SideChatIndexChanged? onIndexChanged;
  final bool _ownsRegistry;

  CodexAppServerClient get connection => registry.connection;
  CodexConnectionState get connectionState => connection.state;

  final List<SideChatEntry> _entries = [];
  late List<String> _restorableThreadIds;
  String? _restorableSelectedId;
  Future<SideChatEntry?>? _initialization;
  Future<SideChatEntry?>? _creation;
  String? _selectedId;
  String? error;
  var _started = false;
  var _closed = false;
  var _visible = true;
  var _sequence = 0;

  String get _visibilityOwner => 'side-chat:$parentThreadId';

  List<SideChatEntry> get entries {
    final result = _entries.toList(growable: false);
    result.sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
    return List.unmodifiable(result);
  }

  List<SideChatEntry> get _entriesByIndex {
    final result = _entries.toList(growable: false);
    result.sort((a, b) => a.index.compareTo(b.index));
    return result;
  }

  SideChatEntry? get selected {
    final id = _selectedId;
    if (id == null) return null;
    return _entries.where((entry) => entry.id == id).firstOrNull;
  }

  CodexConversationState? get selectedConversation {
    final id = _selectedId;
    return id == null ? null : registry.sessionFor(id);
  }

  bool get creating => _initialization != null || _creation != null;

  Future<SideChatEntry?> ensureInitial() {
    if (_entries.isNotEmpty) {
      final entry = selected ?? _entries.first;
      return _ensureEntrySession(entry);
    }
    final inFlight = _initialization;
    if (inFlight != null) return inFlight;
    final future = _restoreOrCreateInitial();
    _initialization = future;
    notifyListeners();
    return future.whenComplete(() {
      if (!_closed && identical(_initialization, future)) {
        _initialization = null;
        notifyListeners();
      }
    });
  }

  Future<SideChatEntry?> _restoreOrCreateInitial() async {
    final ids = List<String>.of(_restorableThreadIds);
    if (ids.isEmpty) return createSideChat();

    try {
      await _ensureConnected();
      if (_closed) return null;
      final restoredIds = <String>[];
      for (final id in ids) {
        try {
          final createSession =
              id == _restorableSelectedId ||
              (_restorableSelectedId == null && restoredIds.isEmpty);
          final response = await connection.resumeThread(
            id,
            initialTurnsPage: createSession
                ? codexThreadResumeInitialTurnsPage
                : null,
          );
          if (_closed) return null;
          if (!_isExpectedSideChat(response.thread, id)) continue;
          final conversation = registry.registerResumed(
            response,
            kind: CodexThreadSessionKind.sideChat,
            parentThreadId: parentThreadId,
            createSession: createSession,
          );
          _addEntry(
            id: response.thread.id,
            index: restoredIds.length + 1,
            lastActivityAt: _threadActivityAt(response.thread),
            conversation: conversation,
          );
          restoredIds.add(response.thread.id);
        } catch (value) {
          if (!_isMissingThreadError(value)) rethrow;
        }
      }
      if (_closed) return null;
      _restorableThreadIds = restoredIds;
      _sequence = restoredIds.length;
      _selectedId = restoredIds.contains(_restorableSelectedId)
          ? _restorableSelectedId
          : restoredIds.firstOrNull;
      _restorableSelectedId = _selectedId;
      _updateVisibility(null, _selectedId);
      _publishIndex();
      if (_entries.isNotEmpty) {
        error = null;
        notifyListeners();
        return await _ensureEntrySession(selected ?? _entries.first);
      }
    } catch (value) {
      if (!_closed) {
        error = '$value';
        notifyListeners();
      }
      return null;
    }
    return createSideChat();
  }

  Future<SideChatEntry?> createSideChat() {
    if (_closed) return Future.value(null);
    final inFlight = _creation;
    if (inFlight != null) return inFlight;
    final future = _createSideChat();
    _creation = future;
    notifyListeners();
    return future.whenComplete(() {
      if (!_closed && identical(_creation, future)) {
        _creation = null;
        notifyListeners();
      }
    });
  }

  Future<SideChatEntry?> _createSideChat() async {
    try {
      await _ensureConnected();
      if (_closed) return null;
      final response = await connection.forkThread(
        CodexThreadForkParams(
          threadId: parentThreadId,
          ephemeral: true,
          excludeTurns: true,
        ),
      );
      if (_closed) return null;
      final conversation = registry.registerFork(
        response,
        kind: CodexThreadSessionKind.sideChat,
        parentThreadId: parentThreadId,
      );
      final entry = _addEntry(
        id: response.thread.id,
        index: ++_sequence,
        lastActivityAt: DateTime.now(),
        conversation: conversation,
      );
      final previousId = _selectedId;
      _selectedId = entry.id;
      _updateVisibility(previousId, entry.id);
      _restorableThreadIds = _entriesByIndex
          .map((candidate) => candidate.id)
          .toList(growable: false);
      _restorableSelectedId = _selectedId;
      _publishIndex();
      error = null;
      notifyListeners();
      return entry;
    } catch (value) {
      if (!_closed) {
        error = '$value';
        notifyListeners();
      }
      return null;
    }
  }

  SideChatEntry _addEntry({
    required String id,
    required int index,
    required CodexConversationState? conversation,
    required DateTime lastActivityAt,
  }) {
    final existing = _entries.where((entry) => entry.id == id).firstOrNull;
    if (existing != null) return existing;
    final entry = SideChatEntry(
      id: id,
      index: index,
      registry: registry,
      lastActivityAt: lastActivityAt,
      activitySignature: _activitySignature(conversation),
    );
    _entries.add(entry);
    return entry;
  }

  Future<void> _ensureConnected() async {
    if (connection.state.phase == CodexConnectionPhase.connected) return;
    if (_started) {
      await connection.retry();
    } else {
      _started = true;
      await connection.start();
    }
    if (connection.state.phase != CodexConnectionPhase.connected) {
      throw StateError(connection.state.error ?? 'Could not connect to Codex');
    }
  }

  Future<void> select(String threadId) async {
    if (_closed || !_entries.any((entry) => entry.id == threadId)) return;
    final previousId = _selectedId;
    if (previousId != threadId) {
      _selectedId = threadId;
      _restorableSelectedId = threadId;
      _updateVisibility(previousId, threadId);
      _publishIndex();
      notifyListeners();
    }
    final entry = selected;
    if (entry != null) await _ensureEntrySession(entry);
  }

  Future<SideChatEntry?> _ensureEntrySession(SideChatEntry entry) async {
    try {
      await registry.ensureSession(entry.id);
      if (_closed) return null;
      error = null;
      notifyListeners();
      return entry;
    } catch (value) {
      if (!_closed) {
        error = '$value';
        notifyListeners();
      }
      return null;
    }
  }

  void setVisible(bool value) {
    if (_closed || _visible == value) return;
    _visible = value;
    final id = _selectedId;
    if (id == null) return;
    if (value) {
      registry.acquireVisibility(id, _visibilityOwner);
      unawaited(_ensureEntrySession(selected!));
    } else {
      registry.releaseVisibility(id, _visibilityOwner);
    }
  }

  void _updateVisibility(String? previousId, String? nextId) {
    if (!_visible || previousId == nextId) return;
    if (previousId != null) {
      registry.releaseVisibility(previousId, _visibilityOwner);
    }
    if (nextId != null) {
      registry.acquireVisibility(nextId, _visibilityOwner);
    }
  }

  void _onRegistryChanged() {
    if (_closed) return;
    var indexChanged = false;
    for (final entry in _entries.toList(growable: false)) {
      final handle = registry.handleFor(entry.id);
      if (handle == null) {
        _entries.remove(entry);
        if (_selectedId == entry.id) _selectedId = null;
        indexChanged = true;
        continue;
      }
      final conversation = entry.conversationOrNull;
      final nextSignature = _activitySignature(conversation);
      if (entry.activitySignature != nextSignature) {
        entry.activitySignature = nextSignature;
        entry.lastActivityAt = handle.lastActivityAt;
      }
    }
    if (indexChanged) {
      _selectedId ??= entries.firstOrNull?.id;
      _restorableThreadIds = _entriesByIndex
          .map((candidate) => candidate.id)
          .toList(growable: false);
      _restorableSelectedId = _selectedId;
      _updateVisibility(null, _selectedId);
      _publishIndex();
    }
    notifyListeners();
  }

  void _onConnectionChanged() {
    if (!_closed) notifyListeners();
  }

  bool _isExpectedSideChat(CodexThread thread, String expectedId) =>
      thread.id == expectedId &&
      thread.ephemeral &&
      (thread.parentThreadId == parentThreadId ||
          thread.forkedFromId == parentThreadId);

  bool _isMissingThreadError(Object error) {
    if (error is! CodexRpcException) return false;
    final message = error.error.message.toLowerCase();
    return message.contains('no rollout found') ||
        message.contains('rollout not found') ||
        message.contains('thread not found') ||
        message.contains('no thread found') ||
        message.contains('unknown thread');
  }

  void _publishIndex() {
    onIndexChanged?.call(
      List.unmodifiable(_restorableThreadIds),
      _restorableSelectedId,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    registry.removeListener(_onRegistryChanged);
    connection.removeListener(_onConnectionChanged);
    if (_visible && _selectedId != null) {
      registry.releaseVisibility(_selectedId!, _visibilityOwner);
    }
    _entries.clear();
    _selectedId = null;
    if (_ownsRegistry) {
      await registry.close();
      registry.dispose();
      await connection.close();
      connection.dispose();
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

String _activitySignature(CodexConversationState? state) {
  if (state == null) return 'evicted';
  final itemCount = state.turns.fold<int>(
    0,
    (total, turn) => total + turn.items.length,
  );
  return '${state.turns.length}:$itemCount:${state.activeTurn?.id}:'
      '${state.pendingServerRequests.length}:${state.queuedMessages.length}:'
      '${state.sending}';
}

List<String> _normalizedIds(Iterable<String> source) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in source) {
    final id = value.trim();
    if (id.isNotEmpty && seen.add(id)) result.add(id);
  }
  return result;
}

DateTime _threadActivityAt(CodexThread thread) {
  final seconds =
      thread.recencyAt ??
      (thread.updatedAt == 0 ? thread.createdAt : thread.updatedAt);
  return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
}
