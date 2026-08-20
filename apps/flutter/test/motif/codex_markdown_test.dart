import 'dart:ui' show PointerDeviceKind;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/ui/theme/codex_typography.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/codex_markdown.dart';

void main() {
  testWidgets('uses one parent selection area across Markdown blocks', (
    tester,
  ) async {
    SelectedContent? selection;
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: SelectionArea(
            onSelectionChanged: (value) => selection = value,
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CodexMarkdown('First block'),
                CodexMarkdown('```text\nCode block\n```'),
                CodexMarkdown('- List item'),
                CodexMarkdown('Last block'),
              ],
            ),
          ),
        ),
      ),
    );

    final markdown = find.byType(CodexMarkdown);
    expect(
      find.descendant(of: markdown, matching: find.byType(SelectableText)),
      findsNothing,
    );
    expect(
      find.descendant(of: markdown, matching: find.byType(RichText)),
      findsWidgets,
    );

    final first = tester.getRect(find.text('First block'));
    final last = tester.getRect(find.text('Last block'));
    final gesture = await tester.startGesture(
      Offset(first.left + 1, first.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveTo(Offset(last.right - 1, last.center.dy));
    await gesture.up();
    await tester.pump();

    expect(selection?.plainText, contains('First block'));
    expect(selection?.plainText, contains('Code block'));
    expect(selection?.plainText, contains('List item'));
    expect(selection?.plainText, contains('Last block'));
  });

  testWidgets('fenced code is highlighted without per-token backgrounds', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: const Scaffold(
          body: CodexMarkdown('''
Inline `token`.

```json
{"admin": true}
```
'''),
        ),
      ),
    );

    final block = find.byKey(const ValueKey('codex-markdown-code-block'));
    expect(block, findsOneWidget);

    final blockText = tester.widget<SelectableText>(
      find.descendant(of: block, matching: find.byType(SelectableText)),
    );
    final blockSpans = _flatten(blockText.textSpan!);
    expect(blockText.textSpan?.style?.fontSize, CodexType.body.fontSize);
    expect(
      blockSpans.map((span) => span.style?.backgroundColor),
      everyElement(isNull),
    );
    expect(
      blockSpans
          .map((span) => span.style?.color)
          .whereType<Color>()
          .toSet()
          .length,
      greaterThan(1),
    );

    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(
      markdown.styleSheet?.code?.fontSize,
      markdown.styleSheet?.p?.fontSize,
    );
    expect(
      markdown.styleSheet?.blockquote?.fontSize,
      markdown.styleSheet?.p?.fontSize,
    );
    expect(
      markdown.styleSheet?.code?.backgroundColor,
      MotifColors.light.subtleFill,
    );
  });

  testWidgets('ordered-list markers stay on one line', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: const Scaffold(body: CodexMarkdown('1. One\n2. Two\n3. Three')),
      ),
    );

    final marker = find.text('2.');
    final item = find.text('Two');
    expect(marker, findsOneWidget);
    expect(item, findsOneWidget);
    expect(
      tester.getSize(marker).height,
      lessThanOrEqualTo(tester.getSize(item).height),
    );
  });

  testWidgets('list items have eight pixels of vertical spacing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: const Scaffold(body: CodexMarkdown('- One\n- Two')),
      ),
    );

    final first = tester.getRect(find.text('One'));
    final second = tester.getRect(find.text('Two'));
    expect(second.top - first.bottom, MotifSpacing.sm);
  });

  testWidgets('streaming Markdown preserves stable blocks and recovers', (
    tester,
  ) async {
    var source = 'First **block**\n\nSecond';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return CodexStreamingMarkdown(source);
            },
          ),
        ),
      ),
    );

    Finder markdownWithData(String data) => find.byWidgetPredicate(
      (widget) => widget is MarkdownBody && widget.data == data,
    );

    final stable = markdownWithData('First **block**\n\n');
    expect(stable, findsOneWidget);
    expect(markdownWithData('Second'), findsOneWidget);
    final stableElement = tester.element(stable);

    update(() => source += ' grows');
    await tester.pump();

    expect(identical(tester.element(stable), stableElement), isTrue);
    expect(markdownWithData('Second grows'), findsOneWidget);

    update(() => source += '\n\n```dart\nfinal value = 1;');
    await tester.pump();

    expect(
      find.byKey(const ValueKey('codex-markdown-code-block')),
      findsOneWidget,
    );

    update(() => source += '\n```\n\nAfter **bold**');
    await tester.pump();

    expect(find.text('After bold'), findsOneWidget);

    update(() => source = 'Replacement *content*');
    await tester.pump();

    expect(stable, findsNothing);
    expect(markdownWithData('Replacement *content*'), findsOneWidget);
    expect(find.text('Replacement content'), findsOneWidget);
  });
}

Iterable<TextSpan> _flatten(TextSpan span) sync* {
  yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) yield* _flatten(child);
  }
}
