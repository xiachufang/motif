/// Web-conditional builder for [PlatformServices]. Native builds get the real
/// libtailscale-backed Tailscale service (FFI); web gets the no-op (the browser
/// has no tsnet and "web 不需要tailscale"). Keeps `dart:ffi`/`dart:io` out of
/// the web compile.
library;

export 'platform_factory_io.dart' if (dart.library.html) 'platform_factory_web.dart';
