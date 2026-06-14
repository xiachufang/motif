import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Web: no proxy control (the browser manages networking), so [proxyHost] etc.
/// are inert and the default client is used. Cert pinning ([certPin]) isn't
/// available in the browser either; the rzv transport is native-only.
class ProxySettings {
  final String? proxyHost;
  final int? proxyPort;
  final String? username;
  final String? password;
  const ProxySettings({this.proxyHost, this.proxyPort, this.username, this.password});

  static const none = ProxySettings();
  bool get isActive => false;
}

http.Client makeHttpClient(ProxySettings p, {Uint8List? certPin}) =>
    http.Client();
