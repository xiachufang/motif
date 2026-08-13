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
    required this.conversation,
    required this.lastActivityAt,
    required this.activitySignature,
  });

  final String id;
  final int index;
  final CodexConversationState conversation;
  DateTime lastActivityAt;
  String activitySignature;

  String get name => 'Side Chat $index';
  CodexThreadStatus get status =>
      conversation.selectedThread?.status ?? const CodexNotLoadedThreadStatus();
}

/// Owns all temporary forks for one parent thread and the independent
/// app-server connection that keeps them alive.
final class SideChatCollectionController extends ChangeNotifier {
  SideChatCollectionController({
    required this.serverId,
    required this.parentThreadId,
    required this.connection,
    this.preferredModelId,
    this.onModelSelected,
    this.preferredReasoningEffort,
    this.onReasoningEffortSelected,
    this.onReasoningEffortPreferenceInvalidated,
    this.hasPermissionPreference = false,
    this.preferredPermissionId,
    this.onPermissionSelected,
    this.onPermissionPreferenceInvalidated,
    this.initialThreadIds = const [],
    this.initialSelectedThreadId,
    this.onIndexChanged,
  }) {
    _restorableThreadIds = _normalizedIds(initialThreadIds);
    _restorableSelectedId =
        _restorableThreadIds.contains(initialSelectedThreadId)
        ? initialSelectedThreadId
        : null;
    _wasConnected = connection.state.phase == CodexConnectionPhase.connected;
    connection.addListener(_onConnectionChanged);
  }

  final String serverId;
  final String parentThreadId;
  final CodexAppServerClient connection;
  final String? preferredModelId;
  final ValueChanged<String?>? onModelSelected;
  String? preferredReasoningEffort;
  final ValueChanged<String?>? onReasoningEffortSelected;
  final VoidCallback? onReasoningEffortPreferenceInvalidated;
  final ValueChanged<String?>? onPermissionSelected;
  final VoidCallback? onPermissionPreferenceInvalidated;
  final List<String> initialThreadIds;
  final String? initialSelectedThreadId;
  final SideChatIndexChanged? onIndexChanged;
  bool hasPermissionPreference;
  String? preferredPermissionId;

  final List<SideChatEntry> _entries = [];
  final Map<String, VoidCallback> _conversationListeners = {};
  late List<String> _restorableThreadIds;
  String? _restorableSelectedId;
  Future<SideChatEntry?>? _initialization;
  Future<SideChatEntry?>? _creation;
  String? _selectedId;
  String? error;
  var _started = false;
  var _wasConnected = false;
  var _closed = false;
  var _sequence = 0;

  CodexConnectionState get connectionState => connection.state;

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

  bool get creating => _initialization != null || _creation != null;

