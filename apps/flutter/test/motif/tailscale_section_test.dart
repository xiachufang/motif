import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/tailscale_section.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeTailscale extends TailscaleService {
  final Future<void> Function(String? authKey)? onStart;
  _FakeTailscale(TailscaleState state, {this.onStart})
    : super(initialState: state);
  @override
  Future<void> start({String? authKey}) async => onStart?.call(authKey);
  @override
  Future<void> stop() async {}
  @override
  Future<String> resolveHost(String host) async => host;
  @override
  Future<List<TailscalePeer>> discoverPeers() async => const [];
  @override
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async => const TailscalePingResult.unreachable('Tailscale off');
  @override
  ProxySettings? get loopbackProxy => null;
}

class _MutableTailscale extends TailscaleService {
  _MutableTailscale(TailscaleState state) : super(initialState: state);

  void emit(TailscaleState state) => tailscaleState = state;

  @override
  Future<void> start({String? authKey}) async {}
  @override
  Future<void> stop() async => emit(TailscaleState.stopped);
  @override
  Future<String> resolveHost(String host) async => host;
  @override
  Future<List<TailscalePeer>> discoverPeers() async => const [];
  @override
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async => const TailscalePingResult.unreachable('Tailscale off');
  @override
  ProxySettings? get loopbackProxy => null;

  @override
  Future<void> dispose() => Future<void>.value();
}

Future<AppState> _appWith(
  TailscaleState st, {
  TailscaleService? tailscale,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices(
      tailscale: tailscale ?? _FakeTailscale(st),
      speech: NoopSpeechService(),
      push: NoopPushService(),
    ),
  );
}

Future<void> _pump(WidgetTester tester, TailscaleState st) async {
  final app = await _appWith(st);
  await tester.pumpWidget(
    MotifScope(
      appState: app,
      child: MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: const Scaffold(body: TailscaleSection()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders stopped with an auth-key setup sheet', (t) async {
    await _pump(t, TailscaleState.stopped);
    expect(find.text('Setup Tailscale'), findsOneWidget);

    await t.tap(find.text('Setup Tailscale'));
    await t.pumpAndSettle();
    expect(find.text('Connect with browser'), findsOneWidget);
    expect(find.text('Connect with auth key'), findsOneWidget);
    expect(find.textContaining('tskey'), findsOneWidget);
  });

  testWidgets('starts browser login without an auth key', (t) async {
    String? capturedAuthKey = 'unset';
    final fake = _FakeTailscale(
      TailscaleState.stopped,
      onStart: (authKey) async => capturedAuthKey = authKey,
    );
    final app = await _appWith(TailscaleState.stopped, tailscale: fake);
    await t.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: TailscaleSection()),
        ),
      ),
    );

    await t.tap(find.text('Setup Tailscale'));
    await t.pumpAndSettle();
    await t.tap(find.text('Connect with browser'));
    await t.pump();

    expect(capturedAuthKey, isNull);
  });

  testWidgets('shows unavailable state when embedded Tailscale is missing', (
    t,
  ) async {
    final app = await _appWith(
      TailscaleState.stopped,
      tailscale: NoopTailscaleService(),
    );
    await t.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: TailscaleSection()),
        ),
      ),
    );

    await t.tap(find.text('Setup Tailscale'));
    await t.pumpAndSettle();
    await t.tap(find.text('Connect with browser'));
    await t.pump();

    expect(find.text('Failed'), findsOneWidget);
    expect(
      find.textContaining('Embedded Tailscale is unavailable'),
      findsWidgets,
    );
  });

  testWidgets('renders running with a details disconnect button', (t) async {
    await _pump(t, const TailscaleState(TailscaleStatus.running));
    expect(find.text('Tailscale connected'), findsOneWidget);

    await t.tap(find.text('Tailscale connected'));
    await t.pumpAndSettle();
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('switches an open setup sheet to details after login succeeds', (
    t,
  ) async {
    final tailscale = _MutableTailscale(TailscaleState.stopped);
    addTearDown(tailscale.dispose);
    final app = await _appWith(TailscaleState.stopped, tailscale: tailscale);
    await t.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const Scaffold(body: TailscaleSection()),
        ),
      ),
    );

    await t.tap(find.text('Setup Tailscale'));
    await t.pumpAndSettle();
    expect(find.text('Connect with browser'), findsOneWidget);

    tailscale.emit(const TailscaleState(TailscaleStatus.running));
    await t.pumpAndSettle();

    expect(find.text('Connect with browser'), findsNothing);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('renders needsAuth with the sign-in URL', (t) async {
    await _pump(
      t,
      const TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: 'https://login.tailscale.com/a/abc123',
      ),
    );
    expect(find.text('Tailscale needs login'), findsOneWidget);

    await t.tap(find.text('Tailscale needs login'));
    await t.pumpAndSettle();
    expect(find.textContaining('login.tailscale.com'), findsOneWidget);
  });

  testWidgets('opens the sign-in URL in the external browser', (t) async {
    const channel = MethodChannel('motif/browser');
    final calls = <MethodCall>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return true;
    });
    addTearDown(
      () => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );

    await _pump(
      t,
      const TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: 'https://login.tailscale.com/a/abc123',
      ),
    );

    await t.tap(find.text('Tailscale needs login'));
    await t.pumpAndSettle();
    await t.tap(find.textContaining('login.tailscale.com'));
    await t.pump();

    expect(calls, hasLength(1));
    expect(calls.single.method, 'openUrl');
    expect(calls.single.arguments, {
      'url': 'https://login.tailscale.com/a/abc123',
    });
  });

  testWidgets('renders degraded with a reason detail', (t) async {
    await _pump(
      t,
      const TailscaleState(
        TailscaleStatus.degraded,
        detail: 'control plane offline',
      ),
    );
    expect(find.text('Tailscale reconnecting…'), findsOneWidget);
    expect(find.text('control plane offline'), findsOneWidget);
  });
}
