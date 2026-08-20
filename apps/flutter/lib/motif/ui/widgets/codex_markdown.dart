import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../theme/codex_typography.dart';
import '../theme/motif_theme.dart';
import 'syntax_highlight.dart';

/// Incremental Markdown renderer used while a protocol item is streaming.
///
/// Only the unfinished tail is reparsed for an append-only update. Blocks that
/// can be parsed independently are committed behind stable widget identities,
/// so their Markdown trees and selections survive subsequent deltas. A source
/// rewrite (for example after reconnecting to a corrected snapshot) discards
/// the checkpoints and resumes parsing from the replacement source.
class CodexStreamingMarkdown extends StatefulWidget {
  const CodexStreamingMarkdown(
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
  State<CodexStreamingMarkdown> createState() => _CodexStreamingMarkdownState();
}

class _CodexStreamingMarkdownState extends State<CodexStreamingMarkdown> {
  final _document = _IncrementalMarkdownDocument();
  final _callbacks = _StreamingMarkdownCallbacks();
  final Map<int, Widget> _stableWidgets = <int, Widget>{};

  @override
  void initState() {
    super.initState();
    _callbacks.update(widget);
    _document.update(widget.data);
  }

  @override
  void didUpdateWidget(CodexStreamingMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    _callbacks.update(widget);
    if (oldWidget.style != widget.style ||
        oldWidget.selectable != widget.selectable ||
        oldWidget.softLineBreak != widget.softLineBreak ||
        oldWidget.fitContent != widget.fitContent ||
        oldWidget.blockSpacing != widget.blockSpacing ||
        (oldWidget.imageBuilder == null) != (widget.imageBuilder == null)) {
      _stableWidgets.clear();
    }
    _document.update(widget.data);
    final liveIds = _document.stableBlocks.map((block) => block.id).toSet();
    _stableWidgets.removeWhere((id, _) => !liveIds.contains(id));
  }

  @override
  Widget build(BuildContext context) {
    final sections = <Widget>[
      for (final block in _document.stableBlocks)
        _stableWidgets.putIfAbsent(
          block.id,
          () => _markdown(
            block.source,
            ValueKey('codex-streaming-markdown-block-${block.id}'),
          ),
        ),
      if (_document.pendingSource.trim().isNotEmpty)
        _markdown(
          _document.pendingSource,
          const ValueKey('codex-streaming-markdown-tail'),
        ),
    ];
    if (sections.isEmpty) return const SizedBox.shrink();
    if (sections.length == 1) return sections.single;
    return Column(
      crossAxisAlignment: widget.fitContent
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < sections.length; index++) ...[
          if (index > 0) SizedBox(height: widget.blockSpacing),
          sections[index],
        ],
      ],
    );
  }

  Widget _markdown(String source, Key key) => CodexMarkdown(
    source,
    key: key,
    style: widget.style,
    selectable: widget.selectable,
    softLineBreak: widget.softLineBreak,
    fitContent: widget.fitContent,
    blockSpacing: widget.blockSpacing,
    onTapFileLink: _callbacks.openFile,
    imageBuilder: widget.imageBuilder == null ? null : _callbacks.buildImage,
  );
}

final class _StreamingMarkdownCallbacks {
  ValueChanged<String>? _onTapFileLink;
  MarkdownImageBuilder? _imageBuilder;

  void update(CodexStreamingMarkdown widget) {
    _onTapFileLink = widget.onTapFileLink;
    _imageBuilder = widget.imageBuilder;
  }

  void openFile(String href) => _onTapFileLink?.call(href);

  Widget buildImage(Uri uri, String? title, String? alt) =>
      _imageBuilder?.call(uri, title, alt) ?? const SizedBox.shrink();
}

final class _IncrementalMarkdownDocument {
  static final RegExp _blankLine = RegExp(r'\n[ \t]*\n');
  static final RegExp _referenceDefinition = RegExp(
    r'^ {0,3}\[[^\n]+?\]:[ \t]*\S',
    multiLine: true,
  );

