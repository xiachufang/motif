part of '../session_screen.dart';

class _AnimatedSidebarLayout extends StatefulWidget {
  static const Duration _duration = Duration(milliseconds: 180);

  final bool visible;
  final double width;
  final Widget sidebar;
  final Widget resizeHandle;
  final Widget mainContent;

  const _AnimatedSidebarLayout({
    required this.visible,
    required this.width,
    required this.sidebar,
    required this.resizeHandle,
    required this.mainContent,
  });

  @override
  State<_AnimatedSidebarLayout> createState() => _AnimatedSidebarLayoutState();
}

class _AnimatedSidebarLayoutState extends State<_AnimatedSidebarLayout>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _progress;
  late Widget _displayedSidebar;
  bool _keepSidebarMounted = false;

  @override
  void initState() {
    super.initState();
    _keepSidebarMounted = widget.visible;
    _displayedSidebar = widget.sidebar;
    _controller = AnimationController(
      vsync: this,
      duration: _AnimatedSidebarLayout._duration,
      value: widget.visible ? 1 : 0,
    );
    _progress = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void didUpdateWidget(_AnimatedSidebarLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible) {
      _displayedSidebar = widget.sidebar;
      _keepSidebarMounted = true;
    }
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _controller.forward();
    } else {
      _controller.reverse().whenComplete(() {
        if (mounted && !widget.visible) {
          setState(() {
            _keepSidebarMounted = false;
            _displayedSidebar = const SizedBox.shrink();
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final fraction = _progress.value;
        return Row(
          children: [
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                child: SizedBox(
                  width: widget.width,
                  child: _keepSidebarMounted
                      ? _displayedSidebar
                      : const SizedBox.shrink(),
                ),
              ),
            ),
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                child: SizedBox(
                  width: _SidebarResizeHandle.extent,
                  child: widget.visible
                      ? widget.resizeHandle
                      : const SizedBox.shrink(),
                ),
              ),
            ),
            Expanded(child: widget.mainContent),
          ],
        );
      },
    );
  }
}
