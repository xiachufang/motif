/// QR / deep-link payload for first-time pairing.
///
/// `motifd` renders a single `motif://pair?...` URI as a QR code; the client
/// scans it and routes by content:
///   - **rzv form** (`rzv=<relay>`): reach motifd through the rendezvous relay.
///   - **direct form** (`host=<ip1,ip2,…>&port=`): reach motifd directly over
///     the LAN; the client probes the NIC candidates and dials the reachable
///     one.
/// Both forms carry `psk` (the access capability — the motifd bearer and, for
/// rzv, the relay token are derived from it) and `pk` (the cert pin verifying
/// motifd's self-signed TLS). One server has exactly one QR at a time.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../models/settings.dart';

class MotifPairingPayload {
  /// Payload schema version.
  final int version;

  /// Relay endpoint (`host:port`) for the rzv form; `null`/empty for direct.
  final String? relay;

  /// Direct-form NIC candidates (from `host=ip1,ip2,…`); empty for the rzv form.
  final List<String> hosts;

  /// Direct-form motifd port.
  final int port;

  /// 32-byte pairing secret. The motifd access bearer (and, for rzv, the relay
  /// token) are derived from this.
  final Uint8List psk;

  /// The TLS pin: SHA-256 of motifd's self-signed cert DER. The client verifies
  /// the presented cert by `sha256(cert.der) == pubKey`. (Wire field is `pk`.)
  final Uint8List? pubKey;

  /// Optional display name and instance id, for the UI.
  final String? name;
  final String? instanceId;

  const MotifPairingPayload({
    required this.psk,
    this.version = 1,
    this.relay,
    this.hosts = const [],
    this.port = 7777,
    this.pubKey,
    this.name,
    this.instanceId,
  });

  static const String scheme = 'motif';
  static const String host = 'pair';

  /// True when this pairs a rendezvous (relay) server vs a direct one.
  bool get isRendezvous => relay != null && relay!.isNotEmpty;

  /// Parse a scanned `motif://pair?...` URI. Throws [FormatException] when the
  /// URI is not a motif pairing link or a required/!32-byte field is missing.
  /// Presence of `rzv` selects the rzv form; otherwise `host` selects direct.
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

    final pskStr = q['psk'];
    if (pskStr == null) throw const FormatException('pairing URI missing psk');
    final psk = _decodeKey(pskStr, 'psk');

    final pkStr = q['pk'];
    final pk = pkStr == null ? null : _decodeKey(pkStr, 'pk');

    final version = int.tryParse(q['v'] ?? '1') ?? 1;
    final relay = q['rzv'];

    if (relay != null && relay.isNotEmpty) {
      // rzv form.
      return MotifPairingPayload(
        version: version,
        relay: relay,
        psk: psk,
        pubKey: pk,
        name: q['name'],
        instanceId: q['id'],
      );
    }

    // direct form: comma-separated NIC candidates + port.
    final hostStr = q['host'];
    if (hostStr == null || hostStr.isEmpty) {
      throw const FormatException('pairing URI missing rzv or host');
    }
    final hosts = hostStr
        .split(',')
        .map((h) => h.trim())
        .where((h) => h.isNotEmpty)
        .toList(growable: false);
    if (hosts.isEmpty) {
      throw const FormatException('pairing URI host list is empty');
    }
    final port = int.tryParse(q['port'] ?? '7777') ?? 7777;
    return MotifPairingPayload(
      version: version,
      hosts: hosts,
      port: port,
      psk: psk,
      pubKey: pk,
      name: q['name'],
      instanceId: q['id'],
    );
  }

  /// Render back to a `motif://pair?...` URI (used by tests and Dart-side QR).
  String toUri() {
    final params = <String, String>{'v': '$version', 'psk': _encodeKey(psk)};
    if (isRendezvous) {
      params['rzv'] = relay!;
    } else {
      params['host'] = hosts.join(',');
      params['port'] = '$port';
    }
    if (pubKey != null) params['pk'] = _encodeKey(pubKey!);
    if (name != null) params['name'] = name!;
    if (instanceId != null) params['id'] = instanceId!;
    return Uri(scheme: scheme, host: host, queryParameters: params).toString();
  }

  /// Build a persistable [MotifServer] from this scanned payload — `rendezvous`
  /// or `direct` depending on the form. Keys are re-encoded canonically
  /// (base64url, no padding) so the stored form is stable.
  MotifServer toServer({required String id}) {
    if (isRendezvous) {
      // Store a clean host/port (the relay endpoint) for display; the rzv
      // transport ignores them and dials `relay`.
      final hp = MotifServer.splitRelayEndpoint(relay!);
      return MotifServer(
        id: id,
        name: (name == null || name!.isEmpty) ? relay! : name!,
        host: hp?.host ?? relay!,
        port: hp?.port ?? 7777,
        kind: ServerKind.rendezvous,
        relay: relay!,
        psk: _encodeKey(psk),
        pubKey: pubKey == null ? '' : _encodeKey(pubKey!),
      );
    }
    // Direct: candidates + pin + psk; the resolver probes `directHosts`.
    return MotifServer(
      id: id,
      name: (name == null || name!.isEmpty) ? hosts.first : name!,
      host: hosts.first, // first candidate, for display
      port: port,
      scheme: pubKey == null ? 'http' : 'https',
      kind: ServerKind.direct,
      psk: _encodeKey(psk),
      pubKey: pubKey == null ? '' : _encodeKey(pubKey!),
      directHosts: hosts,
    );
  }

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
