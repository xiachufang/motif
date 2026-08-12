import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/codex_markdown.dart';

void main() {
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

    final inlineText = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            widget.textSpan?.toPlainText().contains('Inline token.') == true,
      ),
    );
    final token = _flatten(
      inlineText.textSpan!,
    ).singleWhere((span) => span.text == 'token');
    expect(token.style?.backgroundColor, MotifColors.light.subtleFill);
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
}

Iterable<TextSpan> _flatten(TextSpan span) sync* {
  yield span;
  for (final child in span.children ?? const <InlineSpan>[]) {
    if (child is TextSpan) yield* _flatten(child);
  }
}
