// App Store screenshot flow against the dedicated review motifd.
// Credentials are supplied with --dart-define so they never live in source.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/codex_service_state.dart';
import 'package:motif/motif/codex/codex_thread_catalog.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:motif/motif/codex/side_chat_collection_controller.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/platform/secret_store.dart';
import 'package:motif/motif/platform/services.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:motif/motif/state/connection/connection_state.dart';
import 'package:motif/motif/state/server/server_transport.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_view_model.dart';
import 'package:motif/motif/state/workspace/workspace_api.dart';
import 'package:motif/motif/state/workspace/workspace_instance.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:motif/motif/ui/screens/codex_screen.dart';
import 'package:motif/motif/ui/screens/file_tree_panel.dart';
import 'package:motif/motif/ui/screens/side_chat_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('capture content-rich light and dark App Store scenes', (
    tester,
  ) async {
    const host = String.fromEnvironment('APPSTORE_REVIEW_HOST');
    const psk = String.fromEnvironment('APPSTORE_REVIEW_PSK');
    const publicKey = String.fromEnvironment('APPSTORE_REVIEW_PK');
    const port = int.fromEnvironment(
      'APPSTORE_REVIEW_PORT',
      defaultValue: 8099,
    );
    const serverId = 'appstore-review';
    const primarySession = 'motif-mobile';
    const showcaseSessions = [
      primarySession,
      'release-checks',
      'api-observability',
      'staging-shell',
      'crash-triage',
      'edge-logs',
      'database-migration',
      'security-audit',
    ];
    const baseWorkdir = '/home/demo/work';
    const demoRoot = '/home/demo/work/motif-showcase';
    const showcaseCodexThreadTitles = [
      'Review the mobile release',
      'Plan offline sync',
      'Audit reconnect handling',
      'Polish App Store screenshots',
      'Check TestFlight rollout',
    ];

    expect(host, isNotEmpty, reason: 'APPSTORE_REVIEW_HOST is required');
    expect(psk, isNotEmpty, reason: 'APPSTORE_REVIEW_PSK is required');
    expect(publicKey, isNotEmpty, reason: 'APPSTORE_REVIEW_PK is required');

    final profile = MotifServer(
      id: serverId,
      name: 'Review Mac',
      host: host,
      port: port,
      scheme: 'https',
      kind: ServerKind.direct,
      pubKey: publicKey,
      directHosts: const [host],
    );
    SharedPreferences.setMockInitialValues({
      'motif.servers.v1': MotifServer.encodeList([profile]),
      'activeServerID': serverId,
      'motif.insecureSecret.motif.server.credentials.$serverId': jsonEncode({
        'psk': psk,
      }),
      'motif.push.enabled': false,
      'motif.terminalSettings.v1': jsonEncode({
        'fontSize': 16.0,
        'theme': 'light',
      }),
    });

    final app = await AppState.load(
      platform: PlatformServices(
        tailscale: NoopTailscaleService(),
        speech: NoopSpeechService(),
        push: NoopPushService(),
        secrets: PreferencesSecretStore(),
      ),
    );
    addTearDown(app.dispose);

    await tester.pumpWidget(MotifScope(appState: app, child: const MotifApp()));
    await tester.pump();

    final startup = app.autoConnectStartupServer();
    final server = app.serverInstance(serverId);
    await _pumpUntil(
      tester,
      () => server.access.state is ServerConnected,
      reason: 'review motifd connects',
      timeout: const Duration(seconds: 30),
    );
    await startup;
    await server.sessions.refresh();
    for (final sessionName in {
      ...showcaseSessions,
      'motif-showcase',
      'motif-appstore',
    }) {
      if (server.viewModel.sessions.sessions.any(
        (session) => session.name == sessionName,
      )) {
        await app.destroySession(serverId, sessionName);
      }
    }

    CodexServiceState? codexSeed;
    final codexThreadIds = <String>[];
    SideChatCollectionController? screenshotSideChats;
    WorkspaceApi? cleanupWorkspace;
    addTearDown(() async {
      try {
        await screenshotSideChats?.close();
      } catch (_) {
        // Screenshot-only Side Chats may already be closed with their route.
      }
      final seed = codexSeed;
      if (seed != null) {
        for (final threadId in codexThreadIds.reversed) {
          try {
            await seed.deleteThread(threadId);
          } catch (_) {
            // The thread is disposable showcase data.
          }
        }
      }
      try {
        await seed?.close();
      } catch (_) {
        // The Codex socket may already be closed after a failed run.
      }
      seed?.dispose();
      final attachedWorkspace = cleanupWorkspace;
      if (attachedWorkspace != null) {
        try {
          await attachedWorkspace.remove(demoRoot);
        } catch (_) {
          // The temporary project may already be gone after a failed run.
        }
      }
      for (final sessionName in showcaseSessions) {
        try {
          await app.destroySession(serverId, sessionName);
        } catch (_) {
          // Best-effort cleanup keeps the shared review server tidy.
        }
      }
      try {
        await app.disconnectServer(serverId);
      } catch (_) {
        // The connection may already be closed by a failed integration run.
      }
    });

    for (final sessionName in showcaseSessions) {
      await server.sessions.create(sessionName, baseWorkdir);
    }
    await tester.pumpAndSettle();

    await _captureLightDark(tester, app, '01-workspaces');

    final primarySessionFinder = find.text(primarySession);
    for (
      var attempt = 0;
      attempt < 8 && primarySessionFinder.hitTestable().evaluate().isEmpty;
      attempt++
    ) {
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -420));
      await tester.pumpAndSettle();
    }
    await tester.tap(primarySessionFinder.hitTestable().first);
    await tester.pumpAndSettle();
    final workspace = app.workspaceForSession(serverId, primarySession);
    await _pumpUntil(
      tester,
      () => workspace.viewModel.connection.status is ConnAttached,
      reason: 'showcase session attaches',
      timeout: const Duration(seconds: 30),
    );
    cleanupWorkspace = workspace.workspace;
    try {
      await workspace.workspace.remove(demoRoot);
    } catch (_) {
      // A clean run has no previous showcase directory.
    }
    await _prepareShowcaseProject(workspace.workspace, demoRoot);

    if (workspace.viewModel.terminal.ptys.isEmpty) {
      await tester.tap(find.byTooltip('New terminal'));
      await tester.pumpAndSettle();
    }
    await _pumpUntil(
      tester,
      () => _activePtyId(workspace) != null,
      reason: 'terminal is ready',
      timeout: const Duration(seconds: 30),
    );
    final ptyId = _activePtyId(workspace)!;
    await workspace.terminal.activatePtyStream(ptyId);

    await workspace.terminal.writePty(ptyId, [
      ...utf8.encode("cd '$demoRoot'"),
      0x0d,
    ]);
    await _pumpUntil(
      tester,
      () => workspace.workspace.activeCwd() == demoRoot,
      reason: 'terminal enters the showcase project',
      timeout: const Duration(seconds: 20),
    );

    const initializeGit =
        "git init -q; git config user.name 'Motif Demo'; "
        "git config user.email 'demo@motif.app'; git add .; "
        "git commit -qm 'Build remote release workspace'";
    await workspace.terminal.writePty(ptyId, [
      ...utf8.encode(initializeGit),
      0x0d,
    ]);
    await _settleFor(tester, const Duration(seconds: 3));
    await _writeText(
      workspace.workspace,
      '$demoRoot/lib/services/sync_service.dart',
      _syncServiceUpdated,
    );
    await _writeText(
      workspace.workspace,
      '$demoRoot/lib/main.dart',
      _mainDartUpdated,
    );
    await _writeText(
      workspace.workspace,
      '$demoRoot/README.md',
      _readmeUpdated,
    );
    await _settleFor(tester, const Duration(seconds: 2));

    final serverTransport = server.transport;
    expect(serverTransport, isA<PoolServerTransport>());
    final codexConnection = CodexConnectionController(
      transport: RpcCodexTransport(
        (serverTransport as PoolServerTransport).pool,
      ),
    );
    final seed = CodexServiceState(
      serverId: serverId,
      connection: codexConnection,
    );
    codexSeed = seed;
    await seed.start();
    await _pumpUntil(
      tester,
      () => seed.connectionState.phase == CodexConnectionPhase.connected,
      reason: 'Codex connects for the showcase review',
      timeout: const Duration(seconds: 45),
    );
    await seed.refreshCatalog(showLoading: false);
    for (final staleThread in seed.catalog.allThreads.where(
      (thread) => showcaseCodexThreadTitles.contains(thread.name),
    )) {
      try {
        await seed.deleteThread(staleThread.id);
      } catch (_) {
        // A previous interrupted screenshot run may already have removed it.
      }
    }
    final created = await seed.createThreadForProject(
      const CodexLocalProject(
        id: 'motif-showcase',
        name: 'Motif Mobile',
        rootPaths: [demoRoot],
      ),
    );
    expect(created, isTrue, reason: seed.createThreadError);
    final createdThreadId = seed.selectedThread!.id;
    codexThreadIds.add(createdThreadId);
    await seed.renameThread(createdThreadId, showcaseCodexThreadTitles.first);
    await _pumpUntil(
      tester,
      () => seed.selectedConversation != null,
      reason: 'showcase Codex conversation opens',
    );
    final codexConversation = seed.selectedConversation!;
    final accepted = await codexConversation.submitMessage(
      'Review this project for a mobile release. Do not edit files. '
      'Summarize what is ready, call out the three modified files, and give '
      'a short launch checklist. Use clear bullets and finish with '
      '"Ready for review."',
      const [],
    );
    expect(accepted, isTrue, reason: codexConversation.sendError);

    var terminalCommand =
        "clear; printf '\\033[1;36mMOTIF REMOTE RELEASE CONSOLE\\033[0m\\n'; "
        "printf '\\033[2mSecure session · motif-mobile · 42 ms\\033[0m\\n\\n'; "
        "printf '\\033[1mProject\\033[0m   motif-showcase\\n'; "
        "printf '\\033[1mBranch\\033[0m    main\\n'; "
        "printf '\\033[1mRuntime\\033[0m   Flutter 3.35 · Dart 3.9\\n'; "
        "printf '\\n\\033[1;34m\$ git status --short\\033[0m\\n'; "
        "git status --short; "
        "printf '\\n\\033[1;34m\$ git diff --stat\\033[0m\\n'; "
        "git diff --stat; "
        "printf '\\n\\033[1;34m\$ flutter test\\033[0m\\n'; "
        "printf '00:04 +18: All tests passed!\\n'; "
        "printf '\\n\\033[1;32m✓ Remote workspace healthy\\033[0m\\n'; "
        "printf '\\033[1;32m✓ Changes ready for review\\033[0m\\n'; "
        "printf '\\033[1;32m✓ Release checks passed\\033[0m\\n'";
    final logicalWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    if (logicalWidth >= 768) {
      terminalCommand +=
          "; printf '\\n\\033[1;34m\$ flutter analyze\\033[0m\\n'; "
          "printf 'Analyzing motif-showcase...\\n'; "
          "printf 'No issues found! (ran in 2.1s)\\n'; "
          "printf '\\n\\033[1;34m\$ flutter build ios --release\\033[0m\\n'; "
          "printf 'Building com.motif.showcase for device...\\n'; "
          "printf '✓ Tree-shaken assets     12.4 MB → 3.1 MB\\n'; "
          "printf '✓ Signed release bundle  Build/Products/Release-iphoneos\\n'; "
          "printf '\\n\\033[1mRelease summary\\033[0m\\n'; "
          "printf 'Version        2.4.0 (128)\\n'; "
          "printf 'Bundle ID      com.motif.showcase\\n'; "
          "printf 'Minimum iOS    17.0\\n'; "
          "printf 'Artifact       MotifShowcase.ipa · 18.6 MB\\n'; "
          "printf '\\n\\033[1mQuality gates\\033[0m\\n'; "
          "printf '\\033[1;32m✓ Static analysis      0 issues\\033[0m\\n'; "
          "printf '\\033[1;32m✓ Unit tests           18 passed\\033[0m\\n'; "
          "printf '\\033[1;32m✓ Integration tests     6 passed\\033[0m\\n'; "
          "printf '\\033[1;32m✓ Accessibility        100%% labels\\033[0m\\n'; "
          "printf '\\033[1;32m✓ Signing               valid\\033[0m\\n'; "
          "printf '\\n\\033[1mDeployment\\033[0m\\n'; "
          "printf 'Channel        App Store Connect\\n'; "
          "printf 'Target         Internal review\\n'; "
          "printf 'Commit         a17c9e2 · main\\n'; "
          "printf 'Status         Ready to upload\\n'";
    }
    if (_commandInput().evaluate().isNotEmpty) {
      await _sendCommand(tester, terminalCommand);
    } else {
      await workspace.terminal.writePty(ptyId, [
        ...utf8.encode(terminalCommand),
        0x0d,
      ]);
    }
    await _settleFor(tester, const Duration(seconds: 3));
    await _captureLightDark(tester, app, '02-terminal');

    await tester.tap(find.byKey(const ValueKey('file-tree-sidebar-toggle')));
    await tester.pumpAndSettle();
    await _pumpUntil(
      tester,
      () =>
          find.byType(FileTreePanel).evaluate().isNotEmpty &&
          find.byType(CircularProgressIndicator).evaluate().isEmpty,
      reason: 'file tree loads',
    );
    await _captureLightDark(tester, app, '03-files');

    if (find
        .byKey(const ValueKey('mobile-files-drawer'))
        .evaluate()
        .isNotEmpty) {
      await _popRoute(tester);
    }
    await workspace.views.open(
      spec: const PreviewViewSpec(
        '/home/demo/work/motif-showcase/lib/services/sync_service.dart',
      ),
      activate: true,
    );
    await tester.pumpAndSettle();
    await _pumpUntil(
      tester,
      () => _activeSpec(workspace) is PreviewViewSpec,
      reason: 'source preview opens',
    );
    await _realDelay(tester, const Duration(seconds: 1));
    await _captureLightDark(tester, app, '04-code');

    await tester.tap(find.byKey(const ValueKey('git-diff-sidebar-toggle')));
    await tester.pumpAndSettle();
    await _realDelay(tester, const Duration(seconds: 3));
    await _captureLightDark(tester, app, '05-git');

    if (find
        .byKey(const ValueKey('mobile-git-diff-drawer'))
        .evaluate()
        .isNotEmpty) {
      await _popRoute(tester);
    }
    await _popRoute(tester);
    await _pumpUntil(
      tester,
      () => find.text('Codex').evaluate().isNotEmpty,
      reason: 'session list returns',
    );
    await codexConversation.interruptActiveTurn();
    app.requestOpenCodexThread(serverId: serverId, threadId: createdThreadId);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find
          .byKey(ValueKey('codex-thread-$createdThreadId'))
          .evaluate()
          .isNotEmpty,
      reason: 'completed Codex review opens',
      timeout: const Duration(seconds: 60),
    );
    final codexScreen = tester.widget<CodexScreen>(find.byType(CodexScreen));
    final displayService = codexScreen.controller.viewModel.service!;
    for (final title in showcaseCodexThreadTitles.skip(1)) {
      final createdExtra = await displayService.createThreadForProject(
        const CodexLocalProject(
          id: 'motif-showcase',
          name: 'Motif Mobile',
          rootPaths: [demoRoot],
        ),
      );
      expect(createdExtra, isTrue, reason: displayService.createThreadError);
      final threadId = displayService.selectedThread!.id;
      codexThreadIds.add(threadId);
      await displayService.renameThread(threadId, title);
    }
    await displayService.readThread(createdThreadId);
    await _pumpUntil(
      tester,
      () => displayService.selectedThread?.id == createdThreadId,
      reason: 'main showcase Codex thread is restored',
    );
    final displayConversation =
        displayService.selectedConversation ?? displayService;
    displayConversation.turns = const [
      CodexTurn(
        id: 'showcase-release-review',
        status: CodexTurnStatus.completed,
        items: [
          CodexUserMessageThreadItem(
            id: 'showcase-review-request',
            content: [
              CodexTextUserInput(
                text:
                    'Review this project for a mobile release. Do not edit '
                    'files. Summarize what is ready and give me a launch '
                    'checklist.',
              ),
            ],
          ),
          CodexAgentMessageThreadItem(
            id: 'showcase-review-answer',
            text: '''## Mobile release review

**Ready now**
- Resilient sync with retry and timeout handling
- Release configuration and tests are in place
- 3 focused changes across README, app entry, and sync service

**Launch checklist**
- [x] Tests passing
- [x] Error states covered
- [x] Diff is scoped and reviewable

**Ready for review.**''',
          ),
        ],
      ),
    ];
    displayConversation.synchronizeViewModel();
    await tester.pump();
    await _settleFor(tester, const Duration(seconds: 3));
    await _captureLightDark(tester, app, '06-codex');

    if (logicalWidth < 768) {
      await tester.tap(find.byKey(const ValueKey('codex-sidebar-toggle')));
      await tester.pumpAndSettle();
    } else {
      codexScreen.controller.preferences.sidebarWidth = 460;
      await tester.pumpAndSettle();
    }
    await tester.tap(
      find.byKey(const ValueKey('codex-mode-timeline')).hitTestable(),
    );
    await tester.pumpAndSettle();
    await _captureLightDark(tester, app, '07-codex-threads');
    if (logicalWidth < 768) await _popRoute(tester);

    final sideChats = SideChatCollectionController(
      serverId: serverId,
      parentThreadId: createdThreadId,
      connection: _ScreenshotSideChatClient(),
    );
    screenshotSideChats = sideChats;
    final firstSideChat = await sideChats.ensureInitial();
    expect(firstSideChat, isNotNull, reason: sideChats.error);
    final secondSideChat = await sideChats.createSideChat();
    expect(secondSideChat, isNotNull, reason: sideChats.error);
    final thirdSideChat = await sideChats.createSideChat();
    expect(thirdSideChat, isNotNull, reason: sideChats.error);
    for (final entry in sideChats.entries) {
      final conversation = entry.conversation;
      conversation.turns = [
        CodexTurn(
          id: 'showcase-side-chat-${entry.index}',
          status: CodexTurnStatus.completed,
          items: [
            CodexUserMessageThreadItem(
              id: 'showcase-side-chat-request-${entry.index}',
              content: [
                CodexTextUserInput(
                  text: switch (entry.index) {
                    1 => 'Check the retry policy for edge cases. No edits.',
                    2 => 'Suggest a focused TestFlight rollout plan.',
                    _ =>
                      'Explore release risks without changing the main review.',
                  },
                ),
              ],
            ),
            CodexAgentMessageThreadItem(
              id: 'showcase-side-chat-answer-${entry.index}',
              text: switch (entry.index) {
                1 =>
                  '''## Retry policy check

- Attempts are bounded at three
- Backoff grows predictably
- Timeout failures remain visible to the caller

The change is scoped and safe to review.''',
                2 =>
                  '''## TestFlight rollout

1. Start with the internal review group
2. Watch reconnect and sync health
3. Expand after a clean 24-hour window

No changes to the main release thread.''',
                _ =>
                  '''## Release risk check

**Low risk**
- The diff is limited to three focused files
- Tests and static analysis are green
- Retry behavior has a clear upper bound

**Recommendation**
Ship with a staged rollout and monitor sync latency.''',
              },
            ),
          ],
        ),
      ];
      conversation.synchronizeViewModel();
    }
    await tester.pumpAndSettle();

    final navigator = Navigator.of(tester.element(find.byType(CodexScreen)));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'side-chat/showcase'),
          builder: (_) => SideChatScreen(collection: sideChats),
        ),
      ),
    );
    await _pumpUntil(
      tester,
      () => find.byType(SideChatScreen).evaluate().isNotEmpty,
      reason: 'Side Chat opens',
      timeout: const Duration(seconds: 30),
    );
    if (logicalWidth >= 768) {
      await tester.tap(
        find.byKey(const ValueKey('side-chat-sidebar-toggle')).hitTestable(),
      );
      await tester.pumpAndSettle();
    }
    await _captureLightDark(tester, app, '08-sidechat');

    await tester.tap(
      find.byKey(const ValueKey('side-chat-sidebar-toggle')).hitTestable(),
    );
    await tester.pumpAndSettle();
    await _captureLightDark(tester, app, '09-sidechat-list');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

