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

/// Owns the return-to-cursor button's show/hover/idle-hide state independently
/// of the terminal's much more expensive render tree.
class TerminalScrollbarVisibilityController extends ChangeNotifier {
  TerminalScrollbarVisibilityController({
    this.hideDelay = const Duration(milliseconds: 1000),
  });

  final Duration hideDelay;
  Timer? _hideTimer;
  bool _canShow = false;
  bool _visible = false;
  bool _returnButtonHovered = false;

  bool get visible => _canShow && _visible;

  void updateCanShow(bool value) {
    if (_canShow == value) return;
    _canShow = value;
    if (!value) {
      _hideTimer?.cancel();
      _hideTimer = null;
      _returnButtonHovered = false;
      _setVisible(false);
    }
  }

  void showTemporarily() {
    if (!_canShow) return;
    _setVisible(true);
    _scheduleHide();
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

  void _scheduleHide() {
    _hideTimer?.cancel();
    if (!_canShow || _returnButtonHovered) return;
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
class TerminalReturnToCursorButton extends StatefulWidget {
  static const double size = 40;
  static const double iconSize = 20;
  static const double rightInset = 12;
  static const double bottomInset = 12;

  final bool visible;
  final Color foregroundColor;
  final Color backgroundColor;
  final VoidCallback onPressStart;
  final VoidCallback onPressed;
  final ValueChanged<bool> onHoverChanged;

  const TerminalReturnToCursorButton({
    super.key,
    required this.visible,
    required this.foregroundColor,
    required this.backgroundColor,
    required this.onPressStart,
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
  State<TerminalReturnToCursorButton> createState() =>
      _TerminalReturnToCursorButtonState();
}

class _TerminalReturnToCursorButtonState
    extends State<TerminalReturnToCursorButton> {
  bool _handledPointerDown = false;

  void _handlePointerDown(PointerDownEvent _) {
    _handledPointerDown = true;
    widget.onPressStart();
    widget.onPressed();
  }

  void _handlePointerFinished(PointerEvent _) {
    // IconButton resolves its tap from the same pointer-up dispatch. Keep the
    // guard set through that dispatch, then clear it for keyboard/semantics.
    scheduleMicrotask(() => _handledPointerDown = false);
  }

  void _handleIconPressed() {
    if (_handledPointerDown) return;
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      key: const ValueKey('terminal-return-to-cursor-opacity'),
      opacity: widget.visible ? 1 : 0,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      child: IgnorePointer(
        ignoring: !widget.visible,
        child: Listener(
          onPointerDown: _handlePointerDown,
          onPointerUp: _handlePointerFinished,
          onPointerCancel: _handlePointerFinished,
          child: MouseRegion(
            key: const ValueKey('terminal-return-to-cursor-hot-zone'),
            onEnter: (_) => widget.onHoverChanged(true),
            onExit: (_) => widget.onHoverChanged(false),
            child: Tooltip(
              message: 'Jump to cursor',
              child: IconButton(
                key: const ValueKey('terminal-return-to-cursor-button'),
                onPressed: _handleIconPressed,
                icon: const Icon(Icons.keyboard_arrow_down_rounded),
                iconSize: TerminalReturnToCursorButton.iconSize,
                style: ButtonStyle(
                  foregroundColor: WidgetStatePropertyAll(
                    widget.foregroundColor,
                  ),
                  backgroundColor: WidgetStatePropertyAll(
                    widget.backgroundColor,
                  ),
                  overlayColor: const WidgetStatePropertyAll(
                    Colors.transparent,
                  ),
                  splashFactory: NoSplash.splashFactory,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  fixedSize: const WidgetStatePropertyAll(
                    Size.square(TerminalReturnToCursorButton.size),
                  ),
                  minimumSize: const WidgetStatePropertyAll(
                    Size.square(TerminalReturnToCursorButton.size),
                  ),
                  padding: const WidgetStatePropertyAll(EdgeInsets.zero),
                  shape: const WidgetStatePropertyAll(CircleBorder()),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shared Native/Web return-to-cursor overlay.
class TerminalScrollControls extends StatelessWidget {
  final int totalRows;
  final int visibleRows;
  final int viewportOffset;
  final bool alternateScreenActive;
  final TerminalScrollbarVisibilityController visibilityController;
  final Color buttonForegroundColor;
  final Color buttonBackgroundColor;
  final ValueChanged<bool> onReturnButtonHoverChanged;
  final VoidCallback onReturnToCursorInteractionStart;
  final VoidCallback onReturnToCursor;

  const TerminalScrollControls({
    super.key,
    required this.totalRows,
    required this.visibleRows,
    required this.viewportOffset,
    required this.alternateScreenActive,
    required this.visibilityController,
    required this.buttonForegroundColor,
    required this.buttonBackgroundColor,
    required this.onReturnButtonHoverChanged,
    required this.onReturnToCursorInteractionStart,
    required this.onReturnToCursor,
  });

  @override
  Widget build(BuildContext context) {
    final hasScrollback = visibleRows > 0 && totalRows > visibleRows;
    if (!hasScrollback || alternateScreenActive) {
      return const SizedBox.shrink();
    }
    final maxOffset = totalRows - visibleRows;
    final isAtLatest = viewportOffset >= maxOffset;
    return ListenableBuilder(
      listenable: visibilityController,
      builder: (context, _) {
        final controlsVisible = visibilityController.visible;
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned(
              right: TerminalReturnToCursorButton.rightInset,
              bottom: TerminalReturnToCursorButton.bottomInset,
              width: TerminalReturnToCursorButton.size,
              height: TerminalReturnToCursorButton.size,
              child: TerminalReturnToCursorButton(
                visible: terminalReturnToCursorShouldBeVisible(
                  controlsVisible: controlsVisible,
                  hasScrollback: hasScrollback,
                  alternateScreenActive: alternateScreenActive,
                  isAtLatest: isAtLatest,
                ),
                foregroundColor: buttonForegroundColor,
                backgroundColor: buttonBackgroundColor,
                onPressStart: onReturnToCursorInteractionStart,
                onPressed: onReturnToCursor,
                onHoverChanged: onReturnButtonHoverChanged,
              ),
            ),
          ],
        );
      },
    );
  }
}
