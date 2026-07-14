import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/secret_store.dart';
import 'package:motif/motif/state/stores.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('push encryption key is created in secure storage', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecretStore();

    final store = await PushSettingsStore.load(prefs, secrets);

    expect(store.encKeyBase64, isNotEmpty);
    expect(prefs.containsKey('motif.push.encKey'), isFalse);
    expect(secrets.values['motif.push.encKey'], store.encKeyBase64);
  });

  test('deleting a server deletes its secure credentials', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecretStore();
    final store = await ServerStore.load(prefs, secrets: secrets);
    const server = MotifServer(
      id: 'server-1',
      name: 'Dev',
      host: 'localhost',
      token: 'secret-token',
    );
    await store.add(server);

    await store.delete(server.id);

    expect(secrets.values, isEmpty);
    expect(store.servers, isEmpty);
  });

  test(
    'plaintext preferences secret store persists and deletes values',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final secrets = PlaintextPreferencesSecretStore(
        preferences: Future.value(prefs),
      );

      await secrets.write('server-token', 'plaintext-secret');

      expect(await secrets.read('server-token'), 'plaintext-secret');
      expect(
        prefs.getString('motif.insecureSecret.server-token'),
        'plaintext-secret',
      );

      await secrets.delete('server-token');
      expect(await secrets.read('server-token'), isNull);
    },
  );

  test(
    'migrating secret store moves legacy values into secure storage',
    () async {
      final primary = MemorySecretStore();
      final legacy = MemorySecretStore();
      final secrets = MigratingSecretStore(primary: primary, legacy: legacy);
      await legacy.write('server-token', 'legacy-secret');

      expect(await secrets.read('server-token'), 'legacy-secret');
      expect(primary.values['server-token'], 'legacy-secret');
      expect(legacy.values['server-token'], isNull);
    },
  );

  test(
    'migrating secret store clears legacy values on write and delete',
    () async {
      final primary = MemorySecretStore();
      final legacy = MemorySecretStore();
      final secrets = MigratingSecretStore(primary: primary, legacy: legacy);
      await legacy.write('server-token', 'stale-secret');

      await secrets.write('server-token', 'new-secret');
      expect(primary.values['server-token'], 'new-secret');
      expect(legacy.values['server-token'], isNull);

      await secrets.delete('server-token');
      expect(primary.values['server-token'], isNull);
      expect(legacy.values['server-token'], isNull);
    },
  );
}
