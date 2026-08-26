import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:motif/motif/state/embedded/embedded_server_service.dart';
import 'package:motif/motif/ui/screens/embedded_server_settings_sheet_desktop.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/top_toast.dart';

void main() {
  testWidgets('server page keeps actions directly after its content', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(
        rzvMode: EmbeddedRelayMode.custom,
        rzvRelay: 'relay.example.com',
        rzvJwt: 'owner.jwt',
      ),
      status: const EmbeddedServerStatus(
        pairingUri: 'motif://pair?v=1&rzv=relay.example.com&psk=abc',
      ),
    );

    await _pumpPage(tester, service);

    expect(find.text('Local Server'), findsOneWidget);
    expect(find.text('Stopped'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.text('RELAY'), findsNothing);
    expect(find.text('Copy pairing link'), findsNothing);
    expect(find.text('Start Server'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Start Server')).dy,
      greaterThan(tester.getTopLeft(find.text('Local Server')).dy),
    );
    expect(tester.getTopLeft(find.text('Start Server')).dy, lessThan(300));
  });

  testWidgets('shows Relay QR only while the Server is running', (
    tester,
  ) async {
    const pairingUri = 'motif://pair?v=1&rzv=relay.example.com&psk=abc&pk=def';
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(
        rzvMode: EmbeddedRelayMode.custom,
        rzvRelay: 'relay.example.com',
        rzvJwt: 'owner.jwt',
      ),
      status: const EmbeddedServerStatus(pairingUri: pairingUri),
    );
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await _pumpPage(tester, service);
    expect(find.text('RELAY'), findsNothing);

    service.setStatus(
      const EmbeddedServerStatus(
        running: true,
        boundAddrs: ['tcp://127.0.0.1:7777'],
        pairingUri: pairingUri,
      ),
    );
    await tester.pump();

    expect(find.text('RELAY'), findsOneWidget);
    expect(find.text('relay.example.com'), findsOneWidget);
    expect(find.text('Copy pairing link'), findsOneWidget);

    await tester.tap(find.text('Copy pairing link'));
    await tester.pump();
    expect(clipboardText, pairingUri);
  });

  testWidgets('Relay page remains compact without overflow when narrow', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(
        rzvMode: EmbeddedRelayMode.custom,
        rzvRelay: 'wss://relay.example.com',
        rzvJwt: 'owner.jwt',
      ),
      status: const EmbeddedServerStatus(
        running: true,
        boundAddrs: ['tcp://127.0.0.1:7777', 'rzv://wss://relay.example.com'],
        pairingUri: 'motif://pair?v=1&rzv=relay.example.com&psk=abc&pk=def',
      ),
    );

    final errors = await _captureFlutterErrors(tester, () async {
      await _pumpPage(tester, service, size: const Size(460, 760));
    });

    expect(find.text('RELAY'), findsOneWidget);
    expect(find.text('Copy pairing link'), findsOneWidget);
    expect(errors, isEmpty);
  });

  testWidgets('settings Dialog renders configuration and explicit actions', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(),
      status: const EmbeddedServerStatus(),
    );
    final errors = await _captureFlutterErrors(tester, () async {
      await _pumpSettings(tester, service);
    });

    expect(find.text('Server Settings'), findsOneWidget);
    expect(find.text('Loopback'), findsNothing);
    expect(find.text('Local network'), findsOneWidget);
    expect(find.text('CONNECTION RELAY'), findsOneWidget);
    expect(find.byKey(const ValueKey('relay-mode-free')), findsOneWidget);
    expect(find.text('Free'), findsOneWidget);
    expect(find.text(kDefaultRzvRelayAddress), findsOneWidget);
    expect(find.text('NOTIFICATIONS'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Local Server'), findsNothing);
    expect(errors, isEmpty);
  });

  testWidgets('Cancel discards the settings draft', (tester) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(),
      status: const EmbeddedServerStatus(),
    );
    await _pumpPage(tester, service);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    await tester.enterText(_fieldWithLabel('Port'), '8888');
    await tester.pump();

    expect(service.config.port, 7777);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(service.config.port, 7777);
    expect(service.stopCount, 0);
    expect(service.startCount, 0);
  });

  testWidgets('Save persists settings without starting a stopped Server', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(),
      status: const EmbeddedServerStatus(),
    );
    await _pumpSettings(tester, service);

    await tester.enterText(_fieldWithLabel('Port'), '8888');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(service.config.port, 8888);
    expect(service.stopCount, 0);
    expect(service.startCount, 0);
  });

  testWidgets('Save confirms and restarts a running Server', (tester) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(),
      status: const EmbeddedServerStatus(running: true, sessionCount: 2),
    );
    await _pumpSettings(tester, service);

    await tester.enterText(_fieldWithLabel('Port'), '8888');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Save and restart Server?'), findsOneWidget);
    expect(find.textContaining('every current Terminal'), findsOneWidget);
    expect(find.textContaining('running Codex Threads'), findsOneWidget);
    expect(service.config.port, 7777);

    await tester.tap(find.text('Back to settings'));
    await tester.pumpAndSettle();
    expect(find.text('Server Settings'), findsOneWidget);
    expect(service.config.port, 7777);

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save and restart'));
    await tester.pumpAndSettle();

    expect(service.config.port, 8888);
    expect(service.stopCount, 1);
    expect(service.startCount, 1);
  });

  testWidgets('Relay settings are validated before saving', (tester) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(),
      status: const EmbeddedServerStatus(),
    );
    await _pumpSettings(tester, service);

    await tester.tap(find.byKey(const ValueKey('relay-mode-free')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(
      find.text('Relay address is required for a Custom Relay.'),
      findsOneWidget,
    );
    expect(service.config.rzvMode, EmbeddedRelayMode.free);
  });

  testWidgets('stopping the Server requires destructive confirmation', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(),
      status: const EmbeddedServerStatus(running: true, sessionCount: 1),
    );
    await _pumpPage(tester, service);

    await tester.tap(find.text('Stop Server'));
    await tester.pumpAndSettle();
    expect(find.text('Stop Server?'), findsOneWidget);
    expect(find.textContaining('running Codex Threads'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(service.stopCount, 0);

    await tester.tap(find.text('Stop Server'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop Server').last);
    await tester.pumpAndSettle();
    expect(service.stopCount, 1);
  });

  testWidgets('shows Relay connection errors on the running page', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(
        rzvMode: EmbeddedRelayMode.custom,
        rzvRelay: 'relay.example.com',
        rzvJwt: 'owner.jwt',
      ),
      status: const EmbeddedServerStatus(
        running: true,
        relayError: 'rzv WebSocket upgrade: HTTP error: 401 Unauthorized',
      ),
    );
    await _pumpPage(tester, service);

    expect(find.text('RELAY'), findsOneWidget);
    expect(
      find.text('JWT verification failed — check the Relay owner JWT.'),
      findsOneWidget,
    );
  });

  testWidgets('reveals and copies the Relay owner JWT in settings', (
    tester,
  ) async {
    const jwt = 'header.payload.signature';
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(
        rzvMode: EmbeddedRelayMode.custom,
        rzvRelay: 'relay.example.com',
        rzvJwt: jwt,
      ),
      status: const EmbeddedServerStatus(),
    );
    String? clipboardText;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardText =
                (call.arguments as Map<Object?, Object?>)['text'] as String?;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );

    await _pumpSettings(tester, service);
    final jwtField = _fieldWithLabel('Relay owner JWT');
    expect(tester.widget<TextField>(jwtField).obscureText, isTrue);

    await tester.ensureVisible(find.byTooltip('Show Relay owner JWT'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show Relay owner JWT'));
    await tester.pump();
    expect(tester.widget<TextField>(jwtField).obscureText, isFalse);

    await tester.ensureVisible(find.byTooltip('Copy Relay owner JWT'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Copy Relay owner JWT'));
    await tester.pump();
    expect(clipboardText, jwt);
  });

  testWidgets('checks the Push Relay health without saving the draft', (
    tester,
  ) async {
    final service = _FakeEmbeddedServerService(
      config: const EmbeddedServerConfig(),
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

    await tester.ensureVisible(find.text('Health'));
    await tester.tap(find.text('Health'));
    await tester.pump();
    expect(checkedAddress, kDefaultPushRelayAddress);
    expect(find.text('Checking'), findsOneWidget);

    health.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('OK'), findsOneWidget);
    expect(service.config.pushRelayUrl, kDefaultPushRelayAddress);
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

    await tester.ensureVisible(find.text('Tailscale settings'));
    expect(find.text('motif-dev · Official · Browser login'), findsOneWidget);
    expect(find.text('CONTROL SERVER'), findsNothing);
    expect(find.text('SIGN-IN'), findsNothing);

    await tester.tap(find.text('Tailscale settings'));
    await tester.pumpAndSettle();
    expect(find.text('CONTROL SERVER'), findsOneWidget);
    expect(find.text('SIGN-IN'), findsOneWidget);
  });
}

Finder _fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _pumpSettings(
  WidgetTester tester,
  EmbeddedServerService service, {
  Future<bool> Function(String address)? pushRelayHealthChecker,
}) async {
  tester.view.physicalSize = const Size(900, 900);
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
        home: EmbeddedServerSettingsDialog(
          pushRelayHealthChecker: pushRelayHealthChecker,
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _pumpPage(
  WidgetTester tester,
  EmbeddedServerService service, {
  Size size = const Size(900, 600),
}) async {
  tester.view.physicalSize = size;
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
  int startCount = 0;
  int stopCount = 0;

  _FakeEmbeddedServerService({required super.config, required super.status})
    : super(available: true);

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
  Future<List<RegisteredPushToken>> registeredPushTokens() async => const [];

  @override
  Future<PushTestResult> sendTestPush(String deviceToken) async =>
      const PushTestResult(sent: true);

  @override
  Future<void> updateConfig(EmbeddedServerConfig next) async {
    configState = next;
  }

  void setStatus(EmbeddedServerStatus next) => statusState = next;
}
