/// Wire protocol for the motif rendezvous (rzv) relay — the shared contract
/// between this Flutter client and the Rust `motif-rendezvous` server.
///
/// `motifd` and the client connect to role-specific WSS endpoints and send a
/// fixed-length [buildHello] binary message carrying a 32-byte token. The
/// relay pairs matching endpoints, sends [ctrlPaired] as a binary message, then
/// forwards binary messages containing the opaque client↔motifd TLS stream.
/// Keepalive uses native WebSocket PING/PONG control frames.
///
/// Keep this in lockstep with `docs/rzv-protocol.md` and the Rust side.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class RzvProtocol {
  RzvProtocol._();

  /// 4-byte magic: ASCII "MRZV".
  static const List<int> magic = [0x4D, 0x52, 0x5A, 0x56];
  static const int version = 2;

  /// Pre-pairing control bytes (relay <-> a parked side).
  static const int ctrlPaired = 0x10; // relay -> both, once; then transparent

  static const int tokenLength = 32;
  static const int helloLength = 4 + 1 + tokenLength; // 37

  static const String _tokenInfo = 'motif-rzv-token-v1';
  static const String _bearerInfo = 'motif-auth-bearer-v1';

  /// Derive the on-the-wire relay token from the 32-byte pairing secret via
  /// HKDF-SHA256 (RFC 5869, empty salt, L = 32). Byte-identical with the Rust
  /// `motif_server::rzv::derive_token`. One-way, so the relay — which sees the
  /// token — never learns the pairing secret.
  static Uint8List deriveToken(Uint8List psk) => _hkdf(psk, _tokenInfo);

  /// Derive the **motifd access bearer** from the same `psk` under a distinct
  /// label. Sent as `Authorization: Bearer <base64url>` on every connection
  /// (rzv or direct) over its TLS channel; motifd requires it. Byte-identical
  /// with the Rust `motif_server::rzv::derive_bearer`. Independent of the relay
  /// token (the relay never sees this value).
  static Uint8List deriveAuthBearer(Uint8List psk) => _hkdf(psk, _bearerInfo);

  /// HKDF-SHA256 (empty salt, single-block expand, L = 32) under [info].
  static Uint8List _hkdf(Uint8List psk, String info) {
    final salt = Uint8List(tokenLength); // empty salt -> HashLen zero bytes
    final prk = Hmac(sha256, salt).convert(psk).bytes;
    final ctr = <int>[...utf8.encode(info), 0x01];
    return Uint8List.fromList(Hmac(sha256, prk).convert(ctr).bytes);
  }

  /// Build the fixed-length binary HELLO message carrying [token].
  static Uint8List buildHello(List<int> token) {
    if (token.length != tokenLength) {
      throw ArgumentError(
        'rzv token must be $tokenLength bytes, got ${token.length}',
      );
    }
    final b = BytesBuilder(copy: false)
      ..add(magic)
      ..addByte(version)
      ..add(token);
    return b.toBytes();
  }

  /// Parse a HELLO message (relay side / tests).
  static Uint8List parseHello(Uint8List frame) {
    if (frame.length != helloLength) {
      throw FormatException('rzv HELLO: bad length ${frame.length}');
    }
    for (var i = 0; i < magic.length; i++) {
      if (frame[i] != magic[i]) {
        throw const FormatException('rzv HELLO: bad magic');
      }
    }
    if (frame[4] != version) {
      throw FormatException('rzv HELLO: unsupported version ${frame[4]}');
    }
    return Uint8List.sublistView(frame, 5, 5 + tokenLength);
  }
}
