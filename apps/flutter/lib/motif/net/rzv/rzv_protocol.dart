/// Wire protocol for the motif rendezvous (rzv) relay — the shared contract
/// between this Flutter client and the Rust `motif-rendezvous` server.
///
/// Both `motifd` (role [roleAccept]) and the client (role [roleConnect]) dial
/// OUT to the relay and send a fixed-length [buildHello] frame carrying a role
/// and a 32-byte token. The relay pairs an `accept` with a `connect` that
/// present the same token, sends [ctrlPaired] to both, then becomes a
/// transparent byte pipe. Control bytes ([ctrlPing]/[ctrlPong]/[ctrlPaired])
/// are valid only in the pre-pairing window; after [ctrlPaired] every byte is
/// opaque application data (TLS / WebSocket).
///
/// Keep this in lockstep with `docs/rzv-protocol.md` and the Rust side.
library;

import 'dart:typed_data';

class RzvProtocol {
  RzvProtocol._();

  /// 4-byte magic: ASCII "MRZV".
  static const List<int> magic = [0x4D, 0x52, 0x5A, 0x56];
  static const int version = 1;

  /// HELLO roles.
  static const int roleAccept = 0; // server (motifd) parks, waiting
  static const int roleConnect = 1; // client dials in

  /// Pre-pairing control bytes (relay <-> a parked side).
  static const int ctrlPing = 0x01; // relay -> waiter, keepalive
  static const int ctrlPong = 0x02; // waiter -> relay, keepalive ack
  static const int ctrlPaired = 0x10; // relay -> both, once; then transparent

  static const int tokenLength = 32;
  static const int helloLength = 4 + 1 + 1 + tokenLength; // 38

  /// Build the fixed-length HELLO frame for [role] carrying [token].
  static Uint8List buildHello(int role, List<int> token) {
    if (token.length != tokenLength) {
      throw ArgumentError(
        'rzv token must be $tokenLength bytes, got ${token.length}',
      );
    }
    if (role != roleAccept && role != roleConnect) {
      throw ArgumentError('invalid rzv role $role');
    }
    final b = BytesBuilder(copy: false)
      ..add(magic)
      ..addByte(version)
      ..addByte(role)
      ..add(token);
    return b.toBytes();
  }

  /// Parse a HELLO frame (relay side / tests). Returns the role and a view of
  /// the 32-byte token, or throws [FormatException] on a malformed frame.
  static ({int role, Uint8List token}) parseHello(Uint8List frame) {
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
    final role = frame[5];
    final token = Uint8List.sublistView(frame, 6, 6 + tokenLength);
    return (role: role, token: token);
  }
}
