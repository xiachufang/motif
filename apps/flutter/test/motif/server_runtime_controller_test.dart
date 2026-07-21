import 'dart:typed_data';

import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/server/server_access_controller.dart';
import 'package:motif/motif/state/server/server_runtime_state.dart';
import 'package:motif/motif/state/server/server_view_models.dart';
import 'package:motif/motif/state/server/session_catalog_controller.dart';
import 'package:motif/motif/state/server/session_catalog_view_model.dart';
import 'package:motif/motif/state/server/transport_resolver.dart';

import 'support/test_server_transport.dart';

final class _PromotionResolver extends TransportResolver {
  _PromotionResolver() : super(PlatformServices.defaults());

  int resolves = 0;
  bool learned = false;

  @override
  Future<TransportResolution> resolve(MotifServer server) async {
    resolves++;
    return TransportReady(
      target: server.copyWith(host: resolves == 1 ? 'relay' : 'direct'),
      proxy: ProxySettings.none,
    );
  }

  @override
  Future<void> stopForwarder(String serverId) async {}

  @override
  bool learnRzvDirect(MotifServer server, PingInfo? ping) {
    if (learned) return false;
    learned = true;
    return true;
  }
}

void main() {
  test('catalog loads only after rendezvous route promotion settles', () async {
    const server = MotifServer(
      id: 'rzv',
      name: 'Rendezvous',
      host: 'paired',
      kind: ServerKind.rendezvous,
    );
    final connectedHosts = <String>[];
    late final TestServerTransport transport;
    transport = TestServerTransport(
      onConnect:
          (
            _,
            target, {
            required force,
            required proxy,
            required Uint8List? certPin,
          }) async {
            connectedHosts.add(target.host);
            return const PingInfo(
              service: 'motif-server',
              version: 'test',
              rzvDirectPort: 7777,
              rzvDirectAddrs: ['127.0.0.1'],
            );
          },
      onCall: (method, [params = const {}]) async {
        expect(method, 'session.list');
        expect(transport.connectCalls, 2);
        return const {
          'sessions': <Object?>[
            <String, Object?>{'name': 'dev'},
          ],
        };
      },
    );
    final catalogViewModel = SessionCatalogViewModel(
      sessions: ObservableList(),
    );
    final catalog = SessionCatalogController(
      viewModel: catalogViewModel,
      transport: SessionCatalogTransport(
        isAvailable: () => transport.isLive,
        call: transport.call,
      ),
    );
    final access = ServerAccessController(
      serverId: server.id,
      serverProvider: () => server,
      resolver: _PromotionResolver(),
      transport: transport,
      sessions: catalog,
      viewModel: ServerAccessViewModel(),
    );
    addTearDown(access.dispose);

    await access.connect();

    expect(connectedHosts, ['relay', 'direct']);
    expect(access.runtimeState, isA<ServerRuntimeReady>());
    expect(catalogViewModel.sessions.map((session) => session.name), ['dev']);
  });
}
