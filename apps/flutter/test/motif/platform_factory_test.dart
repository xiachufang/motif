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
  test(
    'makePlatformServices uses TailscaleNativeService when the dylib exists',
    () {
      final present = _libtailscaleCandidates().any(
        (path) => File(path).existsSync(),
      );
      final p = makePlatformServices();
      if (present) {
        expect(
          p.tailscale,
          isA<TailscaleNativeService>(),
          reason:
              'real service should be selected when libtailscale is present',
        );
      } else {
        markTestSkipped(
          'libtailscale dylib not built; factory falls back to no-op',
        );
      }
    },
  );
}

Iterable<String> _libtailscaleCandidates() sync* {
  if (Platform.isMacOS) {
    yield 'build/native_assets/macos/libtailscale.dylib';
    yield 'build/native/tailscale/macos/arm64/libtailscale.dylib';
    yield 'build/native/tailscale/macos/x64/libtailscale.dylib';
    yield 'build/macos/Build/Products/Debug/Motif.app/Contents/Frameworks/tailscale.framework/tailscale';
    yield 'build/macos/Build/Products/Debug/Motif.app/Contents/Frameworks/tailscale.framework/Versions/A/tailscale';
  }
  yield 'build/native/tailscale/libtailscale.dylib';
  yield '/tmp/libtailscale.dylib';
}
