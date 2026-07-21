import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/platform/secret_store.dart';
import 'package:motif/motif/state/embedded/embedded_server_serialization.dart';
import 'package:motif/motif/state/embedded/embedded_server_service.dart';
import 'package:motif/motif/state/embedded/embedded_server_service_desktop.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('starts the embedded server on launch by default', () {
    const config = EmbeddedServerConfig();

    expect(config.autostart, isTrue);
  });

  test('loads legacy config with a missing push relay field', () {
    final config = embeddedServerConfigFromJson({
      'listen_mode': 'lan',
      'port': 7777,
      'tailscale': {
        'enabled': false,
        'hostname': '',
        'authkey': '',
        'control_url': '',
      },
      'auth': {'enabled': false, 'token': ''},
      'rzv': {'enabled': true, 'relay': 'us.allsunday.io:8765'},
      'autostart': true,
    });

    expect(config.listenMode, EmbeddedListenMode.lan);
    expect(config.port, 7777);
    expect(config.rzvEnabled, isTrue);
    expect(config.rzvRelay, 'us.allsunday.io:8765');
    expect(config.autostart, isTrue);
    expect(config.pushRelayUrl, kDefaultPushRelayAddress);
  });

  test('uses defaults for missing or malformed values', () {
    final config = embeddedServerConfigFromJson({
      'listen_mode': null,
      'port': 'not-a-port',
      'tailscale': 'not-an-object',
      'rzv': null,
      'push_relay_url': 42,
      'autostart': 'yes',
    });

    const defaults = EmbeddedServerConfig();
    expect(config.listenMode, defaults.listenMode);
    expect(config.port, defaults.port);
    expect(config.tsEnabled, defaults.tsEnabled);
    expect(config.tsHostname, defaults.tsHostname);
    expect(config.rzvEnabled, defaults.rzvEnabled);
    expect(config.rzvRelay, defaults.rzvRelay);
    expect(config.pushRelayUrl, defaults.pushRelayUrl);
    expect(config.autostart, defaults.autostart);
  });

  test('preserves an explicitly disabled autostart setting', () {
    final config = embeddedServerConfigFromJson({'autostart': false});

    expect(config.autostart, isFalse);
  });

  test('persisted embedded config excludes the relay JWT', () {
    const config = EmbeddedServerConfig(
      rzvEnabled: true,
      rzvRelay: 'wss://relay.example.com',
      rzvJwt: 'header.payload.signature',
    );

    final persistedRzv = config.toPersistedJson()['rzv'] as Map;
    final runtimeRzv = config.toRuntimeJson()['rzv'] as Map;

    expect(persistedRzv.containsKey('jwt'), isFalse);
    expect(runtimeRzv['jwt'], 'header.payload.signature');
  });

  test('drops the retired embedded WSL shell setting', () {
    final config = embeddedServerConfigFromJson({'shell': 'wsl.exe'});

    expect(config.toPersistedJson().containsKey('shell'), isFalse);
    expect(config.toRuntimeJson().containsKey('shell'), isFalse);
  });

  test('migrates a legacy plaintext relay JWT into secure storage', () async {
    SharedPreferences.setMockInitialValues({
      'motif.embedded.v1': jsonEncode({
        'listen_mode': 'loopback',
        'port': 7777,
        'tailscale': {
          'enabled': false,
          'hostname': '',
          'authkey': '',
          'control_url': '',
        },
        'rzv': {
          'enabled': true,
          'relay': 'wss://relay.example.com',
          'jwt': 'legacy.jwt.value',
        },
        'autostart': false,
      }),
    });
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecretStore();

    final service = await DesktopEmbeddedServerService.create(prefs, secrets);
    addTearDown(service.dispose);

    expect(service.config.rzvJwt, 'legacy.jwt.value');
    expect(secrets.values[kEmbeddedRzvJwtSecretKey], 'legacy.jwt.value');
    final persisted =
        jsonDecode(prefs.getString('motif.embedded.v1')!)
            as Map<String, dynamic>;
    expect((persisted['rzv'] as Map).containsKey('jwt'), isFalse);
  });

  test('writes and deletes the relay JWT only in secure storage', () async {
    SharedPreferences.setMockInitialValues({
      'motif.embedded.v1': jsonEncode({'autostart': false}),
    });
    final prefs = await SharedPreferences.getInstance();
    final secrets = MemorySecretStore();
    final service = await DesktopEmbeddedServerService.create(prefs, secrets);
    addTearDown(service.dispose);

    await service.updateConfig(
      service.config.copyWith(rzvJwt: 'new.jwt.value'),
    );
    expect(secrets.values[kEmbeddedRzvJwtSecretKey], 'new.jwt.value');
    expect(
      (jsonDecode(prefs.getString('motif.embedded.v1')!)['rzv'] as Map)
          .containsKey('jwt'),
      isFalse,
    );

    await service.updateConfig(service.config.copyWith(rzvJwt: ''));
    expect(secrets.values[kEmbeddedRzvJwtSecretKey], isNull);
  });
}
