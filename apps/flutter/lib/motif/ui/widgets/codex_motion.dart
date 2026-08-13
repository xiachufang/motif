import 'package:material_ui/material_ui.dart';

import '../theme/motif_theme.dart';

/// Shared motion timings for the Codex surfaces. They intentionally match the
/// rest of Motif's short, functional transitions instead of delaying work.
abstract final class CodexMotion {
  static const enter = MotifMotion.enterDuration;
  static const exit = MotifMotion.exitDuration;
  static const layout = MotifMotion.layoutDuration;
  static const expansion = MotifMotion.disclosureDuration;
  static const enterCurve = MotifMotion.enterCurve;
  static const exitCurve = MotifMotion.exitCurve;
  static const expansionCurve = MotifMotion.disclosureCurve;
}

Duration codexMotionDuration(BuildContext context, Duration duration) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

Duration codexExpansionDuration(BuildContext context) => codexMotionDuration(
  context,
  ExpansionTileTheme.of(context).expansionAnimationStyle?.duration ??
      CodexMotion.expansion,
);

Curve codexExpansionCurve(BuildContext context) =>
    ExpansionTileTheme.of(context).expansionAnimationStyle?.curve ??
    CodexMotion.expansionCurve;

/// Fades structural state changes in with a small directional lift. The old
/// child is removed immediately so duplicate controls never share a key.
class CodexMotionSwitcher extends StatelessWidget {
  const CodexMotionSwitcher({
    required this.child,
    this.animateSize = false,
    this.offset = const Offset(0, 0.035),
    this.alignment = Alignment.center,
    super.key,
  });

  final Widget child;
  final bool animateSize;
  final Offset offset;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final incoming = TweenAnimationBuilder<double>(
      key: ValueKey<(Type, Key?)>((child.runtimeType, child.key)),
      tween: Tween(begin: 0, end: 1),
      duration: codexMotionDuration(context, CodexMotion.enter),
      curve: CodexMotion.enterCurve,
      child: child,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: FractionalTranslation(
          translation: Offset(offset.dx * (1 - value), offset.dy * (1 - value)),
          child: child,
        ),
      ),
    );
    if (!animateSize) return incoming;
    return AnimatedSize(
      duration: codexMotionDuration(context, CodexMotion.layout),
      curve: CodexMotion.enterCurve,
      alignment: alignment,
      child: incoming,
    );
  }
}

/// Animates optional vertical content in and out while also closing its space.
class CodexMotionPresence extends StatelessWidget {
  const CodexMotionPresence({
    required this.visible,
    required this.child,
    this.animateSize = true,
    super.key,
  });

  final bool visible;
  final Widget child;
  final bool animateSize;

  @override
  Widget build(BuildContext context) => ClipRect(
    child: CodexMotionSwitcher(
      animateSize: animateSize,
      alignment: Alignment.topCenter,
      offset: const Offset(0, -0.035),
      child: visible
          ? KeyedSubtree(key: const ValueKey('visible'), child: child)
          : const SizedBox.shrink(key: ValueKey('hidden')),
    ),
  );
}

/// Matches Flutter's default [ExpansionTile] height timing without adding a
/// separate fade, so custom and stock disclosure controls move together.
class CodexMotionExpansion extends StatefulWidget {
  const CodexMotionExpansion({
    required this.expanded,
    required this.child,
    super.key,
  });

  final bool expanded;
  final Widget child;

  @override
  State<CodexMotionExpansion> createState() => _CodexMotionExpansionState();
}

class _CodexMotionExpansionState extends State<CodexMotionExpansion>
    with SingleTickerProviderStateMixin {
  late bool _keepChildMounted = widget.expanded;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: CodexMotion.expansion,
    value: widget.expanded ? 1 : 0,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _controller.duration = codexExpansionDuration(context);
    if (MediaQuery.disableAnimationsOf(context)) {
      _keepChildMounted = widget.expanded;
      _controller.value = widget.expanded ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant CodexMotionExpansion oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;
    if (widget.expanded) {
      _keepChildMounted = true;
      _controller.forward();
    } else {
      _controller.reverse().whenComplete(() {
        if (mounted && !widget.expanded) {
          setState(() => _keepChildMounted = false);
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
    final curve = codexExpansionCurve(context);
    return AnimatedBuilder(
      animation: _controller,
      child: _keepChildMounted
          ? SizedBox(width: double.infinity, child: widget.child)
          : null,
      builder: (context, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: curve.transform(_controller.value),
          child: IgnorePointer(
            ignoring: !widget.expanded,
            child: ExcludeSemantics(excluding: !widget.expanded, child: child),
          ),
        ),
      ),
    );
  }
}

/// Keeps a desktop sidebar mounted while its width and opacity animate.
class CodexAnimatedSidebarLayout extends StatefulWidget {
  const CodexAnimatedSidebarLayout({
    required this.visible,
    required this.sidebarExtent,
    required this.sidebar,
    required this.mainContent,
    super.key,
  });

  final bool visible;
  final double sidebarExtent;
  final Widget sidebar;
  final Widget mainContent;

  @override
  State<CodexAnimatedSidebarLayout> createState() =>
      _CodexAnimatedSidebarLayoutState();
}

class _CodexAnimatedSidebarLayoutState extends State<CodexAnimatedSidebarLayout>
    with SingleTickerProviderStateMixin {
  late bool _keepSidebarMounted = widget.visible;
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: CodexMotion.layout,
    value: widget.visible ? 1 : 0,
  );
  late final Animation<double> _progress = CurvedAnimation(
    parent: _controller,
    curve: CodexMotion.enterCurve,
    reverseCurve: CodexMotion.exitCurve,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _keepSidebarMounted = widget.visible;
      _controller.value = widget.visible ? 1 : 0;
    }
  }

  @override
  void didUpdateWidget(covariant CodexAnimatedSidebarLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      _keepSidebarMounted = widget.visible;
      _controller.value = widget.visible ? 1 : 0;
    } else if (widget.visible) {
      _keepSidebarMounted = true;
      _controller.forward();
    } else {
      _controller.reverse().whenComplete(() {
        if (mounted && !widget.visible) {
          setState(() => _keepSidebarMounted = false);
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
    return Row(
      children: [
        AnimatedBuilder(
          animation: _progress,
          child: _keepSidebarMounted
              ? SizedBox(width: widget.sidebarExtent, child: widget.sidebar)
              : null,
          builder: (context, child) => ClipRect(
            child: Align(
              alignment: Alignment.centerLeft,
              widthFactor: _progress.value,
              child: IgnorePointer(
                ignoring: !widget.visible,
                child: Opacity(opacity: _progress.value, child: child),
              ),
            ),
          ),
        ),
        Expanded(child: widget.mainContent),
      ],
    );
  }
}
