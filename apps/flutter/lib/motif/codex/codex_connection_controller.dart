import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../net/rpc_client.dart';
import '../state/server/server_transport.dart';
import 'protocol/generated/codex_app_server_protocol.dart';

enum CodexConnectionPhase { connecting, initializing, connected, failed }

enum CodexConnectionFailureKind { connection, cliNotFound }

final class CodexConnectionState {
  const CodexConnectionState({
    required this.phase,
    this.response,
    this.error,
    this.failureKind = CodexConnectionFailureKind.connection,
  });

  const CodexConnectionState.connecting()
    : this(phase: CodexConnectionPhase.connecting);

  final CodexConnectionPhase phase;
  final CodexInitializeResponse? response;
  final String? error;
  final CodexConnectionFailureKind failureKind;
}

const _codexCliNotFoundErrorCode = -32022;

final class CodexCliNotFoundException implements Exception {
  const CodexCliNotFoundException(this.serverMessage);

  final String serverMessage;

  @override
  String toString() =>
      'Install the Codex CLI on the Motif server, then retry. The standalone '
      'installer normally places it at ~/.local/bin/codex. If Codex is '
      'installed elsewhere, set MOTIFD_CODEX_PATH to its executable.\n\n'
      'Server detail: $serverMessage';
}

abstract interface class CodexTransport {
  Future<void> connect();
  WebSocketChannel openCodexWebSocket();
  Future<void> close();
}

final class RpcCodexTransport implements CodexTransport {
  RpcCodexTransport(this._server);

  final RpcServerTransport _server;
  RpcClient? _rpc;

  @override
  Future<void> connect() async {
    final rpc = _server.forkClient();
    try {
      // Starting over HTTP first preserves motifd's structured launch errors.
      // A failed WebSocket upgrade otherwise collapses them into an opaque
      // channel connection exception on both native and web clients.
      await rpc.call('codex.start');
      _rpc = rpc;
    } on RpcException catch (error) {
      await rpc.close();
      if (error.code == _codexCliNotFoundErrorCode) {
        throw CodexCliNotFoundException(error.message);
      }
      rethrow;
    } catch (_) {
      await rpc.close();
      rethrow;
    }
  }

  @override
  WebSocketChannel openCodexWebSocket() {
    final rpc = _rpc;
    if (rpc == null) {
      throw const RpcException('codex transport is not connected');
    }
    return rpc.openRawWebSocket('/codex');
  }

  @override
  Future<void> close() async {
    final rpc = _rpc;
    _rpc = null;
    await rpc?.close();
  }
}

final class CodexRpcException implements Exception {
  const CodexRpcException(this.error);
  final CodexJSONRPCErrorError error;

  @override
  String toString() => 'codex rpc ${error.code}: ${error.message}';
}

typedef CodexAppVersionProvider = Future<String> Function();
typedef CodexReconnectDelay = Duration Function(int attempt);
typedef _Decoder = Object? Function(Object? value);

Duration _defaultReconnectDelay(int attempt) {
  const delays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 16),
    Duration(seconds: 30),
  ];
  final index = attempt <= 1
      ? 0
      : attempt >= delays.length
      ? delays.length - 1
      : attempt - 1;
  return delays[index];
}

abstract interface class CodexAppServerClient implements Listenable {
  CodexConnectionState get state;
  Stream<Map<String, Object?>> get rawMessages;
  Stream<CodexJsonEncodable> get typedMessages;