final class _ScreenshotSideChatClient extends ChangeNotifier
    implements CodexAppServerClient {
  final StreamController<Map<String, Object?>> _rawMessages =
      StreamController<Map<String, Object?>>.broadcast();
  final StreamController<CodexJsonEncodable> _typedMessages =
      StreamController<CodexJsonEncodable>.broadcast();
  var _sequence = 0;

  @override
  CodexConnectionState state = CodexConnectionState(
    phase: CodexConnectionPhase.connected,
    response: const CodexInitializeResponse(
      codexHome: CodexV2AbsolutePathBuf('/home/demo/.codex'),
      platformFamily: 'unix',
      platformOs: 'linux',
      userAgent: 'motif-appstore-showcase',
    ),
  );

  @override
  Stream<Map<String, Object?>> get rawMessages => _rawMessages.stream;

  @override
  Stream<CodexJsonEncodable> get typedMessages => _typedMessages.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> retry() async {}

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async {
    final index = ++_sequence;
    final threadId = 'showcase-side-chat-$index';
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final thread = CodexThread(
      cliVersion: 'showcase',
      createdAt: now,
      cwd: const CodexV2AbsolutePathBuf('/home/demo/work/motif-showcase'),
      ephemeral: true,
      forkedFromId: params.threadId,
      id: threadId,
      modelProvider: 'openai',
      parentThreadId: params.threadId,
      preview: '',
      sessionId: threadId,
      source: const CodexSessionSource('cli'),
      status: const CodexIdleThreadStatus(),
      turns: const [],
      updatedAt: now,
    );
    return CodexThreadForkResponse(
      approvalPolicy: const CodexAskForApproval('on-request'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: thread.cwd,
      model: 'gpt-5-codex',
      modelProvider: 'openai',
      sandbox: const CodexDangerFullAccessSandboxPolicy(),
      thread: thread,
    );
  }

  @override
  Future<CodexThreadUnsubscribeResponse> unsubscribeThread(
    String threadId,
  ) async => const CodexThreadUnsubscribeResponse(
    status: CodexThreadUnsubscribeStatus.unsubscribed,
  );

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
  Future<void> close() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unused Side Chat API: ${invocation.memberName}');

  @override
  void dispose() {
    unawaited(_rawMessages.close());
    unawaited(_typedMessages.close());
    super.dispose();
  }
}

Future<void> _prepareShowcaseProject(
  WorkspaceApi workspace,
  String root,
) async {
  for (final directory in [
    root,
    '$root/assets',
    '$root/lib',
    '$root/lib/models',
    '$root/lib/services',
    '$root/test',
  ]) {
    await workspace.mkdir(directory);
  }
  final files = <String, String>{
    '$root/README.md': _readmeBaseline,
    '$root/CHANGELOG.md': _changelog,
    '$root/analysis_options.yaml': _analysisOptions,
    '$root/pubspec.yaml': _pubspec,
    '$root/assets/release_config.json': _releaseConfig,
    '$root/lib/main.dart': _mainDartBaseline,
    '$root/lib/models/deploy_status.dart': _deployStatus,
    '$root/lib/services/sync_service.dart': _syncServiceBaseline,
    '$root/test/sync_service_test.dart': _syncServiceTest,
  };
  for (final entry in files.entries) {
    await _writeText(workspace, entry.key, entry.value);
  }
}

Future<void> _writeText(
  WorkspaceApi workspace,
  String path,
  String contents,
) async {
  await workspace.write(path, base64Encode(utf8.encode(contents)));
}

Future<void> _captureLightDark(
  WidgetTester tester,
  AppState app,
  String scene,
) async {
  for (final theme in [TerminalThemeSetting.light, TerminalThemeSetting.dark]) {
    await app.terminalSettings.setTheme(theme);
    await tester.pumpAndSettle();
    await _settleFor(tester, const Duration(milliseconds: 800));
    await _holdForHostScreenshot(tester, '$scene-${theme.name}');
  }
  await app.terminalSettings.setTheme(TerminalThemeSetting.light);
  await tester.pumpAndSettle();
}

ViewSpec? _activeSpec(WorkspaceInstance workspace) {
  final activeId = workspace.viewModel.views.activeViewId;
  for (final view in workspace.viewModel.views.items) {
    if (view.id == activeId) return view.spec;
  }
  return null;
}

String? _activePtyId(WorkspaceInstance workspace) {
  final spec = _activeSpec(workspace);
  return spec is PtyViewSpec ? spec.ptyId : null;
}

Finder _commandInput() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      (widget.decoration?.hintText == 'type or speak…' ||
          widget.decoration?.hintText == 'type…' ||
          widget.decoration?.hintText == 'type a command…'),
  description: 'Terminal command input',
);

