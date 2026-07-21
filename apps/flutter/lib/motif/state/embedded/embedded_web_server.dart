import '../../models/settings.dart';

const embeddedWebServerId = 'embedded-motifd';

MotifServer? embeddedWebServerFromUri(Uri uri, {String token = ''}) {
  if (uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return MotifServer(
    id: embeddedWebServerId,
    name: 'This motifd',
    host: uri.host,
    port: _originPort(uri),
    scheme: uri.scheme,
    token: token,
    kind: ServerKind.direct,
  );
}

int _originPort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme == 'https' ? 443 : 80;
}
