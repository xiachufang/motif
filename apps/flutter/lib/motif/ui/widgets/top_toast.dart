import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/motif_theme.dart';

OverlayEntry? _activeMotifToastEntry;
Timer? _activeMotifToastTimer;

void showMotifToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 2),
}) {
  if (!context.mounted || message.isEmpty) return;
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _activeMotifToastTimer?.cancel();
  _activeMotifToastEntry?.remove();

  final theme = Theme.of(context);
  final colors = theme.extension<MotifColors>();
  final snackBarTheme = theme.snackBarTheme;
  final background =
      snackBarTheme.backgroundColor ??
      colors?.surfaceElevated ??
      theme.colorScheme.surface;
  final textStyle =
      snackBarTheme.contentTextStyle ??
      TextStyle(color: colors?.textPrimary ?? theme.colorScheme.onSurface);

  final entry = OverlayEntry(
    builder: (overlayContext) {
      final topPadding = MediaQuery.viewPaddingOf(overlayContext).top;
      return Positioned(
        top: topPadding + MotifSpacing.md,
        left: MotifSpacing.lg,
        right: MotifSpacing.lg,
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            tween: Tween(begin: 0, end: 1),
            builder: (context, t, child) {
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, (1 - t) * -8),
                  child: child,
                ),
              );
            },
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Material(
                  color: background,
                  elevation: 10,
                  shadowColor: (colors?.shadow ?? Colors.black).withValues(
                    alpha: 0.24,
                  ),
                  borderRadius: BorderRadius.circular(MotifRadius.sm),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: MotifSpacing.lg,
                      vertical: MotifSpacing.md,
                    ),
                    child: Text(message, style: textStyle),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  _activeMotifToastEntry = entry;
  overlay.insert(entry);
  _activeMotifToastTimer = Timer(duration, () {
    if (_activeMotifToastEntry == entry) {
      _activeMotifToastEntry = null;
      _activeMotifToastTimer = null;
    }
    entry.remove();
  });
}
