import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/ui/widgets/tab_selection_area.dart';

Offset _textOffsetToPosition(RenderParagraph paragraph, int offset) {
  const caret = Rect.fromLTWH(0, 0, 2, 20);
  final localOffset = paragraph.getOffsetForCaret(
    TextPosition(offset: offset),
    caret,
  );
  return paragraph.localToGlobal(
    Offset(localOffset.dx, paragraph.size.height / 2),
  );
}

void main() {
  testWidgets('clears selected text when its tab becomes inactive', (
    tester,
  ) async {
    Widget build({required bool tabActive}) => MaterialApp(
      home: Scaffold(
        body: TabSelectionArea(
          tabActive: tabActive,
          child: const Text('select this text'),
        ),
      ),
    );

    await tester.pumpWidget(build(tabActive: true));
    final paragraph = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.text('select this text'),
        matching: find.byType(RichText),
      ),
    );
    final gesture = await tester.startGesture(
      _textOffsetToPosition(paragraph, 1),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(_textOffsetToPosition(paragraph, 7));
    await gesture.up();
    await tester.pump();
    expect(paragraph.selections, isNotEmpty);

    await tester.pumpWidget(build(tabActive: false));
    await tester.pump();
    expect(paragraph.selections, isEmpty);
  });
}
