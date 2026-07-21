// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'adaptive_modal.dart';

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$_KeyboardAwareSheet extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_KeyboardAwareSheet({super.key});

  Widget build(
    BuildContext context, {
    required _FocusChangeTracker focusTracker,
  });

  bool shouldRecreateStates(covariant _$_KeyboardAwareSheet oldWidget) => false;

  void didUpdateStates(
    covariant _$_KeyboardAwareSheet oldWidget, {
    required _FocusChangeTracker focusTracker,
  }) {}

  void disposeStates({required _FocusChangeTracker focusTracker}) {}

  @override
  State<_KeyboardAwareSheet> createState() => _$_KeyboardAwareSheetState();
}

final class _$_KeyboardAwareSheetState extends State<_KeyboardAwareSheet>
    with ObservationStateMixin<_KeyboardAwareSheet> {
  late _FocusChangeTracker _focusTracker;
  bool _hasFocusTracker = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasFocusTracker) (name: 'focusTracker', value: _focusTracker),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _focusTracker = widget.createFocusTracker();
      _hasFocusTracker = true;
      _statesReady = true;
    } catch (error, stackTrace) {
      runObservationCallbacks([
        () => Error.throwWithStackTrace(error, stackTrace),
        _disposeCreatedStates,
      ]);
    }
  }

  @override
  void didUpdateWidget(covariant _KeyboardAwareSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(oldWidget, focusTracker: _focusTracker);
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(context, focusTracker: _focusTracker);
    });
  }

  void _disposeStates(_KeyboardAwareSheet owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(focusTracker: _focusTracker),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
      if (_hasFocusTracker)
        () {
          _hasFocusTracker = false;
          _focusTracker.dispose();
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

abstract class _$_DraggablePanelSheet extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_DraggablePanelSheet({super.key});

  Widget build(
    BuildContext context, {
    required _DraggablePanelInteraction interaction,
  });

  bool shouldRecreateStates(covariant _$_DraggablePanelSheet oldWidget) =>
      false;

  void didUpdateStates(
    covariant _$_DraggablePanelSheet oldWidget, {
    required _DraggablePanelInteraction interaction,
  }) {}

  void disposeStates({required _DraggablePanelInteraction interaction}) {}

  @override
  State<_DraggablePanelSheet> createState() => _$_DraggablePanelSheetState();
}

final class _$_DraggablePanelSheetState extends State<_DraggablePanelSheet>
    with ObservationStateMixin<_DraggablePanelSheet> {
  late _DraggablePanelInteraction _interaction;
  bool _hasInteraction = false;
  bool _statesReady = false;

  @override
  Iterable<({String name, Object? value})> get observationOwnedStates => [
    if (_hasInteraction) (name: 'interaction', value: _interaction),
  ];

  @override
  void initState() {
    super.initState();
    _createStates();
  }

  void _createStates() {
    try {
      _interaction = widget.createInteraction();
      _hasInteraction = true;
      _statesReady = true;
    } catch (error, stackTrace) {
      runObservationCallbacks([
        () => Error.throwWithStackTrace(error, stackTrace),
        _disposeCreatedStates,
      ]);
    }
  }

  @override
  void didUpdateWidget(covariant _DraggablePanelSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.shouldRecreateStates(oldWidget)) {
      stopObservation();
      _disposeStates(oldWidget);
      _createStates();
    } else {
      widget.didUpdateStates(oldWidget, interaction: _interaction);
    }
  }

  @override
  Widget build(BuildContext context) {
    return buildObserved((context) {
      return widget.build(context, interaction: _interaction);
    });
  }

  void _disposeStates(_DraggablePanelSheet owner) {
    if (!_statesReady) return;
    _statesReady = false;
    runObservationCallbacks([
      () => owner.disposeStates(interaction: _interaction),
      _disposeCreatedStates,
    ]);
  }

  void _disposeCreatedStates() {
    runObservationCallbacks([
      if (_hasInteraction)
        () {
          _hasInteraction = false;
          _interaction.dispose();
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
