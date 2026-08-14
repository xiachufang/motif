/// Server-scoped connection sharing for all Motif features.
///
/// A pool owns route resolution and one package:http client per route
/// generation. Handles own only their WebSockets and references; closing a
/// handle never closes the shared HTTP generation.
library;

// Public dependency-injection parameter names intentionally omit the private
// field underscores used by the implementation.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../log/log.dart';
import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../net/proxy_client.dart';
import '../../net/rpc_error.dart';
import '../../net/ws_channel.dart';
import '../connection/connection_state.dart';
import 'transport_resolver.dart';

export '../../net/rpc_error.dart' show UncertainDeliveryException;

enum ServerConnectionPoolPhase {
  idle,
  resolving,
  probing,
  ready,
  recovering,
  blocked,
  disconnected,
  closed,
}

enum ConnectionOwnerKind { serverHome, codex, session, remotePort }

enum RpcRetryPolicy {
  /// Mutations use this by default. A transport failure can mean that motifd
  /// received the request even though the response did not reach the client.
  never,

  /// Retry once after rebuilding the route. Callers must opt in only for a
  /// read or an operation with an idempotency guarantee.
  safeOnce,
}

sealed class MotifRequestScope {
  const MotifRequestScope();
}

final class ServerRequestScope extends MotifRequestScope {
  const ServerRequestScope();
}

final class SessionRequestScope extends MotifRequestScope {
  const SessionRequestScope(this.attachmentId);

  final String attachmentId;
}

final class MotifRpcResponse {
  const MotifRpcResponse({required this.body, this.sessionAttachmentId});

  final Map<String, Object?> body;
  final String? sessionAttachmentId;
}

