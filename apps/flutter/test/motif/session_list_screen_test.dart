import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/net/proxy_client.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:motif/motif/ui/screens/session_list_screen.dart';
import 'package:motif/motif/ui/screens/session_name_generator.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/top_toast.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_server_transport.dart';

class _CreatingServerFixture {
  _CreatingServerFixture({this.live = true, this.onConnect});

  final List<(String, String)> created = [];
  final bool live;
  final TestServerConnect? onConnect;
  List<SessionInfo> _sessions = [];
  List<SessionInfo> get sessions => _sessions;
  set sessions(Iterable<SessionInfo> value) => _sessions = [...value];
  int refreshes = 0;
  late final TestServerTransport transport = TestServerTransport(
    live: live,
    onConnect: onConnect,
    onCall: handleServerCall,
  );

  Future<Map<String, Object?>> handleServerCall(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    switch (method) {
      case 'session.create':
        final name = params['name']! as String;
        final workdir = params['workdir']! as String;
        created.add((name, workdir));
        sessions.add(SessionInfo(name: name, workdir: workdir));
        return {
          'session': {'name': name, 'workdir': workdir},
        };
      case 'session.list':
        refreshes++;
        return {
          'sessions': [
            for (final session in sessions)
              {'name': session.name, 'workdir': session.workdir},
          ],
        };
      case 'session.destroy':
        await destroyServerSession(params['name']! as String);
        return const {};
      default:
        return const {};
    }
  }

  Future<void> destroyServerSession(String name) async {}
}

class _DestroyingServerFixture extends _CreatingServerFixture {
  _DestroyingServerFixture({this.fail = false});

  final bool fail;
  final List<String> destroyed = [];

  @override
  Future<void> destroyServerSession(String name) async {
    destroyed.add(name);
    final index = sessions.indexWhere((session) => session.name == name);
    final removed = index < 0 ? null : sessions[index];
    if (removed != null) {
      sessions = [...sessions]..removeAt(index);
    }

    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (!fail) return;

    if (removed != null) {
      final restored = [...sessions]..insert(index, removed);
      sessions = restored;
    }
    throw StateError('server rejected destroy');
  }
}

class _StoppedTailscale extends TailscaleService {
  @override
  Future<void> start({String? authKey}) async {}

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

Future<AppState> _appStateFor(
  Map<String, _CreatingServerFixture> fixtures,
) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final app = AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices.defaults(),
    serverTransportFactory: (server) => fixtures[server.id]!.transport,
  );
  for (final entry in fixtures.entries) {
    await app.servers.add(
      MotifServer(id: entry.key, name: entry.key, host: '127.0.0.1'),
    );
    app.serverInstance(entry.key);
  }
  return app;
}

Future<AppState> _appState(_CreatingServerFixture motif) async {
  return _appStateFor({'server-1': motif});
}

Future<void> _pumpSessionList(
  WidgetTester tester,
  _CreatingServerFixture motif,
) async {
  final app = await _appState(motif);
  await tester.pumpWidget(
    MotifScope(
      appState: app,
      child: MaterialApp(
        theme: motifTheme(Brightness.dark),
        home: const MotifToastHost(child: SessionListScreen()),
      ),
    ),
  );
  await tester.pump();
}

Finder _fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

