import 'dart:async';

import 'package:flutter/material.dart';

bool terminalReturnToCursorShouldBeVisible({
  required bool controlsVisible,
  required bool hasScrollback,
  required bool alternateScreenActive,
  required bool isAtLatest,
}) {
  return controlsVisible &&
      hasScrollback &&
      !alternateScreenActive &&
      !isAtLatest;
}

/// Pixel geometry for a terminal scrollback thumb.
class TerminalScrollbarGeometry {
  final double trackExtent;
  final double thumbExtent;
  final double thumbOffset;
  final int maxOffset;
  final int currentOffset;
  final int visibleRows;

  const TerminalScrollbarGeometry._({
    required this.trackExtent,
    required this.thumbExtent,
    required this.thumbOffset,
    required this.maxOffset,
    required this.currentOffset,
    required this.visibleRows,
  });

  factory TerminalScrollbarGeometry.calculate({
    required double trackExtent,
    required int totalRows,
    required int visibleRows,
    required int viewportOffset,
    double minThumbExtent = 28,
  }) {
    final safeTrack = trackExtent < 0 ? 0.0 : trackExtent;
    final safeTotal = totalRows < 0 ? 0 : totalRows;
    final safeVisible = visibleRows.clamp(0, safeTotal).toInt();
    final maxOffset = safeTotal > safeVisible ? safeTotal - safeVisible : 0;
    final currentOffset = viewportOffset.clamp(0, maxOffset).toInt();
    final proportionalExtent = safeTotal == 0
        ? safeTrack
        : safeTrack * safeVisible / safeTotal;
    final thumbExtent = proportionalExtent
        .clamp(minThumbExtent.clamp(0, safeTrack), safeTrack)
        .toDouble();
    final travel = safeTrack - thumbExtent;
    final thumbOffset = maxOffset == 0 || travel <= 0
        ? 0.0
        : travel * currentOffset / maxOffset;
    return TerminalScrollbarGeometry._(
      trackExtent: safeTrack,
      thumbExtent: thumbExtent,
      thumbOffset: thumbOffset,
      maxOffset: maxOffset,
      currentOffset: currentOffset,
      visibleRows: safeVisible,
    );
  }

  bool get isScrollable => maxOffset > 0 && trackExtent > thumbExtent;

  double get thumbEnd => thumbOffset + thumbExtent;

  int offsetForThumbTop(double thumbTop) {
    final travel = trackExtent - thumbExtent;
    if (maxOffset <= 0 || travel <= 0) return 0;
    final clampedTop = thumbTop.clamp(0.0, travel);
    return (maxOffset * clampedTop / travel)
        .round()
        .clamp(0, maxOffset)
        .toInt();
  }

  int pageTargetForPointer(double position) {
    if (position < thumbOffset) {
      return (currentOffset - visibleRows).clamp(0, maxOffset).toInt();
    }
    if (position > thumbEnd) {
      return (currentOffset + visibleRows).clamp(0, maxOffset).toInt();
    }
    return currentOffset;
  }
}

/// Owns the scrollbar's show/hover/drag/idle-hide state independently of the
/// terminal's much more expensive render tree.
class TerminalScrollbarVisibilityController extends ChangeNotifier {
  TerminalScrollbarVisibilityController({
    this.hideDelay = const Duration(milliseconds: 1000),
  });

  final Duration hideDelay;
  Timer? _hideTimer;
  bool _canShow = false;
  bool _visible = false;
  bool _scrollbarHovered = false;
  bool _returnButtonHovered = false;
  bool _dragging = false;

  bool get _hovered => _scrollbarHovered || _returnButtonHovered;

  bool get visible => _canShow && _visible;
  bool get dragging => _dragging;

  void updateCanShow(bool value) {
    if (_canShow == value) return;
    _canShow = value;
    if (!value) {
      _hideTimer?.cancel();
      _hideTimer = null;
      _scrollbarHovered = false;
      _returnButtonHovered = false;
      _dragging = false;
      _setVisible(false);
    }
  }

  void showTemporarily() {
    if (!_canShow) return;
    _setVisible(true);
    _scheduleHide();
  }

  void setHovered(bool value) {
    if (!_canShow || _scrollbarHovered == value) return;
    _scrollbarHovered = value;
    _updateHoverVisibility(value);
  }

  void setReturnButtonHovered(bool value) {
    if (_returnButtonHovered == value) return;
    _returnButtonHovered = value;
    if (!_canShow) return;
    _updateHoverVisibility(value);
  }

  void _updateHoverVisibility(bool entered) {
    if (entered) {
      _hideTimer?.cancel();
      _setVisible(true);
    } else {
      _scheduleHide();
    }
  }

  void beginDrag() {
    if (!_canShow) return;
    _dragging = true;
    _hideTimer?.cancel();
    _setVisible(true);
  }

  void endDrag() {
    if (!_dragging) return;
    _dragging = false;
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_canShow || _hovered || _dragging) return;
    _hideTimer = Timer(hideDelay, () => _setVisible(false));
  }

  void _setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    notifyListeners();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }
}

/// Floating action that returns a scrolled-back terminal to its live cursor.
class TerminalReturnToCursorButton extends StatelessWidget {
  static const double size = 40;
  static const double iconSize = 20;
  static const double rightInset = TerminalScrollbarOverlay.hitWidth + 8;
  static const double bottomInset = 12;

