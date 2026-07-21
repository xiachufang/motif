import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/embedded/embedded_server_service.dart';
import 'package:motif/motif/ui/screens/embedded_server_settings_sheet_desktop.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/top_toast.dart';
import 'package:motif/motif/state/app/motif_scope.dart';

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

  testWidgets('server page keeps its scroll position across status polls', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(listenMode: EmbeddedListenMode.lan),
      status: const EmbeddedServerStatus(
        running: true,
        boundAddrs: ['tcp://0.0.0.0:7777', 'rzv://wss://relay.example.com'],
        sessionCount: 1,
        pairingUri: 'motif://pair?v=1&host=127.0.0.1&port=7777&psk=abc',
      ),
    );
    await _pumpPage(tester, service);

    final portField = find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == 'Port',
    );
    await tester.tap(portField);
    final portFocus = tester
        .widget<EditableText>(
          find.descendant(of: portField, matching: find.byType(EditableText)),
        )
        .focusNode;
    expect(portFocus.hasFocus, isTrue);

    final list = find.byType(ListView);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(list),
        scrollDelta: const Offset(0, 700),
      ),
    );
    await tester.pumpAndSettle();

    expect(portFocus.hasFocus, isFalse);
    final controller = tester.widget<ListView>(list).controller!;
    final beforePoll = controller.offset;
    expect(beforePoll, greaterThan(0));

    service.setStatus(
      const EmbeddedServerStatus(
        running: true,
        boundAddrs: ['tcp://0.0.0.0:7777', 'rzv://wss://relay.example.com'],
        sessionCount: 2,
        pairingUri: 'motif://pair?v=1&host=127.0.0.1&port=7777&psk=abc',
      ),
    );
    await tester.pump();

    expect(controller.offset, closeTo(beforePoll, 0.1));
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
    var checkedAddress = '';
    await _pumpSettings(
      tester,
      service,
      pushRelayHealthChecker: (address) async {
        checkedAddress = address;
        return true;
      },
    );

    final relayField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Push relay',
    );
    await tester.tap(relayField);
    await tester.enterText(relayField, 'relay.example.com');
    await tester.pump(const Duration(seconds: 1));

    expect(service.config.pushRelayUrl, 'relay.example.com');
    expect(checkedAddress, isEmpty);
    expect(find.text('Restart server?'), findsNothing);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(find.text('Restart server?'), findsOneWidget);
    expect(checkedAddress, 'relay.example.com');
    expect(find.text('OK'), findsOneWidget);
  });

  testWidgets('resets the push relay and checks its health', (tester) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(pushRelayUrl: 'relay.example.com'),
      status: const EmbeddedServerStatus(),
    );
    var checkedAddress = '';
    await _pumpSettings(
      tester,
      service,
      pushRelayHealthChecker: (address) async {
        checkedAddress = address;
        return true;
      },
    );

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();

    expect(service.config.pushRelayUrl, kDefaultPushRelayAddress);
    expect(checkedAddress, kDefaultPushRelayAddress);
    expect(find.text('OK'), findsOneWidget);
    final relayField = tester.widget<TextField>(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Push relay',
      ),
    );
    expect(relayField.controller?.text, kDefaultPushRelayAddress);
  });

  testWidgets('shows JWT verification failure in the relay row', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(rzvEnabled: true),
      status: const EmbeddedServerStatus(
        running: true,
        relayError: 'rzv WebSocket upgrade: HTTP error: 401 Unauthorized',
      ),
    );
    await _pumpSettings(tester, service);

    expect(find.text('Pair over a relay'), findsOneWidget);
    expect(
      find.text('JWT verification failed — check the Relay owner JWT.'),
      findsOneWidget,
    );
    expect(find.text('Reach it without direct connectivity'), findsNothing);
  });

  testWidgets('shows connection failure in the relay row', (tester) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(rzvEnabled: true),
      status: const EmbeddedServerStatus(
        running: true,
        relayError: 'Connection refused (os error 61)',
      ),
    );
    await _pumpSettings(tester, service);

    expect(find.text('Pair over a relay'), findsOneWidget);
    expect(
      find.text(
        'Unable to connect to the relay — check its address and your network.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reach it without direct connectivity'), findsNothing);
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
    MotifValueScope<EmbeddedServerService>(
      value: service,
      child: MaterialApp(
        theme: motifTheme(Brightness.light),
        builder: (context, child) =>
            MotifToastHost(child: child ?? const SizedBox.shrink()),
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

Future<void> _pumpPage(
  WidgetTester tester,
  EmbeddedServerService service,
) async {
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    MotifValueScope<EmbeddedServerService>(
      value: service,
      child: MaterialApp(
        theme: motifTheme(Brightness.light),
        home: const EmbeddedServerPage(),
      ),
    ),
  );
  await tester.pump();
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
  final List<RegisteredPushToken> pushTokens;
  int startCount = 0;
  int stopCount = 0;
  int pushTokenListCount = 0;
  final List<String> testedTokens = [];

  _FakeEmbeddedServerService({
    required super.config,
    required super.status,
    this.pushTokens = const [],
  }) : super(available: true);

  @override
  String generateToken() => 'generated-token';

  @override
  Future<void> start() async {
    startCount += 1;
    statusState = const EmbeddedServerStatus(running: true);
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
    statusState = const EmbeddedServerStatus();
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
    configState = next;
  }

  void setStatus(EmbeddedServerStatus next) => statusState = next;
}
