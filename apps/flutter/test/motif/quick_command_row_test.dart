import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/state/workspace/terminal/sticky_modifiers.dart';
import 'package:motif/motif/terminal/terminal_key.dart';
import 'package:motif/motif/terminal/terminal_session.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/quick_command_row.dart';

Uint8List _bytes(List<int> bytes) => Uint8List.fromList(bytes);

QuickCommand _key(String id, String label, String keyId) =>
    QuickCommand.key(id, label, keyId);

Future<_Harness> _pumpRow(
  WidgetTester tester,
  List<QuickCommand> commands,
) async {
  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      theme: motifTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: QuickCommandRow(
            commands: commands,
            modifiers: harness.modifiers,
            onSendBytes: harness.sent.add,
            onSendKey: harness.keys.add,
            onPaste: harness.pastes.add,
            onInsertText: harness.inserted.add,
            onChangeDirectory: () => harness.cdCount++,
            onEdit: () => harness.editCount++,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return harness;
}

void main() {
  testWidgets('renders only configured quick commands', (tester) async {
    await _pumpRow(tester, [_key('tab', 'Tab', TerminalKeyIds.tab)]);

    expect(find.byTooltip('Tab'), findsOneWidget);
    expect(find.byTooltip('Ctrl'), findsNothing);
    expect(find.byTooltip('Alt'), findsNothing);
    expect(find.byTooltip('Shift'), findsNothing);
  });

  testWidgets('sends semantic key events and inserts non-immediate snippets', (
    tester,
  ) async {
    final harness = await _pumpRow(tester, [
      _key('tab', 'Tab', TerminalKeyIds.tab),
      _key('esc', 'Esc', TerminalKeyIds.escape),
      _key('up', 'Up', TerminalKeyIds.arrowUp),
      QuickCommand.text('insert', 'insert', 'hello', sendImmediately: false),
    ]);

    await tester.tap(find.byTooltip('Tab'));
    await tester.tap(find.byTooltip('Esc'));
    await tester.tap(find.byTooltip('Up'));
    await tester.tap(find.byTooltip('insert'));
    await tester.pump();

    expect(harness.keys.map((key) => key.keyId), [
      TerminalKeyIds.tab,
      TerminalKeyIds.tab,
      TerminalKeyIds.escape,
      TerminalKeyIds.escape,
      TerminalKeyIds.arrowUp,
      TerminalKeyIds.arrowUp,
    ]);
    expect(harness.keys.map((key) => key.action), [
      TerminalKeyAction.press,
      TerminalKeyAction.release,
      TerminalKeyAction.press,
      TerminalKeyAction.release,
      TerminalKeyAction.press,
      TerminalKeyAction.release,
    ]);
    expect(harness.inserted, ['hello']);
  });

  testWidgets('applies armed sticky modifier combinations once', (
    tester,
  ) async {
    final harness = await _pumpRow(tester, [
      QuickCommand.ctrlModifier('ctrl'),
      QuickCommand.altModifier('alt'),
      QuickCommand.shiftModifier('shift'),
      _key('c', 'c', TerminalKeyIds.character('c')),
      _key('b', 'b', TerminalKeyIds.character('b')),
      _key('a', 'a', TerminalKeyIds.character('a')),
      _key('1', '1', TerminalKeyIds.character('1')),
    ]);

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.tap(find.byTooltip('c'));
    await tester.pump();
    expect(harness.keys[harness.keys.length - 2].modifiers.ctrl, isTrue);
    expect(harness.modifiers.ctrl, StickyLevel.inactive);

    await tester.tap(find.byTooltip('Alt'));
    await tester.tap(find.byTooltip('b'));
    await tester.pump();
    expect(harness.keys[harness.keys.length - 2].modifiers.alt, isTrue);
    expect(harness.modifiers.alt, StickyLevel.inactive);

    await tester.tap(find.byTooltip('Shift'));
    await tester.tap(find.byTooltip('a'));
    await tester.pump();
    expect(harness.keys[harness.keys.length - 2].modifiers.shift, isTrue);
    expect(harness.modifiers.shift, StickyLevel.inactive);

    await tester.tap(find.byTooltip('Shift'));
    await tester.tap(find.byTooltip('1'));
    await tester.pump();
    expect(harness.keys[harness.keys.length - 2].modifiers.shift, isTrue);
    expect(harness.modifiers.shift, StickyLevel.inactive);

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.tap(find.byTooltip('Alt'));
    await tester.tap(find.byTooltip('c'));
    await tester.pump();
    final ctrlAlt = harness.keys[harness.keys.length - 2].modifiers;
    expect(ctrlAlt.ctrl, isTrue);
    expect(ctrlAlt.alt, isTrue);
    expect(harness.modifiers.ctrl, StickyLevel.inactive);
    expect(harness.modifiers.alt, StickyLevel.inactive);
  });

  testWidgets('keeps locked modifiers across repeated keys', (tester) async {
    final harness = await _pumpRow(tester, [
      QuickCommand.ctrlModifier('ctrl'),
      _key('c', 'c', TerminalKeyIds.character('c')),
    ]);

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.tap(find.byTooltip('Ctrl'));
    await tester.tap(find.byTooltip('c'));
    await tester.tap(find.byTooltip('c'));
    await tester.pump();

    expect(harness.keys, hasLength(4));
    expect(
      harness.keys.where((key) => key.action == TerminalKeyAction.press),
      everyElement(
        isA<TerminalKeyInput>().having(
          (key) => key.modifiers.ctrl,
          'ctrl',
          isTrue,
        ),
      ),
    );
    expect(harness.modifiers.ctrl, StickyLevel.locked);
  });

  testWidgets('long-press repeats immediate commands without modifiers', (
    tester,
  ) async {
    final harness = await _pumpRow(tester, [
      _key('tab', 'Tab', TerminalKeyIds.tab),
    ]);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Tab')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 220));

    expect(harness.keys.length, greaterThan(1));
    expect(harness.keys.first.action, TerminalKeyAction.press);
    expect(
      harness.keys.skip(1),
      everyElement(
        isA<TerminalKeyInput>().having(
          (key) => key.action,
          'action',
          TerminalKeyAction.repeat,
        ),
      ),
    );

    final sentWhilePressed = harness.keys.length;
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 220));

    expect(harness.keys.length, sentWhilePressed + 1);
    expect(harness.keys.last.action, TerminalKeyAction.release);
  });

  testWidgets('long-press does not repeat while a modifier is armed', (
    tester,
  ) async {
    final harness = await _pumpRow(tester, [
      QuickCommand.ctrlModifier('ctrl'),
      _key('c', 'c', TerminalKeyIds.character('c')),
    ]);

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('c')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 220));
    await gesture.up();
    await tester.pump();

    expect(harness.keys, hasLength(2));
    expect(harness.keys.first.action, TerminalKeyAction.press);
    expect(harness.keys.first.modifiers.ctrl, isTrue);
    expect(harness.keys.last.action, TerminalKeyAction.release);
    expect(harness.modifiers.ctrl, StickyLevel.inactive);
  });

  testWidgets('combines baked-in modifiers with payloads', (tester) async {
    final harness = await _pumpRow(tester, [
      QuickCommand.key(
        'combo',
        'Ctrl Alt d',
        TerminalKeyIds.character('d'),
        modifiers: const QuickCommandModifiers(ctrl: true, alt: true),
      ),
      QuickCommand.key(
        'shift',
        'Shift x',
        TerminalKeyIds.character('x'),
        modifiers: const QuickCommandModifiers(shift: true),
      ),
    ]);

    await tester.tap(find.byTooltip('Ctrl Alt d'));
    await tester.tap(find.byTooltip('Shift x'));
    await tester.pump();

    expect(harness.keys[0].modifiers.ctrl, isTrue);
    expect(harness.keys[0].modifiers.alt, isTrue);
    expect(harness.keys[2].modifiers.shift, isTrue);
  });

  testWidgets('paste, cd, and edit route to their callbacks', (tester) async {
    final harness = await _pumpRow(tester, [
      QuickCommand.paste('paste'),
      QuickCommand.cd('cd'),
    ]);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': 'clip'};
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.tap(find.byTooltip('Paste'));
    await tester.tap(find.byTooltip('cd'));
    await tester.tap(find.byTooltip('Edit quick commands'));
    await tester.pump();

    expect(harness.pastes.single, _bytes('clip'.codeUnits));
    expect(harness.cdCount, 1);
    expect(harness.editCount, 1);
  });

  testWidgets('paste sends UTF-8 for non-ASCII clipboard text', (tester) async {
    final harness = await _pumpRow(tester, [QuickCommand.paste('paste')]);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') {
          return <String, Object?>{'text': '中文🙂'};
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.tap(find.byTooltip('Paste'));
    await tester.pump();

    expect(harness.pastes.single, _bytes(utf8.encode('中文🙂')));
  });
}

class _Harness {
  final StickyModifiers modifiers = StickyModifiers();
  final List<Uint8List> sent = [];
  final List<TerminalKeyInput> keys = [];
  final List<Uint8List> pastes = [];
  final List<String> inserted = [];
  int cdCount = 0;
  int editCount = 0;
}
