import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/state/server/server_access_controller.dart';
import 'package:motif/motif/state/server/server_runtime_state.dart';
import 'package:motif/motif/state/server/server_view_models.dart';
import 'package:motif/motif/state/server/session_catalog_controller.dart';
import 'package:motif/motif/state/server/session_catalog_view_model.dart';

import 'support/test_server_transport.dart';

void main() {
  test('catalog loads only after shared transport readiness settles', () async {
    const server = MotifServer(
      id: 'rzv',
      name: 'Rendezvous',
      host: 'paired',
      kind: ServerKind.rendezvous,
    );
    late final TestServerTransport transport;
    transport = TestServerTransport(
      onConnect: (_, {required force}) async =>
          const PingInfo(service: 'motif-server', version: 'test'),
      onCall: (method, [params = const {}]) async {
        expect(method, 'session.list');
        expect(transport.connectCalls, 1);
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
      transport: transport,
      sessions: catalog,
      viewModel: ServerAccessViewModel(),
    );
    addTearDown(access.dispose);

    await access.connect();

    expect(transport.connectCalls, 1);
    expect(access.runtimeState, isA<ServerRuntimeReady>());
    expect(catalogViewModel.sessions.map((session) => session.name), ['dev']);
  });
}
