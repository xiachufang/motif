import 'package:flutter/foundation.dart';

/// Whether bundled libtailscale — and therefore Tailscale connectivity and its
/// UI — is available on the current platform.
///
/// - Web has no FFI.
/// - Windows has no libtailscale: upstream tailscale/libtailscale's C wrapper
///   (`tailscale.c`) is POSIX-only (`<sys/socket.h>`, `<unistd.h>`) with no
///   winsock fallback, so it can't build for Windows. The native build hook
///   skips it there, `platform_factory_io.dart` falls back to
///   `NoopTailscaleService`, and the Tailscale UI is hidden.
///
/// Uses [defaultTargetPlatform] rather than `dart:io`'s `Platform` so it stays
/// safe to evaluate on web (where `dart:io` is unavailable).
bool get tailscaleSupported =>
    !kIsWeb && defaultTargetPlatform != TargetPlatform.windows;
