/// Reusable Motif button widgets, ported from `MotifButtonStyle.swift` and
/// `MotifIconButtonStyle.swift`. Capsule text buttons and circular icon
/// buttons sharing role/size axes and press feedback.
library;

import 'package:flutter/material.dart';

import 'motif_theme.dart';

enum MotifButtonRole { filled, tinted, bordered, plain }

enum MotifButtonSize {
  small(MotifControlSize.sm),
  medium(MotifControlSize.md),
  large(MotifControlSize.lg),
  xl(MotifControlSize.xl);

  final double dimension;
  const MotifButtonSize(this.dimension);
}

/// Shared press-feedback wrapper (opacity + scale).
class _PressFeedback extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;
  final BoxShape shape;

  const _PressFeedback({
    required this.child,
    this.onTap,
    this.borderRadius,
    this.shape = BoxShape.rectangle,
  });

  @override
  State<_PressFeedback> createState() => _PressFeedbackState();
}

class _PressFeedbackState extends State<_PressFeedback> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
      onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
        child: AnimatedScale(
          scale: _pressed ? MotifInteraction.pressedScale : 1,
          duration: MotifInteraction.pressDuration,
          child: AnimatedOpacity(
            opacity: !enabled
                ? MotifInteraction.disabledOpacity
                : (_pressed ? MotifInteraction.pressedOpacity : 1),
            duration: MotifInteraction.pressDuration,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// A capsule-shaped text/label button.
class MotifButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final MotifButtonRole role;
  final MotifButtonSize size;
  final bool selected;

  const MotifButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.role = MotifButtonRole.filled,
    this.size = MotifButtonSize.medium,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final (bg, fg, border) = _resolve(c);
    final height = size.dimension;
    return _PressFeedback(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(height / 2),
      child: Container(
        height: height,
        padding: EdgeInsets.symmetric(horizontal: height * 0.45),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(height / 2),
          border: border == null ? null : Border.all(color: border, width: 1),
        ),
        alignment: Alignment.center,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: fg),
              const SizedBox(width: MotifSpacing.xs),
            ],
            // Ellipsize rather than overflow when the button is width-bounded
            // (e.g. wrapped in a Wrap/row of fixed width). Flexible is safe here
            // because every call site gives the button a bounded width.
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  (Color, Color, Color?) _resolve(MotifColors c) => switch (role) {
    MotifButtonRole.filled => (c.accent, c.textOnAccent, null),
    MotifButtonRole.tinted => (c.accentContainer, c.accent, null),
    MotifButtonRole.bordered => (
      selected ? c.accentContainer : c.subtleFill,
      selected ? c.accent : c.textPrimary,
      c.border,
    ),
    MotifButtonRole.plain => (
      Colors.transparent,
      selected ? c.accent : c.textPrimary,
      null,
    ),
  };
}

/// A circular icon-only button.
class MotifIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final MotifButtonRole role;
  final MotifButtonSize size;
  final bool selected;
  final String? tooltip;

  const MotifIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.role = MotifButtonRole.bordered,
    this.size = MotifButtonSize.medium,
    this.selected = false,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final (bg, fg, border) = _resolve(c);
    final d = size.dimension;
    final btn = _PressFeedback(
      onTap: onPressed,
      shape: BoxShape.circle,
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: border == null ? null : Border.all(color: border, width: 1),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: d * 0.42, color: fg),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }

  (Color, Color, Color?) _resolve(MotifColors c) => switch (role) {
    MotifButtonRole.filled => (c.accent, c.textOnAccent, null),
    MotifButtonRole.tinted => (c.accentContainer, c.accent, null),
    MotifButtonRole.bordered => (
      selected ? c.accentContainer : c.subtleFill,
      selected ? c.accent : c.textPrimary,
      c.border,
    ),
    MotifButtonRole.plain => (
      Colors.transparent,
      selected ? c.accent : c.textPrimary,
      null,
    ),
  };
}