  final List<_StableMarkdownBlock> stableBlocks = <_StableMarkdownBlock>[];
  String pendingSource = '';
  String _source = '';
  int _nextBlockId = 0;
  int _examinedBoundaryEnd = 0;

  void update(String nextSource) {
    if (nextSource == _source) return;
    if (!nextSource.startsWith(_source)) {
      _restart(nextSource);
      return;
    }

    final delta = nextSource.substring(_source.length);
    _source = nextSource;
    pendingSource += delta;

    // A late reference definition can change links in an earlier block. Roll
    // back the checkpoints so the full dependency is reparsed and then find a
    // new safe boundary after it.
    if (stableBlocks.isNotEmpty && _referenceDefinition.hasMatch(delta)) {
      _restart(nextSource);
      return;
    }
    _commitStablePrefix();
  }

  void _restart(String source) {
    stableBlocks.clear();
    _source = source;
    pendingSource = source;
    _examinedBoundaryEnd = 0;
    _commitStablePrefix();
  }

  void _commitStablePrefix() {
    while (true) {
      final boundaries = _blankLine
          .allMatches(pendingSource)
          .where((match) => match.end > _examinedBoundaryEnd)
          .toList();
      if (boundaries.isEmpty) return;
      final wholeSignature = _nodeSignatures(pendingSource);
      if (wholeSignature == null) return;

      var committed = false;
      for (final boundary in boundaries) {
        final prefix = pendingSource.substring(0, boundary.end);
        final suffix = pendingSource.substring(boundary.end);
        // Revisit the trailing boundary after the next non-whitespace delta.
        if (suffix.trim().isEmpty) return;
        final prefixSignature = _nodeSignatures(prefix);
        final suffixSignature = _nodeSignatures(suffix);
        if (prefixSignature == null || suffixSignature == null) return;
        _examinedBoundaryEnd = boundary.end;
        if (!_sameSignatures(wholeSignature, [
          ...prefixSignature,
          ...suffixSignature,
        ])) {
          continue;
        }
        stableBlocks.add(
          _StableMarkdownBlock(id: _nextBlockId++, source: prefix),
        );
        pendingSource = suffix;
        _examinedBoundaryEnd = 0;
        committed = true;
        break;
      }
      if (!committed) return;
    }
  }

  List<String>? _nodeSignatures(String source) {
    try {
      final document = md.Document(
        extensionSet: md.ExtensionSet.gitHubFlavored,
        encodeHtml: false,
      );
      return [
        for (final node in document.parse(source)) md.renderToHtml([node]),
      ];
    } on Object {
      // Partial protocol text must remain renderable. Keep it in the mutable
      // tail and retry when a later delta completes the construct.
      return null;
    }
  }

  bool _sameSignatures(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

final class _StableMarkdownBlock {
  const _StableMarkdownBlock({required this.id, required this.source});

  final int id;
  final String source;
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
    final body = (style ?? CodexType.body).copyWith(
      color: style?.color ?? c.textPrimary,
      height: style?.height ?? 1.5,
    );
    final secondary = body.copyWith(color: c.textSecondary);
    final code = body.copyWith(
      fontFamily: MotifType.mono.fontFamily,
      color: c.textPrimary,
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
        h3: CodexType.headline.copyWith(color: c.textPrimary, height: 1.4),
        h4: MotifType.callout.copyWith(color: c.textPrimary, height: 1.4),
        h5: MotifType.callout.copyWith(color: c.textSecondary, height: 1.4),
        h6: MotifType.caption.copyWith(color: c.textSecondary, height: 1.4),
        em: body.copyWith(fontStyle: FontStyle.italic),
        strong: body.copyWith(fontWeight: FontWeight.w700),
        del: secondary.copyWith(decoration: TextDecoration.lineThrough),
        code: code.copyWith(backgroundColor: c.subtleFill),
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
          style: code,
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
    required this.style,
    required this.padding,
    required this.selectable,
    required this.usesParentSelection,
  });

  final MotifColors colors;
  final TextStyle style;
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
      baseStyle: style,
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
