import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/settings.dart';
import 'package:motif/motif/state/sticky_modifiers.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/quick_command_row.dart';

Uint8List _bytes(List<int> bytes) => Uint8List.fromList(bytes);

QuickCommand _key(String id, String label, List<int> bytes) =>
    QuickCommand.bytes(id, label, bytes);

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
    await _pumpRow(tester, [_key('tab', 'Tab', QuickKeys.tab)]);

    expect(find.byTooltip('Tab'), findsOneWidget);
    expect(find.byTooltip('Ctrl'), findsNothing);
    expect(find.byTooltip('Alt'), findsNothing);
    expect(find.byTooltip('Shift'), findsNothing);
  });

  testWidgets('sends built-in key bytes and inserts non-immediate snippets', (
    tester,
  ) async {
    final harness = await _pumpRow(tester, [
      _key('tab', 'Tab', QuickKeys.tab),
      _key('esc', 'Esc', QuickKeys.esc),
      _key('up', 'Up', QuickKeys.up),
      QuickCommand.text('insert', 'insert', 'hello', sendImmediately: false),
    ]);

    await tester.tap(find.byTooltip('Tab'));
    await tester.tap(find.byTooltip('Esc'));
    await tester.tap(find.byTooltip('Up'));
    await tester.tap(find.byTooltip('insert'));
    await tester.pump();

    expect(harness.sent, [
      _bytes(QuickKeys.tab),
      _bytes(QuickKeys.esc),
      _bytes(QuickKeys.up),
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
      _key('c', 'c', [0x63]),
      _key('b', 'b', [0x62]),
      _key('a', 'a', [0x61]),
      _key('1', '1', [0x31]),
    ]);

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.tap(find.byTooltip('c'));
    await tester.pump();
    expect(harness.sent.last, _bytes([0x03]));
    expect(harness.modifiers.ctrl, StickyLevel.inactive);

    await tester.tap(find.byTooltip('Alt'));
    await tester.tap(find.byTooltip('b'));
    await tester.pump();
    expect(harness.sent.last, _bytes([0x1b, 0x62]));
    expect(harness.modifiers.alt, StickyLevel.inactive);

    await tester.tap(find.byTooltip('Shift'));
    await tester.tap(find.byTooltip('a'));
    await tester.pump();
    expect(harness.sent.last, _bytes([0x41]));
    expect(harness.modifiers.shift, StickyLevel.inactive);

    await tester.tap(find.byTooltip('Shift'));
    await tester.tap(find.byTooltip('1'));
    await tester.pump();
    expect(harness.sent.last, _bytes([0x21]));
    expect(harness.modifiers.shift, StickyLevel.inactive);

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.tap(find.byTooltip('Alt'));
    await tester.tap(find.byTooltip('c'));
    await tester.pump();
    expect(harness.sent.last, _bytes([0x1b, 0x03]));
    expect(harness.modifiers.ctrl, StickyLevel.inactive);
    expect(harness.modifiers.alt, StickyLevel.inactive);
  });

  testWidgets('keeps locked modifiers across repeated keys', (tester) async {
    final harness = await _pumpRow(tester, [
      QuickCommand.ctrlModifier('ctrl'),
      _key('c', 'c', [0x63]),
    ]);

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.tap(find.byTooltip('Ctrl'));
    await tester.tap(find.byTooltip('c'));
    await tester.tap(find.byTooltip('c'));
    await tester.pump();

    expect(harness.sent, [
      _bytes([0x03]),
      _bytes([0x03]),
    ]);
    expect(harness.modifiers.ctrl, StickyLevel.locked);
  });

  testWidgets('long-press repeats immediate commands without modifiers', (
    tester,
  ) async {
    final harness = await _pumpRow(tester, [_key('tab', 'Tab', QuickKeys.tab)]);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byTooltip('Tab')),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 220));

    expect(harness.sent.length, greaterThan(1));
    expect(harness.sent, everyElement(_bytes(QuickKeys.tab)));

    final sentWhilePressed = harness.sent.length;
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 220));

    expect(harness.sent.length, sentWhilePressed);
  });

  testWidgets('long-press does not repeat while a modifier is armed', (
    tester,
  ) async {
    final harness = await _pumpRow(tester, [
      QuickCommand.ctrlModifier('ctrl'),
      _key('c', 'c', [0x63]),
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

    expect(harness.sent, [
      _bytes([0x03]),
    ]);
    expect(harness.modifiers.ctrl, StickyLevel.inactive);
  });

  testWidgets('combines baked-in modifiers with payloads', (tester) async {
    final harness = await _pumpRow(tester, [
      QuickCommand.bytes(
        'combo',
        'Ctrl Alt d',
        [0x64],
        modifiers: const QuickCommandModifiers(ctrl: true, alt: true),
      ),
      QuickCommand.bytes('shift', 'Shift x', [
        0x78,
      ], modifiers: const QuickCommandModifiers(shift: true)),
    ]);

    await tester.tap(find.byTooltip('Ctrl Alt d'));
    await tester.tap(find.byTooltip('Shift x'));
    await tester.pump();

    expect(harness.sent[0], _bytes([0x1b, 0x04]));
    expect(harness.sent[1], _bytes([0x58]));
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

    expect(
      harness.sent.single,
      _bytes([
        0x1b,
        0x5b,
        0x32,
        0x30,
        0x30,
        0x7e,
        ...'clip'.codeUnits,
        0x1b,
        0x5b,
        0x32,
        0x30,
        0x31,
        0x7e,
      ]),
    );
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

    expect(
      harness.sent.single,
      _bytes([
        0x1b,
        0x5b,
        0x32,
        0x30,
        0x30,
        0x7e,
        ...utf8.encode('中文🙂'),
        0x1b,
        0x5b,
        0x32,
        0x30,
        0x31,
        0x7e,
      ]),
    );
  });
}

class _Harness {
  final StickyModifiers modifiers = StickyModifiers();
  final List<Uint8List> sent = [];
  final List<String> inserted = [];
  int cdCount = 0;
  int editCount = 0;
}
