import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/codex/codex_connection_controller.dart';
import 'package:motif/motif/codex/codex_service_state.dart';
import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';
import 'package:motif/motif/ui/screens/codex_thread_workspace.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/codex_subagent_activity.dart';
import 'package:motif/motif/ui/widgets/codex_turn_activity.dart';

void main() {
  testWidgets('agent messages retain their positions outside Worked history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _Client();
    final state = CodexConversationState(
      serverId: 'server',
      connection: client,
      features: const {},
    );
    state.turns = [
      CodexTurn(
        id: 'parent-turn',
        status: CodexTurnStatus.completed,
        items: [
          _command('before'),
          _message('first', 'cp_phy_next_consumers', 'a'),
          _command('middle'),
          _message('second', 'ap_emmc_reference_sdma', 'b'),
          _command('after'),
          _message('third', 'cp_phy_next_consumers', 'a'),
          const CodexAgentMessageThreadItem(
            id: 'answer',
            text: 'Parent answer',
            phase: CodexMessagePhase('final_answer'),
          ),
        ],
      ),
    ];
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        CodexThreadWorkspace(
          state: state,
          onOpenSubagent: (threadId, {required name}) => opened.add(threadId),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CodexSubagentActivity), findsNWidgets(3));
    expect(find.text('Cp phy next consumers finished'), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('codex-subagent-open-third')));
    await tester.pump();
    expect(opened, ['a']);
    await tester.tap(
      find.byKey(const ValueKey('codex-worked-toggle-parent-turn')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CodexSubagentActivity), findsNWidgets(3));
    final groups = tester.widgetList<CodexTurnActivityGroup>(
      find.byType(CodexTurnActivityGroup),
    );
    expect(groups, hasLength(3));
    expect(
      groups
          .expand((group) => group.items)
          .whereType<CodexSubAgentActivityThreadItem>(),
      isEmpty,
    );
    expect(
      tester.getTopLeft(find.byType(CodexTurnActivityGroup).at(0)).dy,
      lessThan(tester.getTopLeft(find.byType(CodexSubagentActivity).at(0)).dy),
    );
    expect(
      tester.getTopLeft(find.byType(CodexSubagentActivity).at(0)).dy,
      lessThan(tester.getTopLeft(find.byType(CodexTurnActivityGroup).at(1)).dy),
    );
    expect(
      tester.getTopLeft(find.byType(CodexSubagentActivity).at(1)).dy,
      lessThan(tester.getTopLeft(find.byType(CodexTurnActivityGroup).at(2)).dy),
    );
    final icons = find.descendant(
      of: find.byType(CodexSubagentActivity),
      matching: find.byType(Icon),
    );
    expect(
      tester.widget<Icon>(icons.at(0)).color,
      tester.widget<Icon>(icons.at(2)).color,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('each lifecycle message opens its exact child', (tester) async {
    final opened = <(String, String)>[];
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            for (final kind in CodexSubAgentActivityKind.values)
              CodexSubagentActivity(
                item: CodexSubAgentActivityThreadItem(
                  id: kind.value,
                  agentPath: '/root/reviewer',
                  agentThreadId: 'child-${kind.value}',
                  kind: kind,
                ),
                onOpenSubagent: (id, {required name}) => opened.add((id, name)),
              ),
          ],
        ),
      ),
    );
    expect(find.text('Reviewer started'), findsOneWidget);
    expect(find.text('Reviewer finished'), findsOneWidget);
    expect(find.text('Reviewer interrupted'), findsOneWidget);
    expect(find.text('Reviewer updated'), findsOneWidget);
    await tester.tap(find.text('Reviewer finished'));
    await tester.pump();
    expect(opened, [('child-completed', 'Reviewer')]);
  });

  testWidgets('long agent names remain clickable on a narrow dark screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var opened = false;
    await tester.pumpWidget(
      _app(
        CodexSubagentActivity(
          item: _message('long', 'very_long_agent_name_' * 10, 'child'),
          onOpenSubagent: (_, {required name}) => opened = true,
        ),
        brightness: Brightness.dark,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('codex-subagent-open-long')));
    await tester.pump();
    expect(opened, isTrue);
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: motifTheme(brightness),
      home: Scaffold(body: child),
    );

CodexSubAgentActivityThreadItem _message(
  String id,
  String name,
  String threadId,
) => CodexSubAgentActivityThreadItem(
  id: id,
  agentPath: '/root/$name',
  agentThreadId: threadId,
  kind: CodexSubAgentActivityKind.completed,
);

CodexCommandExecutionThreadItem _command(String id) =>
    CodexCommandExecutionThreadItem(
      id: id,
      command: 'echo $id',
      cwd: const CodexLegacyAppPathString('/work'),
      commandActions: const [],
      status: CodexCommandExecutionStatus.completed,
    );

class _Client extends ChangeNotifier implements CodexAppServerClient {
  @override
  CodexConnectionState get state =>
      const CodexConnectionState(phase: CodexConnectionPhase.connected);
  @override
  Stream<CodexJsonEncodable> get typedMessages => const Stream.empty();
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
