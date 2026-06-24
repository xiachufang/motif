import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rzv/pairing_payload.dart';

void main() {
  final psk = Uint8List.fromList(List.generate(32, (i) => i));
  final pk = Uint8List.fromList(List.generate(32, (i) => 255 - i));

  group('MotifPairingPayload', () {
    test('toUri / parse round-trip with all fields', () {
      final p = MotifPairingPayload(
        relay: 'relay.example.com:9999',
        psk: psk,
        pubKey: pk,
        name: 'studio',
        instanceId: 'inst-7',
      );
      final uri = p.toUri();
      expect(uri, startsWith('motif://pair?'));

      final back = MotifPairingPayload.parse(uri);
      expect(back.relay, p.relay);
      expect(back.psk, psk);
      expect(back.pubKey, pk);
      expect(back.name, 'studio');
      expect(back.instanceId, 'inst-7');
      expect(back.version, 1);
    });

    test('parses minimal payload (no pk/name/id)', () {
      final p = MotifPairingPayload(relay: 'host:7000', psk: psk);
      final back = MotifPairingPayload.parse(p.toUri());
      expect(back.relay, 'host:7000');
      expect(back.psk, psk);
      expect(back.pubKey, isNull);
      expect(back.name, isNull);
    });

    test('encodes keys as base64url without padding', () {
      final encoded = MotifPairingPayload(relay: 'h:1', psk: psk).toUri();
      // The psk *value* must carry no '=' padding (the URI itself has '=' as
      // query separators, so check the decoded parameter, not the whole URI).
      final pskValue = Uri.parse(encoded).queryParameters['psk']!;
      expect(pskValue.contains('='), isFalse);
      expect(() => MotifPairingPayload.parse(encoded), returnsNormally);
    });

    test('rejects non-motif URIs', () {
      expect(
        () => MotifPairingPayload.parse('https://pair?rzv=h:1'),
        throwsFormatException,
      );
      expect(
        () => MotifPairingPayload.parse('motif://other?rzv=h:1'),
        throwsFormatException,
      );
    });

    test('rejects missing rzv / psk', () {
      expect(
        () => MotifPairingPayload.parse('motif://pair?psk=AAAA'),
        throwsFormatException,
      );
      expect(
        () => MotifPairingPayload.parse('motif://pair?rzv=h:1'),
        throwsFormatException,
      );
    });

    test('rejects wrong key length', () {
      final shortKey = Uint8List(16);
      final uri = MotifPairingPayload(
        relay: 'h:1',
        psk: psk,
      ).toUri().replaceAll(RegExp(r'psk=[^&]*'), 'psk=${base64Like(shortKey)}');
      expect(() => MotifPairingPayload.parse(uri), throwsFormatException);
    });

    test('toServer produces a persistable rendezvous MotifServer', () {
      final p = MotifPairingPayload(
        relay: 'relay:9999',
        psk: psk,
        pubKey: pk,
        name: 'studio',
        instanceId: 'inst-7',
      );
      final server = p.toServer(id: 'srv-1');
      expect(server.kind, ServerKind.rendezvous);
      expect(server.relay, 'relay:9999');
      expect(server.name, 'studio');
      // host/port are the relay endpoint, split cleanly — never the whole
      // relay string with an embedded colon (which made `endpoint` garbage).
      expect(server.host, 'relay');
      expect(server.port, 9999);
      expect(server.endpoint, 'relay:9999');
      expect(server.psk, isNotEmpty);
      expect(server.pubKey, isNotEmpty);

      // JSON round-trip preserves rendezvous fields.
      final back = MotifServer.fromJson(server.toJson());
      expect(back.kind, ServerKind.rendezvous);
      expect(back.relay, 'relay:9999');
      expect(back.host, 'relay');
      expect(back.port, 9999);
      expect(back.psk, server.psk);
      expect(back.pubKey, server.pubKey);
    });

    test('fromJson heals a legacy rendezvous record with relay in host', () {
      // Older builds stored the whole relay (with its port) in `host`, leaving
      // a default `port` — `endpoint` came out as `h:port:port`.
      final back = MotifServer.fromJson({
        'id': 'srv-legacy',
        'name': 'old',
        'host': 'us.allsunday.io:8765',
        'port': 7777,
        'kind': 'rendezvous',
        'relay': 'us.allsunday.io:8765',
        'psk': 'AAA',
      });
      expect(back.host, 'us.allsunday.io');
      expect(back.port, 8765);
      expect(back.endpoint, 'us.allsunday.io:8765');
    });

    test('direct server JSON omits empty rendezvous fields', () {
      const s = MotifServer(id: 'a', name: 'n', host: 'h');
      final json = s.toJson();
      expect(json.containsKey('relay'), isFalse);
      expect(json.containsKey('psk'), isFalse);
      expect(json.containsKey('pubKey'), isFalse);
    });
  });

  group('direct form (no relay)', () {
    test('parses a comma-separated host list and maps to a direct server', () {
      final uri =
          'motif://pair?v=1&host=192.168.1.9,10.0.0.4&port=7777'
          '&psk=${base64Like(psk)}&pk=${base64Like(pk)}';
      final p = MotifPairingPayload.parse(uri);
      expect(p.isRendezvous, isFalse);
      expect(p.hosts, ['192.168.1.9', '10.0.0.4']);
      expect(p.port, 7777);

      final s = p.toServer(id: 'd');
      expect(s.kind, ServerKind.direct);
      expect(s.scheme, 'https'); // pin present ⇒ TLS
      expect(s.host, '192.168.1.9'); // first candidate, for display
      expect(s.directHosts, ['192.168.1.9', '10.0.0.4']);
      expect(s.psk, isNotEmpty);
      expect(s.pubKey, isNotEmpty);

      // directHosts survives a JSON round-trip.
      final back = MotifServer.fromJson(s.toJson());
      expect(back.kind, ServerKind.direct);
      expect(back.directHosts, ['192.168.1.9', '10.0.0.4']);
    });

    test('toUri round-trips the direct form', () {
      final p = MotifPairingPayload(
        hosts: const ['192.168.1.9', '10.0.0.4'],
        port: 8000,
        psk: psk,
        pubKey: pk,
      );
      final back = MotifPairingPayload.parse(p.toUri());
      expect(back.isRendezvous, isFalse);
      expect(back.hosts, ['192.168.1.9', '10.0.0.4']);
      expect(back.port, 8000);
    });

    test('rejects a link with neither rzv nor host', () {
      expect(
        () => MotifPairingPayload.parse(
          'motif://pair?v=1&psk=${base64Like(psk)}',
        ),
        throwsFormatException,
      );
    });
  });
}

/// base64url-no-pad encoder for test fixtures.
String base64Like(Uint8List b) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final sb = StringBuffer();
  var i = 0;
  while (i < b.length) {
    final n =
        (b[i] << 16) |
        (i + 1 < b.length ? b[i + 1] << 8 : 0) |
        (i + 2 < b.length ? b[i + 2] : 0);
    sb.write(chars[(n >> 18) & 63]);
    sb.write(chars[(n >> 12) & 63]);
    if (i + 1 < b.length) sb.write(chars[(n >> 6) & 63]);
    if (i + 2 < b.length) sb.write(chars[n & 63]);
    i += 3;
  }
  return sb.toString();
}
