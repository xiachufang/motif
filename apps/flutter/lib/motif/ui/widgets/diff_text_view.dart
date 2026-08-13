import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../theme/motif_theme.dart';
import 'tab_selection_area.dart';

/// Shared, scrollable line renderer for unified diff bodies.
///
/// Containers such as a turn activity card or a full diff document own their
/// headers, vertical scrolling, and collapse behavior. This widget owns the
/// horizontal sizing, selection, line gutter, and diff syntax colors.
class DiffTextView extends StatelessWidget {
  const DiffTextView({required this.lines, this.tabActive, super.key});

  final List<String> lines;

  /// When supplied, selection is cleared as this view's tab becomes inactive.
  /// When omitted, an existing surrounding selection area is reused.
  final bool? tabActive;

  @override
  Widget build(BuildContext context) {
    final content = LayoutBuilder(
      builder: (context, constraints) {
        const fontSize = 12.0;
        final longestLine = lines.fold<int>(
          0,
          (longest, line) => math.max(longest, line.length),
        );
        final contentWidth = math.max(
          constraints.maxWidth,
          longestLine * fontSize * 0.62 + 72,
        );
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth,
            child: Column(
              children: [
                for (var i = 0; i < lines.length; i++)
                  _DiffLine(
                    index: i + 1,
                    line: lines[i],
                    width: contentWidth,
                    fontSize: fontSize,
                  ),
              ],
            ),
          ),
        );
      },
    );
    final active = tabActive;
    if (active != null) {
      return TabSelectionArea(tabActive: active, child: content);
    }
    if (SelectionContainer.maybeOf(context) != null) return content;
    return SelectionArea(child: content);
  }
}

enum _DiffLineKind { addition, deletion, hunk, fileHeader, context }

class _DiffLine extends StatelessWidget {
  const _DiffLine({
    required this.index,
    required this.line,
    required this.width,
    required this.fontSize,
  });

  final int index;
  final String line;
  final double width;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final kind = _kindFor(line);
    final textColor = switch (kind) {
      _DiffLineKind.addition => c.success,
      _DiffLineKind.deletion => c.danger,
      _DiffLineKind.hunk => c.accent,
      _DiffLineKind.fileHeader => c.textPrimary,
      _DiffLineKind.context => c.textSecondary,
    };
    final background = switch (kind) {
      _DiffLineKind.addition => c.success.withValues(alpha: 0.08),
      _DiffLineKind.deletion => c.danger.withValues(alpha: 0.08),
      _DiffLineKind.hunk => c.accentFill(0.10),
      _DiffLineKind.fileHeader => c.surfaceElevated,
      _DiffLineKind.context => Colors.transparent,
    };
    final gutterBackground = switch (kind) {
      _DiffLineKind.addition => c.success.withValues(alpha: 0.12),
      _DiffLineKind.deletion => c.danger.withValues(alpha: 0.12),
      _DiffLineKind.hunk => c.accentFill(0.14),
      _DiffLineKind.fileHeader => c.surfaceElevated,
      _DiffLineKind.context => c.background.withValues(alpha: 0.45),
    };
    return Container(
      width: width,
      color: background,
      child: Row(
        children: [
          Container(
            width: 52,
            padding: const EdgeInsets.only(right: MotifSpacing.sm),
            decoration: BoxDecoration(
              color: gutterBackground,
              border: Border(right: BorderSide(color: c.border)),
            ),
            alignment: Alignment.centerRight,
            child: Text(
              '$index',
              maxLines: 1,
              style: MotifType.micro.copyWith(
                color: c.textTertiary,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w400,
                height: 1.45,
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.sm),
              child: Text(
                line.isEmpty ? ' ' : line,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: fontSize,
                  color: textColor,
                  height: 1.45,
                  fontWeight: kind == _DiffLineKind.fileHeader
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  _DiffLineKind _kindFor(String value) {
    if (value.startsWith('+') && !value.startsWith('+++')) {
      return _DiffLineKind.addition;
    }
    if (value.startsWith('-') && !value.startsWith('---')) {
      return _DiffLineKind.deletion;
    }
    if (value.startsWith('@@')) return _DiffLineKind.hunk;
    if (value.startsWith('diff --git') ||
        value.startsWith('index ') ||
        value.startsWith('---') ||
        value.startsWith('+++')) {
      return _DiffLineKind.fileHeader;
    }
    return _DiffLineKind.context;
  }
}
