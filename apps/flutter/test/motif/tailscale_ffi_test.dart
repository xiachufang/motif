@Tags(['tailscale'])
library;

import 'dart:io';

import 'package:motif/motif/platform/tailscale_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// Verifies the libtailscale FFI bindings against the real dylib. Build it from
/// the libtailscale source with:
///   `CGO_ENABLED=1 go build -buildmode=c-shared -o /tmp/libtailscale.dylib .`
/// then: flutter test test/motif/tailscale_ffi_test.dart
///
/// Skips if the dylib isn't present. Does NOT call tailscale_up (that needs a
/// real tailnet + auth); it exercises create/set/close to prove the binding.
void main() {
  const dylib = '/tmp/libtailscale.dylib';

  test('create → set options → close round-trips through libtailscale', () {
    if (!File(dylib).existsSync()) {
      markTestSkipped('libtailscale.dylib not built at $dylib');
      return;
    }
    final ts = LibTailscale.open(dylib);
    final sd = ts.create();
    expect(
      sd,
      greaterThanOrEqualTo(0),
      reason: 'tailscale_new returned a handle',
    );

    // Configure without bringing the node up — these are pure local setters.
    final tmp = Directory.systemTemp.createTempSync('motif-ts-');
    expect(ts.setDir(sd, tmp.path), 0);
    expect(ts.setHostname(sd, 'motif-flutter-test'), 0);
    expect(ts.setControlUrl(sd, 'https://controlplane.tailscale.com'), 0);
    expect(ts.errmsg(sd), isA<String>());

    expect(ts.close(sd), 0);
    tmp.deleteSync(recursive: true);
  });
}
