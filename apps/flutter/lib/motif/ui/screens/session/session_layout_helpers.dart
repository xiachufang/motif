part of '../session_screen.dart';

class _BottomBarPlaceholder extends StatelessWidget {
  final ValueListenable<double> contentHeight;

  const _BottomBarPlaceholder({required this.contentHeight});

  @override
  Widget build(BuildContext context) {
    final bottomViewPadding = MediaQuery.viewPaddingOf(context).bottom;
    return ValueListenableBuilder<double>(
      valueListenable: contentHeight,
      builder: (context, height, _) =>
          SizedBox(height: math.max(0.0, height) + bottomViewPadding),
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