  Future<SideChatEntry?> ensureInitial() {
    if (_entries.isNotEmpty) {
      return Future.value(selected ?? _entries.first);
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

    final restored = <CodexThreadResumeResponse>[];
    try {
      await _ensureConnected();
      if (_closed) return null;
      for (final id in ids) {
        try {
          final response = await connection.resumeThread(
            id,
            includeTurns: true,
          );
          if (_closed) {
            await _unsubscribeBestEffort(response.thread.id);
            return null;
          }
          if (!_isExpectedSideChat(response.thread, id)) {
            await _unsubscribeBestEffort(response.thread.id);
            continue;
          }
          restored.add(response);
        } catch (value) {
          if (!_isMissingThreadError(value)) rethrow;
        }
      }
      if (_closed) return null;
      final restoredIds = <String>[];
      for (final response in restored) {
        _addEntry(
          id: response.thread.id,
          index: restoredIds.length + 1,
          conversation: _conversation()..openResumedConversation(response),
          lastActivityAt: _threadActivityAt(response.thread),
        );
        restoredIds.add(response.thread.id);
      }
      _restorableThreadIds = restoredIds;
      _sequence = restoredIds.length;
      _selectedId = restoredIds.contains(_restorableSelectedId)
          ? _restorableSelectedId
          : restoredIds.firstOrNull;
      _restorableSelectedId = _selectedId;
      _publishIndex();
      if (_entries.isNotEmpty) {
        error = null;
        notifyListeners();
        return selected ?? _entries.first;
      }
    } catch (value) {
      for (final response in restored) {
        await _unsubscribeBestEffort(response.thread.id);
      }
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
      if (_closed) {
        await _unsubscribeBestEffort(response.thread.id);
        return null;
      }
      final entry = _addEntry(
        id: response.thread.id,
        index: ++_sequence,
        conversation: _conversation()..openSubscribedConversation(response),
        lastActivityAt: DateTime.now(),
      );
      _selectedId = entry.id;
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

  CodexConversationState _conversation() =>
      CodexConversationState(
          serverId: serverId,
          connection: connection,
          connectionLease: const CodexSharedConnectionLease(),
          features: const <CodexConversationFeature>{},
        )
        ..configureModelPreference(
          preferredModelId: preferredModelId,
          onSelected: onModelSelected,
        )
        ..configureReasoningEffortPreference(
          preferredReasoningEffort: preferredReasoningEffort,
          onSelected: (effort) {
            preferredReasoningEffort = effort;
            onReasoningEffortSelected?.call(effort);
          },
          onInvalidated: () {
            preferredReasoningEffort = null;
            onReasoningEffortPreferenceInvalidated?.call();
          },
        )
        ..configurePermissionPreference(
          hasPreference: hasPermissionPreference,
          preferredPermissionId: preferredPermissionId,
          onSelected: (permissionId) {
            hasPermissionPreference = true;
            preferredPermissionId = permissionId;
            onPermissionSelected?.call(permissionId);
          },
          onInvalidated: () {
            hasPermissionPreference = false;
            preferredPermissionId = null;
            onPermissionPreferenceInvalidated?.call();
          },
        );

  SideChatEntry _addEntry({
    required String id,
    required int index,
    required CodexConversationState conversation,
    required DateTime lastActivityAt,
  }) {
    final entry = SideChatEntry(
      id: id,
      index: index,
      conversation: conversation,
      lastActivityAt: lastActivityAt,
      activitySignature: _activitySignature(conversation),
    );
    void listener() => _onConversationChanged(entry);
    _conversationListeners[entry.id] = listener;
    conversation.addListener(listener);
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

  void select(String threadId) {
    if (_selectedId == threadId ||
        !_entries.any((entry) => entry.id == threadId)) {
      return;
    }
    _selectedId = threadId;
    _restorableSelectedId = threadId;
    _publishIndex();
    notifyListeners();
  }

  void _onConversationChanged(SideChatEntry entry) {
    if (_closed) return;
    if (entry.conversation.selectedThread == null) {
      final listener = _conversationListeners.remove(entry.id);
      if (listener != null) entry.conversation.removeListener(listener);
      _entries.remove(entry);
      if (_selectedId == entry.id) {
        _selectedId = entries.firstOrNull?.id;
      }
      _restorableThreadIds = _entriesByIndex
          .map((candidate) => candidate.id)
          .toList(growable: false);
      _restorableSelectedId = _selectedId;
      _publishIndex();
      unawaited(
        entry.conversation.close().whenComplete(entry.conversation.dispose),
      );
      notifyListeners();
      return;
    }
    final next = _activitySignature(entry.conversation);
    if (entry.activitySignature != next) {
      entry.activitySignature = next;
      entry.lastActivityAt = DateTime.now();
    }
    notifyListeners();
  }

  void _onConnectionChanged() {
    if (_closed) return;
    final phase = connection.state.phase;
    if (phase == CodexConnectionPhase.connected) {
      _wasConnected = true;
    } else if (_wasConnected && _entries.isNotEmpty) {
      _wasConnected = false;
      unawaited(_expireConversations());
    }
    notifyListeners();
  }

  Future<void> _expireConversations() async {
    final expired = List<SideChatEntry>.of(_entries);
    _entries.clear();
    _selectedId = null;
    error = 'Side Chats expired because the Codex connection restarted.';
    for (final entry in expired) {
      final listener = _conversationListeners.remove(entry.id);
      if (listener != null) entry.conversation.removeListener(listener);
      await entry.conversation.close();
      entry.conversation.dispose();
    }
    if (!_closed) notifyListeners();
  }

  Future<void> _unsubscribeBestEffort(String threadId) async {
    if (connection.state.phase != CodexConnectionPhase.connected) return;
    try {
      await connection.unsubscribeThread(threadId);
    } catch (_) {
      // Closing the socket below also releases app-server subscriptions.
    }
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
    connection.removeListener(_onConnectionChanged);
    final current = List<SideChatEntry>.of(_entries);
    for (final entry in current) {
      await _unsubscribeBestEffort(entry.id);
    }
    for (final entry in current) {
      final listener = _conversationListeners.remove(entry.id);
      if (listener != null) entry.conversation.removeListener(listener);
      await entry.conversation.close();
      entry.conversation.dispose();
    }
    _entries.clear();
    _selectedId = null;
    await connection.close();
    connection.dispose();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

String _activitySignature(CodexConversationState state) {
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
