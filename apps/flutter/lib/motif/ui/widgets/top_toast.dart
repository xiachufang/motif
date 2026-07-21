import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../platform/desktop_window.dart';
import '../theme/motif_theme.dart';

part 'top_toast.g.dart';

const double _desktopTitleBarHeight = 38;
const double _toastMaxWidth = 560;

MotifToastCoordinator? _activeMotifToastHost;
OverlayEntry? _activeMotifToastEntry;
Timer? _activeMotifToastTimer;

void showMotifToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 2),
}) {
  if (!context.mounted || message.isEmpty) return;

  final host = _activeMotifToastHost;
  if (host != null && !host.disposed) {
    _clearOverlayToast();
    host.show(message, duration: duration);
    return;
  }

  _showOverlayToast(context, message, duration: duration);
}

@ObservableModel()
class MotifToastCoordinator extends _$MotifToastCoordinator {
  MotifToastCoordinator({MotifToastData? toast}) : super(toast) {
    _activeMotifToastHost = this;
  }

  Timer? _timer;
  int _serial = 0;
  bool disposed = false;

  void show(String message, {required Duration duration}) {
    _timer?.cancel();
    toast = MotifToastData(++_serial, message);
    _timer = Timer(duration, () {
      if (disposed) return;
      toast = null;
      _timer = null;
    });
  }

  void dispose() {
    disposed = true;
    if (identical(_activeMotifToastHost, this)) {
      _activeMotifToastHost = null;
    }
    _timer?.cancel();
  }
}

@ObservationWidget()
class MotifToastHost extends _$MotifToastHost {
  const MotifToastHost({super.key, required this.child});

  final Widget child;

  @ObservableState(name: 'coordinator')
  MotifToastCoordinator createCoordinator() => MotifToastCoordinator();

  @override
  Widget build(
    BuildContext context, {
    required MotifToastCoordinator coordinator,
  }) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        child,
        _MotifToastPositioned(toast: coordinator.toast),
      ],
    );
  }
}

class MotifToastData {
  const MotifToastData(this.id, this.message);

  final int id;
  final String message;
}

void _showOverlayToast(
  BuildContext context,
  String message, {
  required Duration duration,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return;

  _clearOverlayToast();

  final data = MotifToastData(0, message);
  final theme = Theme.of(context);
  final entry = OverlayEntry(
    builder: (_) => Theme(
      data: theme,
      child: _MotifToastPositioned(toast: data),
    ),
  );

  _activeMotifToastEntry = entry;
  overlay.insert(entry);
  _activeMotifToastTimer = Timer(duration, () {
    if (_activeMotifToastEntry == entry) {
      _activeMotifToastEntry = null;
      _activeMotifToastTimer = null;
    }
    if (entry.mounted) {
      entry.remove();
    }
  });
}

void _clearOverlayToast() {
  _activeMotifToastTimer?.cancel();
  _activeMotifToastTimer = null;

  final entry = _activeMotifToastEntry;
  _activeMotifToastEntry = null;
  if (entry != null && entry.mounted) {
    entry.remove();
  }
}

class _MotifToastPositioned extends StatelessWidget {
  const _MotifToastPositioned({required this.toast});

  final MotifToastData? toast;

  @override
  Widget build(BuildContext context) {
    final topInset =
        MediaQuery.viewPaddingOf(context).top +
        (DesktopWindow.usesCustomTitleBar ? _desktopTitleBarHeight : 0);

    return Positioned.fill(
      child: IgnorePointer(
        child: Padding(
          padding: EdgeInsets.only(
            top: topInset + MotifSpacing.md,
            left: MotifSpacing.lg,
            right: MotifSpacing.lg,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              reverseDuration: const Duration(milliseconds: 120),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) {
                return FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, -0.18),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                );
              },
              child: toast == null
                  ? const SizedBox.shrink(key: ValueKey('motif-toast-empty'))
                  : _MotifToastCard(
                      key: ValueKey('motif-toast-${toast!.id}'),
                      message: toast!.message,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MotifToastCard extends StatelessWidget {
  const _MotifToastCard({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
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

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: _toastMaxWidth),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(MotifRadius.md),
          border: Border.all(
            color: colors?.border ?? theme.colorScheme.outlineVariant,
          ),
          boxShadow: MotifElevation.overlay(colors?.shadow ?? Colors.black),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MotifSpacing.lg,
              vertical: MotifSpacing.md,
            ),
            child: Text(
              message,
              style: textStyle,
              textAlign: TextAlign.center,
              softWrap: true,
            ),
          ),
        ),
      ),
    );
  }
}
