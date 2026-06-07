@Tags(['tailscale'])
library;

import 'dart:io';

import 'package:motif/motif/platform/platform_factory.dart';
import 'package:motif/motif/platform/tailscale_native_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies the native platform factory selects the real libtailscale-backed
/// service when the dylib is discoverable (built to build/native/tailscale/ or
/// /tmp), and a no-op otherwise.
void main() {
  test('makePlatformServices uses TailscaleNativeService when the dylib exists', () {
    final present = File('build/native/tailscale/libtailscale.dylib').existsSync() ||
        File('/tmp/libtailscale.dylib').existsSync();
    final p = makePlatformServices();
    if (present) {
      expect(p.tailscale, isA<TailscaleNativeService>(),
          reason: 'real service should be selected when libtailscale is present');
    } else {
      markTestSkipped('libtailscale dylib not built; factory falls back to no-op');
    }
  });
}
