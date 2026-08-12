import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/motif_theme.dart';

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
  });

  final String data;
  final TextStyle? style;
  final bool selectable;
  final bool softLineBreak;
  final bool fitContent;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final body = (style ?? MotifType.body).copyWith(
      color: style?.color ?? c.textPrimary,
      height: style?.height ?? 1.5,
    );
    final secondary = body.copyWith(color: c.textSecondary);
    final mono = MotifType.mono.copyWith(
      color: c.textPrimary,
      backgroundColor: c.subtleFill,
      height: 1.45,
    );

    return MarkdownBody(
      data: data,
      selectable: selectable,
      fitContent: fitContent,
      softLineBreak: softLineBreak,
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
        code: mono,
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
        blockSpacing: MotifSpacing.xs,
        listIndent: MotifSpacing.md,
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
      onTapLink: (_, href, _) {
        final uri = href == null ? null : Uri.tryParse(href);
        if (uri == null ||
            !const {'http', 'https', 'mailto'}.contains(uri.scheme)) {
          return;
        }
        unawaited(launchUrl(uri, mode: LaunchMode.externalApplication));
      },
    );
  }
}
