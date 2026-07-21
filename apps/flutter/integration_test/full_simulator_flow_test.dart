// Full iOS-simulator UI flow against a live motifd on 127.0.0.1:7777.
//
// Run:
//   flutter test integration_test/full_simulator_flow_test.dart -d <simulator>
//
// The test skips gracefully when no local motifd is reachable.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/net/rpc_client.dart';
import 'package:motif/motif/state/app/app_state.dart';
import 'package:motif/motif/state/connection/connection_state.dart';
import 'package:motif/motif/state/workspace/connection/workspace_connection_view_model.dart';
import 'package:motif/motif/state/workspace/workspace_instance.dart';
import 'package:motif/motif/ui/app.dart';
import 'package:motif/motif/ui/screens/file_tree_panel.dart';
import 'package:motif/motif/terminal/terminal_painter.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'welcome → server → session → terminal → files → preview → diff',
    (tester) async {
      final probe = RpcClient()
        ..connect(host: '127.0.0.1', port: 7777, token: '');
      try {
        await probe.ping();
      } catch (_) {
        await probe.close();
        markTestSkipped('no motifd on 127.0.0.1:7777');
        return;
      }
      await probe.close();

      SharedPreferences.setMockInitialValues({});
      final app = await AppState.load();
      final stamp = DateTime.now().microsecondsSinceEpoch;
      final session = 'sim-flow-$stamp';
      const workdir = '/Users/feichao/Developer/flutter_ghostty';
      final fileName = '000_motif_sim_flow_$stamp.txt';
      var filePath = '$workdir/$fileName';
      String? serverId;
      WorkspaceInstance? activeWorkspace;
      final terminalFilePath = '$workdir/000_motif_terminal_$stamp.txt';
      final directKeysFilePath = '$workdir/000_motif_direct_keys_$stamp.txt';
      final interruptFilePath = '$workdir/000_motif_interrupt_$stamp.txt';
      final interruptStartedPath =
          '$workdir/000_motif_interrupt_started_$stamp.txt';

      Future<void> cleanup() async {
        final workspace = activeWorkspace;
        try {
          await workspace?.workspace.remove(directKeysFilePath);
        } catch (_) {}
        try {
          await workspace?.workspace.remove(interruptStartedPath);
        } catch (_) {}
        try {
          await workspace?.workspace.remove(interruptFilePath);
        } catch (_) {}
        try {
          await workspace?.workspace.remove(terminalFilePath);
        } catch (_) {}
        try {
          await workspace?.workspace.remove(filePath);
        } catch (_) {}
        try {
          await workspace?.attachment.detach();
        } catch (_) {}
        try {
          if (serverId != null) await app.destroySession(serverId, session);
        } catch (_) {}
        try {
          if (serverId != null) await app.disconnectServer(serverId);
        } catch (_) {}
      }

      try {
        await tester.pumpWidget(
          MotifScope(appState: app, child: const MotifApp()),
        );
        await tester.pumpAndSettle();

        expect(find.text('Welcome to motif'), findsOneWidget);
        expect(find.text('TAILSCALE'), findsOneWidget);

        await tester.tap(find.text('Add Server'));
        await tester.pumpAndSettle();
        await _enterField(tester, 'Name', 'Local motifd');
        await _enterField(tester, 'Host', '127.0.0.1');
        await _enterField(tester, 'Port', '7777');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        serverId = app.servers.activeId!;
        final server = app.serverInstance(serverId);

        await _pumpUntil(
          tester,
          () => server.access.state is ServerConnected,
          reason: 'app connects to local motifd',
        );
        expect(find.text('Local motifd'), findsWidgets);
        expect(server.isLive, isTrue);

        await tester.tap(find.byTooltip('Create session').last);
        await tester.pumpAndSettle();
        await _enterField(tester, 'Name', session);
        await _enterField(tester, 'Working directory', workdir);
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();

        await _pumpUntil(
          tester,
          () => server.viewModel.sessions.sessions.any(
            (candidate) => candidate.name == session,
          ),
          reason: 'new session appears',
        );
        await tester.tap(find.text(session).first);
        await tester.pumpAndSettle();
        activeWorkspace = app.workspaceForSession(serverId, session);
        final workspace = activeWorkspace;
        await _pumpUntil(
          tester,
          () => workspace.viewModel.connection.status is ConnAttached,
          reason: 'session attaches',
        );

        expect(find.byTooltip('New terminal'), findsOneWidget);
        await tester.tap(find.byTooltip('New terminal'));
        await tester.pumpAndSettle();
        await _pumpUntil(
          tester,
          () =>
              workspace.viewModel.terminal.ptys.isNotEmpty &&
              workspace.viewModel.views.items.any((v) => v.spec is PtyViewSpec),
          reason: 'terminal pty/view is created',
        );
        await _pumpUntil(
          tester,
          () => _sameRemotePath(workspace.workspace.activeCwd(), workdir),
          reason: 'terminal reports the session working directory',
          timeout: const Duration(seconds: 20),
        );

        final firstViewId = workspace.viewModel.views.activeViewId!;
        final firstPtyId = _activePtyId(workspace)!;
        await _sendCommand(tester, "printf terminal-ok > '$terminalFilePath'");
        await _pumpUntilAsync(tester, () async {
          try {
            final r = await workspace.workspace.read(terminalFilePath);
            return utf8.decode(base64Decode(r.contentB64)) == 'terminal-ok';
          } catch (_) {
            return false;
          }
        }, reason: 'terminal input executes a remote command');

        await workspace.terminal.activatePtyStream(firstPtyId);
        await workspace.terminal.writePty(firstPtyId, [
          ..."cat > '$directKeysFilePath'".codeUnits,
          0x0d,
        ]);
        await tester.pump(const Duration(milliseconds: 300));
        await _tapTerminalSurface(tester);
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft), isTrue);
        expect(
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight),
          isTrue,
        );
        await _tapTerminalSurface(tester);
        await tester.pump();
        expect(await tester.sendKeyEvent(LogicalKeyboardKey.enter), isTrue);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        expect(
          await tester.sendKeyEvent(LogicalKeyboardKey.keyD, character: 'd'),
          isTrue,
        );
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await _pumpUntilAsync(tester, () async {
          try {
            final r = await workspace.workspace.read(directKeysFilePath);
            final text = utf8.decode(
              base64Decode(r.contentB64),
              allowMalformed: true,
            );
            return _leftArrowByteCount(text) >= 1 &&
                _rightArrowByteCount(text) >= 1;
          } catch (_) {
            return false;
          }
        }, reason: 'terminal-focused keyboard arrows reach the PTY');

        final interruptCommand =
            "sh -c 'trap \"printf interrupted > $interruptFilePath; exit\" INT; printf started > $interruptStartedPath; sleep 10; printf bad > $interruptFilePath'";
        await workspace.terminal.activatePtyStream(firstPtyId);
        await workspace.terminal.writePty(firstPtyId, [
          ...interruptCommand.codeUnits,
          0x0d,
        ]);
        await _pumpUntilAsync(tester, () async {
          try {
            final r = await workspace.workspace.read(interruptStartedPath);
            return utf8.decode(base64Decode(r.contentB64)) == 'started';
          } catch (_) {
            return false;
          }
        }, reason: 'long-running terminal command starts');
        await _dragUntilVisible(
          tester,
          item: find.byTooltip('^C'),
          scrollable: find.byType(ListView).last,
          delta: const Offset(-280, 0),
          reason: 'Ctrl+C quick command becomes visible',
        );
        await tester.tap(find.byTooltip('^C').first);
        await tester.pumpAndSettle();
        await _pumpUntilAsync(tester, () async {
          try {
            final r = await workspace.workspace.read(interruptFilePath);
            return utf8.decode(base64Decode(r.contentB64)) == 'interrupted';
          } catch (_) {
            return false;
          }
        }, reason: 'Ctrl+C interrupts the running terminal command');

        await tester.tap(find.byTooltip('New terminal'));
        await tester.pumpAndSettle();
        await _pumpUntil(
          tester,
          () =>
              workspace.viewModel.terminal.ptys.length >= 2 &&
              _activePtyId(workspace) != null &&
              _activePtyId(workspace) != firstPtyId,
          reason: 'second terminal pty/view is created',
          timeout: const Duration(seconds: 20),
        );
        final secondPtyId = _activePtyId(workspace)!;
        expect(
          find.byKey(ValueKey('terminal-$firstPtyId'), skipOffstage: false),
          findsOneWidget,
          reason: 'first terminal surface remains mounted offstage',
        );
        expect(
          find.byKey(ValueKey('terminal-$secondPtyId'), skipOffstage: false),
          findsOneWidget,
          reason: 'second terminal surface is mounted',
        );
        await tester.tap(find.byKey(ValueKey('tab-$firstViewId')));
        await tester.pumpAndSettle();
        await _pumpUntil(
          tester,
          () => workspace.viewModel.views.activeViewId == firstViewId,
          reason: 'switches back to first terminal tab',
        );
        expect(
          find.byKey(ValueKey('terminal-$firstPtyId'), skipOffstage: false),
          findsOneWidget,
          reason: 'first terminal is still retained after tab switch',
        );

        await tester.tap(find.byTooltip('Terminal settings').last);
        await tester.pumpAndSettle();
        expect(find.text('Terminal'), findsWidgets);
        expect(find.text('Theme'), findsOneWidget);
        expect(find.text('Push notifications'), findsNothing);
        await tester.tap(find.text('Dark'));
        await tester.pumpAndSettle();
        await _popRoute(tester);

        await _dragUntilVisible(
          tester,
          item: find.byTooltip('cd'),
          scrollable: find.byType(ListView).last,
          delta: const Offset(-280, 0),
          reason: 'cd quick command chip becomes visible',
        );
        await tester.tap(find.byTooltip('cd').first);
        await tester.pumpAndSettle();
        expect(find.text('Change directory'), findsOneWidget);
        await tester.tap(
          find.byKey(const ValueKey('change-directory-confirm')),
        );
        await tester.pumpAndSettle();

        await _pumpUntil(
          tester,
          () => _sameRemotePath(workspace.workspace.activeCwd(), workdir),
          reason: 'cd here keeps the working directory active',
        );

        final treeRoot = workspace.workspace.activeCwd() ?? workdir;
        filePath = _joinRemote(treeRoot, fileName);
        await workspace.workspace.write(
          filePath,
          base64Encode(utf8.encode('hello from simulator flow\n')),
          force: true,
        );
        final rootEntries = await workspace.workspace.tree(treeRoot, depth: 1);
        expect(
          rootEntries.map((e) => e.name),
          contains(fileName),
          reason: 'motifd fs.tree should include the file before opening UI',
        );

        await tester.tap(find.byTooltip('Files').last);
        await tester.pumpAndSettle();
        await _pumpUntil(
          tester,
          () =>
              find.byType(FileTreePanel).evaluate().isNotEmpty &&
              find.byType(CircularProgressIndicator).evaluate().isEmpty,
          reason: 'file tree panel loads',
        );
        await _scrollUntilVisible(
          tester,
          find.text(fileName),
          reason: 'file tree shows test file',
        );
        await tester.tap(find.text(fileName));
        await tester.pumpAndSettle();
        await _pumpUntil(
          tester,
          () => _activeSpec(workspace) is PreviewViewSpec,
          reason: 'preview tab becomes active',
        );
        await _pumpUntil(
          tester,
          () => find
              .textContaining('hello from simulator flow')
              .evaluate()
              .isNotEmpty,
          reason: 'preview loads file content',
        );

        await tester.tap(find.byIcon(Icons.edit).last);
        await tester.pumpAndSettle();
        await tester.enterText(_previewEditor(), 'edited in simulator\n');
        await tester.tap(find.byIcon(Icons.save).last);
        await tester.pumpAndSettle();
        final edited = await workspace.workspace.read(filePath);
        expect(
          utf8.decode(base64Decode(edited.contentB64)),
          'edited in simulator\n',
        );

        await tester.tap(find.byTooltip('Git diff'));
        await tester.pumpAndSettle();
        expect(find.text('Git diff'), findsOneWidget);
        await _pumpUntil(
          tester,
          () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
          reason: 'git diff finishes loading',
        );
        await _popRoute(tester);

        await _dragUntilVisible(
          tester,
          item: find.byTooltip('Edit quick commands'),
          scrollable: find.byType(ListView).last,
          delta: const Offset(-280, 0),
          reason: 'quick command editor button becomes visible',
          maxDrags: 20,
        );
        await tester.tap(find.byTooltip('Edit quick commands').last);
        await tester.pumpAndSettle();
        expect(find.text('Quick commands'), findsOneWidget);
        await tester.tap(find.byTooltip('Command sets'));
        await tester.pumpAndSettle();
        expect(find.text('Command sets'), findsOneWidget);
        await _popRoute(tester);
        await _popRoute(tester);
      } finally {
        await cleanup();
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

ViewSpec? _activeSpec(WorkspaceInstance workspace) {
  final id = workspace.viewModel.views.activeViewId;
  for (final v in workspace.viewModel.views.items) {
    if (v.id == id) return v.spec;
  }
  return null;
}

String? _activePtyId(WorkspaceInstance workspace) {
  final spec = _activeSpec(workspace);
  return spec is PtyViewSpec ? spec.ptyId : null;
}

String _joinRemote(String dir, String name) =>
    dir.endsWith('/') ? '$dir$name' : '$dir/$name';

bool _sameRemotePath(String? a, String b) {
  if (a == null || a.isEmpty) return false;
  String normalize(String p) =>
      p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;
  return normalize(a) == normalize(b);
}

Future<void> _enterField(
  WidgetTester tester,
  String label,
  String value,
) async {
  final finder = find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
    description: 'TextField(labelText: $label)',
  );
  expect(finder, findsOneWidget);
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Finder _previewEditor() => find.byWidgetPredicate(
  (w) => w is TextField && w.expands && w.maxLines == null,
  description: 'Preview editor TextField',
);

Finder _commandInput() => find.byWidgetPredicate(
  (w) =>
      w is TextField &&
      (w.decoration?.hintText == 'type or speak…' ||
          w.decoration?.hintText == 'type a command…'),
  description: 'Terminal command input',
);

Future<void> _sendCommand(WidgetTester tester, String command) async {
  await tester.enterText(_commandInput(), command);
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.arrow_upward).last);
  await tester.pumpAndSettle();
}