  final bool visible;
  final Color foregroundColor;
  final Color backgroundColor;
  final VoidCallback onPressed;
  final ValueChanged<bool> onHoverChanged;

  const TerminalReturnToCursorButton({
    super.key,
    required this.visible,
    required this.foregroundColor,
    required this.backgroundColor,
    required this.onPressed,
    required this.onHoverChanged,
  });

  static Rect hitRectForViewport(Size viewport) {
    return Rect.fromLTWH(
      viewport.width - rightInset - size,
      viewport.height - bottomInset - size,
      size,
      size,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      key: const ValueKey('terminal-return-to-cursor-opacity'),
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      child: IgnorePointer(
        ignoring: !visible,
        child: MouseRegion(
          key: const ValueKey('terminal-return-to-cursor-hot-zone'),
          onEnter: (_) => onHoverChanged(true),
          onExit: (_) => onHoverChanged(false),
          child: Tooltip(
            message: 'Jump to cursor',
            child: IconButton(
              key: const ValueKey('terminal-return-to-cursor-button'),
              onPressed: onPressed,
              icon: const Icon(Icons.keyboard_arrow_down_rounded),
              iconSize: iconSize,
              style: ButtonStyle(
                foregroundColor: WidgetStatePropertyAll(foregroundColor),
                backgroundColor: WidgetStatePropertyAll(backgroundColor),
                overlayColor: const WidgetStatePropertyAll(Colors.transparent),
                splashFactory: NoSplash.splashFactory,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                fixedSize: const WidgetStatePropertyAll(Size.square(size)),
                minimumSize: const WidgetStatePropertyAll(Size.square(size)),
                padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                shape: const WidgetStatePropertyAll(CircleBorder()),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Overlay scrollbar for terminal scrollback. The outer mouse region remains
/// active while faded out so moving to the right edge can reveal the thumb.
class TerminalScrollbarOverlay extends StatefulWidget {
  static const double hitWidth = 16;

  final int totalRows;
  final int visibleRows;
  final int viewportOffset;
  final bool visible;
  final Color thumbColor;
  final Color trackColor;
  final ValueChanged<int> onScrollToOffset;
  final ValueChanged<bool> onHoverChanged;
  final VoidCallback onActivity;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;

  const TerminalScrollbarOverlay({
    super.key,
    required this.totalRows,
    required this.visibleRows,
    required this.viewportOffset,
    required this.visible,
    required this.thumbColor,
    required this.trackColor,
    required this.onScrollToOffset,
    required this.onHoverChanged,
    required this.onActivity,
    required this.onDragStart,
    required this.onDragEnd,
  });

  @override
  State<TerminalScrollbarOverlay> createState() =>
      _TerminalScrollbarOverlayState();
}

class _TerminalScrollbarOverlayState extends State<TerminalScrollbarOverlay> {
  TerminalScrollbarGeometry? _geometry;
  double _dragGrabOffset = 0;
  bool _dragActive = false;

  void _emitDragOffset(double pointerY) {
    final geometry = _geometry;
    if (geometry == null) return;
    widget.onScrollToOffset(
      geometry.offsetForThumbTop(pointerY - _dragGrabOffset),
    );
  }

  void _finishDrag() {
    if (!_dragActive) return;
    _dragActive = false;
    widget.onDragEnd();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      key: const ValueKey('terminal-scrollbar-hot-zone'),
      opaque: true,
      cursor: widget.visible ? SystemMouseCursors.basic : MouseCursor.defer,
      onEnter: (_) => widget.onHoverChanged(true),
      onExit: (_) => widget.onHoverChanged(false),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final geometry = TerminalScrollbarGeometry.calculate(
            trackExtent: constraints.maxHeight,
            totalRows: widget.totalRows,
            visibleRows: widget.visibleRows,
            viewportOffset: widget.viewportOffset,
          );
          _geometry = geometry;
          final interactive = widget.visible && geometry.isScrollable;
          return AnimatedOpacity(
            key: const ValueKey('terminal-scrollbar'),
            opacity: interactive ? 1 : 0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOut,
            child: IgnorePointer(
              ignoring: !interactive,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  widget.onActivity();
                  widget.onScrollToOffset(
                    geometry.pageTargetForPointer(details.localPosition.dy),
                  );
                },
                onVerticalDragStart: (details) {
                  _dragActive = true;
                  widget.onDragStart();
                  final y = details.localPosition.dy;
                  _dragGrabOffset =
                      y >= geometry.thumbOffset && y <= geometry.thumbEnd
                      ? y - geometry.thumbOffset
                      : geometry.thumbExtent / 2;
                  _emitDragOffset(y);
                },
                onVerticalDragUpdate: (details) {
                  _emitDragOffset(details.localPosition.dy);
                },
                onVerticalDragEnd: (_) => _finishDrag(),
                onVerticalDragCancel: _finishDrag,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned(
                      right: 5,
                      top: 0,
                      bottom: 0,
                      width: 3,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.trackColor,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    Positioned(
                      key: const ValueKey('terminal-scrollbar-thumb'),
                      right: 3,
                      top: geometry.thumbOffset,
                      width: 7,
                      height: geometry.thumbExtent,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: widget.thumbColor,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
