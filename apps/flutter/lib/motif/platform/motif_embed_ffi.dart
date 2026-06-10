/// Thin Dart FFI wrapper over the `motif-embed` cdylib — a C ABI around
/// `motif-server` that lets the desktop app run an embedded `motifd`
/// in-process (the Flutter equivalent of the Tauri menu-bar app). Mirrors the
/// loading style of [tailscale_ffi.dart]: a `DynamicLibrary` resolved from the
/// bundled native asset, with `lookupFunction` bindings.
///
/// Desktop only — the library isn't built/bundled for mobile or web. Strings
/// returned by the library are owned by it and freed via `motif_embed_free`;
/// this wrapper copies them into Dart strings before freeing.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// C signatures.
typedef _InitNative = Int32 Function(Pointer<Utf8>);
typedef _Init = int Function(Pointer<Utf8>);
typedef _StartNative = Int32 Function(Pointer<Utf8>);
typedef _Start = int Function(Pointer<Utf8>);
typedef _StopNative = Int32 Function();
typedef _Stop = int Function();
typedef _StrOutNative = Pointer<Utf8> Function();
typedef _StrOut = Pointer<Utf8> Function();
typedef _TailNative = Pointer<Utf8> Function(Int32);
typedef _Tail = Pointer<Utf8> Function(int);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _Free = void Function(Pointer<Utf8>);

/// Low-level bindings to the embedded-server cdylib.
class LibMotifEmbed {
  final DynamicLibrary _lib;

  late final _Init _init = _lib.lookupFunction<_InitNative, _Init>(
    'motif_embed_init',
  );
  late final _StrOut _generateToken = _lib
      .lookupFunction<_StrOutNative, _StrOut>('motif_embed_generate_token');
  late final _Start _start = _lib.lookupFunction<_StartNative, _Start>(
    'motif_embed_start',
  );
  late final _Stop _stop = _lib.lookupFunction<_StopNative, _Stop>(
    'motif_embed_stop',
  );
  late final _StrOut _statusJson = _lib.lookupFunction<_StrOutNative, _StrOut>(
    'motif_embed_status_json',
  );
  late final _Tail _tailLogs = _lib.lookupFunction<_TailNative, _Tail>(
    'motif_embed_tail_logs',
  );
  late final _Free _free = _lib.lookupFunction<_FreeNative, _Free>(
    'motif_embed_free',
  );

  LibMotifEmbed(this._lib);

  /// Open from an explicit path (e.g. a built dylib/.so) — used by tests.
  factory LibMotifEmbed.open(String path) =>
      LibMotifEmbed(DynamicLibrary.open(path));

  /// One-time init: build the runtime + route logs under [logDir]. Idempotent.
  /// Returns 0 on success.
  int init(String logDir) => _withStr(logDir, (p) => _init(p));

  /// A fresh bearer token (32 bytes, base64url).
  String generateToken() => _consume(_generateToken());

  /// Start the embedded server with the given config JSON (the `MenuConfig`
  /// shape). Non-blocking; 0 = accepted, -1 = bad config. Poll [statusJson].
  int start(String configJson) => _withStr(configJson, (p) => _start(p));

  /// Stop the embedded server. Idempotent. 0 on success.
  int stop() => _stop();

  /// Current status as a JSON string (the `StatusDto` shape).
  String statusJson() => _consume(_statusJson());

  /// Last [n] log lines as a JSON string array.
  String tailLogs(int n) => _consume(_tailLogs(n));

  int _withStr(String s, int Function(Pointer<Utf8>) fn) {
    final p = s.toNativeUtf8();
    try {
      return fn(p);
    } finally {
      calloc.free(p);
    }
  }

  /// Copy a library-owned C string into a Dart string and free the original.
  /// A null pointer becomes an empty string.
  String _consume(Pointer<Utf8> p) {
    if (p == nullptr) return '';
    try {
      return p.toDartString();
    } finally {
      _free(p);
    }
  }

  /// Resolve the embedded-server library from bundled/known dynamic-library
  /// names. Returns null if it isn't present (e.g. on mobile/web, or if the
  /// native asset failed to build/bundle).
  static LibMotifEmbed? tryOpenDefault() {
    final candidates = <String>[
      // On macOS the native-asset bundler repackages the dylib as a framework
      // (`motif_embed.framework/motif_embed`), as it does for libtailscale.
      if (Platform.isMacOS) '@rpath/motif_embed.framework/motif_embed',
      if (Platform.isMacOS) 'motif_embed.framework/motif_embed',
      if (Platform.isMacOS) 'Frameworks/motif_embed.framework/motif_embed',
      if (Platform.isMacOS) 'libmotif_embed.dylib',
      if (Platform.isLinux) 'libmotif_embed.so',
      if (Platform.isWindows) 'motif_embed.dll',
      'libmotif_embed',
    ];
    for (final c in candidates) {
      try {
        return LibMotifEmbed.open(c);
      } catch (_) {}
    }
    return null;
  }
}
