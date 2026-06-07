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
  test('macOS/host picks the real TailscaleNativeService when the lib is built',
      () {
    final ext = Platform.isMacOS ? 'dylib' : (Platform.isWindows ? 'dll' : 'so');
    final lib = File('build/native/tailscale/libtailscale.$ext');
    if (!lib.existsSync()) {
      markTestSkipped('libtailscale not built at ${lib.path}');
      return;
    }
    final services = makePlatformServices();
    expect(services.tailscale, isNot(isA<NoopTailscaleService>()),
        reason: 'should load the real libtailscale-backed service');
    // It should report a sane initial state and expose the proxy accessor.
    expect(services.tailscale.state.status, isA<TailscaleStatus>());
  });
}
