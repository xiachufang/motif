import 'dart:async';

import 'package:flutter/foundation.dart';

import 'codex_connection_controller.dart';
import 'codex_service_state.dart';
import 'protocol/generated/codex_app_server_protocol.dart';

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
  }) {
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
  bool hasPermissionPreference;
  String? preferredPermissionId;

  final List<SideChatEntry> _entries = [];
  final Map<String, VoidCallback> _conversationListeners = {};
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

  SideChatEntry? get selected {
    final id = _selectedId;
    if (id == null) return null;
    return _entries.where((entry) => entry.id == id).firstOrNull;
  }

  bool get creating => _creation != null;

  Future<SideChatEntry?> ensureInitial() async {
    if (_entries.isNotEmpty) return selected ?? _entries.first;
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
      final conversation =
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
            )
            ..openSubscribedConversation(response);
      final entry = SideChatEntry(
        id: response.thread.id,
        index: ++_sequence,
        conversation: conversation,
        lastActivityAt: DateTime.now(),
        activitySignature: _activitySignature(conversation),
      );
      void listener() => _onConversationChanged(entry);
      _conversationListeners[entry.id] = listener;
      conversation.addListener(listener);
      _entries.add(entry);
      _selectedId = entry.id;
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
