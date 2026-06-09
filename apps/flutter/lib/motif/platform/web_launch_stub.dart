class WebLaunchLocation {
  final Uri uri;
  final String token;

  const WebLaunchLocation({required this.uri, required this.token});
}

WebLaunchLocation? currentWebLaunchLocation() => null;

void scrubWebLaunchToken() {}
