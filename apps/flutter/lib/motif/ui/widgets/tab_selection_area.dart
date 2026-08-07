import 'package:flutter/material.dart';

/// A selection area that clears its selection when its owner stops being the
/// active tab.
class TabSelectionArea extends StatefulWidget {
  final bool tabActive;
  final Widget child;

  const TabSelectionArea({
    super.key,
    required this.tabActive,
    required this.child,
  });

  @override
  State<TabSelectionArea> createState() => _TabSelectionAreaState();
}

class _TabSelectionAreaState extends State<TabSelectionArea> {
  final GlobalKey<SelectionAreaState> _selectionAreaKey =
      GlobalKey<SelectionAreaState>();

  @override
  void didUpdateWidget(covariant TabSelectionArea oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabActive && !widget.tabActive) {
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();
    }
  }

  @override
  Widget build(BuildContext context) =>
      SelectionArea(key: _selectionAreaKey, child: widget.child);
}
