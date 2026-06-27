import 'package:flutter/material.dart';

import '../theme/motif_theme.dart';

/// Flat header bar for embedded side panels (file tree, git diff, …): a fixed
/// height row on the panel background with a single bottom border — no shadow.
///
/// Use the default `icon` + `title` + `actions` layout, or pass a [child] to
/// supply a fully custom row while still inheriting the shared chrome
/// (height, padding, background, bottom border).
class MotifPanelHeader extends StatelessWidget {
  final IconData? icon;
  final String? title;
  final List<Widget> actions;
  final double height;
  final EdgeInsetsGeometry padding;

  /// Custom row content. When set, [icon]/[title]/[actions] are ignored.
  final Widget? child;

  const MotifPanelHeader({
    super.key,
    this.icon,
    this.title,
    this.actions = const [],
    this.height = 48,
    this.padding = const EdgeInsets.symmetric(horizontal: MotifSpacing.md),
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: c.background,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child:
          child ??
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: c.textSecondary),
                const SizedBox(width: MotifSpacing.sm),
              ],
              if (title != null)
                Expanded(
                  child: Text(
                    title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MotifType.body.copyWith(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ...actions,
            ],
          ),
    );
  }
}
