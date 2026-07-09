import 'package:flutter/widgets.dart';

/// Rebuilds only when [selector] returns a value that is not `==` to the
/// previous one. Use to partition listeners on a coarse [Listenable] (e.g. a
/// god-object [ChangeNotifier]) without splitting the notifier itself.
class ListenableSelect<T> extends StatefulWidget {
  const ListenableSelect({
    super.key,
    required this.listenable,
    required this.selector,
    required this.builder,
    this.child,
  });

  final Listenable listenable;
  final T Function() selector;
  final Widget Function(BuildContext context, T value, Widget? child) builder;
  final Widget? child;

  @override
  State<ListenableSelect<T>> createState() => _ListenableSelectState<T>();
}

class _ListenableSelectState<T> extends State<ListenableSelect<T>> {
  late T _value;

  @override
  void initState() {
    super.initState();
    _value = widget.selector();
    widget.listenable.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant ListenableSelect<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_onChange);
      widget.listenable.addListener(_onChange);
      _value = widget.selector();
    } else if (oldWidget.selector != widget.selector) {
      final next = widget.selector();
      if (next != _value) {
        _value = next;
      }
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    final next = widget.selector();
    if (next == _value) return;
    setState(() => _value = next);
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, _value, widget.child);
}
