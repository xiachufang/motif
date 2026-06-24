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
      config: const EmbeddedServerConfig(listenMode: EmbeddedListenMode.lan),
      status: const EmbeddedServerStatus(
        running: true,
        boundAddrs: ['tcp://0.0.0.0:7777', 'tailscale://*:7777'],
        sessionCount: 1,
        tailscaleState: 'Running',
      ),
    );
    final errors = await _captureFlutterErrors(tester, () async {
      await _pumpSettings(tester, service);
    });
    await tester.pumpAndSettle();

    expect(find.text('Local Server'), findsOneWidget);
    expect(find.text('Running'), findsWidgets);
    expect(find.text('Loopback'), findsOneWidget);
    expect(find.text('LAN'), findsOneWidget);
    expect(
      find.text('PAIRING'),
      findsOneWidget,
    ); // MotifSection uppercases titles
    expect(find.text('Pair over a relay'), findsOneWidget);
    expect(errors, isEmpty);
  });

  testWidgets('prompts to restart immediately for option changes', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(listenMode: EmbeddedListenMode.lan),
      status: const EmbeddedServerStatus(running: true),
    );
    await _pumpSettings(tester, service);

    await tester.tap(find.text('Loopback'));
    await tester.pumpAndSettle();

    expect(find.text('Restart server?'), findsOneWidget);
    await tester.tap(find.text('Restart'));
    await tester.pumpAndSettle();

    expect(service.config.listenMode, EmbeddedListenMode.loopback);
    expect(service.stopCount, 1);
    expect(service.startCount, 1);
  });

  testWidgets('prompts to restart text-field changes only after blur', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(listenMode: EmbeddedListenMode.lan),
      status: const EmbeddedServerStatus(running: true),
    );
    await _pumpSettings(tester, service);

    final portField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == 'Port',
    );
    await tester.tap(portField);
    await tester.enterText(portField, '8888');
    await tester.pump(const Duration(seconds: 1));

    expect(service.config.port, 8888);
    expect(find.text('Restart server?'), findsNothing);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(find.text('Restart server?'), findsOneWidget);
    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    expect(service.stopCount, 0);
    expect(service.startCount, 0);
  });

  testWidgets('keeps Tailscale details collapsed until opened', (tester) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(
        tsEnabled: true,
        tsHostname: 'motif-dev',
      ),
      status: const EmbeddedServerStatus(),
    );
    await _pumpSettings(tester, service);
    await tester.pumpAndSettle();

    expect(find.text('Tailscale settings'), findsOneWidget);
    expect(find.text('motif-dev · Official · Browser login'), findsOneWidget);
    expect(find.text('CONTROL SERVER'), findsNothing);
    expect(find.text('SIGN-IN'), findsNothing);

    await tester.tap(find.text('Tailscale settings'));
    await tester.pumpAndSettle();

    expect(find.text('CONTROL SERVER'), findsOneWidget);
    expect(find.text('SIGN-IN'), findsOneWidget);
  });
}

Future<void> _pumpSettings(
  WidgetTester tester,
  EmbeddedServerService service,
) async {
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
}

Future<List<FlutterErrorDetails>> _captureFlutterErrors(
  WidgetTester tester,
  Future<void> Function() run,
) async {
  final errors = <FlutterErrorDetails>[];
  final previousOnError = FlutterError.onError;
  FlutterError.onError = errors.add;
  addTearDown(() => FlutterError.onError = previousOnError);
  await run();
  return errors;
}

class _FakeEmbeddedServerService extends EmbeddedServerService {
  EmbeddedServerConfig _config;
  EmbeddedServerStatus _status;
  int startCount = 0;
  int stopCount = 0;

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
    startCount += 1;
    _status = const EmbeddedServerStatus(running: true);
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
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
