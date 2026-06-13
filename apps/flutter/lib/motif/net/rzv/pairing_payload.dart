/// QR / deep-link payload for first-time rendezvous pairing.
///
/// `motifd` renders a `motif://pair?...` URI as a QR code; the client scans it
/// to learn where to meet ([relay]), the shared pairing secret ([psk]) used to
/// derive the rendezvous token, and `motifd`'s identity public key ([pubKey])
/// used to pin the end-to-end TLS session (P2). The URI is one-time /
/// short-lived — see `docs/rzv-protocol.md`.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../models/settings.dart';

class MotifPairingPayload {
  /// Payload schema version.
  final int version;

  /// Relay endpoint to meet at, as `host:port`.
  final String relay;

  /// 32-byte pairing secret. The rendezvous token is derived from this.
  final Uint8List psk;

  /// `motifd`'s 32-byte ed25519 identity key. Optional in P1 (plaintext
  /// bring-up); required in P2 to pin the E2E TLS session.
  final Uint8List? pubKey;

  /// Optional display name and instance id, for the UI.
  final String? name;
  final String? instanceId;

  const MotifPairingPayload({
    required this.relay,
    required this.psk,
    this.version = 1,
    this.pubKey,
    this.name,
    this.instanceId,
  });

  static const String scheme = 'motif';
  static const String host = 'pair';

  /// Parse a scanned `motif://pair?...` URI. Throws [FormatException] when the
  /// URI is not a motif pairing link or a required/!32-byte field is missing.
  factory MotifPairingPayload.parse(String input) {
    final Uri uri;
    try {
      uri = Uri.parse(input.trim());
    } on FormatException {
      throw const FormatException('not a valid URI');
    }
    if (uri.scheme != scheme || uri.host != host) {
      throw const FormatException('not a motif pairing URI');
    }
    final q = uri.queryParameters;

    final relay = q['rzv'];
    if (relay == null || relay.isEmpty) {
      throw const FormatException('pairing URI missing rzv');
    }

    final pskStr = q['psk'];
    if (pskStr == null) throw const FormatException('pairing URI missing psk');
    final psk = _decodeKey(pskStr, 'psk');

    final pkStr = q['pk'];
    final pk = pkStr == null ? null : _decodeKey(pkStr, 'pk');

    return MotifPairingPayload(
      version: int.tryParse(q['v'] ?? '1') ?? 1,
      relay: relay,
      psk: psk,
      pubKey: pk,
      name: q['name'],
      instanceId: q['id'],
    );
  }

  /// Render back to a `motif://pair?...` URI (used by tests and, eventually,
  /// any Dart-side QR generation).
  String toUri() {
    final params = <String, String>{
      'v': '$version',
      'rzv': relay,
      'psk': _encodeKey(psk),
    };
    if (pubKey != null) params['pk'] = _encodeKey(pubKey!);
    if (name != null) params['name'] = name!;
    if (instanceId != null) params['id'] = instanceId!;
    return Uri(scheme: scheme, host: host, queryParameters: params).toString();
  }

  /// Build a persistable [MotifServer] of `kind == rendezvous` from this
  /// scanned payload. Keys are re-encoded canonically (base64url, no padding)
  /// so the stored form is stable regardless of how the QR encoded them.
  MotifServer toServer({required String id}) => MotifServer(
        id: id,
        name: (name == null || name!.isEmpty) ? relay : name!,
        host: instanceId ?? relay,
        kind: ServerKind.rendezvous,
        relay: relay,
        psk: _encodeKey(psk),
        pubKey: pubKey == null ? '' : _encodeKey(pubKey!),
      );

  static Uint8List _decodeKey(String s, String field) {
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(base64Url.normalize(s));
    } on FormatException {
      throw FormatException('pairing URI $field is not base64url');
    }
    if (bytes.length != 32) {
      throw FormatException('$field must be 32 bytes, got ${bytes.length}');
    }
    return bytes;
  }

  // URL-safe alphabet, padding stripped (re-added on decode via normalize).
  static String _encodeKey(Uint8List b) =>
      base64Url.encode(b).replaceAll('=', '');
}
