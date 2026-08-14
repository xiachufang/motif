import 'dart:convert';
import 'dart:typed_data';

import '../../models/motif_proto.dart';
import '../../net/rpc_error.dart';
import 'server_connection_pool.dart';

/// Server-scoped command transport. It is never attached to a Session and has
/// no terminal/event streams.
abstract interface class ServerTransport {
  bool get isLive;
  PingInfo? get lastPing;

  Future<PingInfo> connect({required bool force});

  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params,
  ]);

  Future<String> writeFileBytes(String path, Uint8List data);
  Future<void> close();
}

/// A control-channel failure for which rebuilding the transport is useful.
final class ServerTransportException implements Exception {
  const ServerTransportException(this.cause);

  final Object cause;

  @override
  String toString() => '$cause';
}

/// It owns a server-home handle. HTTP connection ownership,
/// route details and ping health remain entirely inside [pool].
final class PoolServerTransport implements ServerTransport {
  PoolServerTransport(this.pool);

  final ServerConnectionPool pool;
  ServerConnectionHandle? _handle;

  ServerConnectionHandle get _activeHandle => _handle ??= pool.acquire(
    ownerId: 'server-home:${pool.serverId}',
    ownerKind: ConnectionOwnerKind.serverHome,
  );

  @override
  bool get isLive =>
      _handle?.isClosed == false &&
      pool.snapshot.phase == ServerConnectionPoolPhase.ready;

  @override
  PingInfo? get lastPing => pool.snapshot.lastPing;

  @override
  Future<PingInfo> connect({required bool force}) =>
      _activeHandle.ensureReady(forceProbe: force);

  /// Used by the server runtime before its synthetic establish step. Keeping
  /// this separate lets the existing state machine project resolving/probing
  /// UI without exposing the resolved target to feature code.
  Future<PingInfo> ensureReady({required bool forceProbe}) =>
      _activeHandle.ensureReady(forceProbe: forceProbe);

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final response = await _activeHandle.rpc(
      method,
      params: params,
      retry: _safeServerReadMethods.contains(method)
          ? RpcRetryPolicy.safeOnce
          : RpcRetryPolicy.never,
    );
    return response.body;
  }

  @override
  Future<String> writeFileBytes(String path, Uint8List data) async {
    final response = await _activeHandle.send(
      ServerHttpRequest(
        method: 'POST',
        path: '/rpc/fs.write',
        query: {'path': path, 'force': 'true'},
        headers: const {'Content-Type': 'application/octet-stream'},
        body: data,
        timeout: const Duration(seconds: 60),
      ),
    );
    if (response.statusCode != 200) {
      throw RpcException(
        'fs.write (binary) failed: HTTP ${response.statusCode}',
      );
    }
    return (jsonDecode(response.bodyText) as Map)['sha256'] as String;
  }

  /// Closes only the server-home owner. The shared pool survives recovery and
  /// feature teardown.
  @override
  Future<void> close() async {
    final handle = _handle;
    _handle = null;
    await handle?.close();
  }

  /// Explicit server disconnect is the one server-home action allowed to tear
  /// down every owner and route resource.
  Future<void> disconnectAll({bool forgetLearnedRoute = false}) async {
    await close();
    await pool.disconnectAll(forgetLearnedRoute: forgetLearnedRoute);
  }
}

const _safeServerReadMethods = <String>{
  'session.list',
  'fs.list',
  'fs.read',
  'fs.stat',
  'device.get',
  'device.status',
};
