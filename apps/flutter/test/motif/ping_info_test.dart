import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';

void main() {
  test('parses the rzv LAN-direct hint when present', () {
    final p = PingInfo.fromJson({
      'service': 'motif-server',
      'version': '1.2.3',
      'rzv_direct_port': 7777,
      'rzv_direct_addrs': ['192.168.1.9', '10.0.0.4'],
    });
    expect(p.isMotifServer, isTrue);
    expect(p.rzvDirectPort, 7777);
    expect(p.rzvDirectAddrs, ['192.168.1.9', '10.0.0.4']);
  });

  test('defaults the rzv fields when absent (older servers)', () {
    final p = PingInfo.fromJson({'service': 'motif-server', 'version': '1'});
    expect(p.rzvDirectPort, isNull);
    expect(p.rzvDirectAddrs, isEmpty);
  });

  test('tolerates non-string entries in the addrs array', () {
    final p = PingInfo.fromJson({
      'service': 'motif-server',
      'version': '1',
      'rzv_direct_port': 8000,
      'rzv_direct_addrs': ['192.168.1.9', 42, null],
    });
    expect(p.rzvDirectAddrs, ['192.168.1.9']);
  });
}
