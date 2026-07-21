import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/secret_store.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/embedded/embedded_web_server.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('embedded web server is derived from current origin', () {
    final server = embeddedWebServerFromUri(
      Uri.parse('https://motif.example.test:8443/sessions?token=secret'),
      token: 'secret',
    );

    expect(server, isNotNull);
    expect(server!.id, embeddedWebServerId);
    expect(server.name, 'This motifd');
    expect(server.host, 'motif.example.test');
    expect(server.port, 8443);
    expect(server.scheme, 'https');
    expect(server.token, 'secret');
    expect(server.kind, ServerKind.direct);
  });

  test('embedded web server uses scheme default port when omitted', () {
    expect(embeddedWebServerFromUri(Uri.parse('http://motif.test'))?.port, 80);
    expect(
      embeddedWebServerFromUri(Uri.parse('https://motif.test'))?.port,
      443,
    );
  });

  test('AppState.load seeds embedded web server when store is empty', () async {
    SharedPreferences.setMockInitialValues({});

    final app = await AppState.load(
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: NoopPushService(),
        secrets: MemorySecretStore(),
      ),
      embeddedWebUri: Uri.parse('http://127.0.0.1:7777/?token=dev'),
      embeddedWebToken: 'dev',
    );

    expect(app.servers.servers, hasLength(1));
    final server = app.servers.servers.single;
    expect(server.id, embeddedWebServerId);
    expect(server.host, '127.0.0.1');
    expect(server.port, 7777);
    expect(server.scheme, 'http');
    expect(server.token, 'dev');
    expect(app.servers.activeId, embeddedWebServerId);
  });

  test('AppState.load keeps an existing server list unchanged', () async {
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1':
          '[{"id":"s1","name":"Dev box","host":"dev.test","port":7777,"token":"","kind":"direct"}]',
      'activeServerID': 's1',
    });

    final app = await AppState.load(
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: NoopPushService(),
        secrets: MemorySecretStore(),
      ),
      embeddedWebUri: Uri.parse('http://127.0.0.1:7777/?token=dev'),
      embeddedWebToken: 'dev',
    );

    expect(app.servers.servers, hasLength(1));
    expect(app.servers.servers.single.id, 's1');
    expect(app.servers.servers.single.host, 'dev.test');
    expect(app.servers.activeId, 's1');
  });
}
