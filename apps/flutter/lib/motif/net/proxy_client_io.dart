import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:socks5_proxy/socks_client.dart' as socks;

import 'ws_channel_io.dart' show certMatchesPin;

/// Proxy routing for RPC. When [proxyHost] is set, traffic is tunneled through
/// that **SOCKS5** proxy (the libtailscale/tsnet loopback is SOCKS5-only — its
/// HTTP port is the localapi, not a forward/CONNECT proxy — so SOCKS5 is the
/// only way through). `dart:io` has no built-in SOCKS5, so we use the
/// `socks5_proxy` package's connectionFactory hook. tsnet auth is username
/// `"tsnet"` + the loopback proxy credential as the password.
class ProxySettings {
  final String? proxyHost;
  final int? proxyPort;
  final String? username;
  final String? password;
  const ProxySettings({this.proxyHost, this.proxyPort, this.username, this.password});

  static const none = ProxySettings();
  bool get isActive => proxyHost != null && proxyPort != null;
}

/// Build a `dart:io` [HttpClient] that tunnels every connection through the
/// SOCKS5 proxy in [p] (used for both the http client and the WebSocket
/// customClient so they share the route). When [certPin] is set, the server's
/// leaf cert is pinned to `sha256(cert.der) == certPin` (the rzv E2E path).
HttpClient makeProxiedHttpClient(ProxySettings p, {Uint8List? certPin}) {
  final c = HttpClient();
  if (p.isActive) {
    socks.SocksTCPClient.assignToHttpClient(c, [
      socks.ProxySettings(
        InternetAddress(p.proxyHost!),
        p.proxyPort!,
        username: p.username,
        password: p.password,
      ),
    ]);
  }
  if (certPin != null) {
    c.badCertificateCallback =
        (cert, host, port) => certMatchesPin(cert, certPin);
  }
  return c;
}

/// A `package:http` Client that routes through [p] on native, optionally
/// pinning motifd's cert via [certPin] (rzv E2E).
http.Client makeHttpClient(ProxySettings p, {Uint8List? certPin}) {
  if (!p.isActive && certPin == null) return http.Client();
  return IOClient(makeProxiedHttpClient(p, certPin: certPin));
}
