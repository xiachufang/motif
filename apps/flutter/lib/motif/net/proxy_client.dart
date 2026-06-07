/// Web-conditional factory for a proxy-aware HTTP client. On native platforms a
/// SOCKS5/HTTP proxy (e.g. the libtailscale loopback) can be configured so RPC
/// traffic routes through the tailnet; on web there's no proxy control, so the
/// default client is returned.
library;

export 'proxy_client_io.dart' if (dart.library.html) 'proxy_client_web.dart';
