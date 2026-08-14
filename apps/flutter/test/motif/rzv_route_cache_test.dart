import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/state/persistence/rzv_route_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = MotifServer(
  id: 'rzv-cache',
  name: 'studio',
  host: 'studio',
  kind: ServerKind.rendezvous,
  relay: 'wss://relay.example:443',
  psk: 'secret-must-never-be-cached',
  pubKey: 'paired-cert-pin',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'persists candidates and prioritizes the last successful host',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final firstProcess = RzvRouteCache.persistent(prefs);
      firstProcess.rememberCandidates(
        _server,
        port: 7788,
        addrs: const ['192.168.1.8', '10.0.0.8'],
      );
      firstProcess.rememberSuccess(_server, '10.0.0.8');
      await firstProcess.flush();

      final nextProcess = RzvRouteCache.persistent(prefs);
      final restored = nextProcess.lookup(_server);

      expect(restored?.port, 7788);
      expect(restored?.orderedAddrs, ['10.0.0.8', '192.168.1.8']);
      expect(
        prefs.getString('motif.rzvRoutes.v1'),
        isNot(contains(_server.psk)),
        reason: 'the pairing secret is never part of the route hint',
      );
    },
  );

  test('rejects a hint after relay or certificate identity changes', () async {
    final prefs = await SharedPreferences.getInstance();
    final cache = RzvRouteCache.persistent(prefs);
    cache.rememberCandidates(_server, port: 7788, addrs: const ['192.168.1.8']);
    await cache.flush();

    expect(
      cache.lookup(_server.copyWith(relay: 'wss://other.example:443')),
      isNull,
    );
    await cache.flush();

    final reloaded = RzvRouteCache.persistent(prefs);
    expect(reloaded.lookup(_server), isNull);
  });
}
