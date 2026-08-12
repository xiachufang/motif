import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../theme/motif_theme.dart';
import 'syntax_highlight.dart';

/// Lightweight renderer used while a protocol item is still streaming.
///
/// Full Markdown parsing and syntax highlighting are intentionally deferred
/// until item completion. A surrounding [SelectionArea] still makes this text
/// selectable without creating a separate selection tree per update.
class CodexStreamingText extends StatelessWidget {
  const CodexStreamingText(this.data, {required this.style, super.key});

  final String data;
  final TextStyle style;

  @override
  Widget build(BuildContext context) => Text(data, style: style);
}

/// Motif-styled Markdown for text received from or sent to Codex.
///
/// Navigation labels and other application chrome intentionally remain plain
/// [Text]. This widget is for protocol content such as messages, plans, tool
/// output, approval explanations, and questionnaire copy.
class CodexMarkdown extends StatelessWidget {
  const CodexMarkdown(
    this.data, {
    super.key,
    this.style,
    this.selectable = true,
    this.softLineBreak = true,
    this.fitContent = false,
    this.blockSpacing = MotifSpacing.lg,
    this.onTapFileLink,
    this.imageBuilder,
  });

  final String data;
  final TextStyle? style;
  final bool selectable;
  final bool softLineBreak;
  final bool fitContent;
  final double blockSpacing;
  final ValueChanged<String>? onTapFileLink;
  final MarkdownImageBuilder? imageBuilder;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final parentSelection = SelectionContainer.maybeOf(context);
    final usesParentSelection = selectable && parentSelection != null;
    final buildsSelectableText = selectable && !usesParentSelection;
    final body = (style ?? MotifType.body).copyWith(
      color: style?.color ?? c.textPrimary,
      height: style?.height ?? 1.5,
    );
    final secondary = body.copyWith(color: c.textSecondary);
    final inlineCode = MotifType.mono.copyWith(
      color: c.textPrimary,
      backgroundColor: c.subtleFill,
      height: 1.45,
    );
    final listBuilder = _CompactMarkdownListBuilder(
      bodyStyle: body,
      selectable: selectable,
      softLineBreak: softLineBreak,
      onTapFileLink: onTapFileLink,
      imageBuilder: imageBuilder,
    );

    final markdown = MarkdownBody(
      data: data,
      selectable: buildsSelectableText,
      fitContent: fitContent,
      softLineBreak: softLineBreak,
      imageBuilder: imageBuilder,
      styleSheet: MarkdownStyleSheet(
        p: body,
        a: body.copyWith(
          color: c.accent,
          decoration: TextDecoration.underline,
          decorationColor: c.accent,
        ),
        h1: MotifType.display.copyWith(color: c.textPrimary, height: 1.3),
        h2: MotifType.title.copyWith(color: c.textPrimary, height: 1.35),
        h3: MotifType.headline.copyWith(color: c.textPrimary, height: 1.4),
        h4: MotifType.callout.copyWith(color: c.textPrimary, height: 1.4),
        h5: MotifType.callout.copyWith(color: c.textSecondary, height: 1.4),
        h6: MotifType.caption.copyWith(color: c.textSecondary, height: 1.4),
        em: body.copyWith(fontStyle: FontStyle.italic),
        strong: body.copyWith(fontWeight: FontWeight.w700),
        del: secondary.copyWith(decoration: TextDecoration.lineThrough),
        code: inlineCode,
        codeblockDecoration: BoxDecoration(
          color: c.subtleFill,
          border: Border.all(color: c.border),
          borderRadius: BorderRadius.circular(8),
        ),
        codeblockPadding: const EdgeInsets.all(MotifSpacing.sm),
        blockquote: secondary,
        blockquoteDecoration: BoxDecoration(
          color: c.subtleFill,
          border: Border(left: BorderSide(color: c.accent, width: 3)),
          borderRadius: BorderRadius.circular(4),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(
          MotifSpacing.sm,
          MotifSpacing.xs,
          MotifSpacing.sm,
          MotifSpacing.xs,
        ),
        blockSpacing: blockSpacing,
        listIndent: MotifSpacing.lg,
        listBullet: body,
        listBulletPadding: const EdgeInsets.only(right: MotifSpacing.sm),
        tableBorder: TableBorder.all(color: c.border),
        tableHead: MotifType.callout.copyWith(color: c.textPrimary),
        tableBody: MotifType.subhead.copyWith(color: c.textPrimary),
        tableCellsPadding: const EdgeInsets.symmetric(
          horizontal: MotifSpacing.sm,
          vertical: MotifSpacing.xs,
        ),
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: c.border)),
        ),
      ),
      builders: {
        'pre': _MarkdownCodeBlockBuilder(
          colors: c,
          padding: const EdgeInsets.all(MotifSpacing.sm),
          selectable: buildsSelectableText,
          usesParentSelection: usesParentSelection,
        ),
        'ul': listBuilder,
        'ol': listBuilder,
      },
      onTapLink: (_, href, _) {
        if (href == null) return;
        final uri = Uri.tryParse(href);
        if (uri != null &&
            const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
          unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
        } else {
          onTapFileLink?.call(href);
        }
      },
    );
    if (!selectable && parentSelection != null) {
      return SelectionContainer.disabled(child: markdown);
    }
    return markdown;
  }
}