  Future<void> start();
  Future<void> retry();
  Future<void> close();
  Future<CodexThreadListResponse> listThreads(CodexThreadListParams params);
  Future<CodexThreadSetNameResponse> setThreadName(
    String threadId,
    String name,
  );
  Future<CodexThreadArchiveResponse> archiveThread(String threadId);
  Future<CodexThreadUnarchiveResponse> unarchiveThread(String threadId);
  Future<CodexThreadDeleteResponse> deleteThread(String threadId);
  Future<CodexThreadReadResponse> readThread(
    String threadId, {
    bool includeTurns = false,
  });
  Future<CodexThreadTurnsListResponse> listThreadTurns(
    CodexThreadTurnsListParams params,
  );
  Future<CodexThreadStartResponse> startThread(CodexThreadStartParams params);
  Future<CodexThreadForkResponse> forkThread(CodexThreadForkParams params);
  Future<CodexThreadUnsubscribeResponse> unsubscribeThread(String threadId);
  Future<CodexThreadResumeResponse> resumeThread(
    String threadId, {
    bool includeTurns = false,
    CodexThreadResumeInitialTurnsPageParams? initialTurnsPage,
  });
  Future<CodexTurnStartResponse> startTurn(CodexTurnStartParams params);
  Future<CodexTurnSteerResponse> steerTurn(CodexTurnSteerParams params);
  Future<CodexTurnInterruptResponse> interruptTurn(
    String threadId,
    String turnId,
  );
  Future<CodexModelListResponse> listModels(CodexModelListParams params);
  Future<CodexPermissionProfileListResponse> listPermissionProfiles(
    CodexPermissionProfileListParams params,
  );
  Future<CodexCollaborationModeListResponse> listCollaborationModes();
  Future<CodexSkillsListResponse> listSkills(CodexSkillsListParams params);
  Future<CodexPluginListResponse> listPlugins(CodexPluginListParams params);
  Future<CodexThreadGoalGetResponse> getThreadGoal(String threadId);
  Future<CodexThreadGoalSetResponse> setThreadGoal(
    CodexThreadGoalSetParams params,
  );
  Future<CodexThreadGoalClearResponse> clearThreadGoal(String threadId);
  Future<CodexFsReadFileResponse> readFile(String path);
  Future<CodexFsCreateDirectoryResponse> createDirectory(String path);
  Future<CodexFsWriteFileResponse> writeFile(String path, String dataBase64);
  Future<CodexFsWatchResponse> watchFile(String path, String watchId);
  Future<CodexFsUnwatchResponse> unwatchFile(String watchId);
  Future<void> respondToServerRequest(
    CodexV2RequestId id,
    CodexJsonEncodable response,
  );
  void dispose();
}

final class _PendingRequest {
  const _PendingRequest(this.completer, this.decoder);
  final Completer<Object?> completer;
  final _Decoder decoder;
}

