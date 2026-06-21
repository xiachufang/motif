part of '../session_screen.dart';

const double _bottomBarCollapsedContentHeight = 116;

class _BottomBarPlaceholder extends StatelessWidget {
  const _BottomBarPlaceholder();

  @override
  Widget build(BuildContext context) {
    final bottomViewPadding = MediaQuery.viewPaddingOf(context).bottom;
    return SizedBox(
      height: _bottomBarCollapsedContentHeight + bottomViewPadding,
    );
  }
}

class _BottomBarLiftedPane extends StatelessWidget {
  final bool enabled;
  final ValueListenable<double> contentHeight;
  final Widget child;

  const _BottomBarLiftedPane({
    required this.enabled,
    required this.contentHeight,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<double>(
      valueListenable: contentHeight,
      child: child,
      builder: (context, height, child) {
        final pane = child!;
        if (!enabled) return pane;
        final lift = math.max(0.0, height - _bottomBarCollapsedContentHeight);
        if (lift <= 0) return pane;
        return Transform.translate(offset: Offset(0, -lift), child: pane);
      },
    );
  }
}

class _KeyboardAnchoredBottomBar extends StatelessWidget {
  final ValueListenable<double> keyboardInset;
  final Widget child;

  const _KeyboardAnchoredBottomBar({
    required this.keyboardInset,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final bottomViewPadding = MediaQuery.viewPaddingOf(context).bottom;
    return Stack(
      children: [
        if (bottomViewPadding > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: bottomViewPadding,
            child: ColoredBox(color: c.background),
          ),
        ValueListenableBuilder<double>(
          valueListenable: keyboardInset,
          child: RepaintBoundary(child: child),
          builder: (context, inset, child) => Positioned(
            left: 0,
            right: 0,
            bottom: math.max(bottomViewPadding, inset),
            child: child!,
          ),
        ),
      ],
    );
  }
}

class _MeasureSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChange;

  const _MeasureSize({required this.onChange, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _MeasureSizeRenderObject(onChange);

  @override
  void updateRenderObject(
    BuildContext context,
    _MeasureSizeRenderObject renderObject,
  ) {
    renderObject.onChange = onChange;
  }
}

class _MeasureSizeRenderObject extends RenderProxyBox {
  ValueChanged<Size> onChange;
  Size? _lastSize;

  _MeasureSizeRenderObject(this.onChange);

  @override
  void performLayout() {
    super.performLayout();
    final nextSize = child?.size ?? size;
    if (_lastSize == nextSize) return;
    _lastSize = nextSize;
    WidgetsBinding.instance.addPostFrameCallback((_) => onChange(nextSize));
  }
}
