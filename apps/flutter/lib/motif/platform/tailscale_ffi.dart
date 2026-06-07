/// Thin Dart FFI wrapper over Tailscale's `libtailscale` C API (a C surface
/// over the Go `tsnet` library). Lets the app join the tailnet itself and reach
/// a remote `motifd` peer — the Flutter port of the iOS TailscaleKit usage.
///
/// `libtailscale` is loaded from a dylib/.so/.framework. Pass an explicit path
/// (tests) or rely on the bundled native asset on a real build. The handle type
/// `tailscale` is a plain `int`.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _NewNative = Int32 Function();
typedef _New = int Function();
typedef _SetStrNative = Int32 Function(Int32, Pointer<Utf8>);
typedef _SetStr = int Function(int, Pointer<Utf8>);
typedef _IntHandleNative = Int32 Function(Int32);
typedef _IntHandle = int Function(int);
typedef _ErrmsgNative = Int32 Function(Int32, Pointer<Utf8>, Size);
typedef _Errmsg = int Function(int, Pointer<Utf8>, int);
typedef _LoopbackNative =
    Int32 Function(Int32, Pointer<Utf8>, Size, Pointer<Utf8>, Pointer<Utf8>);
typedef _Loopback =
    int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, Pointer<Utf8>);
typedef _GetIpsNative = Int32 Function(Int32, Pointer<Utf8>, Size);
typedef _GetIps = int Function(int, Pointer<Utf8>, int);

/// Result of starting the loopback proxy: a `host:port` SOCKS5/HTTP proxy plus
/// the credential the proxy requires.
class TailscaleLoopback {
  final String proxyAddr;
  final String proxyCred;
  final String localApiCred;
  const TailscaleLoopback(this.proxyAddr, this.proxyCred, this.localApiCred);
}

class LibTailscale {
  final DynamicLibrary _lib;

  late final _New _new = _lib.lookupFunction<_NewNative, _New>('tailscale_new');
  late final _SetStr _setDir = _lib.lookupFunction<_SetStrNative, _SetStr>(
    'tailscale_set_dir',
  );
  late final _SetStr _setHostname = _lib.lookupFunction<_SetStrNative, _SetStr>(
    'tailscale_set_hostname',
  );
  late final _SetStr _setAuthkey = _lib.lookupFunction<_SetStrNative, _SetStr>(
    'tailscale_set_authkey',
  );
  late final _SetStr _setControlUrl = _lib
      .lookupFunction<_SetStrNative, _SetStr>('tailscale_set_control_url');
  late final _IntHandle _up = _lib.lookupFunction<_IntHandleNative, _IntHandle>(
    'tailscale_up',
  );
  late final _IntHandle _close = _lib
      .lookupFunction<_IntHandleNative, _IntHandle>('tailscale_close');
  late final _GetIps _getips = _lib.lookupFunction<_GetIpsNative, _GetIps>(
    'tailscale_getips',
  );
  late final _Loopback _loopback = _lib
      .lookupFunction<_LoopbackNative, _Loopback>('tailscale_loopback');
  late final _Errmsg _errmsg = _lib.lookupFunction<_ErrmsgNative, _Errmsg>(
    'tailscale_errmsg',
  );

  LibTailscale(this._lib);

  /// Open from an explicit path (e.g. a built dylib/.so).
  factory LibTailscale.open(String path) =>
      LibTailscale(DynamicLibrary.open(path));

  /// Create a server handle (no network until [up]).
  int create() => _new();

  int setDir(int sd, String dir) => _withStr(dir, (p) => _setDir(sd, p));
  int setHostname(int sd, String h) => _withStr(h, (p) => _setHostname(sd, p));
  int setAuthkey(int sd, String k) => _withStr(k, (p) => _setAuthkey(sd, p));
  int setControlUrl(int sd, String u) =>
      _withStr(u, (p) => _setControlUrl(sd, p));

  /// Bring the node up and wait until usable (blocks; with an authkey it's
  /// headless). Returns 0 on success.
  int up(int sd) => _up(sd);

  int close(int sd) => _close(sd);

  /// Details for the last libtailscale error on [sd], if available.
  String errmsg(int sd) {
    final buf = calloc<Uint8>(1024).cast<Utf8>();
    try {
      final rc = _errmsg(sd, buf, 1024);
      return rc == 0 ? buf.toDartString() : '';
    } finally {
      calloc.free(buf);
    }
  }

  /// Comma/newline-separated tailnet IPs assigned to this node (after [up]).
  String getips(int sd) {
    final buf = calloc<Uint8>(256).cast<Utf8>();
    try {
      final rc = _getips(sd, buf, 256);
      return rc == 0 ? buf.toDartString() : '';
    } finally {
      calloc.free(buf);
    }
  }

  /// Start the loopback SOCKS5/HTTP proxy. Returns null on failure.
  TailscaleLoopback? loopback(int sd) {
    final addr = calloc<Uint8>(256).cast<Utf8>();
    final proxyCred = calloc<Uint8>(256).cast<Utf8>();
    final apiCred = calloc<Uint8>(256).cast<Utf8>();
    try {
      final rc = _loopback(sd, addr, 256, proxyCred, apiCred);
      if (rc != 0) return null;
      return TailscaleLoopback(
        addr.toDartString(),
        proxyCred.toDartString(),
        apiCred.toDartString(),
      );
    } finally {
      calloc.free(addr);
      calloc.free(proxyCred);
      calloc.free(apiCred);
    }
  }

  int _withStr(String s, int Function(Pointer<Utf8>) fn) {
    final p = s.toNativeUtf8();
    try {
      return fn(p);
    } finally {
      calloc.free(p);
    }
  }

  /// Resolve libtailscale from bundled/known dynamic library names. Returns
  /// null if the library/symbols aren't present.
  static LibTailscale? tryOpenDefault() {
    final candidates = <String>[
      if (Platform.isMacOS || Platform.isIOS)
        '@rpath/tailscale.framework/tailscale',
      if (Platform.isMacOS || Platform.isIOS) 'tailscale.framework/tailscale',
      if (Platform.isMacOS || Platform.isIOS)
        'Frameworks/tailscale.framework/tailscale',
      if (Platform.isMacOS) 'libtailscale.dylib',
      if (Platform.isLinux || Platform.isAndroid) 'libtailscale.so',
      if (Platform.isWindows) 'libtailscale.dll',
      'libtailscale',
    ];
    for (final c in candidates) {
      try {
        return LibTailscale.open(c);
      } catch (_) {}
    }
    return null;
  }
}
