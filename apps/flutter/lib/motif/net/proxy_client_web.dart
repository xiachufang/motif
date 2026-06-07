import 'package:http/http.dart' as http;

/// Web: no proxy control (the browser manages networking), so [proxyHost] etc.
/// are inert and the default client is used.
class ProxySettings {
  final String? proxyHost;
  final int? proxyPort;
  final String? username;
  final String? password;
  const ProxySettings({this.proxyHost, this.proxyPort, this.username, this.password});

  static const none = ProxySettings();
  bool get isActive => false;
}

http.Client makeHttpClient(ProxySettings p) => http.Client();
