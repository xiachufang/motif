import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_composer_models.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/codex_session_state.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:motif/motif/ui/screens/codex_thread_workspace.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/codex_markdown.dart';

void main() {
  testWidgets(
    'renders turns, keeps tool details collapsed, and floats plan and queue',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 820);
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

      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('codex-thread-detail')))
            .color,
        MotifColors.light.surface,
      );

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
      expect(find.text('Worked for 8m 7s'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey('codex-worked-toggle-turn-history')),
      );
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
      expect(collapsedActivity.minTileHeight, 36);
      expect(collapsedActivity.visualDensity?.vertical, -4);
      expect(find.text('Ran a command, edited files'), findsOneWidget);
      expect(find.text('Ran rg · in 1.0s · exit 0'), findsNothing);
      expect(find.text(r'$ rg TODO'), findsNothing);
      await tester.tap(find.text('Ran a command, edited files'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.byKey(const ValueKey('codex-activity-group-scroll')),
        findsNothing,
      );
      expect(find.text('Ran rg · in 1.0s · exit 0'), findsOneWidget);
      expect(find.text('Edited 1 file'), findsNWidgets(2));
      _expandListTile(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('codex-file-change-file-change-1')),
          matching: find.byType(ListTile),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
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
      expect(find.text('First progress'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is MarkdownBody && widget.data == 'Latest **progress**',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('codex-turn-progress')), findsOneWidget);

      expect(find.text('Step 1 / 2'), findsOneWidget);
      expect(find.textContaining('1 file changed'), findsOneWidget);
      expect(find.textContaining('+1'), findsAtLeast(1));
      expect(find.textContaining('-1'), findsAtLeast(1));
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
        find.byKey(const ValueKey('codex-turn-time-turn-history')),
        findsOneWidget,
      );
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
      await tester.tap(
        find.byKey(const ValueKey('codex-model-settings-label')),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('codex-model-submenu')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('codex-effort-selector')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('codex-effort-selector')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Consumes usage limits faster'), findsOneWidget);
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
        of: find.text('Ran sh · exit 0'),
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
    expect(find.text('/work/motif/lib/long.dart'), findsNothing);
    expect(find.text('lib/long.dart'), findsWidgets);
    expect(tester.getSize(diffScroll).height, lessThanOrEqualTo(280));
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

  testWidgets('add menu owns goal, plan, skill and plugin composer options', (
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
    await tester.tap(find.byKey(const ValueKey('codex-add-menu')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('codex-add-goal')), findsOneWidget);
    expect(find.byKey(const ValueKey('codex-add-plan')), findsOneWidget);
    expect(find.text('Skills'), findsOneWidget);
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
    await tester.pumpWidget(buildComposerApp());
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('codex-add-menu')));
    await tester.pumpAndSettle();
    final skill = find.byKey(const ValueKey('codex-add-skill-0'));
    await tester.ensureVisible(skill);
    await tester.tap(skill);
    await tester.pumpAndSettle();
    expect(
      find.byKey(
        const ValueKey('codex-reference-skill-/skills/review/SKILL.md'),
      ),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey('codex-composer-input')),
      'Use the selected capability',
    );
    await tester.tap(find.byKey(const ValueKey('codex-send')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(client.started, hasLength(1));
    expect(client.started.single.collaborationMode?.mode, CodexModeKind.plan);
    expect(
      client.started.single.input.whereType<CodexSkillUserInput>().single.path,
      '/skills/review/SKILL.md',
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

  testWidgets('narrow composer keeps model settings before the send action', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(580, 820);
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

    final model = find.byKey(const ValueKey('codex-model-settings-label'));
    final send = find.byKey(const ValueKey('codex-stop'));
    final modelRect = tester.getRect(model);
    final sendRect = tester.getRect(send);
    expect(
      modelRect.center.dy,
      moreOrLessEquals(sendRect.center.dy, epsilon: 1),
    );
    expect(modelRect.right, lessThan(sendRect.left));

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

CodexSessionState workspaceState(WorkspaceFakeClient client) {
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
  return CodexSessionState(
      serverId: 'server',
      session: 'agent',
      connection: client,
    )
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
  final List<CodexThreadForkParams> forked = [];
  final List<CodexTurnStartParams> started = [];
  final List<CodexTurnSteerParams> steered = [];
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

  @override
  Future<void> start() async {}

  @override
  Future<void> retry() async {}

  @override
  Future<CodexThreadListResponse> listThreads(
    CodexThreadListParams params,
  ) async => CodexThreadListResponse(data: [thread]);

  @override
  Future<CodexThreadReadResponse> readThread(
    String threadId, {
    bool includeTurns = false,
  }) async => CodexThreadReadResponse(thread: thread);

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
  Future<CodexThreadResumeResponse> resumeThread(String threadId) async =>
      CodexThreadResumeResponse(
        approvalPolicy: const CodexAskForApproval('on-request'),
        approvalsReviewer: CodexApprovalsReviewer.user,
        cwd: thread.cwd,
        model: 'codex-test',
        modelProvider: 'openai',
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
