import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/coding_agent_hooks.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/state/server/coding_agent_hook_prompt.dart';
import 'package:motif/motif/ui/screens/terminal_settings_sheet.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/top_toast.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_server_transport.dart';

void main() {
  test('hook prompt choices are persisted per server and agent', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = TerminalSettingsStore(prefs);

    await store.markCodingAgentHookPromptShown('server-a', CodingAgent.claude);

    final reloaded = TerminalSettingsStore(prefs);
    expect(
      reloaded.codingAgentHookPromptShown('server-a', CodingAgent.claude),
      isTrue,
    );
    expect(
      reloaded.codingAgentHookPromptShown('server-a', CodingAgent.codex),
      isFalse,
    );
    expect(
      reloaded.codingAgentHookPromptShown('server-b', CodingAgent.claude),
      isFalse,
    );
  });

  test('configured server hook suppresses the first-run prompt', () async {
    final backend = _HookRpcBackend()..codexConfigured = true;
    final app = await _appWithHookBackend(backend);
    addTearDown(app.dispose);

    final show = await claimCodingAgentHookPrompt(
      controller: app.existingServerInstance('server-1')!.codingAgentHooks,
      promptStore: app.terminalSettings,
      serverId: 'server-1',
      agent: CodingAgent.codex,
    );

    expect(show, isFalse);
    expect(
      app.terminalSettings.codingAgentHookPromptShown(
        'server-1',
        CodingAgent.codex,
      ),
      isTrue,
    );
    expect(backend.methods, contains('agent_hooks.status'));
  });

  testWidgets('manages Claude and Codex hooks through the server RPC', (
    tester,
  ) async {
    final backend = _HookRpcBackend();
    final app = await _appWithHookBackend(backend);
    addTearDown(app.dispose);

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: const MotifToastHost(
            child: Scaffold(body: TerminalSettingsSheet(serverId: 'server-1')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(backend.methods, contains('agent_hooks.status'));
    expect(find.text('CODING AGENT HOOKS'), findsOneWidget);
    expect(find.text('Claude Code'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Not installed'), findsNWidgets(2));

    await tester.tap(find.byKey(const ValueKey('install-claude-hook')));
    await tester.pumpAndSettle();

    expect(backend.methods.last, 'agent_hooks.install');
    expect(backend.agents.last, 'claude');
    expect(find.byKey(const ValueKey('remove-claude-hook')), findsOneWidget);
    expect(find.byKey(const ValueKey('install-codex-hook')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('remove-claude-hook')));
    await tester.pumpAndSettle();

    expect(backend.methods.last, 'agent_hooks.uninstall');
    expect(backend.agents.last, 'claude');
    expect(find.byKey(const ValueKey('install-claude-hook')), findsOneWidget);
  });

  testWidgets('treats a configured server hook as installed', (tester) async {
    final backend = _HookRpcBackend()..codexConfigured = true;
    final app = await _appWithHookBackend(backend);
    addTearDown(app.dispose);

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: const Scaffold(
            body: TerminalSettingsSheet(serverId: 'server-1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('remove-codex-hook')), findsOneWidget);
  });
}

Future<AppState> _appWithHookBackend(_HookRpcBackend backend) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final transport = TestServerTransport(live: true, onCall: backend.call);
  final app = AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices.defaults(),
    serverTransportFactory: (_) => transport,
  );
  await app.servers.add(
    const MotifServer(
      id: 'server-1',
      name: 'Remote',
      host: 'remote.example.com',
    ),
  );
  app.serverInstance('server-1');
  return app;
}

class _HookRpcBackend {
  bool claudeConfigured = false;
  bool codexConfigured = false;
  final List<String> methods = [];
  final List<String> agents = [];

  Future<Map<String, Object?>> call(
    String method, [
    Map<String, Object?> params = const {},
  ]) async {
    methods.add(method);
    final agent = params['agent'] as String?;
    if (agent != null) agents.add(agent);
    if (method == 'agent_hooks.install') {
      if (agent == 'claude') claudeConfigured = true;
      if (agent == 'codex') codexConfigured = true;
    } else if (method == 'agent_hooks.uninstall') {
      if (agent == 'claude') claudeConfigured = false;
      if (agent == 'codex') codexConfigured = false;
    }
    return {
      'claude': {'installed': claudeConfigured, 'configured': claudeConfigured},
      'codex': {'installed': codexConfigured, 'configured': codexConfigured},
    };
  }
}
