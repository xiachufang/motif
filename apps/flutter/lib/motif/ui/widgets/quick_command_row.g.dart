// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'quick_command_row.dart';

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$QuickCommandRow extends ObservationStatelessWidget {
  const _$QuickCommandRow({super.key});
}

abstract class _$_RepeatingQuickCommandChip extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_RepeatingQuickCommandChip({super.key});

  Widget build(
    BuildContext context, {
    required _QuickCommandRepeatTimer repeatTimer,
  });

  bool shouldRecreateStates(covariant _$_RepeatingQuickCommandChip oldWidget) =>
      false;

  void didUpdateStates(
    covariant _$_RepeatingQuickCommandChip oldWidget, {
    required _QuickCommandRepeatTimer repeatTimer,
  }) {}

  void disposeStates({required _QuickCommandRepeatTimer repeatTimer}) {}

  @override
  State<_RepeatingQuickCommandChip> createState() =>
      _$_RepeatingQuickCommandChipState();
}

final class _$_RepeatingQuickCommandChipState
    extends State<_RepeatingQuickCommandChip>
    with ObservationStateMixin<_RepeatingQuickCommandChip> {
  late _QuickCommandRepeatTimer _repeatTimer;
  bool _hasRepeatTimer = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasRepeatTimer) (name: 'repeatTimer', value: _repeatTimer),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _repeatTimer = widget.createRepeatTimer();
      _hasRepeatTimer = true;
      _statesReady = true;
    } catch (error, stackTrace) {
      runObservationCallbacks([
        () => Error.throwWithStackTrace(error, stackTrace),
        _disposeCreatedStates,
      ]);
    }
  }

  @override
  void didUpdateWidget(covariant _RepeatingQuickCommandChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(oldWidget, repeatTimer: _repeatTimer);
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(context, repeatTimer: _repeatTimer);
    });
  }

  void _disposeStates(_RepeatingQuickCommandChip owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(repeatTimer: _repeatTimer),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
      if (_hasRepeatTimer)
        () {
          _hasRepeatTimer = false;
          _repeatTimer.dispose();
        },
    ]);
  }

  @override
  void dispose() {
    stopObservation();
    try {
      _disposeStates(widget);
    } finally {
      super.dispose();
    }
  }
}
