/// Exercises the Dart↔Rust FFI ABI of the embedded-server library against the
/// host-built dynamic library: confirms the symbol names/signatures match and
/// that a real start→status→stop cycle works over loopback. Skipped
/// automatically when the library hasn't been built
/// (`scripts/build_motif_embed.sh --target <host>`).
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/motif_embed_ffi.dart';

String? _libraryPath() {
  final (os, file) = Platform.isWindows
      ? ('windows', 'motif_embed.dll')
      : Platform.isLinux
      ? ('linux', 'libmotif_embed.so')
      : ('macos', 'libmotif_embed.dylib');
  for (final arch in ['arm64', 'x64']) {
    final p = 'build/native/motif/$os/$arch/$file';
    if (File(p).existsSync()) return p;
  }
  return null;
}

void main() {
  final path = _libraryPath();
  if (path == null) {
    // No host dylib — nothing to test. Run build_motif_embed.sh to enable.
    return;
  }

  late LibMotifEmbed lib;

  setUpAll(() {
    lib = LibMotifEmbed.open(path);
    final tmp = Directory.systemTemp.createTempSync('motif_embed_test');
    expect(lib.init('${tmp.path}/logs'), 0);
  });

  test('generateToken returns a non-empty token', () {
    final t = lib.generateToken();
    expect(t, isNotEmpty);
    expect(t.length, greaterThan(20));
  });

  test('status is stopped before start', () {
    final s = jsonDecode(lib.statusJson()) as Map<String, Object?>;
    expect(s['running'], false);
    expect(s['starting'], false);
  });

  test('start → running → stop on loopback', () async {
    final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    await probe.close();
    final config = {
      'listen_mode': 'loopback',
      'port': port,
      'tailscale': {
        'enabled': false,
        'hostname': '',
        'authkey': '',
        'control_url': '',
      },
      'rzv': {'enabled': false, 'relay': ''},
      'push_relay_url': '',
      'autostart': false,
    };
    expect(lib.start(jsonEncode(config)), 0);

    // Poll until it reports running (bring-up is async on the Rust side).
    Map<String, Object?> status = const {};
    for (var i = 0; i < 50; i++) {
      status = jsonDecode(lib.statusJson()) as Map<String, Object?>;
      if (status['running'] == true) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(status['running'], true, reason: 'server should come up');
    final bound = (status['bound_addrs'] as List).cast<String>();
    expect(bound.any((a) => a.endsWith(':$port')), true);

    expect(lib.stop(), 0);
    final after = jsonDecode(lib.statusJson()) as Map<String, Object?>;
    expect(after['running'], false);
  });
}
