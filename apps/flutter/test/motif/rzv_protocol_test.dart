import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rzv/rzv_protocol.dart';

void main() {
  group('RzvProtocol HELLO', () {
    final token = Uint8List.fromList(List.generate(32, (i) => i + 1));

    test('buildHello has fixed layout and round-trips', () {
      final frame = RzvProtocol.buildHello(RzvProtocol.roleConnect, token);
      expect(frame.length, RzvProtocol.helloLength);
      expect(frame.sublist(0, 4), RzvProtocol.magic);
      expect(frame[4], RzvProtocol.version);
      expect(frame[5], RzvProtocol.roleConnect);

      final parsed = RzvProtocol.parseHello(frame);
      expect(parsed.role, RzvProtocol.roleConnect);
      expect(parsed.token, token);
    });

    test('rejects wrong token length', () {
      expect(
        () => RzvProtocol.buildHello(RzvProtocol.roleAccept, [1, 2, 3]),
        throwsArgumentError,
      );
    });

    test('rejects invalid role', () {
      expect(() => RzvProtocol.buildHello(9, token), throwsArgumentError);
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
      final bad = RzvProtocol.buildHello(RzvProtocol.roleAccept, token);
      bad[4] = 99; // version
      expect(() => RzvProtocol.parseHello(bad), throwsFormatException);
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
    });
  });
}