Future<void> _sendCommand(WidgetTester tester, String command) async {
  expect(_commandInput(), findsOneWidget);
  await tester.enterText(_commandInput(), command);
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.arrow_upward).last);
  await tester.pumpAndSettle();
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
}

Future<void> _holdForHostScreenshot(WidgetTester tester, String name) async {
  // The host capture wrapper watches this marker and calls `simctl io screenshot`.
  // ignore: avoid_print
  print('APPSTORE_SHOT:$name');
  await _realDelay(tester, const Duration(seconds: 5));
}

Future<void> _realDelay(WidgetTester tester, Duration duration) async {
  await tester.runAsync(() => Future<void>.delayed(duration));
  await tester.pump();
}

Future<void> _settleFor(WidgetTester tester, Duration duration) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
  fail('Timed out waiting for $reason');
}

Future<void> _popRoute(WidgetTester tester) async {
  final didPop = await tester.binding.handlePopRoute();
  expect(didPop, isTrue);
  await tester.pumpAndSettle();
}

const _readmeBaseline = '''
# Motif Mobile Workspace

Operate a secure development workspace from iPhone and iPad.

## Release goals

- Fast remote terminal access
- Project-aware file navigation
- Git review before every deploy
- Codex-assisted release checks
''';

const _readmeUpdated = '''
# Motif Mobile Workspace

Operate a secure development workspace from iPhone and iPad.

## Release goals

- Fast remote terminal access
- Project-aware file navigation
- Git review before every deploy
- Codex-assisted release checks

## Release candidate

- Offline retry policy verified
- App Store screenshots refreshed
''';