Future<void> _tapTerminalSurface(WidgetTester tester) async {
  final terminal = find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is TerminalPainter,
    description: 'Ghostty terminal surface',
  );
  expect(terminal, findsWidgets);
  await tester.tap(terminal.first, warnIfMissed: false);
  await tester.pump();
}

int _leftArrowByteCount(String text) =>
    _patternCount(text, '\x1b[D') + _patternCount(text, '\x1bOD');

int _rightArrowByteCount(String text) =>
    _patternCount(text, '\x1b[C') + _patternCount(text, '\x1bOC');

int _patternCount(String text, String pattern) {
  var count = 0;
  var start = 0;
  while (true) {
    final index = text.indexOf(pattern, start);
    if (index < 0) return count;
    count++;
    start = index + pattern.length;
  }
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
  fail('Timed out waiting for $reason');
}

Future<void> _pumpUntilAsync(
  WidgetTester tester,
  Future<bool> Function() condition, {
  required String reason,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await tester.pump(const Duration(milliseconds: 200));
  }
  fail('Timed out waiting for $reason');
}

Future<void> _scrollUntilVisible(
  WidgetTester tester,
  Finder item, {
  required String reason,
}) async {
  if (item.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      item,
      320,
      scrollable: find.byType(Scrollable).last,
      maxScrolls: 80,
    );
    await tester.pumpAndSettle();
  }
  expect(item, findsOneWidget, reason: reason);
}

Future<void> _popRoute(WidgetTester tester) async {
  final didPop = await tester.binding.handlePopRoute();
  expect(didPop, isTrue);
  await tester.pumpAndSettle();
}

Future<void> _dragUntilVisible(
  WidgetTester tester, {
  required Finder item,
  required Finder scrollable,
  required Offset delta,
  required String reason,
  int maxDrags = 10,
}) async {
  for (var i = 0; i < maxDrags; i++) {
    if (item.evaluate().isNotEmpty) return;
    await tester.drag(scrollable, delta);
    await tester.pumpAndSettle();
  }
  fail('Timed out waiting for $reason');
}
