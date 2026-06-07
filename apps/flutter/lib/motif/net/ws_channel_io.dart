import 'dart:io';

import 'package:socks5_proxy/socks_client.dart' as socks;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native: open a WebSocket with custom upgrade headers (Bearer auth). When a
/// proxy is given (the libtailscale/tsnet loopback) the upgrade is tunneled
/// through it via a SOCKS5-assigned customClient, so PTY/event streams reach the
/// tailnet peer. (tsnet's loopback is SOCKS5-only; auth = user "tsnet" + cred.)
WebSocketChannel connectWebSocket(
  String url, {
  Map<String, dynamic>? headers,
  String? proxyHost,
  int? proxyPort,
  String? proxyUser,
  String? proxyPass,
}) {
  if (proxyHost != null && proxyPort != null) {
    final client = HttpClient();
    socks.SocksTCPClient.assignToHttpClient(client, [
      socks.ProxySettings(
        InternetAddress(proxyHost),
        proxyPort,
        username: proxyUser,
        password: proxyPass,
      ),
    ]);
    return IOWebSocketChannel.connect(
      Uri.parse(url),
      headers: headers,
      customClient: client,
    );
  }
  return IOWebSocketChannel.connect(Uri.parse(url), headers: headers);
}
