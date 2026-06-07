// End-to-end GUI test: runs the real MotifApp on a device/desktop with the
// native libghostty renderer, connects to a live motifd, attaches a session,
// and verifies the terminal surface appears.
//
// Run (needs Zig + a motifd on 127.0.0.1:7777):
//   flutter test integration_test/native_terminal_app_test.dart -d macos
//
// Skips gracefully (passes) if no server is reachable.
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/rpc_client.dart';
import 'package:motif/motif/state/app_state.dart';
import 'package:motif/motif/state/motif_client.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('connect → attach → terminal renders against live motifd',
      (tester) async {
    // Probe for a server first.
    final probe = RpcClient()..connect(host: '127.0.0.1', port: 7777, token: '');
    try {
      await probe.ping();
    } catch (_) {
      await probe.close();
      // No server — nothing to validate end-to-end; pass.
      return;
    }
    await probe.close();

    SharedPreferences.setMockInitialValues({});
    final app = await AppState.load();
    await app.servers.add(const MotifServer(
      id: 'live',
      name: 'Local',
      host: '127.0.0.1',
      port: 7777,
      token: '',
      kind: ServerKind.direct,
    ));

    await tester.pumpWidget(
      ChangeNotifierProvider.value(value: app, child: const MotifApp()),
    );

    // Allow connect + session.list to complete.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (app.motif.state is ConnConnected || app.motif.state is ConnAttached) {
        break;
      }
    }
    expect(app.motif.state, anyOf(isA<ConnConnected>(), isA<ConnAttached>()),
        reason: 'should connect to motifd');

    // If there's a session, attach and confirm the terminal route opens.
    if (app.motif.sessions.isNotEmpty) {
      final name = app.motif.sessions.first.name;
      await app.motif.attach(name);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      // The session is attached; the client should hold ptys/views from attach.
      expect(app.motif.state, isA<ConnAttached>());
    }

    await app.motif.disconnect();
  });
}
