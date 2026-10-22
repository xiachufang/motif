/// Shared policy for web destinations emitted by remote terminals and Codex.
Uri? parseWebLink(String value) {
  if (value.isEmpty || value != value.trim()) return null;
  if (value.codeUnits.any((unit) => unit <= 0x20 || unit == 0x7f)) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.userInfo.isNotEmpty ||
      uri.port < 1 ||
      uri.port > 65535) {
    return null;
  }
  return uri;
}

/// IP literals and localhost refer to the network of the selected server.
/// Uri's parsers validate IPv4/IPv6 without DNS or a dart:io dependency.
bool webLinkNeedsServerProxy(Uri uri) {
  final host = uri.host.replaceAll('[', '').replaceAll(']', '');
  if (host.toLowerCase() == 'localhost') return true;
  try {
    if (host.contains(':')) {
      Uri.parseIPv6Address(host);
    } else {
      Uri.parseIPv4Address(host);
    }
    return true;
  } on FormatException {
    return false;
  }
}

Uri proxiedWebLink(Uri original, Uri local) =>
    original.replace(host: local.host, port: local.port);

/// One temporary proxy, owned by the browser route that displays it.
final class WebLinkProxy {
  const WebLinkProxy({required this.url, required this.close});

  final Uri url;
  final Future<void> Function() close;
}

typedef WebLinkProxyFactory = Future<WebLinkProxy> Function(Uri url);
