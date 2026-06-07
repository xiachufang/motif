import 'package:web_socket_channel/web_socket_channel.dart';

/// Web: the browser WebSocket API cannot set upgrade headers or use a proxy, so
/// [headers]/[proxyHost]/[proxyPort] are ignored. Auth rides the query string;
/// the browser manages networking.
WebSocketChannel connectWebSocket(
  String url, {
  Map<String, dynamic>? headers,
  String? proxyHost,
  int? proxyPort,
  String? proxyUser,
  String? proxyPass,
}) {
  return WebSocketChannel.connect(Uri.parse(url));
}
