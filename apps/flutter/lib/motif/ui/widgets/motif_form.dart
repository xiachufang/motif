import 'package:flutter/material.dart';

import '../theme/motif_theme.dart';

/// Prevent macOS form fields from competing with their enclosing vertical
/// scroll view for trackpad pan gestures.
///
/// EditableText owns a horizontal Scrollable even when a single-line field is
/// empty. On macOS that Scrollable can enter the PointerPanZoom gesture arena
/// while the pointer is over the field, interrupting the outer view's edge
/// drag. Programmatic/implicit scrolling stays enabled so caret movement still
/// reveals text that extends beyond the field.
ScrollPhysics? motifFormTextFieldScrollPhysics(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.macOS
    ? const _MotifFormTextFieldScrollPhysics()
    : null;

class _MotifFormTextFieldScrollPhysics extends ScrollPhysics {
  const _MotifFormTextFieldScrollPhysics({super.parent});

  @override
  _MotifFormTextFieldScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _MotifFormTextFieldScrollPhysics(parent: buildParent(ancestor));

  @override
  bool get allowUserScrolling => false;

  @override
  bool get allowImplicitScrolling => true;
}

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
            padding: const EdgeInsets.fromLTRB(
              MotifSpacing.lg,
              0,
              MotifSpacing.sm,
              MotifSpacing.xs,
            ),
            child: Row(
              children: [
                if (title != null)
                  Expanded(
                    child: Text(
                      title!.toUpperCase(),
                      style: MotifType.overline.copyWith(
                        color: c.textSecondary,
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
            padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.lg),
            child: Text(
              footer!,
              style: MotifType.caption.copyWith(color: c.textSecondary),
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
  final Color? subtitleColor;
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
    this.subtitleColor,
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
          vertical: MotifSpacing.sm,
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
                    style: MotifType.body.copyWith(
                      color: titleColor ?? c.textPrimary,
                      fontWeight: titleWeight,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: MotifType.subhead.copyWith(
                        color: subtitleColor ?? c.textSecondary,
                      ),
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
              Icon(
                Icons.chevron_right,
                color: c.textTertiary,
                size: MotifIconSize.md,
              ),
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
