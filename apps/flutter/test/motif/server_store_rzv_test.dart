import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rzv/pairing_payload.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rendezvous server persists through ServerStore reload', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    final psk = Uint8List.fromList(List.generate(32, (i) => i));
    final pk = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    final pairing = MotifPairingPayload(
      relay: 'relay.example.com:9999',
      psk: psk,
      pubKey: pk,
      name: 'studio',
      instanceId: 'inst-7',
    );

    final store = ServerStore(prefs);
    await store.add(pairing.toServer(id: 'srv-1'));

    // Reload from the same backing store — exercises encodeList/decodeList.
    final reloaded = ServerStore(prefs);
    expect(reloaded.servers, hasLength(1));
    final s = reloaded.servers.single;
    expect(s.kind, ServerKind.rendezvous);
    expect(s.relay, 'relay.example.com:9999');
    expect(s.psk, isNotEmpty);
    expect(s.pubKey, isNotEmpty);
    expect(s.name, 'studio');
    expect(reloaded.activeId, 'srv-1');
  });
}
