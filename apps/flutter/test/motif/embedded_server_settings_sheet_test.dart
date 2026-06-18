import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/embedded_server_service.dart';
import 'package:motif/motif/ui/screens/embedded_server_settings_sheet_desktop.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('renders condensed embedded server settings without overflow', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(
        listenMode: EmbeddedListenMode.lan,
        authEnabled: true,
        authToken: 'test-token',
      ),
      status: const EmbeddedServerStatus(
        running: true,
        boundAddrs: ['tcp://0.0.0.0:7777', 'tailscale://*:7777'],
        sessionCount: 1,
        tailscaleState: 'Running',
      ),
    );
    final errors = <FlutterErrorDetails>[];
    final previousOnError = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previousOnError);

    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ChangeNotifierProvider<EmbeddedServerService>.value(
        value: service,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: const Scaffold(
            body: SingleChildScrollView(
              padding: EdgeInsets.all(MotifSpacing.lg),
              child: EmbeddedServerSettingsSheet(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Local Server'), findsOneWidget);
    expect(find.text('Running'), findsWidgets);
    expect(find.text('Loopback'), findsOneWidget);
    expect(find.text('LAN'), findsOneWidget);
    expect(find.text('Require a token'), findsOneWidget);
    expect(errors, isEmpty);
  });
}

class _FakeEmbeddedServerService extends EmbeddedServerService {
  EmbeddedServerConfig _config;
  EmbeddedServerStatus _status;

  _FakeEmbeddedServerService({required this._config, required this._status});

  @override
  bool get available => true;

  @override
  EmbeddedServerConfig get config => _config;

  @override
  EmbeddedServerStatus get status => _status;

  @override
  String generateToken() => 'generated-token';

  @override
  Future<void> start() async {
    _status = const EmbeddedServerStatus(running: true);
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    _status = const EmbeddedServerStatus();
    notifyListeners();
  }

  @override
  List<String> tailLogs([int n = 200]) => const [];

  @override
  Future<void> updateConfig(EmbeddedServerConfig next) async {
    _config = next;
    notifyListeners();
  }
}
