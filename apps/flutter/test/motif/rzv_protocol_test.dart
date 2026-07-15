import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rzv/rzv_protocol.dart';

void main() {
  group('RzvProtocol HELLO', () {
    final token = Uint8List.fromList(List.generate(32, (i) => i + 1));

    test('buildHello has fixed layout and round-trips', () {
      final frame = RzvProtocol.buildHello(token);
      expect(frame.length, RzvProtocol.helloLength);
      expect(frame.sublist(0, 4), RzvProtocol.magic);
      expect(frame[4], RzvProtocol.version);

      final parsed = RzvProtocol.parseHello(frame);
      expect(parsed, token);
    });

    test('rejects wrong token length', () {
      expect(() => RzvProtocol.buildHello([1, 2, 3]), throwsArgumentError);
    });

    test('parseHello rejects bad magic / length / version', () {
      expect(
        () => RzvProtocol.parseHello(Uint8List(RzvProtocol.helloLength)),
        throwsFormatException, // all-zero magic
      );
      expect(
        () => RzvProtocol.parseHello(Uint8List(10)),
        throwsFormatException, // wrong length
      );
      final bad = RzvProtocol.buildHello(token);
      bad[4] = 99; // version
      expect(() => RzvProtocol.parseHello(bad), throwsFormatException);
    });
  });

  group('RzvProtocol.deriveToken', () {
    test('matches the cross-language HKDF vector', () {
      // psk = bytes 0..31; must equal the Rust `derive_token` fixture in
      // crates/motif-server/src/rzv.rs.
      final psk = Uint8List.fromList(List.generate(32, (i) => i));
      final token = RzvProtocol.deriveToken(psk);
      final hex = token.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(
        hex,
        'bb48b13937710e30c1fffa843593313a7d403c44236eb01d6c86842e43bfa7da',
      );
    });

    test('is one-way (token != psk) and deterministic', () {
      final psk = Uint8List.fromList(List.generate(32, (i) => i + 5));
      final a = RzvProtocol.deriveToken(psk);
      final b = RzvProtocol.deriveToken(psk);
      expect(a, b);
      expect(a, isNot(psk));
      expect(a, hasLength(32));
    });
  });

  group('RzvProtocol.deriveAuthBearer', () {
    test('matches the cross-language HKDF vector', () {
      // psk = bytes 0..31; must equal the Rust `derive_bearer` fixture in
      // crates/motif-server/src/rzv.rs.
      final psk = Uint8List.fromList(List.generate(32, (i) => i));
      final bearer = RzvProtocol.deriveAuthBearer(psk);
      final hex = bearer.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(
        hex,
        'b15f7d9c90b425671f2fd6b31584ad68b3f177a73bbc7e49fbc882505e329ddf',
      );
    });

    test('differs from the relay token (distinct HKDF label)', () {
      final psk = Uint8List.fromList(List.generate(32, (i) => i));
      expect(
        RzvProtocol.deriveAuthBearer(psk),
        isNot(RzvProtocol.deriveToken(psk)),
      );
    });
  });

  group('ServerKind', () {
    test('rendezvous round-trips through wire form', () {
      expect(ServerKind.fromWire('rendezvous'), ServerKind.rendezvous);
      expect(ServerKind.rendezvous.name, 'rendezvous');
    });

    test('unknown falls back to direct', () {
      expect(ServerKind.fromWire('mystery'), ServerKind.direct);
      expect(ServerKind.fromWire(null), ServerKind.direct);
      expect(ServerKind.fromWire('tailscale'), ServerKind.tailscale);
      expect(ServerKind.fromWire('ssh'), ServerKind.ssh);
    });
  });
}
