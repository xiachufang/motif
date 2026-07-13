import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/embedded_server_service.dart';
import 'package:motif/motif/state/embedded_server_service_desktop.dart';

void main() {
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
}