class _CompactMarkdownListBuilder extends MarkdownElementBuilder {
  _CompactMarkdownListBuilder({
    required this.bodyStyle,
    required this.selectable,
    required this.softLineBreak,
    required this.onTapFileLink,
    required this.imageBuilder,
  });

  final TextStyle bodyStyle;
  final bool selectable;
  final bool softLineBreak;
  final ValueChanged<String>? onTapFileLink;
  final MarkdownImageBuilder? imageBuilder;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final ordered = element.tag == 'ol';
    final start = ordered
        ? int.tryParse(element.attributes['start'] ?? '') ?? 1
        : 1;
    final items = <String>[];
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'li') {
        items.add(_markdownFromNodes(child.children).trim());
      }
    }
    return _CompactMarkdownList(
      items: items,
      ordered: ordered,
      start: start,
      bodyStyle: bodyStyle,
      selectable: selectable,
      softLineBreak: softLineBreak,
      onTapFileLink: onTapFileLink,
      imageBuilder: imageBuilder,
    );
  }
}

class _CompactMarkdownList extends StatelessWidget {
  const _CompactMarkdownList({
    required this.items,
    required this.ordered,
    required this.start,
    required this.bodyStyle,
    required this.selectable,
    required this.softLineBreak,
    required this.onTapFileLink,
    required this.imageBuilder,
  });

