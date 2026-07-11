import 'dart:io';

import 'apns_push_service.dart';
import 'doubao_asr/doubao_speech_service.dart';
import 'services.dart';
import 'secret_store.dart';
import 'tailscale_native_service.dart';
import 'tailscale_ffi.dart';

/// Native platform services. Uses the real libtailscale-backed Tailscale
/// service when the dylib/.so can be located; otherwise falls back to the
/// no-op (so the app still runs and direct servers work). Speech uses Motif's
/// Doubao ASR pipeline (mic PCM → Opus → Doubao WebSocket), not platform STT;
/// push via native APNs on Apple platforms (no Firebase).
PlatformServices makePlatformServices() {
  return PlatformServices(
    tailscale: _makeTailscale(),
    speech: DoubaoSpeechService(),
    push: (Platform.isIOS || Platform.isMacOS)
        ? ApnsPushService()
        : NoopPushService(),
    secrets: FlutterSecureSecretStore(),
  );
}

TailscaleService _makeTailscale() {
  final dylib = _findLibtailscale();
  if (dylib == null) return NoopTailscaleService();
  return TailscaleNativeService(
    dylibPath: dylib,
    stateDir: _stateDir(),
    hostname: 'motif-flutter',
  );
}

/// Resolve the libtailscale shared library. Checks, in order: an explicit
/// `MOTIF_LIBTAILSCALE` override, alongside the executable, the project build
/// output, and `/tmp` (dev). Returns null if none load.
String? _findLibtailscale() {
  final ext = (Platform.isMacOS || Platform.isIOS)
      ? 'dylib'
      : (Platform.isWindows ? 'dll' : 'so');
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final cwd = Directory.current.path;
  final pathCandidates = <String>[
    if (Platform.environment['MOTIF_LIBTAILSCALE'] != null)
      Platform.environment['MOTIF_LIBTAILSCALE']!,
    '$exeDir/libtailscale.$ext',
    '$exeDir/../Frameworks/libtailscale.$ext',
    if (Platform.isMacOS || Platform.isIOS) ...[
      '$exeDir/../Frameworks/tailscale.framework/tailscale',
      '$exeDir/../Frameworks/tailscale.framework/Versions/A/tailscale',
    ],
    '$cwd/build/native_assets/macos/libtailscale.dylib',
    '$cwd/build/native/tailscale/macos/arm64/libtailscale.dylib',
    '$cwd/build/native/tailscale/macos/x64/libtailscale.dylib',
    '$cwd/build/native/tailscale/libtailscale.$ext',
    '/tmp/libtailscale.$ext',
  ];
  for (final path in pathCandidates) {
    if (!File(path).existsSync()) continue;
    if (_canOpenLibtailscale(path)) return path;
  }

  // Android packages native libraries under lib/<abi>/ inside the APK, where
  // they are loadable by soname but do not exist as ordinary files.
  final sonameCandidates = <String>[
    if (Platform.isAndroid || Platform.isLinux) 'libtailscale.so',
    if (Platform.isMacOS || Platform.isIOS)
      '@rpath/tailscale.framework/tailscale',
    if (Platform.isMacOS || Platform.isIOS) 'tailscale.framework/tailscale',
    if (Platform.isMacOS || Platform.isIOS)
      'Frameworks/tailscale.framework/tailscale',
    if (Platform.isMacOS || Platform.isIOS) 'libtailscale.dylib',
    if (Platform.isWindows) 'libtailscale.dll',
    'libtailscale',
  ];
  for (final name in sonameCandidates) {
    if (_canOpenLibtailscale(name)) return name;
  }

  return null;
}

bool _canOpenLibtailscale(String path) {
  try {
    final lib = LibTailscale.open(path);
    final sd = lib.create();
    if (sd >= 0) {
      try {
        lib.close(sd);
      } catch (_) {}
      return true;
    }
  } catch (_) {}
  return false;
}

String _stateDir() {
  final home =
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  final dir = Directory('$home/.motif/tailscale');
  dir.createSync(recursive: true);
  return dir.path;
}