const _changelog = '''
# Changelog

## 1.0.65

- Added reliable background reconnects
- Improved Git diff navigation
- Refined Codex mobile workspace
''';

const _analysisOptions = '''
include: package:flutter_lints/flutter.yaml

linter:
  rules:
    prefer_final_locals: true
    use_super_parameters: true
''';

const _pubspec = '''
name: motif_showcase
description: Remote development from anywhere.
version: 1.0.65+48

environment:
  sdk: ^3.9.0

dev_dependencies:
  flutter_lints: ^6.0.0
  test: ^1.26.0
''';

const _releaseConfig = '''
{
  "channel": "app-store",
  "region": "global",
  "healthChecks": ["terminal", "sync", "codex"],
  "minimumPassRate": 1.0
}
''';

const _mainDartBaseline = r'''
import 'services/sync_service.dart';

Future<void> main() async {
  final service = RemoteSyncService();
  final summary = await service.sync();
  print('Synced ${summary.filesChanged} files');
}
''';

const _mainDartUpdated = r'''
import 'services/sync_service.dart';

Future<void> main() async {
  final service = RemoteSyncService();
  final summary = await service.sync();
  print('Synced ${summary.filesChanged} files');
  print('Release channel: App Store');
}
''';

const _deployStatus = '''
enum DeployStatus { queued, validating, ready, failed }

extension DeployStatusLabel on DeployStatus {
  String get label => switch (this) {
    DeployStatus.queued => 'Queued',
    DeployStatus.validating => 'Running checks',
    DeployStatus.ready => 'Ready to ship',
    DeployStatus.failed => 'Needs attention',
  };
}
''';

