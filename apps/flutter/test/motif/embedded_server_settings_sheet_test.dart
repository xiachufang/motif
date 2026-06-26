import 'dart:async';

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
    expect(find.text('NOTIFICATIONS'), findsOneWidget);
    expect(find.text('Push relay'), findsOneWidget);
    expect(find.text(kDefaultPushRelayAddress), findsWidgets);
    expect(find.text('Health'), findsOneWidget);
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

  testWidgets('saves editable push relay address and restarts after blur', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(listenMode: EmbeddedListenMode.lan),
      status: const EmbeddedServerStatus(running: true),
    );
    await _pumpSettings(tester, service);

    final relayField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Push relay',
    );
    await tester.tap(relayField);
    await tester.enterText(relayField, 'relay.example.com');
    await tester.pump(const Duration(seconds: 1));

    expect(service.config.pushRelayUrl, 'relay.example.com');
    expect(find.text('Restart server?'), findsNothing);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(find.text('Restart server?'), findsOneWidget);
  });

  testWidgets('checks push relay health from the field action', (tester) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(listenMode: EmbeddedListenMode.lan),
      status: const EmbeddedServerStatus(),
    );
    final health = Completer<bool>();
    var checkedAddress = '';
    await _pumpSettings(
      tester,
      service,
      pushRelayHealthChecker: (address) {
        checkedAddress = address;
        return health.future;
      },
    );

    await tester.tap(find.text('Health'));
    await tester.pump();

    expect(checkedAddress, kDefaultPushRelayAddress);
    expect(find.text('Checking'), findsOneWidget);

    health.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('OK'), findsOneWidget);
  });

  testWidgets(
    'opens registered push tokens from server settings and tests one',
    (tester) async {
      const token =
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
      final service = _FakeEmbeddedServerService(
        config: const EmbeddedServerConfig(listenMode: EmbeddedListenMode.lan),
        status: const EmbeddedServerStatus(running: true),
        pushTokens: const [
          RegisteredPushToken(
            deviceToken: token,
            platform: 'ios',
            environment: 'sandbox',
            registeredAt: 1710000000000,
          ),
        ],
      );
      await _pumpSettings(tester, service);

      await tester.tap(find.text('Registered push tokens'));
      await tester.pumpAndSettle();

      expect(find.text('Registered Push Tokens'), findsOneWidget);
      expect(find.text(token), findsOneWidget);
      expect(find.text('ios · sandbox'), findsOneWidget);

      await tester.tap(find.byTooltip('Refresh push tokens'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(service.pushTokenListCount, 2);

      await tester.tap(find.text('Test'));
      await tester.pumpAndSettle();

      expect(service.testedTokens, [token]);
      expect(find.text('Test push sent'), findsOneWidget);
    },
  );

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
  EmbeddedServerService service, {
  Future<bool> Function(String address)? pushRelayHealthChecker,
}) async {
  tester.view.physicalSize = const Size(900, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ChangeNotifierProvider<EmbeddedServerService>.value(
      value: service,
      child: MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(MotifSpacing.lg),
            child: EmbeddedServerSettingsSheet(
              pushRelayHealthChecker: pushRelayHealthChecker,
            ),
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
  try {
    await run();
  } finally {
    FlutterError.onError = previousOnError;
  }
  return errors;
}

class _FakeEmbeddedServerService extends EmbeddedServerService {
  EmbeddedServerConfig _config;
  EmbeddedServerStatus _status;
  final List<RegisteredPushToken> pushTokens;
  int startCount = 0;
  int stopCount = 0;
  int pushTokenListCount = 0;
  final List<String> testedTokens = [];

  _FakeEmbeddedServerService({
    required this._config,
    required this._status,
    this.pushTokens = const [],
  });

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
  Future<List<RegisteredPushToken>> registeredPushTokens() async {
    pushTokenListCount += 1;
    return pushTokens;
  }

  @override
  Future<PushTestResult> sendTestPush(String deviceToken) async {
    testedTokens.add(deviceToken);
    return const PushTestResult(sent: true);
  }

  @override
  Future<void> updateConfig(EmbeddedServerConfig next) async {
    _config = next;
    notifyListeners();
  }
}
