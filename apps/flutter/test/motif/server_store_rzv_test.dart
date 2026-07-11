import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rzv/pairing_payload.dart';
import 'package:motif/motif/platform/secret_store.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rendezvous server persists through ServerStore reload', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecretStore();

    final psk = Uint8List.fromList(List.generate(32, (i) => i));
    final pk = Uint8List.fromList(List.generate(32, (i) => 255 - i));
    final pairing = MotifPairingPayload(
      relay: 'relay.example.com:9999',
      psk: psk,
      pubKey: pk,
      name: 'studio',
      instanceId: 'inst-7',
    );

    final store = await ServerStore.load(prefs, secrets: secrets);
    await store.add(pairing.toServer(id: 'srv-1'));

    // Reload from both backing stores: profile JSON + secure credentials.
    final reloaded = await ServerStore.load(prefs, secrets: secrets);
    expect(reloaded.servers, hasLength(1));
    final s = reloaded.servers.single;
    expect(s.kind, ServerKind.rendezvous);
    expect(s.relay, 'relay.example.com:9999');
    expect(s.psk, isNotEmpty);
    expect(s.pubKey, isNotEmpty);
    expect(s.name, 'studio');
    expect(reloaded.activeId, 'srv-1');
    expect(prefs.getString('motif.servers.v1'), isNot(contains(s.psk)));
    expect(secrets.values.keys, contains('motif.server.credentials.srv-1'));
  });

  test('legacy plaintext credentials migrate atomically', () async {
    const legacy = MotifServer(
      id: 'ssh-1',
      name: 'Bastion',
      host: '127.0.0.1',
      token: 'legacy-token',
      kind: ServerKind.ssh,
      sshHost: 'bastion.example.com',
      sshUsername: 'fei',
      sshPassword: 'legacy-password',
    );
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1': MotifServer.encodeList([legacy]),
    });
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecretStore();

    final store = await ServerStore.load(prefs, secrets: secrets);

    expect(store.servers.single.token, 'legacy-token');
    expect(store.servers.single.sshPassword, 'legacy-password');
    final profileJson = prefs.getString('motif.servers.v1')!;
    expect(profileJson, isNot(contains('legacy-token')));
    expect(profileJson, isNot(contains('legacy-password')));
    expect(
      secrets.values['motif.server.credentials.ssh-1'],
      allOf(contains('legacy-token'), contains('legacy-password')),
    );
  });
}
