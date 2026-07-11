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
}
