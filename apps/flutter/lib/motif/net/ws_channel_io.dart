import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:socks5_proxy/socks_client.dart' as socks;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Native: open a WebSocket with custom upgrade headers (Bearer auth). When a
/// proxy is given (the libtailscale/tsnet loopback) the upgrade is tunneled
/// through it via a SOCKS5-assigned customClient, so PTY/event streams reach the
/// tailnet peer. (tsnet's loopback is SOCKS5-only; auth = user "tsnet" + cred.)
///
/// When [certPin] is set (the rzv end-to-end path), the upgrade runs over TLS
/// (`wss://`) and the server's leaf certificate is pinned: it is accepted iff
/// `sha256(cert.der) == certPin`. The loopback forwarder stays a blind pipe;
/// TLS terminates at motifd.
WebSocketChannel connectWebSocket(
  String url, {
  Map<String, dynamic>? headers,
  String? proxyHost,
  int? proxyPort,
  String? proxyUser,
  String? proxyPass,
  Uint8List? certPin,
}) {
  final hasProxy = proxyHost != null && proxyPort != null;
  if (hasProxy || certPin != null) {
    final client = HttpClient();
    if (hasProxy) {
      socks.SocksTCPClient.assignToHttpClient(client, [
        socks.ProxySettings(
          InternetAddress(proxyHost),
          proxyPort,
          username: proxyUser,
          password: proxyPass,
        ),
      ]);
    }
    if (certPin != null) {
      client.badCertificateCallback = (cert, host, port) =>
          certMatchesPin(cert, certPin);
    }
    return IOWebSocketChannel.connect(
      Uri.parse(url),
      headers: headers,
      customClient: client,
    );
  }
  return IOWebSocketChannel.connect(Uri.parse(url), headers: headers);
}

/// Constant-time check that [cert]'s DER hashes to [pin] (the rzv cert pin
/// delivered out-of-band via the pairing QR).
bool certMatchesPin(X509Certificate cert, Uint8List pin) {
  final got = sha256.convert(cert.der).bytes;
  if (got.length != pin.length) return false;
  var diff = 0;
  for (var i = 0; i < pin.length; i++) {
    diff |= got[i] ^ pin[i];
  }
  return diff == 0;
}
