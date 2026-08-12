import 'dart:async';

import 'package:flutter/foundation.dart';

import 'codex_connection_controller.dart';
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

  CodexServiceState? _service;
  SideChatCollectionController? _sideChats;
  String? setupError;
  bool operationInFlight = false;
  bool sideChatOpening = false;
  bool _started = false;
  bool _closed = false;

  CodexServiceState? get service => _service;
  SideChatCollectionController? get sideChats => _sideChats;

  Future<void> start() async {
    if (_started || _closed) return;
    _started = true;
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
      _service = state;
      state.addListener(_onServiceChanged);
      notifyListeners();
      await state.start();
    } catch (error) {
      if (_closed) return;
      setupError = '$error';
      notifyListeners();
    }
  }

  SideChatCollectionController? openSideChats() {
    if (_closed) return null;
    final thread = _service?.selectedThread;
    if (thread == null) return null;
    var collection = _sideChats;
    if (collection == null || collection.parentThreadId != thread.id) {
      collection?.dispose();
      collection = SideChatCollectionController(
        serverId: serverId,
        parentThreadId: thread.id,
        connection: connectionFactory(),
        preferredModelId: preferences.selectedModelId(serverId),
        onModelSelected: (modelId) =>
            preferences.setSelectedModelId(serverId, modelId),
      );
      _sideChats = collection;
      notifyListeners();
    }
    return collection;
  }

  void setSideChatOpening(bool value) {
    if (sideChatOpening == value || _closed) return;
    sideChatOpening = value;
    notifyListeners();
  }

  Future<bool> runServiceAction(CodexServiceAction action) async {
    if (_closed || operationInFlight) return false;
    operationInFlight = true;
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
        notifyListeners();
      }
    }
  }

  void _onServiceChanged() {
    if (_closed) return;
    final collection = _sideChats;
    final selectedThreadId = _service?.selectedThread?.id;
    if (collection != null && collection.parentThreadId != selectedThreadId) {
      _sideChats = null;
      collection.dispose();
    }
    notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final state = _service;
    state?.removeListener(_onServiceChanged);
    await _sideChats?.close();
    _sideChats = null;
    await state?.close();
    state?.dispose();
    _service = null;
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}