/// Owns the server-scoped `/codex` socket and app-server JSON-RPC handshake.
/// Raw frames are always published before typed decoding so protocol additions
/// in a newer app-server remain observable even when the generated schema is
/// older.
final class CodexConnectionController extends ChangeNotifier
    implements CodexAppServerClient {
  CodexConnectionController({
    required this.transport,
    CodexAppVersionProvider? appVersionProvider,
    CodexReconnectDelay? reconnectDelay,
    this.resumeProbeTimeout = const Duration(seconds: 2),
  }) : _appVersionProvider = appVersionProvider ?? _packageVersion,
       _reconnectDelay = reconnectDelay ?? _defaultReconnectDelay {
    try {
      _lifecycleListener = AppLifecycleListener(onResume: _onAppResumed);
    } catch (_) {
      // Pure unit tests can construct the controller without a widgets binding.
    }
  }

  final CodexTransport transport;
  final CodexAppVersionProvider _appVersionProvider;
  final CodexReconnectDelay _reconnectDelay;
  @visibleForTesting
  final Duration resumeProbeTimeout;
  @override
  CodexConnectionState state = const CodexConnectionState.connecting();

  final StreamController<Map<String, Object?>> _rawMessages =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<CodexJsonEncodable> _typedMessages =
      StreamController<CodexJsonEncodable>.broadcast();
  final Map<Object, _PendingRequest> _pending = {};

  @override
  Stream<Map<String, Object?>> get rawMessages => _rawMessages.stream;
  @override
  Stream<CodexJsonEncodable> get typedMessages => _typedMessages.stream;

  WebSocketChannel? _socket;
  StreamSubscription<Object?>? _subscription;
  Future<void>? _startInFlight;
  Future<void>? _resumeProbeInFlight;
  Timer? _reconnectTimer;
  AppLifecycleListener? _lifecycleListener;
  int _nextId = 0;
  int _generation = 0;
  int _reconnectAttempt = 0;
  bool _closed = false;
  bool _transportOpen = false;
  bool _connectedOnce = false;

  @override
  Future<void> start() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final inFlight = _startInFlight;
    if (inFlight != null) return inFlight;
    late final Future<void> attempt;
    attempt = _start().whenComplete(() {
      if (identical(_startInFlight, attempt)) _startInFlight = null;
    });
    _startInFlight = attempt;
    return attempt;
  }

  Future<void> _start() async {
    final generation = ++_generation;
    await _releaseConnection();
    if (_closed || generation != _generation) return;
    _setState(const CodexConnectionState.connecting());
    try {
      await transport.connect();
      _transportOpen = true;
      if (_closed || generation != _generation) {
        await _releaseConnection();
        return;
      }
      final socket = transport.openCodexWebSocket();
      _socket = socket;
      _subscription = socket.stream.listen(
        (message) => _onMessage(message, generation),
        onError: (Object error, StackTrace stackTrace) =>
            _fail(error, generation),
        onDone: () => _fail('Codex connection closed', generation),
        cancelOnError: true,
      );
      await socket.ready;
      if (_closed || generation != _generation) return;
      _setState(
        const CodexConnectionState(phase: CodexConnectionPhase.initializing),
      );
      final id = ++_nextId;
      final version = await _appVersionProvider();
      final request = CodexInitializeRequest(
        id: CodexV2RequestId.fromJson(id),
        params: CodexInitializeParams(
          clientInfo: CodexClientInfo(
            name: 'motif',
            title: 'Motif',
            version: version,
          ),
          capabilities: const CodexInitializeCapabilities(
            experimentalApi: true,
          ),
        ),
      );
      final response = await _request<CodexInitializeResponse>(
        id,
        request,
        CodexInitializeResponse.fromJson,
      ).timeout(const Duration(seconds: 10));
      if (_closed || generation != _generation) return;
      _send(const CodexInitializedNotification());
      _setState(
        CodexConnectionState(
          phase: CodexConnectionPhase.connected,
          response: response,
        ),
      );
      _connectedOnce = true;
      _reconnectAttempt = 0;
    } catch (error) {
      _fail(error, generation);
    }
  }

  void _onAppResumed() {
    unawaited(probeOnResume());
  }

  /// Actively checks the existing app-server WebSocket after the application
  /// returns to the foreground. A socket can remain locally open after the OS
  /// suspended networking, so its cached state is not a sufficient liveness
  /// signal.
  @visibleForTesting
  Future<void> probeOnResume() {
    final running = _resumeProbeInFlight;
    if (running != null) return running;
    late final Future<void> probe;
    probe = _probeOnResume().whenComplete(() {
      if (identical(_resumeProbeInFlight, probe)) {
        _resumeProbeInFlight = null;
      }
    });
    _resumeProbeInFlight = probe;
    return probe;
  }

  Future<void> _probeOnResume() async {
    if (_closed) return;
    if (state.phase != CodexConnectionPhase.connected) {
      if (state.failureKind == CodexConnectionFailureKind.cliNotFound) return;
      await start();
      return;
    }

    final generation = _generation;
    final id = ++_nextId;
    try {
      await _request<Object?>(
        id,
        CodexAccountReadRequest(
          id: CodexV2RequestId.fromJson(id),
          params: const CodexGetAccountParams(),
        ),
        (_) => null,
      ).timeout(resumeProbeTimeout);
      // A JSON-RPC error also proves the full WebSocket and app-server path is
      // responsive, so only transport errors and timeouts rebuild it.
    } on CodexRpcException {
      return;
    } catch (error) {
      if (_closed || generation != _generation) return;
      _fail(error, generation);
      await start();
    }
  }

  @override
  Future<CodexThreadListResponse> listThreads(CodexThreadListParams params) =>
      _typedRequest(
        (id) => CodexThreadListRequest(id: id, params: params),
        CodexThreadListResponse.fromJson,
      );

  @override
  Future<CodexThreadSetNameResponse> setThreadName(
    String threadId,
    String name,
  ) => _typedRequest(
    (id) => CodexThreadNameSetRequest(
      id: id,
      params: CodexThreadSetNameParams(threadId: threadId, name: name),
    ),
    CodexThreadSetNameResponse.fromJson,
  );

  @override
  Future<CodexThreadArchiveResponse> archiveThread(String threadId) =>
      _typedRequest(
        (id) => CodexThreadArchiveRequest(
          id: id,
          params: CodexThreadArchiveParams(threadId: threadId),
        ),
        CodexThreadArchiveResponse.fromJson,
      );

  @override
  Future<CodexThreadUnarchiveResponse> unarchiveThread(String threadId) =>
      _typedRequest(
        (id) => CodexThreadUnarchiveRequest(
          id: id,
          params: CodexThreadUnarchiveParams(threadId: threadId),
        ),
        CodexThreadUnarchiveResponse.fromJson,
      );

  @override
  Future<CodexThreadDeleteResponse> deleteThread(String threadId) =>
      _typedRequest(
        (id) => CodexThreadDeleteRequest(
          id: id,
          params: CodexThreadDeleteParams(threadId: threadId),
        ),
        CodexThreadDeleteResponse.fromJson,
      );

  @override
  Future<CodexThreadReadResponse> readThread(
    String threadId, {
    bool includeTurns = false,
  }) => _typedRequest(
    (id) => CodexThreadReadRequest(
      id: id,
      params: CodexThreadReadParams(
        threadId: threadId,
        includeTurns: includeTurns,
      ),
    ),
    CodexThreadReadResponse.fromJson,
  );

  @override
  Future<CodexThreadTurnsListResponse> listThreadTurns(
    CodexThreadTurnsListParams params,
  ) => _typedRequest(
    (id) => CodexThreadTurnsListRequest(id: id, params: params),
    CodexThreadTurnsListResponse.fromJson,
  );

  @override
  Future<CodexThreadStartResponse> startThread(CodexThreadStartParams params) =>
      _typedRequest(
        (id) => CodexThreadStartRequest(id: id, params: params),
        CodexThreadStartResponse.fromJson,
      );

  @override
  Future<CodexThreadForkResponse> forkThread(CodexThreadForkParams params) =>
      _typedRequest(
        (id) => CodexThreadForkRequest(id: id, params: params),
        CodexThreadForkResponse.fromJson,
      );

  @override
  Future<CodexThreadUnsubscribeResponse> unsubscribeThread(String threadId) =>
      _typedRequest(
        (id) => CodexThreadUnsubscribeRequest(
          id: id,
          params: CodexThreadUnsubscribeParams(threadId: threadId),
        ),
        CodexThreadUnsubscribeResponse.fromJson,
      );

  @override
  Future<CodexThreadResumeResponse> resumeThread(
    String threadId, {
    bool includeTurns = false,
    CodexThreadResumeInitialTurnsPageParams? initialTurnsPage,
  }) => _typedRequest(
    (id) => CodexThreadResumeRequest(
      id: id,
      params: CodexThreadResumeParams(
        threadId: threadId,
        excludeTurns: initialTurnsPage != null || !includeTurns,
        initialTurnsPage: initialTurnsPage,
      ),
    ),
    CodexThreadResumeResponse.fromJson,
  );

  @override
  Future<CodexTurnStartResponse> startTurn(CodexTurnStartParams params) =>
      _typedRequest(
        (id) => CodexTurnStartRequest(id: id, params: params),
        CodexTurnStartResponse.fromJson,
      );

  @override
  Future<CodexTurnSteerResponse> steerTurn(CodexTurnSteerParams params) =>
      _typedRequest(
        (id) => CodexTurnSteerRequest(id: id, params: params),
        CodexTurnSteerResponse.fromJson,
      );

  @override
  Future<CodexTurnInterruptResponse> interruptTurn(
    String threadId,
    String turnId,
  ) => _typedRequest(
    (id) => CodexTurnInterruptRequest(
      id: id,
      params: CodexTurnInterruptParams(threadId: threadId, turnId: turnId),
    ),
    CodexTurnInterruptResponse.fromJson,
  );

  @override
  Future<CodexModelListResponse> listModels(CodexModelListParams params) =>
      _typedRequest(
        (id) => CodexModelListRequest(id: id, params: params),
        CodexModelListResponse.fromJson,
      );

  @override
  Future<CodexPermissionProfileListResponse> listPermissionProfiles(
    CodexPermissionProfileListParams params,
  ) => _typedRequest(
    (id) => CodexPermissionProfileListRequest(id: id, params: params),
    CodexPermissionProfileListResponse.fromJson,
  );

  @override
  Future<CodexCollaborationModeListResponse> listCollaborationModes() =>
      _typedRequest(
        (id) => CodexCollaborationModeListRequest(
          id: id,
          params: const CodexCollaborationModeListParams(),
        ),
        CodexCollaborationModeListResponse.fromJson,
      );

  @override
  Future<CodexSkillsListResponse> listSkills(CodexSkillsListParams params) =>
      _typedRequest(
        (id) => CodexSkillsListRequest(id: id, params: params),
        CodexSkillsListResponse.fromJson,
      );

  @override
  Future<CodexPluginListResponse> listPlugins(CodexPluginListParams params) =>
      _typedRequest(
        (id) => CodexPluginListRequest(id: id, params: params),
        CodexPluginListResponse.fromJson,
      );

  @override
  Future<CodexThreadGoalGetResponse> getThreadGoal(String threadId) =>
      _typedRequest(
        (id) => CodexThreadGoalGetRequest(
          id: id,
          params: CodexThreadGoalGetParams(threadId: threadId),
        ),
        CodexThreadGoalGetResponse.fromJson,
      );

  @override
  Future<CodexThreadGoalSetResponse> setThreadGoal(
    CodexThreadGoalSetParams params,
  ) => _typedRequest(
    (id) => CodexThreadGoalSetRequest(id: id, params: params),
    CodexThreadGoalSetResponse.fromJson,
  );

  @override
  Future<CodexThreadGoalClearResponse> clearThreadGoal(String threadId) =>
      _typedRequest(
        (id) => CodexThreadGoalClearRequest(
          id: id,
          params: CodexThreadGoalClearParams(threadId: threadId),
        ),
        CodexThreadGoalClearResponse.fromJson,
      );

  @override
  Future<CodexFsReadFileResponse> readFile(String path) => _typedRequest(
    (id) => CodexFsReadFileRequest(
      id: id,
      params: CodexFsReadFileParams(path: CodexV2AbsolutePathBuf(path)),
    ),
    CodexFsReadFileResponse.fromJson,
  );

  @override
  Future<CodexFsCreateDirectoryResponse> createDirectory(String path) =>
      _typedRequest(
        (id) => CodexFsCreateDirectoryRequest(
          id: id,
          params: CodexFsCreateDirectoryParams(
            path: CodexV2AbsolutePathBuf(path),
            recursive: true,
          ),
        ),
        CodexFsCreateDirectoryResponse.fromJson,
      );

  @override
  Future<CodexFsWriteFileResponse> writeFile(String path, String dataBase64) =>
      _typedRequest(
        (id) => CodexFsWriteFileRequest(
          id: id,
          params: CodexFsWriteFileParams(
            path: CodexV2AbsolutePathBuf(path),
            dataBase64: dataBase64,
          ),
        ),
        CodexFsWriteFileResponse.fromJson,
      );

  @override
  Future<CodexFsWatchResponse> watchFile(String path, String watchId) =>
      _typedRequest(
        (id) => CodexFsWatchRequest(
          id: id,
          params: CodexFsWatchParams(
            path: CodexV2AbsolutePathBuf(path),
            watchId: watchId,
          ),
        ),
        CodexFsWatchResponse.fromJson,
      );

  @override
  Future<CodexFsUnwatchResponse> unwatchFile(String watchId) => _typedRequest(
    (id) => CodexFsUnwatchRequest(
      id: id,
      params: CodexFsUnwatchParams(watchId: watchId),
    ),
    CodexFsUnwatchResponse.fromJson,
  );

  @override
  Future<void> respondToServerRequest(
    CodexV2RequestId id,
    CodexJsonEncodable response,
  ) => Future<void>.sync(
    () => _send(CodexJSONRPCResponse(id: id, result: response.toJson())),
  );

  Future<T> _typedRequest<T>(
    CodexJsonEncodable Function(CodexV2RequestId id) build,
    T Function(Object? value) decoder,
  ) {
    if (state.phase != CodexConnectionPhase.connected) {
      throw StateError('Codex connection is not initialized');
    }
    final rawId = ++_nextId;
    return _request(rawId, build(CodexV2RequestId.fromJson(rawId)), decoder);
  }

  Future<T> _request<T>(
    Object id,
    CodexJsonEncodable message,
    T Function(Object? value) decoder,
  ) {
    final completer = Completer<Object?>();
    final pending = _PendingRequest(completer, decoder);
    _pending[id] = pending;
    try {
      _send(message);
    } catch (_) {
      _pending.remove(id);
      rethrow;
    }
    return completer.future.then((value) => value as T).whenComplete(() {
      if (identical(_pending[id], pending)) _pending.remove(id);
    });
  }

  void _send(CodexJsonEncodable message) {
    final socket = _socket;
    if (socket == null) throw StateError('Codex WebSocket is not open');
    socket.sink.add(jsonEncode(message.toJson()));
  }

  void _onMessage(Object? frame, int generation) {
    if (_closed || generation != _generation) return;
    try {
      final decoded = jsonDecode(
        frame is String ? frame : utf8.decode(frame as List<int>),
      );
      final map = (decoded as Map).cast<String, Object?>();
      if (!_rawMessages.isClosed) _rawMessages.add(map);
      final id = map['id'];
      if (id != null &&
          (map.containsKey('result') || map.containsKey('error'))) {
        final pending = _pending.remove(id);
        if (pending == null) return;
        final error = map['error'];
        if (error != null) {
          pending.completer.completeError(
            CodexRpcException(CodexJSONRPCErrorError.fromJson(error)),
          );
        } else {
          try {
            pending.completer.complete(pending.decoder(map['result']));
          } catch (decodeError, stackTrace) {
            pending.completer.completeError(decodeError, stackTrace);
          }
        }
        return;
      }
      if (map['method'] is String && !_typedMessages.isClosed) {
        final typed = map.containsKey('id')
            ? CodexServerRequest.fromJson(map)
            : CodexServerNotification.fromJson(map);
        _typedMessages.add(typed);
      }
    } catch (error, stackTrace) {
      if (!_typedMessages.isClosed) {
        _typedMessages.addError(error, stackTrace);
      }
    }
  }

  void _fail(Object error, int generation) {
    if (_closed ||
        generation != _generation ||
        state.phase == CodexConnectionPhase.failed) {
      return;
    }
    for (final request in _pending.values) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(error);
      }
    }
    _pending.clear();
    _setState(
      CodexConnectionState(
        phase: CodexConnectionPhase.failed,
        error: error.toString(),
        failureKind: error is CodexCliNotFoundException
            ? CodexConnectionFailureKind.cliNotFound
            : CodexConnectionFailureKind.connection,
      ),
    );
    if (_connectedOnce && error is! CodexCliNotFoundException) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_closed || _reconnectTimer != null) return;
    final attempt = ++_reconnectAttempt;
    _reconnectTimer = Timer(_reconnectDelay(attempt), () {
      _reconnectTimer = null;
      if (!_closed) unawaited(start());
    });
  }

  void _setState(CodexConnectionState value) {
    state = value;
    notifyListeners();
  }

  @override
  Future<void> retry() => start();

  Future<void> _releaseConnection() async {
    final subscription = _subscription;
    final socket = _socket;
    _subscription = null;
    _socket = null;
    await subscription?.cancel();
    await socket?.sink.close();
    if (_transportOpen) {
      _transportOpen = false;
      try {
        await transport.close();
      } catch (_) {
        // The server connection may already have failed.
      }
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _generation++;
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    for (final request in _pending.values) {
      if (!request.completer.isCompleted) {
        request.completer.completeError(StateError('Codex connection closed'));
      }
    }
    _pending.clear();
    await _releaseConnection();
    await _rawMessages.close();
    await _typedMessages.close();
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }

  static Future<String> _packageVersion() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }
}
