import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Web: the browser WebSocket API cannot set upgrade headers, use a proxy, or
/// pin certificates, so [headers]/[proxyHost]/[proxyPort]/[certPin] are ignored.
/// Auth rides the query string; the browser manages networking. (The rzv
/// transport is native-only anyway.)
WebSocketChannel connectWebSocket(
  String url, {
  Map<String, dynamic>? headers,
  String? proxyHost,
  int? proxyPort,
  String? proxyUser,
  String? proxyPass,
  Uint8List? certPin,
}) {
  return WebSocketChannel.connect(Uri.parse(url));
}