void main() {
  testWidgets('async connection replaces the connect empty state', (
    tester,
  ) async {
    final connectGate = Completer<void>();
    final motif = _CreatingServerFixture(
      live: false,
      onConnect:
          (_, _, {required force, required proxy, required certPin}) async {
            await connectGate.future;
            return const PingInfo(service: 'motif-server', version: 'test');
          },
    );

    await _pumpSessionList(tester, motif);

    expect(find.text('Connect server-1'), findsOneWidget);
    await tester.tap(find.text('Connect server-1'));
    await tester.pump();
    expect(find.text('Connecting…'), findsOneWidget);

    connectGate.complete();
    await tester.pumpAndSettle();

    expect(find.text('Connect server-1'), findsNothing);
    expect(find.text('Create session'), findsOneWidget);
    expect(find.text('No sessions yet'), findsOneWidget);
    expect(motif.transport.connectCalls, 1);
    expect(motif.refreshes, 1);
  });

  testWidgets('non-empty session list includes create session action', (
    tester,
  ) async {
    final motif = _CreatingServerFixture()
      ..sessions = const [SessionInfo(name: 'dev', workdir: '~/dev')];

    await _pumpSessionList(tester, motif);

    expect(find.text('Create session'), findsOneWidget);
    expect(find.text('dev'), findsOneWidget);

    await tester.tap(find.text('Create session'));
    await tester.pumpAndSettle();

    expect(find.text('New session'), findsOneWidget);
    await tester.enterText(_fieldWithLabel('Name'), 'build');
    await tester.enterText(_fieldWithLabel('Working directory'), '~/build');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(motif.created, [('build', '~/build')]);
    expect(find.text('build'), findsOneWidget);
  });

  testWidgets('create session dialog pre-fills adjective fruit name', (
    tester,
  ) async {
    final motif = _CreatingServerFixture()
      ..sessions = const [SessionInfo(name: 'dev', workdir: '~/dev')];

    await _pumpSessionList(tester, motif);

    await tester.tap(find.text('Create session'));
    await tester.pumpAndSettle();

    final nameField = tester.widget<TextField>(_fieldWithLabel('Name'));
    final generated = nameField.controller!.text;
    final parts = generated.split('-');
    expect(parts, hasLength(2));
    expect(sessionNameAdjectives, contains(parts[0]));
    expect(sessionNameFruits, contains(parts[1]));

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(motif.created, [(generated, '~')]);
  });

  testWidgets('swipe destroy alert cancel keeps the session', (tester) async {
    final motif = _DestroyingServerFixture()
      ..sessions = const [SessionInfo(name: 'dev', workdir: '~/dev')];

    await _pumpSessionList(tester, motif);
    await tester.drag(find.text('dev'), const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(find.text('Destroy "dev"?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('dev'), findsOneWidget);
    expect(motif.destroyed, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swipe destroy confirms and removes the session', (tester) async {
    final motif = _DestroyingServerFixture()
      ..sessions = const [SessionInfo(name: 'dev', workdir: '~/dev')];

    await _pumpSessionList(tester, motif);
    await tester.drag(find.text('dev'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Destroy'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pumpAndSettle();

    expect(motif.destroyed, ['dev']);
    expect(find.text('dev'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('swipe destroy failure restores the session and reports it', (
    tester,
  ) async {
    final motif = _DestroyingServerFixture(fail: true)
      ..sessions = const [SessionInfo(name: 'dev', workdir: '~/dev')];

    await _pumpSessionList(tester, motif);
    await tester.drag(find.text('dev'), const Offset(-600, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Destroy'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump();
    await tester.pump();

    expect(motif.destroyed, ['dev']);
    expect(find.text('dev'), findsOneWidget);
    expect(find.textContaining('Destroy failed:'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Let the toast's auto-dismiss timer complete before test teardown.
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('groups sessions by connected server', (tester) async {
    final dev = _CreatingServerFixture()
      ..sessions = const [SessionInfo(name: 'dev-shell', workdir: '~/dev')];
    final prod = _CreatingServerFixture()
      ..sessions = const [SessionInfo(name: 'prod-shell', workdir: '~/prod')];
    final app = await _appStateFor({'dev': dev, 'prod': prod});

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const SessionListScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('DEV'), findsOneWidget);
    expect(find.text('PROD'), findsOneWidget);
    expect(find.text('dev-shell'), findsOneWidget);
    expect(find.text('prod-shell'), findsOneWidget);
  });

  testWidgets('refreshes one server from section header action', (
    tester,
  ) async {
    final dev = _CreatingServerFixture()
      ..sessions = const [SessionInfo(name: 'dev-shell')];
    final prod = _CreatingServerFixture()
      ..sessions = const [SessionInfo(name: 'prod-shell')];
    final app = await _appStateFor({'dev': dev, 'prod': prod});

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const SessionListScreen(),
        ),
      ),
    );
    await tester.pump();
    dev.refreshes = 0;
    prod.refreshes = 0;

    await tester.tap(find.byKey(const ValueKey('refresh-server-sessions-dev')));
    await tester.pumpAndSettle();

    expect(dev.refreshes, 1);
    expect(prod.refreshes, 0);
  });

  testWidgets('pull to refresh reloads all connected server sessions', (
    tester,
  ) async {
    final dev = _CreatingServerFixture()
      ..sessions = const [SessionInfo(name: 'dev-shell')];
    final prod = _CreatingServerFixture()
      ..sessions = const [SessionInfo(name: 'prod-shell')];
    final app = await _appStateFor({'dev': dev, 'prod': prod});

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const SessionListScreen(),
        ),
      ),
    );
    await tester.pump();
    dev.refreshes = 0;
    prod.refreshes = 0;

    await tester.drag(find.byType(ListView), const Offset(0, 360));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(dev.refreshes, 1);
    expect(prod.refreshes, 1);
  });

  testWidgets('refreshes sessions after returning from another page', (
    tester,
  ) async {
    final dev = _CreatingServerFixture()
      ..sessions = const [SessionInfo(name: 'dev-shell')];
    final app = await _appStateFor({'dev': dev});

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          navigatorObservers: [motifRouteObserver],
          home: const SessionListScreen(),
        ),
      ),
    );
    await tester.pump();
    dev.refreshes = 0;

    Navigator.of(
      tester.element(find.byType(SessionListScreen)),
    ).push(MaterialPageRoute<void>(builder: (_) => const Text('Other page')));
    await tester.pumpAndSettle();
    expect(find.text('Other page'), findsOneWidget);

    Navigator.of(tester.element(find.text('Other page'))).pop();
    await tester.pumpAndSettle();

    expect(dev.refreshes, 1);
  });

  testWidgets('empty state guides Tailscale setup before connecting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final app = AppState(
      servers: ServerStore(prefs),
      terminalSettings: TerminalSettingsStore(prefs),
      commands: QuickCommandStore(prefs),
      push: PushSettingsStore(prefs),
      platform: PlatformServices(
        tailscale: _StoppedTailscale(),
        speech: NoopSpeechService(),
        push: NoopPushService(),
      ),
    );
    await app.servers.add(
      const MotifServer(
        id: 'server-1',
        name: 'Tailnet Dev',
        host: 'motifd-dev.tail.ts.net',
        kind: ServerKind.tailscale,
      ),
    );

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.dark),
          home: const SessionListScreen(),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Tailscale setup'), findsOneWidget);
    expect(
      find.text('Start Tailscale to reach tailnet servers.'),
      findsOneWidget,
    );

    await tester.tap(find.text('Setup Reach Via'));
    await tester.pumpAndSettle();

    expect(find.text('Setup Tailscale'), findsWidgets);
    expect(find.text('Connect with browser'), findsOneWidget);
  });
}
