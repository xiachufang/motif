import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_composer_models.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/codex_service_state.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:motif/motif/models/resource_documents.dart';
import 'package:motif/motif/ui/screens/codex_thread_workspace.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/codex_markdown.dart';
import 'package:motif/motif/ui/widgets/codex_turn_activity.dart';
import 'package:motif/motif/ui/widgets/diff_text_view.dart';

void main() {
  testWidgets('active plan details and diff use separate hit targets', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)..queuedMessages = const [];
    final openedDiffs = <DiffDocument>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: CodexThreadWorkspace(
            state: state,
            onOpenTurnDiff: (document, {initialPath}) {
              openedDiffs.add(document);
            },
          ),
        ),
      ),
    );
    await tester.pump();

    final details = find.byKey(const ValueKey('codex-plan-details'));
    final diff = find.byKey(const ValueKey('codex-plan-diff'));
    expect(details, findsOneWidget);
    expect(diff, findsOneWidget);
    expect(
      tester.getRect(details).right,
      lessThanOrEqualTo(tester.getRect(diff).left),
    );

    await tester.tap(details);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Implement UI'), findsOneWidget);
    expect(find.text('Run tests'), findsOneWidget);
    expect(openedDiffs, isEmpty);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(diff);
    await tester.pump();

    expect(openedDiffs, hasLength(1));
    expect(openedDiffs.single.files, hasLength(1));
    expect(openedDiffs.single.files.single.path, 'lib/a.dart');

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'composer gives Enter to the IME and Shift+Enter inserts a line',
    (tester) async {
      final client = WorkspaceFakeClient();
      final state = workspaceState(client)
        ..turns = const []
        ..activePlan = null
        ..queuedMessages = const [];
      state.synchronizeViewModel();

      await tester.pumpWidget(
        MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Scaffold(body: CodexThreadWorkspace(state: state)),
        ),
      );
      await tester.pump();

      final input = find.byKey(const ValueKey('codex-composer-input'));
      await tester.tap(input);
      await tester.pump();
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'ni',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      expect(client.started, isEmpty);
      expect(tester.widget<TextField>(input).controller?.text, 'ni');

      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '你',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(client.started, isEmpty);
      expect(tester.widget<TextField>(input).controller?.text, '你\n');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.started, hasLength(1));
      expect(tester.widget<TextField>(input).controller?.text, isEmpty);

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('context compaction transitions without a Thinking fallback', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);
    state.turns = const [
      CodexTurn(
        id: 'compaction-turn',
        items: [
          CodexUserMessageThreadItem(
            id: 'compaction-user',
            content: [CodexTextUserInput(text: 'Keep going')],
          ),
        ],
        status: CodexTurnStatus.inProgress,
      ),
    ];
    state.synchronizeViewModel();

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Thinking'), findsOneWidget);

    client.emit(
      const CodexItemStartedNotification2(
        params: CodexItemStartedNotification(
          item: CodexContextCompactionThreadItem(id: 'compaction'),
          startedAtMs: 1,
          threadId: 'thread',
          turnId: 'compaction-turn',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Context compacting'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('codex-processing-sweep')),
      findsOneWidget,
    );
    expect(find.text('Thinking'), findsNothing);

    client.emit(
      const CodexItemCompletedNotification2(
        params: CodexItemCompletedNotification(
          completedAtMs: 2,
          item: CodexContextCompactionThreadItem(id: 'compaction'),
          threadId: 'thread',
          turnId: 'compaction-turn',
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Context compacting'), findsNothing);
    expect(find.text('Context compacted'), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-processing-sweep')), findsNothing);
    expect(find.text('Thinking'), findsNothing);
    expect(
      find.byKey(const ValueKey('codex-context-compaction-compaction')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('running commands use terminal icons instead of loading icons', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);
    state.turns = const [
      CodexTurn(
        id: 'running-command-turn',
        items: [
          CodexUserMessageThreadItem(
            id: 'running-command-user',
            content: [CodexTextUserInput(text: 'Run it')],
          ),
          CodexCommandExecutionThreadItem(
            command:
                '/bin/zsh -lc "flutter test test/motif/codex_service_state_test.dart"',
            commandActions: [
              CodexUnknownCommandAction(
                command:
                    'flutter test test/motif/codex_service_state_test.dart',
              ),
            ],
            cwd: CodexLegacyAppPathString('/work/motif'),
            durationMs: 1,
            exitCode: 0,
            id: 'running-command',
            status: CodexCommandExecutionStatus.inProgress,
          ),
        ],
        status: CodexTurnStatus.inProgress,
      ),
    ];
    state.synchronizeViewModel();

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    final group = find.byKey(
      const ValueKey('codex-activity-running-command-turn-0'),
    );
    expect(
      find.descendant(
        of: group,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: group, matching: find.byIcon(Icons.terminal_rounded)),
      findsOneWidget,
    );

    await tester.tap(
      find.text(
        'Running flutter test test/motif/codex_service_state_test.dart',
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.descendant(
        of: group,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: group, matching: find.byIcon(Icons.terminal_rounded)),
      findsNWidgets(2),
    );

    _expandListTile(
      tester,
      find.descendant(
        of: find.byKey(
          const ValueKey('codex-command-activity-running-command'),
        ),
        matching: find.byType(ListTile),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody &&
            widget.data.contains(
              r'$ flutter test test/motif/codex_service_state_test.dart',
            ),
      ),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody && widget.data.contains('/bin/zsh -lc'),
      ),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('command activities display the complete command', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);
    const cwd = CodexLegacyAppPathString('/work/motif');
    const completed = CodexCommandExecutionStatus.completed;
    const items = <CodexThreadItem>[
      CodexCommandExecutionThreadItem(
        command: 'cat lib/main.dart',
        commandActions: [
          CodexReadCommandAction(
            command: 'cat lib/main.dart',
            name: 'main.dart',
            path: CodexLegacyAppPathString('/work/motif/lib/main.dart'),
          ),
        ],
        cwd: cwd,
        id: 'read-command',
        status: completed,
      ),
      CodexCommandExecutionThreadItem(
        command: 'ls lib',
        commandActions: [
          CodexListFilesCommandAction(command: 'ls lib', path: 'lib'),
        ],
        cwd: cwd,
        id: 'list-command',
        status: completed,
      ),
      CodexCommandExecutionThreadItem(
        command: 'rg TODO lib',
        commandActions: [
          CodexSearchCommandAction(
            command: 'rg TODO lib',
            path: 'lib',
            query: 'TODO',
          ),
        ],
        cwd: cwd,
        id: 'search-command',
        status: completed,
      ),
      CodexCommandExecutionThreadItem(
        command: 'flutter test',
        commandActions: [CodexUnknownCommandAction(command: 'flutter test')],
        cwd: cwd,
        id: 'test-command',
        status: completed,
      ),
      CodexCommandExecutionThreadItem(
        command: 'flutter build macos',
        commandActions: [
          CodexUnknownCommandAction(command: 'flutter build macos'),
        ],
        cwd: cwd,
        id: 'build-command',
        status: completed,
      ),
      CodexCommandExecutionThreadItem(
        command: 'dart format lib',
        commandActions: [CodexUnknownCommandAction(command: 'dart format lib')],
        cwd: cwd,
        id: 'format-command',
        status: completed,
      ),
      CodexCommandExecutionThreadItem(
        command: 'git commit -m done',
        commandActions: [
          CodexUnknownCommandAction(command: 'git commit -m done'),
        ],
        cwd: cwd,
        id: 'commit-command',
        status: completed,
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: CodexTurnActivityGroup(
            state: state,
            items: items,
            boundedDetails: false,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.text('Read files, listed files, searched code, and more'),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Ran cat lib/main.dart'), findsOneWidget);
    expect(find.text('Ran ls lib'), findsOneWidget);
    expect(find.text('Ran rg TODO lib'), findsOneWidget);
    expect(find.text('Ran flutter test'), findsOneWidget);
    expect(find.text('Ran flutter build macos'), findsOneWidget);
    expect(find.text('Ran dart format lib'), findsOneWidget);
    expect(find.text('Ran git commit -m done'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('active activity titles include the latest item details', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              CodexTurnActivityGroup(
                state: state,
                showLatestItemTitle: true,
                items: const [
                  CodexFileChangeThreadItem(
                    changes: [
                      CodexFileUpdateChange(
                        diff: '',
                        kind: CodexUpdatePatchChangeKind(),
                        path: '/work/motif/lib/main.dart',
                      ),
                    ],
                    id: 'detailed-file-change',
                    status: CodexPatchApplyStatus.inProgress,
                  ),
                ],
              ),
              CodexTurnActivityGroup(
                state: state,
                showLatestItemTitle: true,
                items: const [
                  CodexMcpToolCallThreadItem(
                    arguments: {'query': 'Flutter activity progress'},
                    id: 'detailed-mcp-tool',
                    server: 'docs',
                    status: CodexMcpToolCallStatus.inProgress,
                    tool: 'search',
                  ),
                ],
              ),
              CodexTurnActivityGroup(
                state: state,
                showLatestItemTitle: true,
                items: const [
                  CodexCollabAgentToolCallThreadItem(
                    agentsStates: {},
                    id: 'detailed-agent-tool',
                    prompt: 'Review the activity renderer',
                    receiverThreadIds: [],
                    senderThreadId: 'root',
                    status: CodexCollabAgentToolCallStatus.inProgress,
                    tool: CodexCollabAgentTool.spawnAgent,
                  ),
                ],
              ),
              CodexTurnActivityGroup(
                state: state,
                showLatestItemTitle: true,
                items: const [
                  CodexImageGenerationThreadItem(
                    id: 'detailed-image-generation',
                    result: '',
                    revisedPrompt: 'A clear activity timeline',
                    status: 'inProgress',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Editing /work/motif/lib/main.dart'), findsOneWidget);
    expect(
      find.text('Using docs · search — {"query":"Flutter activity progress"}'),
      findsOneWidget,
    );
    expect(
      find.text('Starting agent — Review the activity renderer'),
      findsOneWidget,
    );
    expect(
      find.text('Generating an image — A clear activity timeline'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'active turn falls back to Thinking until assistant text starts',
    (tester) async {
      final client = WorkspaceFakeClient();
      final state = workspaceState(client);

      state.turns = const [
        CodexTurn(
          id: 'thinking-turn',
          items: [
            CodexUserMessageThreadItem(
              id: 'thinking-user',
              content: [CodexTextUserInput(text: 'Start')],
            ),
          ],
          status: CodexTurnStatus.inProgress,
        ),
      ];
      state.synchronizeViewModel();

      await tester.pumpWidget(
        MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Scaffold(body: CodexThreadWorkspace(state: state)),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('codex-turn-thinking-thinking-turn')),
        findsOneWidget,
      );
      expect(find.text('Thinking'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-processing-sweep')),
        findsOneWidget,
      );
      expect(find.text('Working'), findsNothing);

      state.turns = const [
        CodexTurn(
          id: 'thinking-turn',
          items: [
            CodexUserMessageThreadItem(
              id: 'thinking-user',
              content: [CodexTextUserInput(text: 'Start')],
            ),
            CodexAgentMessageThreadItem(id: 'thinking-agent', text: ''),
          ],
          status: CodexTurnStatus.inProgress,
        ),
      ];
      state.synchronizeViewModel();
      await tester.pump();

      expect(find.text('Thinking'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-processing-sweep')),
        findsOneWidget,
      );
      expect(find.text('agentMessage'), findsNothing);

      state.turns = const [
        CodexTurn(
          id: 'thinking-turn',
          items: [
            CodexUserMessageThreadItem(
              id: 'thinking-user',
              content: [CodexTextUserInput(text: 'Start')],
            ),
            CodexAgentMessageThreadItem(
              id: 'thinking-agent',
              text: 'Assistant has started',
            ),
          ],
          status: CodexTurnStatus.inProgress,
        ),
      ];
      state.synchronizeViewModel();
      await tester.pump();

      expect(find.text('Thinking'), findsNothing);
      expect(find.text('Assistant has started'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('empty active reasoning keeps a meaningful activity title', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);
    const tool = CodexMcpToolCallThreadItem(
      arguments: {},
      id: 'empty-reasoning-tool',
      server: 'node_repl',
      status: CodexMcpToolCallStatus.completed,
      tool: 'js',
    );

    state.turns = const [
      CodexTurn(
        id: 'empty-reasoning-turn',
        items: [
          CodexUserMessageThreadItem(
            id: 'empty-reasoning-user',
            content: [CodexTextUserInput(text: 'Do something')],
          ),
          tool,
          CodexReasoningThreadItem(
            id: 'empty-reasoning',
            summary: [],
            content: [],
          ),
        ],
        status: CodexTurnStatus.inProgress,
      ),
    ];
    state.synchronizeViewModel();

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    expect(find.text('Used node_repl · js'), findsOneWidget);

    state.turns = const [
      CodexTurn(
        id: 'empty-reasoning-turn',
        items: [
          CodexUserMessageThreadItem(
            id: 'empty-reasoning-user',
            content: [CodexTextUserInput(text: 'Do something')],
          ),
          tool,
          CodexReasoningThreadItem(
            id: 'empty-reasoning',
            summary: ['Planning the next step'],
            content: [],
          ),
        ],
        status: CodexTurnStatus.inProgress,
      ),
    ];
    state.synchronizeViewModel();
    await tester.pump();

    expect(find.text('Planning the next step'), findsOneWidget);
    expect(find.text('Used node_repl · js'), findsNothing);
    final sweep = find.byKey(const ValueKey('codex-processing-sweep'));
    expect(sweep, findsOneWidget);
    final firstCycle = tester.widget<ShaderMask>(sweep);
    await tester.pump(const Duration(milliseconds: 2200));
    final secondCycle = tester.widget<ShaderMask>(sweep);
    await tester.pump(const Duration(milliseconds: 2200));
    final thirdCycle = tester.widget<ShaderMask>(sweep);
    expect(identical(firstCycle, secondCycle), isFalse);
    expect(identical(secondCycle, thirdCycle), isFalse);

    state.turns = const [
      CodexTurn(
        id: 'reasoning-only-turn',
        items: [
          CodexUserMessageThreadItem(
            id: 'reasoning-only-user',
            content: [CodexTextUserInput(text: 'Keep working')],
          ),
          CodexReasoningThreadItem(
            id: 'reasoning-only',
            summary: [],
            content: [],
          ),
        ],
        status: CodexTurnStatus.inProgress,
      ),
    ];
    state.synchronizeViewModel();
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    expect(find.text('Thinking'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('codex-processing-sweep')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'conversation starts at the bottom and resets there when the thread changes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 820);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = WorkspaceFakeClient();
      final state = workspaceState(client);
      final turns = List.generate(
        12,
        (index) => CodexTurn(
          id: 'scroll-turn-$index',
          items: [
            CodexUserMessageThreadItem(
              id: 'scroll-user-$index',
              content: [CodexTextUserInput(text: 'Question $index')],
            ),
            CodexAgentMessageThreadItem(
              id: 'scroll-agent-$index',
              text: 'Response $index',
            ),
          ],
          status: CodexTurnStatus.completed,
        ),
      );
      client.thread = CodexThread.fromJson({
        ...client.thread.toJson(),
        'turns': turns.map((turn) => turn.toJson()).toList(),
      });
      state
        ..selectedThread = client.thread
        ..turns = turns
        ..activePlan = null
        ..queuedMessages = const []
        ..synchronizeViewModel();

      await tester.pumpWidget(
        MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Scaffold(body: CodexThreadWorkspace(state: state)),
        ),
      );
      await tester.pump();

      final stream = find.byKey(const ValueKey('codex-turn-stream'));
      expect(tester.widget<CustomScrollView>(stream).reverse, isFalse);
      var position = tester
          .state<ScrollableState>(
            find.descendant(of: stream, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.pixels, position.maxScrollExtent);
      expect(
        tester.getTopLeft(find.text('Question 11')).dy,
        lessThan(tester.getTopLeft(find.text('Response 11')).dy),
      );

      await tester.drag(stream, const Offset(0, 400));
      await tester.pump();
      expect(position.pixels, lessThan(position.maxScrollExtent - 96));

      final nextThreadJson = Map<String, Object?>.from(client.thread.toJson())
        ..['id'] = 'next-thread'
        ..['sessionId'] = 'next-thread';
      client.thread = CodexThread.fromJson(nextThreadJson);
      await state.readThread('next-thread');
      await tester.pump();
      await tester.pump();

      position = tester
          .state<ScrollableState>(
            find.descendant(of: stream, matching: find.byType(Scrollable)),
          )
          .position;
      expect(position.pixels, position.maxScrollExtent);

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('loads an older full turn page from the history control', (
    tester,
  ) async {
    const olderTurn = CodexTurn(
      id: 'older-turn',
      items: [
        CodexAgentMessageThreadItem(id: 'older-answer', text: 'Older answer'),
      ],
      status: CodexTurnStatus.completed,
    );
    const recentTurn = CodexTurn(
      id: 'recent-turn',
      items: [
        CodexAgentMessageThreadItem(id: 'recent-answer', text: 'Recent answer'),
      ],
      status: CodexTurnStatus.completed,
    );
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..activePlan = null
      ..queuedMessages = const [];
    client.turnPages = const {
      null: CodexThreadTurnsListResponse(
        data: [recentTurn],
        nextCursor: 'older-page',
      ),
      'older-page': CodexThreadTurnsListResponse(data: [olderTurn]),
    };
    await state.readThread('thread');

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    expect(find.text('Recent answer'), findsOneWidget);
    expect(find.text('Older answer'), findsNothing);
    expect(
      find.byKey(const ValueKey('codex-load-older-turns')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('codex-load-older-turns')));
    await tester.pumpAndSettle();

    expect(find.text('Older answer'), findsOneWidget);
    expect(client.turnListParams.map((params) => params.cursor), [
      null,
      'older-page',
    ]);
    expect(
      client.turnListParams.map((params) => params.itemsView?.value),
      everyElement('full'),
    );
    expect(
      client.turnListParams.map((params) => params.limit),
      everyElement(10),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'renders turns, keeps tool details collapsed, and floats plan and queue',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 820);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = WorkspaceFakeClient();
      final state = workspaceState(client);
      final openedFiles = <String>[];
      final openedDiffs = <({DiffDocument document, String? initialPath})>[];

      await tester.pumpWidget(
        MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Scaffold(
            body: CodexThreadWorkspace(
              state: state,
              onOpenFile: openedFiles.add,
              onOpenTurnDiff: (document, {initialPath}) => openedDiffs.add((
                document: document,
                initialPath: initialPath,
              )),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('codex-thread-detail')))
            .color,
        MotifColors.light.surface,
      );
      final conversationSliver = tester.widget<SliverList>(
        find.byType(SliverList).first,
      );
      expect(
        conversationSliver.delegate.estimatedChildCount,
        greaterThan(state.turns.length),
      );
      expect(find.text('Latest **progress**'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-reasoning-active-reasoning-2')),
        findsOneWidget,
      );
      await tester.drag(
        find.byKey(const ValueKey('codex-turn-stream')),
        const Offset(0, 2000),
      );
      await tester.pump();

      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is MarkdownBody && widget.data == 'Hello **Codex**',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is MarkdownBody &&
              widget.data == 'I am **working** on it.',
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('codex-activity-turn-history-0')),
        findsNothing,
      );
      expect(find.text('Historic reasoning must stay hidden'), findsNothing);
      expect(find.text('First progress'), findsNothing);
      expect(find.text('Worked for 8m 7s'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('codex-worked-toggle-turn-history')),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.byKey(const ValueKey('codex-activity-turn-history-0')),
        findsOneWidget,
      );
      final collapsedActivity = tester.widget<ExpansionTile>(
        find.descendant(
          of: find.byKey(const ValueKey('codex-activity-turn-history-0')),
          matching: find.byType(ExpansionTile),
        ),
      );
      expect(collapsedActivity.dense, isTrue);
      expect(collapsedActivity.minTileHeight, 32);
      expect(collapsedActivity.visualDensity?.vertical, -4);
      expect(find.text('Ran a command, edited files'), findsOneWidget);
      expect(find.text('Ran rg TODO'), findsNothing);
      expect(find.text(r'$ rg TODO'), findsNothing);
      await tester.ensureVisible(find.text('Ran a command, edited files'));
      await tester.pump();
      await tester.tap(find.text('Ran a command, edited files'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('codex-activity-group-scroll')),
        findsNothing,
      );
      expect(find.text('Ran rg TODO'), findsOneWidget);
      expect(find.textContaining('exit 0'), findsNothing);
      expect(find.text('Edited a.dart'), findsOneWidget);
      expect(find.text('Edited b.dart'), findsOneWidget);
      expect(find.text('Edited a.dart, c.dart and 1 more'), findsOneWidget);
      _expandListTile(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('codex-file-change-file-change-1')),
          matching: find.byType(ListTile),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final openFileButton = find.byKey(
        const ValueKey('codex-open-file-lib/a.dart'),
      );
      final activityIconStyle = IconButtonTheme.of(
        tester.element(openFileButton),
      ).style!;
      expect(
        activityIconStyle.foregroundColor!.resolve(<WidgetState>{}),
        MotifColors.light.textSecondary,
      );
      final fileDiffTile = tester.widget<ExpansionTile>(
        find.descendant(
          of: find.byKey(const ValueKey('codex-file-diff-lib/a.dart')),
          matching: find.byType(ExpansionTile),
        ),
      );
      expect(fileDiffTile.iconColor, MotifColors.light.textSecondary);
      expect(fileDiffTile.collapsedIconColor, MotifColors.light.textSecondary);
      tester.widget<IconButton>(openFileButton).onPressed!();
      expect(openedFiles, ['/work/motif/lib/a.dart']);
      _expandListTile(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('codex-file-diff-lib/a.dart')),
          matching: find.byType(ListTile),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('codex-diff-scroll-lib/a.dart')),
        findsOneWidget,
      );
      expect(find.text('/work/motif/lib/a.dart'), findsNothing);
      expect(find.text('Historic reasoning must stay hidden'), findsNothing);

      expect(find.text('Step 1 / 2'), findsOneWidget);
      expect(find.textContaining('1 file changed'), findsOneWidget);
      expect(find.textContaining('+1'), findsAtLeast(1));
      expect(find.textContaining('-1'), findsAtLeast(1));
      await tester.drag(
        find.byKey(const ValueKey('codex-turn-stream')),
        const Offset(0, -1600),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('codex-turn-diff-turn-history')),
        findsOneWidget,
      );
      expect(find.text('Edited 4 files'), findsOneWidget);
      expect(find.text('+5'), findsOneWidget);
      expect(find.text('-2'), findsOneWidget);
      expect(find.text('lib/a.dart'), findsWidgets);
      expect(find.text('lib/b.dart'), findsOneWidget);
      expect(find.text('lib/c.dart'), findsOneWidget);
      expect(find.text('lib/d.dart'), findsNothing);
      expect(find.text('Show 1 more file'), findsOneWidget);
      final turnDiffCard = find.byKey(
        const ValueKey('codex-turn-diff-turn-history'),
      );
      expect(
        find.descendant(
          of: turnDiffCard,
          matching: find.byIcon(Icons.open_in_new_rounded),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<InkWell>(
              find.byKey(const ValueKey('codex-turn-diff-open-turn-history')),
            )
            .onTap,
        isNotNull,
      );
      tester
          .widget<InkWell>(
            find.byKey(const ValueKey('codex-turn-diff-file-lib/a.dart')),
          )
          .onTap!();
      await tester.pump();
      expect(openedDiffs, hasLength(1));
      expect(openedDiffs.single.initialPath, 'lib/a.dart');
      final openedDocument = openedDiffs.single.document;
      expect(openedDocument.files, hasLength(4));
      expect(openedDocument.files.first.path, 'lib/a.dart');
      expect(openedDocument.files.first.sourcePath, '/work/motif/lib/a.dart');
      expect(openedDocument.files.first.additions, 2);
      expect(openedDocument.files.first.deletions, 1);
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey('codex-turn-diff-turn-history')),
            )
            .dy,
        lessThan(
          tester.getTopLeft(find.byKey(const ValueKey('codex-copy-agent'))).dy,
        ),
      );
      tester
          .widget<InkWell>(
            find.byKey(const ValueKey('codex-turn-diff-toggle-turn-history')),
          )
          .onTap!();
      await tester.pump();
      expect(find.text('lib/d.dart'), findsOneWidget);
      expect(find.text('Collapse files'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-context-compaction-compaction-1')),
        findsOneWidget,
      );
      expect(find.text('Context compacted'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-turn-diff-turn-1')),
        findsNothing,
      );
      expect(find.text('queued follow-up'), findsOneWidget);
      expect(find.text('Steer'), findsOneWidget);
      expect(find.byKey(const ValueKey('codex-composer')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-model-selector')),
        findsOneWidget,
      );
      expect(find.text('Codex Test  High'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const ValueKey('codex-stop'))).left -
            tester
                .getRect(find.byKey(const ValueKey('codex-model-selector')))
                .right,
        moreOrLessEquals(MotifSpacing.xs, epsilon: 0.1),
      );
      final stopButton = tester.widget<IconButton>(
        find.byKey(const ValueKey('codex-stop')),
      );
      expect(
        stopButton.style?.backgroundColor?.resolve(const {}),
        MotifColors.light.accent,
      );
      expect(stopButton.style?.shape?.resolve(const {}), isA<CircleBorder>());
      await tester.tap(
        find.byKey(const ValueKey('codex-model-settings-label')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('codex-model-submenu')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-effort-selector')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<SubmenuButton>(
              find.byKey(const ValueKey('codex-model-submenu')),
            )
            .hoverOpenDelay,
        Duration.zero,
      );

      await tester.tap(find.byKey(const ValueKey('codex-model-submenu')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('codex-model-option-codex-test')),
        findsOneWidget,
      );
      expect(find.text('Test model'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('codex-effort-selector')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('codex-model-option-codex-test')),
        findsNothing,
      );
      expect(find.text('Consumes usage limits faster'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('codex-effort-option-high')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('codex-effort-option-ultra')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.selectedReasoningEffort, 'ultra');
      expect(
        find.byKey(const ValueKey('codex-permission-selector')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('codex-stop')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-fork-turn-history')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byKey(const ValueKey('codex-fork-turn-history')),
            )
            .onPressed,
        isNotNull,
      );
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('codex-fork-turn-history')))
            .dx,
        greaterThan(
          tester.getTopLeft(find.byKey(const ValueKey('codex-copy-agent'))).dx,
        ),
      );
      expect(find.byKey(const ValueKey('codex-fork-turn-1')), findsNothing);
      expect(
        find.byKey(const ValueKey('codex-copy-active-agent')),
        findsNothing,
      );

      await tester.tap(find.text('Steer'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(client.steered, hasLength(1));
      expect(state.queuedMessages, isEmpty);

      state.turns = [
        state.turns.first,
        const CodexTurn(
          id: 'turn-1',
          items: [
            CodexAgentMessageThreadItem(
              id: 'active-agent',
              text: 'Partial response',
            ),
            CodexReasoningThreadItem(
              id: 'active-reasoning-2',
              summary: ['Latest **progress**'],
            ),
          ],
          status: CodexTurnStatus.completed,
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Scaffold(body: CodexThreadWorkspace(state: state)),
        ),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('codex-turn-progress')), findsNothing);
      expect(find.byKey(const ValueKey('codex-fork-turn-1')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-copy-active-agent')),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is MarkdownBody && widget.data == 'Latest **progress**',
        ),
        findsNothing,
      );

      for (final status in [
        CodexTurnStatus.interrupted,
        CodexTurnStatus.failed,
      ]) {
        state.turns = [
          state.turns.first,
          CodexTurn(
            durationMs: 6000,
            id: 'turn-1',
            items: const [
              CodexAgentMessageThreadItem(
                id: 'active-agent',
                text: 'Partial response',
              ),
            ],
            status: status,
          ),
        ];
        await tester.pumpWidget(
          MaterialApp(
            theme: motifTheme(Brightness.light),
            home: Scaffold(body: CodexThreadWorkspace(state: state)),
          ),
        );
        await tester.pump();
        expect(find.byKey(const ValueKey('codex-fork-turn-1')), findsNothing);
        expect(
          find.byKey(const ValueKey('codex-copy-active-agent')),
          findsNothing,
        );
        expect(
          find.text(
            status == CodexTurnStatus.interrupted
                ? 'You stopped after 6s'
                : 'Failed after 6s',
          ),
          findsOneWidget,
        );
      }

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('shows only the request from an injected attachment prompt', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..turns = const [
        CodexTurn(
          completedAt: 1754973480,
          id: 'attachment-turn',
          items: [
            CodexUserMessageThreadItem(
              id: 'attachment-user',
              content: [
                CodexTextUserInput(
                  text: '''
# Files mentioned by the user:

## screenshot.png: /tmp/screenshot.png

## notes.md: /tmp/notes.md

## My request:
Only show **this request**.
''',
                ),
              ],
            ),
          ],
          status: CodexTurnStatus.completed,
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody &&
            widget.data == 'Only show **this request**.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Files mentioned by the user'), findsNothing);
    expect(find.textContaining('/tmp/screenshot.png'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('plan items stay collapsed and open on a detail page', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..turns = const [
        CodexTurn(
          id: 'plan-turn',
          items: [
            CodexPlanThreadItem(
              id: 'plan-item',
              text: '# Delivery plan\n\n- Build the UI\n- Run tests',
            ),
          ],
          status: CodexTurnStatus.completed,
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    final card = find.byKey(const ValueKey('codex-plan-item-plan-item'));
    expect(card, findsOneWidget);
    expect(
      find.byKey(const ValueKey('codex-plan-preview-plan-item')),
      findsOneWidget,
    );
    expect(find.text('Delivery plan'), findsOneWidget);
    await tester.tap(card);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('codex-plan-detail')), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody &&
            widget.data == '# Delivery plan\n\n- Build the UI\n- Run tests',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('plan decision can implement, revise, or skip', (tester) async {
    Future<({WorkspaceFakeClient client, CodexServiceState state})> pumpPlan({
      required String itemId,
    }) async {
      final client = WorkspaceFakeClient();
      final state = workspaceState(client)
        ..turns = [
          CodexTurn(
            id: 'plan-turn-$itemId',
            items: [CodexPlanThreadItem(id: itemId, text: '# Plan\n\nDo it.')],
            status: CodexTurnStatus.completed,
          ),
        ]
        ..planModeEnabled = true
        ..awaitingPlanDecisionItemId = itemId;
      await tester.pumpWidget(
        MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Scaffold(body: CodexThreadWorkspace(state: state)),
        ),
      );
      await tester.pump();
      return (client: client, state: state);
    }

    var fixture = await pumpPlan(itemId: 'implement-plan');
    expect(find.byKey(const ValueKey('codex-plan-decision')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-composer')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('codex-plan-implement')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(fixture.state.planModeEnabled, isFalse);
    expect(fixture.client.started, hasLength(1));
    expect(fixture.client.started.single.collaborationMode, isNull);
    expect(
      fixture.client.started.single.input
          .whereType<CodexTextUserInput>()
          .single
          .text,
      'Implement this plan.',
    );
    fixture.state.dispose();

    fixture = await pumpPlan(itemId: 'revise-plan');
    await tester.enterText(
      find.byKey(const ValueKey('codex-plan-feedback')),
      'Add a migration step',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-plan-revise')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(fixture.state.planModeEnabled, isTrue);
    expect(
      fixture.client.started.single.collaborationMode?.mode,
      CodexModeKind.plan,
    );
    expect(
      fixture.client.started.single.input
          .whereType<CodexTextUserInput>()
          .single
          .text,
      'Add a migration step',
    );
    fixture.state.dispose();

    fixture = await pumpPlan(itemId: 'skip-plan');
    await tester.tap(find.byKey(const ValueKey('codex-plan-skip')));
    await tester.pump();
    expect(fixture.state.planModeEnabled, isFalse);
    expect(fixture.client.started, isEmpty);
    expect(find.byKey(const ValueKey('codex-composer')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    fixture.state.dispose();
  });

  testWidgets('activity groups and item details use bounded scroll areas', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 820);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..turns = [
        CodexTurn(
          id: 'scroll-turn',
          items: [
            const CodexUserMessageThreadItem(
              id: 'scroll-user',
              content: [CodexTextUserInput(text: 'Run a large task')],
            ),
            CodexCommandExecutionThreadItem(
              aggregatedOutput: List.generate(
                120,
                (index) => 'output line $index',
              ).join('\n'),
              command: 'sh long-task.sh',
              commandActions: const [],
              cwd: const CodexLegacyAppPathString('/work/motif'),
              exitCode: 0,
              id: 'long-command',
              status: CodexCommandExecutionStatus.completed,
            ),
            for (var index = 0; index < 30; index++)
              CodexSleepThreadItem(durationMs: 1000, id: 'wait-$index'),
            const CodexAgentMessageThreadItem(
              id: 'scroll-agent',
              text: 'Finished.',
            ),
          ],
          status: CodexTurnStatus.inProgress,
        ),
      ];

    Widget buildApp() => MaterialApp(
      theme: motifTheme(Brightness.light),
      home: Scaffold(body: CodexThreadWorkspace(state: state)),
    );
    await tester.pumpWidget(buildApp());
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('codex-activity-scroll-turn-0')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final groupScroll = find.byKey(
      const ValueKey('codex-activity-group-scroll'),
    );
    expect(tester.getSize(groupScroll).height, lessThanOrEqualTo(360));
    expect(_maxScrollExtent(tester, groupScroll), greaterThan(0));

    _expandListTile(
      tester,
      find.ancestor(
        of: find.text('Ran sh long-task.sh'),
        matching: find.byType(ListTile),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final detailScroll = find.byKey(
      const ValueKey('codex-activity-detail-scroll'),
    );
    expect(tester.getSize(detailScroll).height, lessThanOrEqualTo(300));
    expect(_maxScrollExtent(tester, detailScroll), greaterThan(0));

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('long diff details scroll and show cwd-relative paths', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 820);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = WorkspaceFakeClient();
    final longDiff = [
      '--- a/lib/long.dart',
      '+++ b/lib/long.dart',
      for (var index = 0; index < 120; index++) '+line $index',
    ].join('\n');
    final state = workspaceState(client)
      ..turns = [
        CodexTurn(
          completedAt: 1754973480,
          id: 'diff-turn',
          items: [
            const CodexUserMessageThreadItem(
              id: 'diff-user',
              content: [CodexTextUserInput(text: 'Edit the file')],
            ),
            CodexFileChangeThreadItem(
              changes: [
                CodexFileUpdateChange(
                  diff: longDiff,
                  kind: const CodexUpdatePatchChangeKind(),
                  path: '/work/motif/lib/long.dart',
                ),
              ],
              id: 'long-file-change',
              status: CodexPatchApplyStatus.completed,
            ),
            const CodexAgentMessageThreadItem(
              id: 'diff-agent',
              text: 'Edited.',
            ),
          ],
          status: CodexTurnStatus.completed,
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey('codex-worked-toggle-diff-turn')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    final activity = find.byKey(const ValueKey('codex-activity-diff-turn-0'));
    final activityIcon = find.descendant(
      of: activity,
      matching: find.byIcon(Icons.edit_outlined),
    );
    expect(activityIcon, findsOneWidget);
    expect(tester.widget<Icon>(activityIcon).size, 16);
    await tester.tap(find.byKey(const ValueKey('codex-activity-diff-turn-0')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('codex-activity-group-scroll')),
      findsNothing,
    );
    _expandListTile(
      tester,
      find.descendant(
        of: find.byKey(const ValueKey('codex-file-change-long-file-change')),
        matching: find.byType(ListTile),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    _expandListTile(
      tester,
      find.descendant(
        of: find.byKey(const ValueKey('codex-file-diff-lib/long.dart')),
        matching: find.byType(ListTile),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    final diffScroll = find.byKey(
      const ValueKey('codex-diff-scroll-lib/long.dart'),
    );
    final inlineDiff = find.byKey(
      const ValueKey('codex-inline-diff-lib/long.dart'),
    );
    expect(
      find.descendant(of: diffScroll, matching: find.byType(DiffTextView)),
      findsOneWidget,
    );
    expect(find.text('/work/motif/lib/long.dart'), findsNothing);
    expect(find.text('lib/long.dart'), findsWidgets);
    expect(
      tester.getSize(diffScroll).height,
      lessThan(tester.getSize(inlineDiff).height),
    );
    expect(tester.getSize(inlineDiff).height, lessThanOrEqualTo(288));
    expect(tester.getSize(diffScroll).height, lessThanOrEqualTo(246));
    expect(_maxScrollExtent(tester, diffScroll), greaterThan(0));

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('user message bubbles fit content up to a maximum width', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 820);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..turns = [
        CodexTurn(
          id: 'bubble-turn',
          items: [
            const CodexUserMessageThreadItem(
              id: 'short-user',
              content: [CodexTextUserInput(text: 'Short')],
            ),
            CodexUserMessageThreadItem(
              id: 'long-user',
              content: [
                CodexTextUserInput(
                  text: List.filled(30, 'A much longer user message').join(' '),
                ),
              ],
            ),
            const CodexAgentMessageThreadItem(
              id: 'bubble-agent',
              text: 'Done.',
            ),
          ],
          status: CodexTurnStatus.completed,
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();
    await tester.drag(
      find.byKey(const ValueKey('codex-turn-stream')),
      const Offset(0, 2000),
    );
    await tester.pump();

    final shortWidth = tester
        .getSize(find.byKey(const ValueKey('codex-user-message-short-user')))
        .width;
    final longWidth = tester
        .getSize(find.byKey(const ValueKey('codex-user-message-long-user')))
        .width;
    expect(shortWidth, lessThan(200));
    expect(longWidth, greaterThan(shortWidth));
    expect(longWidth, lessThanOrEqualTo(680));

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('image picker includes iOS-compatible type identifiers', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('plugins.flutter.io/file_selector');
    MethodCall? pickerCall;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      pickerCall = call;
      return <String>[];
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)..queuedMessages = const [];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    tester
        .widget<PopupMenuButton<String>>(
          find.byKey(const ValueKey('codex-add-menu')),
        )
        .onSelected!('image');
    await tester.pump();

    expect(pickerCall?.method, 'openFile');
    final arguments = pickerCall!.arguments as Map<Object?, Object?>;
    expect(arguments['multiple'], isTrue);
    final groups = arguments['acceptedTypeGroups'] as List<Object?>;
    final images = groups.single as Map<Object?, Object?>;
    expect(images['uniformTypeIdentifiers'], [
      'public.png',
      'public.jpeg',
      'com.compuserve.gif',
      'org.webmproject.webp',
    ]);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('mobile image action opens the system photo library', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    const channel = MethodChannel('plugins.flutter.io/image_picker');
    MethodCall? pickerCall;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      pickerCall = call;
      return <String>[];
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)..queuedMessages = const [];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    tester
        .widget<PopupMenuButton<String>>(
          find.byKey(const ValueKey('codex-add-menu')),
        )
        .onSelected!('image');
    await tester.pump();

    expect(pickerCall?.method, 'pickMultiImage');
    final arguments = pickerCall!.arguments as Map<Object?, Object?>;
    expect(arguments['requestFullMetadata'], isFalse);

    debugDefaultTargetPlatformOverride = null;
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('add menu owns goal, plan and plugin composer options', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);
    state
      ..turns = [state.turns.first]
      ..goal = const CodexThreadGoal(
        createdAt: 1,
        objective: 'Ship the Codex workspace',
        status: CodexThreadGoalStatus.active,
        threadId: 'thread',
        timeUsedSeconds: 10,
        tokensUsed: 20,
        updatedAt: 2,
      )
      ..skills = const [
        CodexSkillMetadata(
          description: 'Review the current implementation.',
          enabled: true,
          name: 'review',
          path: CodexV2AbsolutePathBuf('/skills/review/SKILL.md'),
          scope: CodexSkillScope.user,
        ),
      ];

    Widget buildComposerApp() => MaterialApp(
      theme: motifTheme(Brightness.light),
      home: Scaffold(body: CodexThreadWorkspace(state: state)),
    );
    await tester.pumpWidget(buildComposerApp());
    await tester.pump();

    expect(find.byKey(const ValueKey('codex-goal-button')), findsNothing);
    expect(find.byKey(const ValueKey('codex-goal-chip')), findsOneWidget);
    expect(
      tester.getRect(find.byKey(const ValueKey('codex-goal-chip'))).left -
          tester
              .getRect(find.byKey(const ValueKey('codex-permission-selector')))
              .right,
      moreOrLessEquals(MotifSpacing.xs, epsilon: 0.1),
    );
    await tester.tap(find.byKey(const ValueKey('codex-add-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('codex-add-goal')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-add-plan')), findsOneWidget);
    expect(find.text('Skills'), findsNothing);
    expect(find.byKey(const ValueKey('codex-add-skill-0')), findsNothing);
    expect(find.text('Plugins'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('codex-add-plan')));
    await tester.pumpAndSettle();
    expect(state.planModeEnabled, isTrue);
    await tester.pumpWidget(buildComposerApp());
    await tester.pump();
    expect(find.byKey(const ValueKey('codex-plan-chip')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('codex-plan-chip')));
    await tester.pump();
    expect(state.planModeEnabled, isFalse);
    await tester.pumpWidget(buildComposerApp());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-add-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('codex-add-plan')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('codex-composer-input')),
      'Use the selected capability',
    );
    await tester.tap(find.byKey(const ValueKey('codex-send')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.started, hasLength(1));
    expect(client.started.single.collaborationMode?.mode, CodexModeKind.plan);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets(
    'permission types have semantic icons and full access is danger',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = WorkspaceFakeClient();
      final state = workspaceState(client)
        ..permissionProfiles = const [
          CodexPermissionProfileSummary(
            allowed: true,
            description: 'Ask for approval',
            id: 'ask-for-approval',
          ),
          CodexPermissionProfileSummary(
            allowed: true,
            description: 'Approve for me',
            id: 'approve-for-me',
          ),
          CodexPermissionProfileSummary(
            allowed: true,
            description: 'Danger: Full access',
            id: 'danger-full-access',
          ),
          CodexPermissionProfileSummary(
            allowed: true,
            description: 'Custom: config.toml',
            id: 'custom',
          ),
          CodexPermissionProfileSummary(allowed: true, id: ':workspace'),
        ]
        ..selectedPermissionId = 'danger-full-access';

      await tester.pumpWidget(
        MaterialApp(
          theme: motifTheme(Brightness.light),
          home: Scaffold(body: CodexThreadWorkspace(state: state)),
        ),
      );
      await tester.pump();

      final selector = find.byKey(const ValueKey('codex-permission-selector'));
      final selectedIcon = tester.widget<Icon>(
        find.descendant(
          of: selector,
          matching: find.byIcon(Icons.error_outline_rounded),
        ),
      );
      expect(selectedIcon.color, MotifColors.light.danger);

      await tester.tap(selector);
      await tester.pump(const Duration(milliseconds: 300));

      void expectOptionIcon(String id, IconData icon) {
        expect(
          find.descendant(
            of: find.byKey(ValueKey('codex-permission-option-$id')),
            matching: find.byIcon(icon),
          ),
          findsOneWidget,
        );
      }

      expectOptionIcon('ask-for-approval', Icons.front_hand_outlined);
      expectOptionIcon('approve-for-me', Icons.verified_user_outlined);
      expectOptionIcon('danger-full-access', Icons.error_outline_rounded);
      expectOptionIcon('custom', Icons.settings_outlined);
      expectOptionIcon(':workspace', Icons.drive_file_rename_outline);
      expect(find.text('Danger: Full access'), findsNothing);
      expect(find.text('Full access'), findsNWidgets(2));
      expect(find.text('Custom: config.toml'), findsNothing);
      expect(find.text('Custom (config.toml)'), findsOneWidget);
      expect(find.text(':workspace'), findsNothing);
      expect(find.text('Workspace'), findsOneWidget);
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byKey(
                  const ValueKey('codex-permission-option-danger-full-access'),
                ),
                matching: find.byIcon(Icons.error_outline_rounded),
              ),
            )
            .color,
        MotifColors.light.danger,
      );
      expect(
        find.descendant(
          of: find.byKey(
            const ValueKey('codex-permission-option-danger-full-access'),
          ),
          matching: find.byIcon(Icons.check_rounded),
        ),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );

  testWidgets('git directives stay out of agent messages', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..turns = const [
        CodexTurn(
          id: 'git-directives',
          items: [
            CodexAgentMessageThreadItem(
              id: 'git-directive-message',
              text:
                  'Finished successfully.\n\n'
                  '::git-stage{cwd="/work/motif"}\n'
                  '::git-commit{cwd="/work/motif"}\n'
                  '::git-push{cwd="/work/motif" branch="main"}\n\n'
                  '```text\n'
                  '::git-stage{cwd="example"}\n'
                  '```',
            ),
          ],
          status: CodexTurnStatus.completed,
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    final response = tester.widget<MarkdownBody>(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody &&
            widget.data.contains('Finished successfully.'),
      ),
    );
    expect(response.data, isNot(contains('::git-commit')));
    expect(response.data, isNot(contains('::git-push')));
    expect(response.data, contains('::git-stage{cwd="example"}'));

    await tester.tap(
      find.byKey(const ValueKey('codex-copy-git-directive-message')),
    );
    await tester.pump();
    expect(copiedText, isNot(contains('::git-commit')));
    expect(copiedText, isNot(contains('::git-push')));
    expect(copiedText, contains('::git-stage{cwd="example"}'));

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('streaming agent text defers full Markdown parsing', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    client.emit(
      const CodexItemAgentMessageDeltaNotification(
        params: CodexAgentMessageDeltaNotification(
          delta: ' **more**',
          itemId: 'active-agent',
          threadId: 'thread',
          turnId: 'turn-1',
        ),
      ),
    );
    await tester.pump(
      CodexConversationState.deltaFlushInterval +
          const Duration(milliseconds: 20),
    );

    expect(find.byType(CodexStreamingText), findsOneWidget);
    expect(find.text('Partial response **more**'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody &&
            widget.data == 'Partial response **more**',
      ),
      findsNothing,
    );

    client.emit(
      const CodexItemCompletedNotification2(
        params: CodexItemCompletedNotification(
          completedAtMs: 2,
          item: CodexAgentMessageThreadItem(
            id: 'active-agent',
            text: 'Partial response **more**',
          ),
          threadId: 'thread',
          turnId: 'turn-1',
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody &&
            widget.data == 'Partial response **more**',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('goal uses the composer for its objective', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);
    state.turns = [state.turns.first];
    Widget buildGoalApp() => MaterialApp(
      theme: motifTheme(Brightness.light),
      home: Scaffold(body: CodexThreadWorkspace(state: state)),
    );

    await tester.pumpWidget(buildGoalApp());
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('codex-add-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('codex-add-goal')));
    await tester.pumpAndSettle();
    await tester.pumpWidget(buildGoalApp());
    await tester.pump();

    expect(find.text('Thread goal'), findsNothing);
    expect(state.goalModeEnabled, isTrue);
    expect(find.byKey(const ValueKey('codex-goal-chip')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('codex-composer-input')))
          .decoration
          ?.hintText,
      'Describe your goal',
    );

    await tester.enterText(
      find.byKey(const ValueKey('codex-composer-input')),
      'Ship the composer goal flow',
    );
    await tester.tap(find.byKey(const ValueKey('codex-send')));
    await tester.pumpAndSettle();

    expect(client.goalsSet, hasLength(1));
    expect(client.goalsSet.single.objective, 'Ship the composer goal flow');
    expect(client.started, isEmpty);
    expect(state.goalModeEnabled, isFalse);
    expect(state.goal?.objective, 'Ship the composer goal flow');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('codex-composer-input')))
          .controller
          ?.text,
      isEmpty,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('questionnaire is interactive and sends a typed response', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1200);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..pendingServerRequests = const [
        CodexItemToolRequestUserInputRequest(
          id: CodexV2RequestId(7),
          params: CodexToolRequestUserInputParams(
            isBlocking: true,
            itemId: 'question-item',
            questions: [
              CodexToolRequestUserInputQuestion(
                header: 'Direction',
                id: 'direction',
                options: [
                  CodexToolRequestUserInputOption(
                    description: 'Continue with the recommended path.',
                    label: 'Continue',
                  ),
                ],
                question: 'How should Codex proceed?',
              ),
            ],
            threadId: 'thread',
            turnId: 'turn-1',
          ),
        ),
      ];

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();
    expect(find.text('Codex has a question'), findsOneWidget);
    expect(find.text('How should Codex proceed?'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.drag(
      find.byKey(const ValueKey('codex-turn-stream')),
      const Offset(0, -220),
    );
    await tester.pump();
    await tester.tap(find.text('Submit answers'));
    await tester.pump(const Duration(milliseconds: 200));

    expect(client.responses, hasLength(1));
    final response =
        client.responses.single.response as CodexToolRequestUserInputResponse;
    expect(response.answers['direction']?.answers, ['Continue']);
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('Markdown blockquotes fill the available content width', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: CodexMarkdown('Paragraph\n\n> Quoted **content**'),
            ),
          ),
        ),
      ),
    );

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.fitContent, isFalse);
    final quote = find.byWidgetPredicate((widget) {
      if (widget is! DecoratedBox || widget.decoration is! BoxDecoration) {
        return false;
      }
      final border = (widget.decoration as BoxDecoration).border;
      return border is Border && border.left.width == 3;
    });
    expect(quote, findsOneWidget);
    expect(tester.getSize(quote).width, 400);
  });

  testWidgets('Markdown lists use compact right-aligned marker gutters', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 400,
              child: CodexMarkdown(
                'Before\n\n1. Ordered item\n\n- First bullet\n- Second bullet\n\nAfter',
              ),
            ),
          ),
        ),
      ),
    );

    final markdown = tester.widget<MarkdownBody>(
      find.byType(MarkdownBody).first,
    );
    expect(markdown.styleSheet?.blockSpacing, MotifSpacing.lg);
    expect(markdown.styleSheet?.listIndent, MotifSpacing.lg);
    expect(
      markdown.styleSheet?.listBulletPadding,
      const EdgeInsets.only(right: MotifSpacing.sm),
    );
    final bullets = find.text('•');
    expect(bullets, findsNWidgets(2));
    final marker = tester.widget<Text>(bullets.first);
    expect(marker.style?.fontSize, MotifType.body.fontSize);
    expect(marker.style?.fontWeight, FontWeight.w700);
    final orderedMarkerRect = tester.getRect(find.text('1.'));
    final orderedItemRect = tester.getRect(find.text('Ordered item'));
    expect(
      orderedMarkerRect.left,
      moreOrLessEquals(MotifSpacing.xs, epsilon: 0.1),
    );
    expect(
      orderedItemRect.left - orderedMarkerRect.right,
      moreOrLessEquals(MotifSpacing.sm, epsilon: 0.1),
    );
    final markerRect = tester.getRect(bullets.first);
    final firstRect = tester.getRect(find.text('First bullet'));
    final secondRect = tester.getRect(find.text('Second bullet'));
    expect(markerRect.left, moreOrLessEquals(MotifSpacing.xs, epsilon: 0.1));
    expect(
      firstRect.left - markerRect.right,
      moreOrLessEquals(MotifSpacing.sm, epsilon: 0.1),
    );
    expect(
      secondRect.top - firstRect.bottom,
      moreOrLessEquals(MotifSpacing.sm, epsilon: 0.1),
    );
  });

  testWidgets('nested Markdown lists use the same vertical spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: const Scaffold(
          body: SizedBox(
            width: 400,
            child: CodexMarkdown(
              '- Parent\n  - Nested one\n  - Nested two\n- Sibling',
            ),
          ),
        ),
      ),
    );

    final parent = tester.getRect(find.text('Parent'));
    final nestedOne = tester.getRect(find.text('Nested one'));
    final nestedTwo = tester.getRect(find.text('Nested two'));
    final sibling = tester.getRect(find.text('Sibling'));
    expect(nestedOne.left, greaterThan(parent.left));
    expect(
      nestedOne.top - parent.bottom,
      moreOrLessEquals(MotifSpacing.sm, epsilon: 0.1),
    );
    expect(
      nestedTwo.top - nestedOne.bottom,
      moreOrLessEquals(MotifSpacing.sm, epsilon: 0.1),
    );
    expect(
      sibling.top - nestedTwo.bottom,
      moreOrLessEquals(MotifSpacing.sm, epsilon: 0.1),
    );
  });

  testWidgets('Markdown file links open through the Codex file navigator', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..turns = const [
        CodexTurn(
          id: 'file-links',
          items: [
            CodexAgentMessageThreadItem(
              id: 'file-link-response',
              text: '- [open file](lib/motif/codex_navigation.dart:42)',
            ),
          ],
          status: CodexTurnStatus.completed,
        ),
      ];
    final openedFiles = <String>[];
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: CodexThreadWorkspace(state: state, onOpenFile: openedFiles.add),
        ),
      ),
    );
    await tester.pump();

    final linkBody = tester.widget<MarkdownBody>(
      find.byWidgetPredicate(
        (widget) =>
            widget is MarkdownBody &&
            widget.data == '[open file](lib/motif/codex_navigation.dart:42)',
      ),
    );
    linkBody.onTapLink!('open file', 'lib/motif/codex_navigation.dart:42', '');

    expect(openedFiles, ['/work/motif/lib/motif/codex_navigation.dart']);
  });

  testWidgets('user and response images open through the image navigator', (
    tester,
  ) async {
    const dataImage =
        'data:image/png;base64,'
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=';
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..turns = const [
        CodexTurn(
          id: 'images',
          items: [
            CodexUserMessageThreadItem(
              id: 'user-images',
              content: [
                CodexLocalImageUserInput(path: '/work/motif/request.png'),
                CodexImageUserInput(url: dataImage),
              ],
            ),
            CodexAgentMessageThreadItem(
              id: 'response-image',
              text: '![result](https://example.test/result.png)',
            ),
          ],
          status: CodexTurnStatus.completed,
        ),
      ];
    final openedImages = <String>[];
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: CodexThreadWorkspace(
            state: state,
            onOpenImage: openedImages.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    tester
        .widget<GestureDetector>(
          find.byKey(
            const ValueKey('codex-user-local-image-/work/motif/request.png'),
          ),
        )
        .onTap!();
    tester
        .widget<GestureDetector>(
          find.byKey(ValueKey('codex-user-remote-image-$dataImage')),
        )
        .onTap!();
    tester
        .widget<GestureDetector>(
          find.byKey(
            const ValueKey(
              'codex-markdown-image-https://example.test/result.png',
            ),
          ),
        )
        .onTap!();

    expect(openedImages, [
      '/work/motif/request.png',
      dataImage,
      'https://example.test/result.png',
    ]);
  });

  testWidgets('view-image activity thumbnail opens the large image', (
    tester,
  ) async {
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);
    final openedImages = <String>[];
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: CodexTurnActivityGroup(
            state: state,
            items: const [
              CodexImageViewThreadItem(
                id: 'view-image',
                path: CodexLegacyAppPathString('/work/motif/result.png'),
              ),
            ],
            onOpenImage: openedImages.add,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Viewed an image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Viewed result.png'));
    await tester.pumpAndSettle();

    tester
        .widget<GestureDetector>(
          find.byKey(
            const ValueKey('codex-image-thumbnail-/work/motif/result.png'),
          ),
        )
        .onTap!();

    expect(openedImages, ['/work/motif/result.png']);
  });

  testWidgets('narrow composer keeps model settings before the send action', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(580, 820);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = WorkspaceFakeClient();
    final state = workspaceState(client)
      ..goal = const CodexThreadGoal(
        createdAt: 1,
        objective: 'Keep the compact composer readable',
        status: CodexThreadGoalStatus.active,
        threadId: 'thread',
        timeUsedSeconds: 0,
        tokensUsed: 0,
        updatedAt: 1,
      )
      ..planModeEnabled = true;

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    final model = find.byKey(const ValueKey('codex-model-settings-label'));
    final send = find.byKey(const ValueKey('codex-stop'));
    final composer = find.byKey(const ValueKey('codex-composer'));
    final modelRect = tester.getRect(model);
    final sendRect = tester.getRect(send);
    expect(
      modelRect.center.dy,
      moreOrLessEquals(sendRect.center.dy, epsilon: 1),
    );
    expect(modelRect.right, lessThan(sendRect.left));
    expect(
      tester.getRect(composer).right - sendRect.right,
      moreOrLessEquals(MotifSpacing.md + 1, epsilon: 0.1),
    );

    final permission = find.byKey(const ValueKey('codex-permission-selector'));
    final goal = find.byKey(const ValueKey('codex-goal-chip'));
    final plan = find.byKey(const ValueKey('codex-plan-chip'));
    expect(
      find.descendant(of: permission, matching: find.byType(Text)),
      findsNothing,
    );
    expect(
      find.descendant(of: goal, matching: find.byType(Text)),
      findsNothing,
    );
    expect(
      find.descendant(of: plan, matching: find.byType(Text)),
      findsNothing,
    );
    expect(
      find.descendant(
        of: goal,
        matching: find.byIcon(Icons.track_changes_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: plan,
        matching: find.byIcon(Icons.lightbulb_outline_rounded),
      ),
      findsOneWidget,
    );
    expect(tester.getSize(permission).width, MotifControlSize.sm);
    expect(
      tester.getRect(plan).left - tester.getRect(goal).right,
      moreOrLessEquals(MotifSpacing.xs, epsilon: 0.1),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('assistant responses can be copied and forked', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 820);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copiedText = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final client = WorkspaceFakeClient();
    final state = workspaceState(client);

    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(body: CodexThreadWorkspace(state: state)),
      ),
    );
    await tester.pump();

    final copy = find.byKey(const ValueKey('codex-copy-agent'));
    await tester.ensureVisible(copy);
    await tester.pump();
    await tester.tap(copy);
    await tester.pump();
    expect(copiedText, 'I am **working** on it.');

    final fork = find.byKey(const ValueKey('codex-fork-turn-history'));
    await tester.ensureVisible(fork);
    await tester.pump();
    await tester.tap(fork);
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.forked.single.threadId, 'thread');
    expect(client.forked.single.lastTurnId, 'turn-history');
    expect(state.selectedThread?.id, 'forked-thread');
    expect(state.turns.map((turn) => turn.id), ['turn-history']);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}

double _maxScrollExtent(WidgetTester tester, Finder container) {
  final scrollable = find.descendant(
    of: container,
    matching: find.byType(Scrollable),
  );
  return tester
      .state<ScrollableState>(scrollable.first)
      .position
      .maxScrollExtent;
}

void _expandListTile(WidgetTester tester, Finder finder) {
  tester.widget<ListTile>(finder).onTap!.call();
}

CodexServiceState workspaceState(WorkspaceFakeClient client) {
  final turns = <CodexTurn>[
    const CodexTurn(
      completedAt: 1754973480,
      durationMs: 487000,
      id: 'turn-history',
      items: [
        CodexUserMessageThreadItem(
          id: 'user',
          content: [CodexTextUserInput(text: 'Hello **Codex**')],
        ),
        CodexReasoningThreadItem(
          id: 'historic-reasoning',
          summary: ['Historic reasoning must stay hidden'],
        ),
        CodexCommandExecutionThreadItem(
          aggregatedOutput: 'lib/main.dart: TODO',
          command: 'rg TODO',
          commandActions: [],
          cwd: CodexLegacyAppPathString('/work/motif'),
          durationMs: 1000,
          exitCode: 0,
          id: 'command',
          status: CodexCommandExecutionStatus.completed,
        ),
        CodexFileChangeThreadItem(
          changes: [
            CodexFileUpdateChange(
              diff: '--- a/lib/a.dart\n+++ b/lib/a.dart\n-old\n+new',
              kind: CodexUpdatePatchChangeKind(),
              path: '/work/motif/lib/a.dart',
            ),
          ],
          id: 'file-change-1',
          status: CodexPatchApplyStatus.completed,
        ),
        CodexFileChangeThreadItem(
          changes: [
            CodexFileUpdateChange(
              diff: '--- /dev/null\n+++ b/lib/b.dart\n+created',
              kind: CodexAddPatchChangeKind(),
              path: '/work/motif/lib/b.dart',
            ),
          ],
          id: 'file-change-2',
          status: CodexPatchApplyStatus.completed,
        ),
        CodexFileChangeThreadItem(
          changes: [
            CodexFileUpdateChange(
              diff: '--- a/lib/a.dart\n+++ b/lib/a.dart\n+another',
              kind: CodexUpdatePatchChangeKind(),
              path: '/work/motif/lib/a.dart',
            ),
            CodexFileUpdateChange(
              diff: '--- /dev/null\n+++ b/lib/c.dart\n+first\n+second',
              kind: CodexAddPatchChangeKind(),
              path: '/work/motif/lib/c.dart',
            ),
            CodexFileUpdateChange(
              diff: '--- a/lib/d.dart\n+++ /dev/null\n-gone',
              kind: CodexDeletePatchChangeKind(),
              path: '/work/motif/lib/d.dart',
            ),
          ],
          id: 'file-change-3',
          status: CodexPatchApplyStatus.completed,
        ),
        CodexPlanThreadItem(id: 'plan-history', text: 'Next **step**.'),
        CodexContextCompactionThreadItem(id: 'compaction-1'),
        CodexAgentMessageThreadItem(
          id: 'agent',
          text: 'I am **working** on it.',
        ),
      ],
      status: CodexTurnStatus.completed,
    ),
    const CodexTurn(
      id: 'turn-1',
      items: [
        CodexAgentMessageThreadItem(
          id: 'active-agent',
          text: 'Partial response',
        ),
        CodexReasoningThreadItem(
          id: 'active-reasoning-1',
          summary: ['First progress'],
        ),
        CodexReasoningThreadItem(
          id: 'active-reasoning-2',
          summary: ['Latest **progress**'],
        ),
      ],
      status: CodexTurnStatus.inProgress,
    ),
  ];
  final thread = CodexThread(
    cliVersion: 'test',
    createdAt: 1,
    cwd: const CodexV2AbsolutePathBuf('/work/motif'),
    ephemeral: false,
    id: 'thread',
    modelProvider: 'openai',
    name: 'Workspace thread',
    preview: '',
    sessionId: 'thread',
    source: const CodexSessionSource('cli'),
    status: const CodexActiveThreadStatus(activeFlags: []),
    turns: turns,
    updatedAt: 1,
  );
  client.thread = thread;
  return CodexServiceState(serverId: 'server', connection: client)
    ..selectedThread = thread
    ..turns = turns
    ..models = const [
      CodexModel(
        defaultReasoningEffort: CodexReasoningEffort('high'),
        description: 'Test model',
        displayName: 'Codex Test',
        hidden: false,
        id: 'codex-test',
        isDefault: true,
        model: 'codex-test',
        supportedReasoningEfforts: [
          CodexReasoningEffortOption(
            description: 'High',
            reasoningEffort: CodexReasoningEffort('high'),
          ),
          CodexReasoningEffortOption(
            description: 'Consumes usage limits faster',
            reasoningEffort: CodexReasoningEffort('ultra'),
          ),
        ],
      ),
    ]
    ..selectedModelId = 'codex-test'
    ..selectedReasoningEffort = 'high'
    ..permissionProfiles = const [
      CodexPermissionProfileSummary(
        allowed: true,
        description: 'Full access',
        id: 'full-access',
      ),
    ]
    ..selectedPermissionId = 'full-access'
    ..activePlan = const CodexTurnPlanUpdatedNotification(
      plan: [
        CodexTurnPlanStep(
          status: CodexTurnPlanStepStatus.inProgress,
          step: 'Implement UI',
        ),
        CodexTurnPlanStep(
          status: CodexTurnPlanStepStatus.pending,
          step: 'Run tests',
        ),
      ],
      threadId: 'thread',
      turnId: 'turn-1',
    )
    ..activeDiff =
        'diff --git a/lib/a.dart b/lib/a.dart\n'
        '--- a/lib/a.dart\n+++ b/lib/a.dart\n-old\n+new\n'
    ..queuedMessages = const [
      CodexQueuedMessage(
        id: 'queued-1',
        text: 'queued follow-up',
        attachments: [],
      ),
    ];
}

final class WorkspaceFakeClient extends ChangeNotifier
    implements CodexAppServerClient {
  late CodexThread thread;
  Map<String?, CodexThreadTurnsListResponse> turnPages = const {};
  final List<CodexThreadTurnsListParams> turnListParams = [];
  final List<CodexThreadForkParams> forked = [];
  final List<CodexTurnStartParams> started = [];
  final List<CodexTurnSteerParams> steered = [];
  final List<CodexThreadGoalSetParams> goalsSet = [];
  final List<({CodexV2RequestId id, CodexJsonEncodable response})> responses =
      [];
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

  void emit(CodexJsonEncodable message) => _typed.add(message);

  @override
  Future<void> start() async {}

  @override
  Future<void> retry() async {}

  @override
  Future<CodexThreadListResponse> listThreads(
    CodexThreadListParams params,
  ) async => CodexThreadListResponse(data: [thread]);

  @override
  Future<CodexThreadSetNameResponse> setThreadName(
    String threadId,
    String name,
  ) async => const CodexThreadSetNameResponse();

  @override
  Future<CodexThreadArchiveResponse> archiveThread(String threadId) async =>
      const CodexThreadArchiveResponse();

  @override
  Future<CodexThreadUnarchiveResponse> unarchiveThread(String threadId) async =>
      CodexThreadUnarchiveResponse(thread: thread);

  @override
  Future<CodexThreadDeleteResponse> deleteThread(String threadId) async =>
      const CodexThreadDeleteResponse();

  @override
  Future<CodexThreadReadResponse> readThread(
    String threadId, {
    bool includeTurns = false,
  }) async => CodexThreadReadResponse(thread: thread);

  @override
  Future<CodexThreadTurnsListResponse> listThreadTurns(
    CodexThreadTurnsListParams params,
  ) async {
    turnListParams.add(params);
    return turnPages[params.cursor] ??
        CodexThreadTurnsListResponse(
          data: thread.turns.reversed.toList(growable: false),
        );
  }

  @override
  Future<CodexThreadForkResponse> forkThread(
    CodexThreadForkParams params,
  ) async {
    forked.add(params);
    final fork = CodexThread(
      cliVersion: thread.cliVersion,
      createdAt: thread.createdAt,
      cwd: thread.cwd,
      ephemeral: false,
      id: 'forked-thread',
      modelProvider: thread.modelProvider,
      name: thread.name,
      preview: thread.preview,
      sessionId: 'forked-thread',
      source: thread.source,
      status: const CodexIdleThreadStatus(),
      turns: thread.turns
          .takeWhile((turn) => turn.id != params.lastTurnId)
          .followedBy(
            thread.turns.where((turn) => turn.id == params.lastTurnId),
          )
          .toList(growable: false),
      updatedAt: thread.updatedAt,
    );
    thread = fork;
    return CodexThreadForkResponse(
      approvalPolicy: const CodexAskForApproval('on-request'),
      approvalsReviewer: CodexApprovalsReviewer.user,
      cwd: fork.cwd,
      model: 'codex-test',
      modelProvider: 'openai',
      reasoningEffort: const CodexReasoningEffort('high'),
      sandbox: const CodexDangerFullAccessSandboxPolicy(),
      thread: fork,
    );
  }

  @override
  Future<CodexThreadStartResponse> startThread(
    CodexThreadStartParams params,
  ) async => throw StateError('unused');

  @override
  Future<CodexThreadUnsubscribeResponse> unsubscribeThread(
    String threadId,
  ) async => const CodexThreadUnsubscribeResponse(
    status: CodexThreadUnsubscribeStatus.unsubscribed,
  );

  @override
  Future<CodexThreadResumeResponse> resumeThread(
    String threadId, {
    bool includeTurns = false,
    CodexThreadResumeInitialTurnsPageParams? initialTurnsPage,
  }) async => CodexThreadResumeResponse(
    approvalPolicy: const CodexAskForApproval('on-request'),
    approvalsReviewer: CodexApprovalsReviewer.user,
    cwd: thread.cwd,
    model: 'codex-test',
    modelProvider: 'openai',
    initialTurnsPage: initialTurnsPage == null
        ? null
        : CodexTurnsPage(data: thread.turns.reversed.toList(growable: false)),
    reasoningEffort: const CodexReasoningEffort('high'),
    sandbox: const CodexDangerFullAccessSandboxPolicy(),
    thread: thread,
  );

  @override
  Future<CodexTurnStartResponse> startTurn(CodexTurnStartParams params) async {
    started.add(params);
    return const CodexTurnStartResponse(
      turn: CodexTurn(
        id: 'new-turn',
        items: [],
        status: CodexTurnStatus.inProgress,
      ),
    );
  }

  @override
  Future<CodexTurnSteerResponse> steerTurn(CodexTurnSteerParams params) async {
    steered.add(params);
    return CodexTurnSteerResponse(turnId: params.expectedTurnId);
  }

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
  ) async {
    goalsSet.add(params);
    return CodexThreadGoalSetResponse(
      goal: CodexThreadGoal(
        createdAt: 1,
        objective: params.objective!,
        status: params.status ?? CodexThreadGoalStatus.active,
        threadId: params.threadId,
        timeUsedSeconds: 0,
        tokenBudget: params.tokenBudget,
        tokensUsed: 0,
        updatedAt: 1,
      ),
    );
  }

  @override
  Future<CodexThreadGoalClearResponse> clearThreadGoal(String threadId) async =>
      const CodexThreadGoalClearResponse(cleared: true);

  @override
  Future<CodexFsReadFileResponse> readFile(
    String path,
  ) async => const CodexFsReadFileResponse(
    dataBase64:
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR4nGNgYAAAAAMAASsJTYQAAAAASUVORK5CYII=',
  );

  @override
  Future<CodexFsCreateDirectoryResponse> createDirectory(String path) async =>
      const CodexFsCreateDirectoryResponse();

  @override
  Future<CodexFsWriteFileResponse> writeFile(
    String path,
    String dataBase64,
  ) async => const CodexFsWriteFileResponse();

  @override
  Future<CodexFsWatchResponse> watchFile(String path, String watchId) async =>
      CodexFsWatchResponse(path: CodexV2AbsolutePathBuf(path));

  @override
  Future<CodexFsUnwatchResponse> unwatchFile(String watchId) async =>
      const CodexFsUnwatchResponse();

  @override
  Future<void> respondToServerRequest(
    CodexV2RequestId id,
    CodexJsonEncodable response,
  ) async => responses.add((id: id, response: response));

  @override
  Future<void> close() => Future<void>.value();

  @override
  void dispose() {
    unawaited(_raw.close());
    unawaited(_typed.close());
    super.dispose();
  }
}
