import 'package:web/web.dart' as web;

class WebLaunchLocation {
  final Uri uri;
  final String token;

  const WebLaunchLocation({required this.uri, required this.token});
}

WebLaunchLocation? currentWebLaunchLocation() {
  final uri = Uri.base;
  if (uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return null;
  }
  return WebLaunchLocation(uri: uri, token: uri.queryParameters['token'] ?? '');
}

void scrubWebLaunchToken() {
  final uri = Uri.base;
  if (!uri.queryParameters.containsKey('token')) return;
  final query = Map<String, String>.from(uri.queryParameters)..remove('token');
  final next = uri.replace(queryParameters: query.isEmpty ? null : query);
  web.window.history.replaceState(null, web.document.title, next.toString());
}