final class ServerHttpRequest {
  const ServerHttpRequest({
    required this.method,
    required this.path,
    this.query = const {},
    this.headers = const {},
    this.body,
    this.scope = const ServerRequestScope(),
    this.retry = RpcRetryPolicy.never,
    this.timeout,
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final Map<String, String> headers;
  final Uint8List? body;
  final MotifRequestScope scope;
  final RpcRetryPolicy retry;
  final Duration? timeout;
}

final class ServerHttpResponse {
  const ServerHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;

  String get bodyText => utf8.decode(body);
}

final class ServerConnectionBlockedException implements Exception {
  const ServerConnectionBlockedException(this.blocker);

  final ConnectionBlocker blocker;

  @override
  String toString() => blocker.message;
}

final class ServerConnectionPoolSnapshot {
  const ServerConnectionPoolSnapshot({
    required this.phase,
    required this.routeGeneration,
    required this.activeOwners,
    this.lastPing,
    this.lastHealthyAt,
    this.blocker,
    this.error,
  });

  const ServerConnectionPoolSnapshot.idle()
    : this(
        phase: ServerConnectionPoolPhase.idle,
        routeGeneration: 0,
        activeOwners: 0,
      );

  final ServerConnectionPoolPhase phase;
  final int routeGeneration;
  final int activeOwners;
  final PingInfo? lastPing;
  final DateTime? lastHealthyAt;
  final ConnectionBlocker? blocker;
  final Object? error;
}

abstract interface class ExclusiveWebSocketConnection {
  int get routeGeneration;
  Stream<Object?> get messages;
  Future<void> get ready;
  Future<void> get done;
  int? get closeCode;
  String? get closeReason;
  void send(Object? value);
  Future<void> close([int? code, String? reason]);
}

/// Compatibility adapter for protocol state machines that consume
/// [WebSocketChannel]. The underlying connection remains pool-registered and
/// exclusive; this wrapper does not add caching or sharing.
final class ExclusiveWebSocketChannelAdapter
    with StreamChannelMixin<Object?>
    implements WebSocketChannel {
  ExclusiveWebSocketChannelAdapter(this.connection)
    : sink = _ExclusiveWebSocketSink(connection);

  final ExclusiveWebSocketConnection connection;

  @override
  Stream<Object?> get stream => connection.messages;

  @override
  final WebSocketSink sink;

  @override
  Future<void> get ready => connection.ready;

  @override
  int? get closeCode => connection.closeCode;

  @override
  String? get closeReason => connection.closeReason;

  @override
  String? get protocol => null;
}

final class _ExclusiveWebSocketSink implements WebSocketSink {
  const _ExclusiveWebSocketSink(this.connection);

  final ExclusiveWebSocketConnection connection;

  @override
  void add(Object? event) => connection.send(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      throw UnsupportedError('WebSocket sink errors cannot be injected');

  @override
  Future<void> addStream(Stream<Object?> stream) async {
    await for (final event in stream) {
      connection.send(event);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      connection.close(closeCode, closeReason);

  @override
  Future<void> get done => connection.done;
}

final class ServerWebSocketRequest {
  const ServerWebSocketRequest({
    required this.path,
    this.query = const {},
    this.scope = const ServerRequestScope(),
  });

  final String path;
  final Map<String, String> query;
  final MotifRequestScope scope;
}

abstract interface class ServerConnectionHandle {
  String get ownerId;
  ConnectionOwnerKind get ownerKind;
  bool get isClosed;

  Future<PingInfo> ensureReady({bool forceProbe = false});

  Future<MotifRpcResponse> rpc(
    String method, {
    Map<String, Object?> params = const {},
    MotifRequestScope scope = const ServerRequestScope(),
    RpcRetryPolicy retry = RpcRetryPolicy.never,
    Duration? timeout,
  });

  Future<ServerHttpResponse> send(ServerHttpRequest request);

  Future<ExclusiveWebSocketConnection> openWebSocket(
    ServerWebSocketRequest request,
  );

  Future<void> close();
}

abstract interface class ServerConnectionPool {
  String get serverId;
  ServerConnectionPoolSnapshot get snapshot;
  Stream<ServerConnectionPoolSnapshot> get snapshots;

  ServerConnectionHandle acquire({
    required String ownerId,
    required ConnectionOwnerKind ownerKind,
  });

  Future<void> reconnect({Object? cause});
  Future<void> disconnectAll({bool forgetLearnedRoute = false});
  Future<void> dispose({bool forgetLearnedRoute = false});
}

typedef ServerHttpClientFactory =
    http.Client Function(ProxySettings proxy, Uint8List? certPin);
typedef ServerWebSocketConnector =
    WebSocketChannel Function({
      required Uri uri,
      required Map<String, String> headers,
      required ProxySettings proxy,
      required Uint8List? certPin,
    });
typedef ServerRouteResolver =
    Future<TransportResolution> Function(MotifServer server);
typedef StopServerForwarder = Future<void> Function(String serverId);
typedef ForgetServerRoute = void Function(String serverId);

/// The production implementation. Dependencies are callbacks so the routing
/// policy can be tested without starting real SSH/rendezvous forwarders.
final class DefaultServerConnectionPool implements ServerConnectionPool {
  DefaultServerConnectionPool({
    required this.serverId,
    required MotifServer? Function() serverProvider,
    required ServerRouteResolver resolveRoute,
    required StopServerForwarder stopForwarder,
    required ForgetServerRoute forgetLearnedRoute,
    ServerHttpClientFactory? httpClientFactory,
    ServerWebSocketConnector? webSocketConnector,
    this.healthTtl = const Duration(seconds: 15),
    this.healthCheckInterval = const Duration(seconds: 30),
    DateTime Function()? now,
  }) : _serverProvider = serverProvider,
       _resolveRoute = resolveRoute,
       _stopForwarder = stopForwarder,
       _forgetLearnedRoute = forgetLearnedRoute,
       _httpClientFactory = httpClientFactory ?? _defaultHttpClientFactory,
       _webSocketConnector = webSocketConnector ?? _defaultWebSocketConnector,
       _now = now ?? DateTime.now;

  @override
  final String serverId;
  final MotifServer? Function() _serverProvider;
  final ServerRouteResolver _resolveRoute;
  final StopServerForwarder _stopForwarder;
  final ForgetServerRoute _forgetLearnedRoute;
  final ServerHttpClientFactory _httpClientFactory;
  final ServerWebSocketConnector _webSocketConnector;
  final DateTime Function() _now;
  final Duration healthTtl;
  final Duration healthCheckInterval;

  static http.Client _defaultHttpClientFactory(
    ProxySettings proxy,
    Uint8List? certPin,
  ) => makeHttpClient(proxy, certPin: certPin);

  static WebSocketChannel _defaultWebSocketConnector({
    required Uri uri,
    required Map<String, String> headers,
    required ProxySettings proxy,
    required Uint8List? certPin,
  }) => connectWebSocket(
    uri.toString(),
    headers: headers,
    proxyHost: proxy.proxyHost,
    proxyPort: proxy.proxyPort,
    proxyUser: proxy.username,
    proxyPass: proxy.password,
    certPin: certPin,
  );

  final StreamController<ServerConnectionPoolSnapshot> _snapshots =
      StreamController<ServerConnectionPoolSnapshot>.broadcast(sync: true);
  final Set<_ServerConnectionHandle> _owners = {};
  _HttpConnectionGeneration? _current;
  Future<PingInfo>? _readyInFlight;
  int _routeGeneration = 0;
  int _operationGeneration = 0;
  bool _closed = false;
  bool _foreground = true;
  Timer? _healthTimer;
  ServerConnectionPoolSnapshot _snapshot =
      const ServerConnectionPoolSnapshot.idle();

  @override
  ServerConnectionPoolSnapshot get snapshot => _snapshot;

  @override
  Stream<ServerConnectionPoolSnapshot> get snapshots => _snapshots.stream;

  @override
  ServerConnectionHandle acquire({
    required String ownerId,
    required ConnectionOwnerKind ownerKind,
  }) {
    if (_closed) throw StateError('connection pool $serverId is closed');
    final owner = _ServerConnectionHandle(this, ownerId, ownerKind);
    _owners.add(owner);
    _emit(activeOwners: _owners.length);
    return owner;
  }

  Future<PingInfo> _ensureReady({required bool forceProbe}) {
    if (_closed) return Future.error(StateError('connection pool is closed'));
    final running = _readyInFlight;
    if (running != null) return running;
    late final Future<PingInfo> operation;
    operation = _ensureReadyImpl(forceProbe: forceProbe).whenComplete(() {
      if (identical(_readyInFlight, operation)) _readyInFlight = null;
    });
    _readyInFlight = operation;
    return operation;
  }

  Future<PingInfo> _ensureReadyImpl({required bool forceProbe}) async {
    final server = _serverProvider();
    if (server == null) throw StateError('Unknown server: $serverId');
    final current = _current;
    if (current != null && current.profile == server) {
      final healthyAt = _snapshot.lastHealthyAt;
      final fresh =
          healthyAt != null && _now().difference(healthyAt) < healthTtl;
      if (!forceProbe && fresh && _snapshot.lastPing != null) {
        return _snapshot.lastPing!;
      }
      try {
        _emit(phase: ServerConnectionPoolPhase.probing, error: null);
        final ping = await _ping(current);
        _markHealthy(ping: ping);
        return ping;
      } catch (error) {
        return _establish(server, recoveringFrom: error);
      }
    }
    return _establish(
      server,
      recoveringFrom: current == null ? null : StateError('server changed'),
    );
  }

  Future<PingInfo> _establish(
    MotifServer server, {
    Object? recoveringFrom,
  }) async {
    final sw = Stopwatch()..start();
    final operation = ++_operationGeneration;
    if (recoveringFrom != null) {
      _emit(phase: ServerConnectionPoolPhase.recovering, error: recoveringFrom);
      await _retireCurrent(force: true);
      await _stopForwarder(serverId);
    } else {
      _emit(phase: ServerConnectionPoolPhase.resolving, error: null);
    }

    final candidate = await _resolveCandidate(server, operation);
    final ping = await _probeCandidate(candidate, operation);

    _checkOperation(operation);
    final previous = _current;
    _current = candidate;
    if (previous != null && !identical(previous, candidate)) {
      previous.retire();
      await _closeSocketsForGeneration(previous.generation);
    }
    _markHealthy(ping: ping);
    Log.i(
      'route establish ready server=$serverId generation=${candidate.generation} '
      'target=${candidate.target.endpoint} took=${sw.elapsedMilliseconds}ms '
      'prevalidated=${candidate.prevalidatedPing != null}',
      name: 'motif.resume',
    );
    return ping;
  }

  Future<_HttpConnectionGeneration> _resolveCandidate(
    MotifServer server,
    int operation,
  ) async {
    _emit(phase: ServerConnectionPoolPhase.resolving, error: null);
    final resolution = await _resolveRoute(server);
    try {
      _checkOperation(operation);
    } catch (_) {
      // A resolver may have started a forwarder immediately before a global
      // disconnect superseded it. Fence state and clean that late resource.
      if (resolution case final TransportReady ready) ready.dispose();
      await _stopForwarder(serverId);
      rethrow;
    }
    switch (resolution) {
      case TransportBlocked(:final blocker):
        _emit(
          phase: ServerConnectionPoolPhase.blocked,
          blocker: blocker,
          error: null,
        );
        throw ServerConnectionBlockedException(blocker);
      case final TransportReady ready:
        final target = ready.target;
        final proxy = ready.proxy;
        final certPin = ready.certPin;
        final generation = ++_routeGeneration;
        return _HttpConnectionGeneration(
          generation: generation,
          profile: server,
          target: target,
          proxy: proxy,
          certPin: certPin,
          client:
              ready.takePreconnectedClient() ??
              _httpClientFactory(proxy, certPin),
          prevalidatedPing: ready.prevalidatedPing,
        );
    }
  }

  Future<PingInfo> _probeCandidate(
    _HttpConnectionGeneration candidate,
    int operation,
  ) async {
    _emit(
      phase: ServerConnectionPoolPhase.probing,
      routeGeneration: candidate.generation,
    );
    try {
      final ping = candidate.prevalidatedPing ?? await _ping(candidate);
      _checkOperation(operation);
      if (!ping.isMotifServer) {
        throw RpcException(
          'Not a motif server at ${candidate.target.endpoint}',
        );
      }
      return ping;
    } catch (_) {
      candidate.retire(force: true);
      rethrow;
    }
  }

  Future<PingInfo> _ping(_HttpConnectionGeneration generation) async {
    final response = await _sendOnGeneration(
      generation,
      const ServerHttpRequest(
        method: 'GET',
        path: '/ping',
        retry: RpcRetryPolicy.safeOnce,
        timeout: Duration(seconds: 8),
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw RpcException('ping HTTP ${response.statusCode}');
    }
    return PingInfo.fromJson(
      (jsonDecode(response.bodyText) as Map).cast<String, Object?>(),
    );
  }

  void _checkOperation(int operation) {
    if (_closed || operation != _operationGeneration) {
      throw StateError('connection pool operation was superseded');
    }
  }

  @override
  Future<void> reconnect({Object? cause}) async {
    if (_closed) throw StateError('connection pool is closed');
    final running = _readyInFlight;
    if (running != null) {
      await running;
      return;
    }
    final server = _serverProvider();
    if (server == null) throw StateError('Unknown server: $serverId');
    late final Future<PingInfo> recovery;
    recovery =
        _establish(
          server,
          recoveringFrom: cause ?? StateError('explicit reconnect'),
        ).whenComplete(() {
          if (identical(_readyInFlight, recovery)) _readyInFlight = null;
        });
    _readyInFlight = recovery;
    await recovery;
  }

  Future<ServerHttpResponse> _send(ServerHttpRequest request) async {
    await _ensureReady(forceProbe: false);
    var generation = _current;
    if (generation == null) throw StateError('connection pool is not ready');
    try {
      return await _sendOnGeneration(generation, request);
    } catch (error, stackTrace) {
      if (!_isTransportFailure(error)) rethrow;
      if (request.retry == RpcRetryPolicy.safeOnce) {
        await _recoverAfterFailure(error);
        generation = _current;
        if (generation == null) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        return _sendOnGeneration(generation, request);
      }
      if (_mayHaveRequestBody(request)) {
        unawaited(
          _recoverAfterFailure(
            error,
          ).then<void>((_) {}, onError: (Object _) {}),
        );
        throw UncertainDeliveryException(error);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _recoverAfterFailure(Object error) async {
    final running = _readyInFlight;
    if (running != null) {
      await running;
      return;
    }
    late final Future<PingInfo> recovery;
    final server = _serverProvider();
    if (server == null) throw StateError('Unknown server: $serverId');
    recovery = _establish(server, recoveringFrom: error).whenComplete(() {
      if (identical(_readyInFlight, recovery)) _readyInFlight = null;
    });
    _readyInFlight = recovery;
    await recovery;
  }

  static bool _mayHaveRequestBody(ServerHttpRequest request) {
    final method = request.method.toUpperCase();
    return method != 'GET' && method != 'HEAD' && method != 'OPTIONS';
  }

  static bool _isTransportFailure(Object error) =>
      error is http.ClientException || error is TimeoutException;

  Future<ServerHttpResponse> _sendOnGeneration(
    _HttpConnectionGeneration generation,
    ServerHttpRequest request,
  ) async {
    generation.beginRequest();
    try {
      final target = generation.target;
      final uri = Uri(
        scheme: target.scheme,
        host: target.host,
        port: target.port,
        path: request.path,
        queryParameters: request.query.isEmpty ? null : request.query,
      );
      final outgoing = http.Request(request.method, uri)
        ..headers.addAll({
          'Authorization': 'Bearer ${target.token}',
          if (request.scope case SessionRequestScope(:final attachmentId))
            'X-Motif-Session': attachmentId,
          ...request.headers,
        });
      final body = request.body;
      if (body != null) outgoing.bodyBytes = body;
      final streamed = request.timeout == null
          ? await generation.client.send(outgoing)
          : await generation.client.send(outgoing).timeout(request.timeout!);
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _markHealthy();
      }
      return ServerHttpResponse(
        statusCode: response.statusCode,
        headers: response.headers,
        body: response.bodyBytes,
      );
    } finally {
      generation.endRequest();
    }
  }

  Future<MotifRpcResponse> _rpc(
    String method, {
    required Map<String, Object?> params,
    required MotifRequestScope scope,
    required RpcRetryPolicy retry,
    required Duration? timeout,
  }) async {
    final response = await _send(
      ServerHttpRequest(
        method: 'POST',
        path: '/rpc/$method',
        headers: const {'Content-Type': 'application/json'},
        body: Uint8List.fromList(utf8.encode(jsonEncode(params))),
        scope: scope,
        retry: retry,
        timeout:
            timeout ??
            (method == 'fs.write'
                ? const Duration(seconds: 60)
                : const Duration(seconds: 30)),
      ),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      try {
        final error = (jsonDecode(response.bodyText) as Map)
            .cast<String, Object?>();
        throw RpcException(
          (error['message'] as String?) ?? 'error',
          code: (error['code'] as num?)?.toInt(),
        );
      } on RpcException {
        rethrow;
      } catch (_) {
        throw RpcException('HTTP ${response.statusCode}');
      }
    }
    final Object? decoded = response.body.isEmpty
        ? const <String, Object?>{}
        : jsonDecode(response.bodyText);
    return MotifRpcResponse(
      body: decoded is Map
          ? decoded.cast<String, Object?>()
          : const <String, Object?>{},
      sessionAttachmentId: response.headers['x-motif-session'],
    );
  }

  Future<ExclusiveWebSocketConnection> _openWebSocket(
    _ServerConnectionHandle owner,
    ServerWebSocketRequest request,
  ) async {
    while (true) {
      await _ensureReady(forceProbe: false);
      final generation = _current;
      if (generation == null) throw StateError('connection pool is not ready');
      final target = generation.target;
      final query = <String, String>{
        ...request.query,
        if (request.scope case SessionRequestScope(:final attachmentId))
          'session': attachmentId,
        'token': target.token,
      };
      final uri = Uri(
        scheme: target.scheme == 'https' ? 'wss' : 'ws',
        host: target.host,
        port: target.port,
        path: request.path,
        queryParameters: query,
      );
      final socket = _webSocketConnector(
        uri: uri,
        headers: {'Authorization': 'Bearer ${target.token}'},
        proxy: generation.proxy,
        certPin: generation.certPin,
      );
      final connection = _ExclusiveWebSocketConnection(
        routeGeneration: generation.generation,
        socket: socket,
        onDone: (connection, locallyClosed) =>
            _socketDone(owner, connection, locallyClosed),
        onMessage: _markHealthy,
      );
      owner._sockets.add(connection);
      try {
        await connection.ready;
      } catch (error, stackTrace) {
        await connection.close();
        if (identical(_current, generation)) {
          try {
            await _ensureReady(forceProbe: true);
          } catch (_) {
            // ensureReady already attempted single-flight route recovery.
          }
        }
        if (!identical(_current, generation) && !owner.isClosed) continue;
        Error.throwWithStackTrace(error, stackTrace);
      }
      if (identical(_current, generation) && !owner.isClosed) {
        return connection;
      }
      await connection.close(4001, 'route changed');
      if (owner.isClosed) throw StateError('connection handle is closed');
    }
  }

  void _socketDone(
    _ServerConnectionHandle owner,
    _ExclusiveWebSocketConnection connection,
    bool locallyClosed,
  ) {
    owner._sockets.remove(connection);
    if (locallyClosed || _closed) return;
    final current = _current;
    if (current == null || current.generation != connection.routeGeneration) {
      return;
    }
    // A WebSocket is exclusive and its loss is socket-local until the shared
    // HTTP route fails an explicit ping.
    unawaited(
      _ensureReady(forceProbe: true).then<void>((_) {}, onError: (Object _) {}),
    );
  }

  Future<void> _closeSocketsForGeneration(int generation) async {
    final sockets = <_ExclusiveWebSocketConnection>[
      for (final owner in _owners)
        for (final socket in owner._sockets)
          if (socket.routeGeneration == generation) socket,
    ];
    await Future.wait([
      for (final socket in sockets) socket.close(4001, 'route changed'),
    ]);
  }

  void _markHealthy({PingInfo? ping}) {
    _emit(
      phase: ServerConnectionPoolPhase.ready,
      routeGeneration: _current?.generation ?? _snapshot.routeGeneration,
      lastPing: ping ?? _snapshot.lastPing,
      lastHealthyAt: _now(),
      blocker: null,
      error: null,
    );
    _scheduleHealthCheck();
  }

  void setForeground(bool foreground) {
    if (_closed || _foreground == foreground) return;
    _foreground = foreground;
    _healthTimer?.cancel();
    _healthTimer = null;
    if (!foreground || _owners.isEmpty || _current == null) return;
    unawaited(
      _ensureReady(
        forceProbe: true,
      ).then<void>((_) => _scheduleHealthCheck(), onError: (Object _) {}),
    );
  }

  void _scheduleHealthCheck() {
    if (_closed || !_foreground || _owners.isEmpty || _current == null) return;
    _healthTimer?.cancel();
    _healthTimer = Timer(healthCheckInterval, () {
      _healthTimer = null;
      if (_closed || !_foreground || _owners.isEmpty || _current == null) {
        return;
      }
      unawaited(
        _ensureReady(forceProbe: true).then<void>(
          (_) => _scheduleHealthCheck(),
          onError: (Object _) => _scheduleHealthCheck(),
        ),
      );
    });
  }

  void _emit({
    ServerConnectionPoolPhase? phase,
    int? routeGeneration,
    int? activeOwners,
    PingInfo? lastPing,
    DateTime? lastHealthyAt,
    ConnectionBlocker? blocker,
    Object? error,
  }) {
    _snapshot = ServerConnectionPoolSnapshot(
      phase: phase ?? _snapshot.phase,
      routeGeneration: routeGeneration ?? _snapshot.routeGeneration,
      activeOwners: activeOwners ?? _snapshot.activeOwners,
      lastPing: lastPing ?? _snapshot.lastPing,
      lastHealthyAt: lastHealthyAt ?? _snapshot.lastHealthyAt,
      blocker: blocker,
      error: error,
    );
    if (!_snapshots.isClosed) _snapshots.add(_snapshot);
  }

  Future<void> _retireCurrent({required bool force}) async {
    final current = _current;
    _current = null;
    if (current == null) return;
    current.retire(force: force);
    await _closeSocketsForGeneration(current.generation);
  }

  void _removeOwner(_ServerConnectionHandle owner) {
    _owners.remove(owner);
    if (_owners.isEmpty) {
      _healthTimer?.cancel();
      _healthTimer = null;
    }
    _emit(activeOwners: _owners.length);
  }

  @override
  Future<void> disconnectAll({bool forgetLearnedRoute = false}) async {
    if (_closed) return;
    _operationGeneration++;
    _healthTimer?.cancel();
    _healthTimer = null;
    _readyInFlight = null;
    await _retireCurrent(force: true);
    await _stopForwarder(serverId);
    if (forgetLearnedRoute) _forgetLearnedRoute(serverId);
    _snapshot = ServerConnectionPoolSnapshot(
      phase: ServerConnectionPoolPhase.disconnected,
      routeGeneration: _routeGeneration,
      activeOwners: _owners.length,
      lastPing: null,
      lastHealthyAt: null,
      blocker: null,
      error: null,
    );
    if (!_snapshots.isClosed) _snapshots.add(_snapshot);
  }

  @override
  Future<void> dispose({bool forgetLearnedRoute = false}) async {
    if (_closed) return;
    await disconnectAll(forgetLearnedRoute: forgetLearnedRoute);
    _closed = true;
    for (final owner in _owners.toList()) {
      await owner.close();
    }
    _emit(phase: ServerConnectionPoolPhase.closed, activeOwners: 0);
    await _snapshots.close();
  }
}

final class _HttpConnectionGeneration {
  _HttpConnectionGeneration({
    required this.generation,
    required this.profile,
    required this.target,
    required this.proxy,
    required this.certPin,
    required this.client,
    this.prevalidatedPing,
  });

  final int generation;
  final MotifServer profile;
  final MotifServer target;
  final ProxySettings proxy;
  final Uint8List? certPin;
  final http.Client client;
  final PingInfo? prevalidatedPing;
  int _inFlight = 0;
  bool _retired = false;
  bool _closed = false;

  void beginRequest() => _inFlight++;

  void endRequest() {
    _inFlight--;
    if (_retired && _inFlight == 0) _close();
  }

  void retire({bool force = false}) {
    _retired = true;
    if (force || _inFlight == 0) _close();
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    client.close();
  }
}

final class _ServerConnectionHandle implements ServerConnectionHandle {
  _ServerConnectionHandle(this._pool, this.ownerId, this.ownerKind);

  final DefaultServerConnectionPool _pool;
  final Set<_ExclusiveWebSocketConnection> _sockets = {};

  @override
  final String ownerId;
  @override
  final ConnectionOwnerKind ownerKind;
  @override
  bool isClosed = false;

  void _checkOpen() {
    if (isClosed) throw StateError('connection handle $ownerId is closed');
  }

  @override
  Future<PingInfo> ensureReady({bool forceProbe = false}) {
    _checkOpen();
    return _pool._ensureReady(forceProbe: forceProbe);
  }

  @override
  Future<MotifRpcResponse> rpc(
    String method, {
    Map<String, Object?> params = const {},
    MotifRequestScope scope = const ServerRequestScope(),
    RpcRetryPolicy retry = RpcRetryPolicy.never,
    Duration? timeout,
  }) {
    _checkOpen();
    return _pool._rpc(
      method,
      params: params,
      scope: scope,
      retry: retry,
      timeout: timeout,
    );
  }

  @override
  Future<ServerHttpResponse> send(ServerHttpRequest request) {
    _checkOpen();
    return _pool._send(request);
  }

  @override
  Future<ExclusiveWebSocketConnection> openWebSocket(
    ServerWebSocketRequest request,
  ) {
    _checkOpen();
    return _pool._openWebSocket(this, request);
  }

  @override
  Future<void> close() async {
    if (isClosed) return;
    isClosed = true;
    final sockets = _sockets.toList();
    _sockets.clear();
    await Future.wait([for (final socket in sockets) socket.close()]);
    _pool._removeOwner(this);
  }
}

final class _ExclusiveWebSocketConnection
    implements ExclusiveWebSocketConnection {
  _ExclusiveWebSocketConnection({
    required this.routeGeneration,
    required WebSocketChannel socket,
    required void Function(
      _ExclusiveWebSocketConnection connection,
      bool locallyClosed,
    )
    onDone,
    required void Function() onMessage,
  }) : _socket = socket,
       _onDone = onDone,
       _onMessage = onMessage {
    _ready = socket.ready;
    _subscription = socket.stream.listen(
      (message) {
        _onMessage();
        if (!_messages.isClosed) _messages.add(message);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_messages.isClosed) _messages.addError(error, stackTrace);
        _finish();
      },
      onDone: _finish,
      cancelOnError: true,
    );
  }

  final WebSocketChannel _socket;
  final void Function(_ExclusiveWebSocketConnection, bool) _onDone;
  final void Function() _onMessage;
  // A physical socket can deliver frames immediately after `ready`, before
  // the owner installs its listener. Single-subscription controllers buffer
  // those frames; broadcast controllers would drop PTY metadata/cursors.
  final StreamController<Object?> _messages = StreamController<Object?>(
    sync: true,
  );
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<Object?> _subscription;
  late final Future<void> _ready;
  bool _locallyClosed = false;
  bool _finished = false;

  @override
  final int routeGeneration;
  @override
  Stream<Object?> get messages => _messages.stream;
  @override
  Future<void> get ready => _ready;
  @override
  Future<void> get done => _done.future;
  @override
  int? get closeCode => _socket.closeCode;
  @override
  String? get closeReason => _socket.closeReason;

  @override
  void send(Object? value) {
    if (_finished) throw StateError('WebSocket is closed');
    _socket.sink.add(value);
  }

  void _finish() {
    if (_finished) return;
    _finished = true;
    if (!_done.isCompleted) _done.complete();
    if (!_messages.isClosed) unawaited(_messages.close());
    _onDone(this, _locallyClosed);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_finished) return;
    _locallyClosed = true;
    try {
      await _socket.sink.close(code, reason);
    } finally {
      await _subscription.cancel();
      _finish();
    }
  }
}

/// Process-wide owner of exactly one pool per configured server id.
final class ServerConnectionPoolRegistry {
  ServerConnectionPoolRegistry({
    required MotifServer? Function(String serverId) serverProvider,
    required TransportResolver resolver,
    ServerHttpClientFactory? httpClientFactory,
    ServerWebSocketConnector? webSocketConnector,
    Duration healthTtl = const Duration(seconds: 15),
    DateTime Function()? now,
    Duration healthCheckInterval = const Duration(seconds: 30),
  }) : _serverProvider = serverProvider,
       _resolver = resolver,
       _httpClientFactory = httpClientFactory,
       _webSocketConnector = webSocketConnector,
       _healthTtl = healthTtl,
       _healthCheckInterval = healthCheckInterval,
       _now = now;

  final MotifServer? Function(String serverId) _serverProvider;
  final TransportResolver _resolver;
  final ServerHttpClientFactory? _httpClientFactory;
  final ServerWebSocketConnector? _webSocketConnector;
  final Duration _healthTtl;
  final Duration _healthCheckInterval;
  final DateTime Function()? _now;
  final Map<String, DefaultServerConnectionPool> _pools = {};
  bool _closed = false;

  ServerConnectionPool poolFor(String serverId) {
    if (_closed) throw StateError('connection pool registry is closed');
    if (_serverProvider(serverId) == null) {
      throw StateError('Unknown server: $serverId');
    }
    return _pools.putIfAbsent(
      serverId,
      () => DefaultServerConnectionPool(
        serverId: serverId,
        serverProvider: () => _serverProvider(serverId),
        resolveRoute: _resolver.resolve,
        stopForwarder: _resolver.stopForwarder,
        forgetLearnedRoute: _resolver.forgetRzvDirect,
        httpClientFactory: _httpClientFactory,
        webSocketConnector: _webSocketConnector,
        healthTtl: _healthTtl,
        healthCheckInterval: _healthCheckInterval,
        now: _now,
      ),
    );
  }

  ServerConnectionPool? existing(String serverId) => _pools[serverId];

  void setForeground(bool foreground) {
    for (final pool in _pools.values) {
      pool.setForeground(foreground);
    }
  }

  Future<void> remove(String serverId) async {
    final pool = _pools.remove(serverId);
    if (pool == null) {
      _resolver.forgetRzvDirect(serverId);
      return;
    }
    await pool.dispose(forgetLearnedRoute: true);
  }

  Future<void> dispose() async {
    if (_closed) return;
    _closed = true;
    final pools = _pools.values.toList();
    _pools.clear();
    await Future.wait([for (final pool in pools) pool.dispose()]);
  }
}
