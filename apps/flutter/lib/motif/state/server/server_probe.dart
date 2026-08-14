/// One-shot identity probe for a server that has not entered the configured
/// server registry yet.
///
/// Normal application traffic must use [ServerConnectionPool]. This helper is
/// deliberately stateless: it creates one temporary HTTP client, performs one
/// `/ping`, and closes the client before returning.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../models/motif_proto.dart';
import '../../models/settings.dart';
import '../../net/proxy_client.dart';
import '../../net/rpc_error.dart';

typedef ServerProbeHttpClientFactory =
    http.Client Function(ProxySettings proxy, Uint8List? certPin);

final class ServerProbe {
  const ServerProbe({ServerProbeHttpClientFactory? httpClientFactory})
    : _httpClientFactory = httpClientFactory ?? _defaultHttpClientFactory;

  final ServerProbeHttpClientFactory _httpClientFactory;

  /// Test seam for the connection-list one-shot probe.
  static ServerProbeHttpClientFactory? debugHttpClientFactory;

  static http.Client _defaultHttpClientFactory(
    ProxySettings proxy,
    Uint8List? certPin,
  ) =>
      debugHttpClientFactory?.call(proxy, certPin) ??
      makeHttpClient(proxy, certPin: certPin);

  Future<PingInfo> ping(
    MotifServer target, {
    ProxySettings proxy = ProxySettings.none,
    Uint8List? certPin,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final client = _httpClientFactory(proxy, certPin);
    try {
      final response = await client
          .get(
            Uri(
              scheme: target.scheme,
              host: target.host,
              port: target.port,
              path: '/ping',
            ),
          )
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw RpcException('ping HTTP ${response.statusCode}');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) throw const RpcException('invalid ping response');
      return PingInfo.fromJson(decoded.cast<String, Object?>());
    } finally {
      client.close();
    }
  }
}
