import 'package:flutter/widgets.dart';
import 'package:flutter_observation/flutter_observation.dart';

part 'observation_select.g.dart';

/// A small derived-value region whose selector runs under Observation tracking.
@ObservationWidget()
final class ObservationSelect<T> extends _$ObservationSelect<T> {
  const ObservationSelect({
    required this.selector,
    required this.builder,
    this.child,
    super.key,
  });

  final T Function() selector;
  final Widget Function(BuildContext context, T value, Widget? child) builder;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return builder(context, selector(), child);
  }
}
