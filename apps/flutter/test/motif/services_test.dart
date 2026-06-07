import 'package:motif/motif/platform/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('default platform services are safe no-ops', () async {
    final s = PlatformServices.defaults();
    expect(s.tailscale.state.status, TailscaleStatus.stopped);
    expect(await s.tailscale.resolveHost('host.ts.net'), 'host.ts.net');
    expect(s.speech.isAvailable, isFalse);
    expect(await s.speech.stop(), '');
    expect(s.push.isSupported, isFalse);
    expect(await s.push.register(encKeyBase64: 'AAAA'), isNull);
  });
}