  final List<String> items;
  final bool ordered;
  final int start;
  final TextStyle bodyStyle;
  final bool selectable;
  final bool softLineBreak;
  final ValueChanged<String>? onTapFileLink;
  final MarkdownImageBuilder? imageBuilder;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final markerStyle = ordered
        ? bodyStyle
        : bodyStyle.copyWith(fontWeight: FontWeight.w700);
    final labels = [
      for (var index = 0; index < items.length; index++)
        ordered ? '${start + index}.' : '•',
    ];
    final markerWidth = labels
        .map((label) => _measureText(context, label, markerStyle))
        .fold<double>(
          0,
          (width, candidate) => candidate > width ? candidate : width,
        );
    return Padding(
      padding: const EdgeInsets.only(left: MotifSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < items.length; index++)
            Padding(
              padding: EdgeInsets.only(top: index == 0 ? 0 : MotifSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.zero,
                    child: SizedBox(
                      width: markerWidth,
                      child: Text(
                        labels[index],
                        maxLines: 1,
                        softWrap: false,
                        textAlign: TextAlign.right,
                        style: markerStyle,
                      ),
                    ),
                  ),
                  const SizedBox(width: MotifSpacing.sm),
                  Expanded(
                    child: CodexMarkdown(
                      items[index],
                      style: bodyStyle,
                      selectable: selectable,
                      softLineBreak: softLineBreak,
                      blockSpacing: MotifSpacing.sm,
                      onTapFileLink: onTapFileLink,
                      imageBuilder: imageBuilder,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  double _measureText(BuildContext context, String text, TextStyle style) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    return painter.width.ceilToDouble();
  }
}

String _markdownFromNodes(List<md.Node>? nodes) =>
    (nodes ?? const <md.Node>[]).map(_markdownFromNode).join();

String _markdownFromNode(md.Node node) {
  if (node is md.Text) return _escapeMarkdownText(node.text);
  if (node is! md.Element) return '';
  final content = _markdownFromNodes(node.children);
  return switch (node.tag) {
    'p' => content,
    'strong' => '**$content**',
    'em' => '*$content*',
    'del' => '~~$content~~',
    'code' => _inlineCode(node.textContent),
    'a' => '[$content](${node.attributes['href'] ?? ''})',
    'img' =>
      '![${node.attributes['alt'] ?? node.textContent}](${node.attributes['src'] ?? ''})',
    'br' => '\n',
    'pre' => '\n```\n${node.textContent}\n```\n',
    'blockquote' =>
      node.textContent.split('\n').map((line) => '> $line').join('\n'),
    'ul' => _markdownListFromElement(node, ordered: false),
    'ol' => _markdownListFromElement(node, ordered: true),
    _ => content,
  };
}

String _markdownListFromElement(md.Element element, {required bool ordered}) {
  final start = ordered
      ? int.tryParse(element.attributes['start'] ?? '') ?? 1
      : 1;
  final result = <String>[];
  var index = 0;
  for (final child in element.children ?? const <md.Node>[]) {
    if (child is! md.Element || child.tag != 'li') continue;
    final marker = ordered ? '${start + index}. ' : '- ';
    final source = _markdownFromNodes(child.children).trim();
    final lines = source.split('\n');
    result.add('$marker${lines.first}');
    result.addAll(lines.skip(1).map((line) => '  $line'));
    index++;
  }
  return '\n${result.join('\n')}\n';
}

String _inlineCode(String source) {
  final fence = source.contains('`') ? '``' : '`';
  return '$fence$source$fence';
}

String _escapeMarkdownText(String source) => source.replaceAllMapped(
  RegExp(r'([\\*_~\[\]`])'),
  (match) => '\\${match[0]}',
);

class _MarkdownCodeBlockBuilder extends MarkdownElementBuilder {
  _MarkdownCodeBlockBuilder({
    required this.colors,
    required this.padding,
    required this.selectable,
    required this.usesParentSelection,
  });

  final MotifColors colors;
  final EdgeInsets padding;
  final bool selectable;
  final bool usesParentSelection;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    md.Element? codeElement;
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element && child.tag == 'code') {
        codeElement = child;
        break;
      }
    }

    final source = (codeElement ?? element).textContent.replaceFirst(
      RegExp(r'\n$'),
      '',
    );
    final span = MotifSyntaxHighlight.buildForLanguage(
      source: source,
      language: _languageFrom(codeElement),
      colors: colors,
    );
    final text = selectable ? SelectableText.rich(span) : Text.rich(span);

    if (usesParentSelection) {
      return Padding(
        key: const ValueKey('codex-markdown-code-block'),
        padding: padding,
        child: text,
      );
    }

    return SingleChildScrollView(
      key: const ValueKey('codex-markdown-code-block'),
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: text,
    );
  }

  String? _languageFrom(md.Element? codeElement) {
    final classes = codeElement?.attributes['class']?.split(RegExp(r'\s+'));
    for (final className in classes ?? const <String>[]) {
      if (className.startsWith('language-')) {
        return className.substring('language-'.length);
      }
    }
    return null;
  }
}
