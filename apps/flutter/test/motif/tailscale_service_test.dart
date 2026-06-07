@Tags(['tailscale'])
library;

import 'dart:io';

import 'package:motif/motif/platform/platform_factory_io.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies that on a host where libtailscale is present (built to
/// build/native/tailscale/ via scripts/build_tailscale.sh), the platform
/// factory selects the REAL [TailscaleNativeService] — not the no-op — i.e. the
/// app actually loads the tsnet library. Skips if the dylib isn't built.
///
/// Does not call start()/up() (that needs a tailnet + auth key).
void main() {
  test(
    'macOS/host picks the real TailscaleNativeService when the lib is built',
    () {
      final ext = Platform.isMacOS
          ? 'dylib'
          : (Platform.isWindows ? 'dll' : 'so');
      final lib = _firstExistingLibtailscale(ext);
      if (lib == null) {
        markTestSkipped('libtailscale not built');
        return;
      }
      final services = makePlatformServices();
      expect(
        services.tailscale,
        isNot(isA<NoopTailscaleService>()),
        reason: 'should load the real libtailscale-backed service',
      );
      // It should report a sane initial state and expose the proxy accessor.
      expect(services.tailscale.state.status, isA<TailscaleStatus>());
    },
  );
}

File? _firstExistingLibtailscale(String ext) {
  for (final path in _libtailscaleCandidates(ext)) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  return null;
}

Iterable<String> _libtailscaleCandidates(String ext) sync* {
  if (Platform.isMacOS) {
    yield 'build/native_assets/macos/libtailscale.dylib';
    yield 'build/native/tailscale/macos/arm64/libtailscale.dylib';
    yield 'build/native/tailscale/macos/x64/libtailscale.dylib';
    yield 'build/macos/Build/Products/Debug/Motif.app/Contents/Frameworks/tailscale.framework/tailscale';
    yield 'build/macos/Build/Products/Debug/Motif.app/Contents/Frameworks/tailscale.framework/Versions/A/tailscale';
  }
  yield 'build/native/tailscale/libtailscale.$ext';
  yield '/tmp/libtailscale.$ext';
}
