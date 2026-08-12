import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/codex_session_state.dart';
import 'package:motif/motif/codex/codex_state.dart';
import 'package:motif/motif/codex/codex_thread_catalog.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:motif/motif/state/persistence/stores.dart';
import 'package:motif/motif/ui/screens/codex_session_screen.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('desktop sidebar defaults open, toggles and resizes', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final codex = CodexState();
    final sessionState = readySessionState();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: codex,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: CodexSessionScreen(
            serverId: 'server',
            session: 'agent',
            sessionStateFactory: (_, _, _) => sessionState,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('codex-desktop-sidebar')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('codex-sidebar-toggle')));
    await tester.pump();
    expect(find.byKey(const ValueKey('codex-desktop-sidebar')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('codex-sidebar-toggle')));
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('codex-sidebar-resize-handle')),
      const Offset(50, 0),
    );
    await tester.pump();
    expect(codex.sidebarWidth, greaterThan(340));

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('mobile sidebar starts closed and opens as a drawer', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(600, 800);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final codex = CodexState();
    final sessionState = readySessionState();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: codex,
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: CodexSessionScreen(
            serverId: 'server',
            session: 'agent',
            sessionStateFactory: (_, _, _) => sessionState,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Drawer), findsNothing);
    expect(find.byKey(const ValueKey('codex-desktop-sidebar')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('codex-sidebar-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(Drawer), findsOneWidget);
    expect(find.text('Projects'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('codex-mode-timeline')));
    await tester.pump();
    expect(codex.sidebarMode, CodexSidebarMode.timeline);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('thread loading replaces the detail content on a white surface', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final sessionState = readySessionState();
    sessionState
      ..selectedThread = sessionState.catalog.allThreads.single
      ..readingThreadId = 'next-thread';

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          theme: motifTheme(Brightness.light),
          home: CodexSessionScreen(
            serverId: 'server',
            session: 'agent',
            sessionStateFactory: (_, _, _) => sessionState,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('codex-thread-loading')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-thread-detail')), findsNothing);
    expect(
      tester
          .widget<ColoredBox>(find.byKey(const ValueKey('codex-main-surface')))
          .color,
      MotifColors.light.surface,
    );

    sessionState
      ..readingThreadId = null
      ..notifyListeners();
    await tester.pump();
    expect(find.byKey(const ValueKey('codex-thread-loading')), findsNothing);
    final detail = tester.widget<Material>(
      find.byKey(const ValueKey('codex-thread-detail')),
    );
    expect(detail.color, MotifColors.light.surface);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });

  testWidgets('nested Codex route keeps Back beside the sidebar toggle', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final app = await appState();
    final sessionState = readySessionState();

    await tester.pumpWidget(
      MotifScope(
        appState: app,
        codexState: CodexState(),
        child: MaterialApp(
          initialRoute: '/codex',
          theme: motifTheme(Brightness.light),
          routes: {
            '/': (_) => const Scaffold(body: Text('Sessions home')),
            '/codex': (_) => CodexSessionScreen(
              serverId: 'server',
              session: 'agent',
              sessionStateFactory: (_, _, _) => sessionState,
            ),
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(BackButton), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-sidebar-toggle')), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Sessions home'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    app.dispose();
  });
}

Future<AppState> appState() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return AppState(
    servers: ServerStore(prefs),
    terminalSettings: TerminalSettingsStore(prefs),
    commands: QuickCommandStore(prefs),
    push: PushSettingsStore(prefs),
    platform: PlatformServices.defaults(),
  );
}

CodexSessionState readySessionState() {
  final thread = CodexThread(
    cliVersion: 'test',
    createdAt: 1,
    cwd: const CodexV2AbsolutePathBuf('/work/motif'),
    ephemeral: false,
    id: 'thread',
    modelProvider: 'openai',
    name: 'Thread',
    preview: '',
    sessionId: 'thread',
    source: const CodexSessionSource('cli'),
    status: const CodexNotLoadedThreadStatus(),
    turns: const [],
    updatedAt: 1,
  );
  return CodexSessionState(
      serverId: 'server',
      session: 'agent',
      connection: ScreenFakeClient(),
    )
    ..catalog = buildCodexCatalog([thread], null)
    ..catalogPhase = CodexCatalogPhase.ready;
}

final class ScreenFakeClient extends ChangeNotifier
    implements CodexAppServerClient {
  final StreamController<Map<String, Object?>> _raw =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<CodexJsonEncodable> _typed =
      StreamController<CodexJsonEncodable>.broadcast();

  @override
  CodexConnectionState state = CodexConnectionState(
    phase: CodexConnectionPhase.connected,
    response: const CodexInitializeResponse(
      codexHome: CodexV2AbsolutePathBuf('/tmp/codex'),
      platformFamily: 'unix',
      platformOs: 'macos',
      userAgent: 'test',
    ),
  );

  @override
  Stream<Map<String, Object?>> get rawMessages => _raw.stream;

  @override
  Stream<CodexJsonEncodable> get typedMessages => _typed.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> retry() async {}

  @override
  Future<CodexThreadListResponse> listThreads(
    CodexThreadListParams params,
  ) async => const CodexThreadListResponse(data: []);

  @override
  Future<CodexThreadReadResponse> readThread(
    String threadId, {
    bool includeTurns = false,
  }) async => throw StateError('unused');

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async => throw StateError('unused');

  @override
  Future<CodexThreadStartResponse> startThread(
    CodexThreadStartParams params,
  ) async => throw StateError('unused');

  @override
  Future<CodexThreadResumeResponse> resumeThread(String threadId) async =>
      throw StateError('unused');

  @override
  Future<CodexTurnStartResponse> startTurn(CodexTurnStartParams params) async =>
      throw StateError('unused');

  @override
  Future<CodexTurnSteerResponse> steerTurn(CodexTurnSteerParams params) async =>
      throw StateError('unused');

  @override
  Future<CodexTurnInterruptResponse> interruptTurn(
    String threadId,
    String turnId,
  ) async => const CodexTurnInterruptResponse();

  @override
  Future<CodexModelListResponse> listModels(
    CodexModelListParams params,
  ) async => const CodexModelListResponse(data: []);

  @override
  Future<CodexPermissionProfileListResponse> listPermissionProfiles(
    CodexPermissionProfileListParams params,
  ) async => const CodexPermissionProfileListResponse(data: []);

  @override
  Future<CodexCollaborationModeListResponse> listCollaborationModes() async =>
      const CodexCollaborationModeListResponse(data: []);

  @override
  Future<CodexSkillsListResponse> listSkills(
    CodexSkillsListParams params,
  ) async => const CodexSkillsListResponse(data: []);

  @override
  Future<CodexPluginListResponse> listPlugins(
    CodexPluginListParams params,
  ) async => const CodexPluginListResponse(marketplaces: []);

  @override
  Future<CodexThreadGoalGetResponse> getThreadGoal(String threadId) async =>
      const CodexThreadGoalGetResponse();

  @override
  Future<CodexThreadGoalSetResponse> setThreadGoal(
    CodexThreadGoalSetParams params,
  ) async => throw StateError('unused');

  @override
  Future<CodexThreadGoalClearResponse> clearThreadGoal(String threadId) async =>
      const CodexThreadGoalClearResponse(cleared: true);

  @override
  Future<CodexFsReadFileResponse> readFile(String path) async =>
      throw StateError('unused');

  @override
  Future<CodexFsCreateDirectoryResponse> createDirectory(String path) async =>
      const CodexFsCreateDirectoryResponse();

  @override
  Future<CodexFsWriteFileResponse> writeFile(
    String path,
    String dataBase64,
  ) async => const CodexFsWriteFileResponse();

  @override
  Future<void> respondToServerRequest(
    CodexV2RequestId id,
    CodexJsonEncodable response,
  ) async {}

  @override
  Future<CodexFsWatchResponse> watchFile(String path, String watchId) async =>
      throw StateError('unused');

  @override
  Future<CodexFsUnwatchResponse> unwatchFile(String watchId) async =>
      const CodexFsUnwatchResponse();

  @override
  Future<void> close() async {}

  @override
  void dispose() {
    unawaited(_raw.close());
    unawaited(_typed.close());
    super.dispose();
  }
}
