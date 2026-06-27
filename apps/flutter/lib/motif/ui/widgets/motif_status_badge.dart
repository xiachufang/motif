import 'package:flutter/material.dart';

import '../theme/motif_theme.dart';

/// Inline status indicator: a leading mark (spinner, icon, or dot) followed by
/// a caption label. Shared by the session-list and connection-manager badges so
/// status reads identically everywhere.
///
/// Leading precedence: [busy] → spinner; else [icon] → icon; else a dot.
class MotifStatusBadge extends StatelessWidget {
  /// Status text.
  final String label;

  /// Indicator (dot/icon/spinner) color, and the label color unless
  /// [labelColor] overrides it.
  final Color color;

  /// When non-null (and not [busy]), shown as a 14px glyph instead of a dot.
  final IconData? icon;

  /// Replace the indicator with a small spinner.
  final bool busy;

  /// Label color; defaults to [color].
  final Color? labelColor;

  const MotifStatusBadge({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.busy = false,
    this.labelColor,
  });

  @override
  Widget build(BuildContext context) {
    final isDot = !busy && icon == null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy)
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else if (icon != null)
          Icon(icon, size: 14, color: color)
        else
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        SizedBox(width: isDot ? 6 : 4),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: MotifType.caption.copyWith(color: labelColor ?? color),
        ),
      ],
    );
  }
}
