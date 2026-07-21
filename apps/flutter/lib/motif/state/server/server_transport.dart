import 'dart:async';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../net/proxy_client.dart';
import '../../net/rpc_client.dart';

/// Server-scoped command transport. It is never attached to a Session and has
/// no terminal/event streams.
abstract interface class ServerTransport {
  bool get isLive;
  PingInfo? get lastPing;

  Future<PingInfo> connect(
    MotifServer server, {
    required bool force,
    required ProxySettings proxy,
    required Uint8List? certPin,
  });

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

final class RpcServerTransport implements ServerTransport {
  RpcClient? _rpc;

  @override
  bool get isLive => _rpc != null;

  @override
  PingInfo? lastPing;

  @override
  Future<PingInfo> connect(
    MotifServer server, {
    required bool force,
    required ProxySettings proxy,
    required Uint8List? certPin,
  }) async {
    if (!force && _rpc != null && lastPing != null) return lastPing!;
    await close();
    final rpc = RpcClient()
      ..connect(
        host: server.host,
        port: server.port,
        scheme: server.scheme,
        token: server.token,
        proxy: proxy,
        certPin: certPin,
      );
    try {
      final ping = await _pingWithRetry(rpc, server);
      if (!ping.isMotifServer) {
        throw RpcException('Not a motif server at ${server.endpoint}');
      }
      _rpc = rpc;
      lastPing = ping;
      return ping;
    } catch (_) {
      await rpc.close();
      rethrow;
    }
  }

  Future<PingInfo> _pingWithRetry(RpcClient rpc, MotifServer server) async {
    try {
      return await rpc.ping();
    } catch (_) {
      await Future<void>.delayed(
        server.kind == ServerKind.tailscale
            ? const Duration(milliseconds: 900)
            : const Duration(milliseconds: 350),
      );
      return rpc.ping();
    }
  }

  @override
  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    final rpc = _rpc;
    if (rpc == null) throw const RpcException('not connected');
    try {
      return await rpc.call(method, params);
    } on http.ClientException catch (error) {
      throw ServerTransportException(error);
    } on TimeoutException catch (error) {
      throw ServerTransportException(error);
    }
  }

  @override
  Future<String> writeFileBytes(String path, Uint8List data) {
    final rpc = _rpc;
    if (rpc == null) throw const RpcException('not connected');
    return rpc.writeFileBinary(path, data);
  }

  @override
  Future<void> close() async {
    final rpc = _rpc;
    _rpc = null;
    lastPing = null;
    await rpc?.close();
  }
}
