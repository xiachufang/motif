import 'package:flutter/material.dart';

import '../theme/motif_theme.dart';

/// Inset grouped form primitives used by the Motif settings-style screens.
class MotifSection extends StatelessWidget {
  final String? title;
  final Widget? headerTrailing;
  final String? footer;
  final List<Widget> children;
  final double dividerIndent;

  const MotifSection({
    super.key,
    this.title,
    this.headerTrailing,
    this.footer,
    required this.children,
    this.dividerIndent = 56,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final trailing = headerTrailing;
    final widgets = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        widgets.add(
          Padding(
            padding: EdgeInsets.only(left: dividerIndent),
            child: Divider(height: 1, color: c.border),
          ),
        );
      }
      widgets.add(children[i]);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title != null || headerTrailing != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
            child: Row(
              children: [
                if (title != null)
                  Expanded(
                    child: Text(
                      title!.toUpperCase(),
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0,
                      ),
                    ),
                  )
                else
                  const Spacer(),
                ?trailing,
              ],
            ),
          ),
        ],
        DecoratedBox(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(MotifRadius.sm),
            border: Border.all(color: c.border),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(MotifRadius.sm),
            child: Column(children: widgets),
          ),
        ),
        if (footer != null) ...[
          const SizedBox(height: MotifSpacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              footer!,
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }
}

class MotifSectionRow extends StatelessWidget {
  final Widget? leading;
  final double leadingWidth;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? titleColor;
  final Color? backgroundColor;
  final FontWeight titleWeight;
  final bool showChevron;
  final double minHeight;

  const MotifSectionRow({
    super.key,
    this.leading,
    this.leadingWidth = 28,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.titleColor,
    this.backgroundColor,
    this.titleWeight = FontWeight.w500,
    this.showChevron = false,
    this.minHeight = 48,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: MotifSpacing.md,
          vertical: 9,
        ),
        child: Row(
          children: [
            if (leading != null) ...[
              SizedBox(
                width: leadingWidth,
                child: Center(child: leading),
              ),
              const SizedBox(width: MotifSpacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: titleColor ?? c.textPrimary,
                      fontSize: 15,
                      fontWeight: titleWeight,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: c.textSecondary, fontSize: 13),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: MotifSpacing.sm),
              trailing!,
            ] else if (showChevron) ...[
              const SizedBox(width: MotifSpacing.sm),
              Icon(Icons.chevron_right, color: c.textTertiary, size: 20),
            ],
          ],
        ),
      ),
    );

    if (onTap == null) {
      if (backgroundColor == null) return row;
      return ColoredBox(color: backgroundColor!, child: row);
    }
    return Material(
      color: backgroundColor ?? Colors.transparent,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}