const _syncServiceBaseline = r'''
import 'dart:async';

class RemoteSyncService {
  Future<SyncSummary> sync() async {
    final startedAt = DateTime.now();
    await Future<void>.delayed(const Duration(milliseconds: 120));

    return SyncSummary(
      filesChanged: 3,
      branch: 'main',
      latencyMs: DateTime.now().difference(startedAt).inMilliseconds,
      healthy: true,
    );
  }
}

class SyncSummary {
  const SyncSummary({
    required this.filesChanged,
    required this.branch,
    required this.latencyMs,
    required this.healthy,
  });

  final int filesChanged;
  final String branch;
  final int latencyMs;
  final bool healthy;
}
''';

const _syncServiceUpdated = r'''
import 'dart:async';

class RemoteSyncService {
  Future<SyncSummary> sync() => _withRetry(maxAttempts: 3);

  Future<SyncSummary> _withRetry({required int maxAttempts}) async {
    final startedAt = DateTime.now();
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await Future<void>.delayed(const Duration(milliseconds: 120));
        return SyncSummary(
          filesChanged: 3,
          branch: 'main',
          latencyMs: DateTime.now().difference(startedAt).inMilliseconds,
          healthy: true,
        );
      } on TimeoutException when (attempt < maxAttempts) {
        await Future<void>.delayed(Duration(milliseconds: 200 * attempt));
      }
    }
    throw TimeoutException('Remote workspace did not respond');
  }
}

class SyncSummary {
  const SyncSummary({
    required this.filesChanged,
    required this.branch,
    required this.latencyMs,
    required this.healthy,
  });

  final int filesChanged;
  final String branch;
  final int latencyMs;
  final bool healthy;
}
''';

const _syncServiceTest = '''
import 'package:test/test.dart';

void main() {
  group('RemoteSyncService', () {
    test('reports a healthy main branch', () async {
      expect('main', isNotEmpty);
    });

    test('retries transient timeouts', () async {
      expect(3, greaterThan(1));
    });
  });
}
''';
