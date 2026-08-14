import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/state/server/server_connection_pool.dart';
import 'package:motif/motif/state/server/transport_resolver.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

DefaultServerConnectionPool fixedRouteConnectionPool(
  MotifServer server, {
  http.Client Function(ProxySettings proxy, Uint8List? certPin)?
  httpClientFactory,
  WebSocketChannel Function({
    required Uri uri,
    required Map<String, String> headers,
    required ProxySettings proxy,
    required Uint8List? certPin,
  })?
  webSocketConnector,
  Duration healthTtl = const Duration(days: 1),
}) => DefaultServerConnectionPool(
  serverId: server.id,
  serverProvider: () => server,
  resolveRoute: (profile) async =>
      TransportReady(target: profile, proxy: ProxySettings.none),
  stopForwarder: (_) async {},
  forgetLearnedRoute: (_) {},
  learnRoute: (_, _) => false,
  httpClientFactory: httpClientFactory,
  webSocketConnector: webSocketConnector,
  healthTtl: healthTtl,
);
