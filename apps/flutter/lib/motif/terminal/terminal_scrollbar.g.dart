// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'terminal_scrollbar.dart';

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$TerminalScrollbarOverlay extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$TerminalScrollbarOverlay({super.key});

  Widget build(
    BuildContext context, {
    required TerminalScrollbarInteraction interaction,
  });

  bool shouldRecreateStates(covariant _$TerminalScrollbarOverlay oldWidget) =>
      false;

  void didUpdateStates(
    covariant _$TerminalScrollbarOverlay oldWidget, {
    required TerminalScrollbarInteraction interaction,
  }) {}

  void disposeStates({required TerminalScrollbarInteraction interaction}) {}

  @override
  State<TerminalScrollbarOverlay> createState() =>
      _$TerminalScrollbarOverlayState();
}

final class _$TerminalScrollbarOverlayState
    extends State<TerminalScrollbarOverlay>
    with ObservationStateMixin<TerminalScrollbarOverlay> {
  late TerminalScrollbarInteraction _interaction;
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
  void didUpdateWidget(covariant TerminalScrollbarOverlay oldWidget) {
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

  void _disposeStates(TerminalScrollbarOverlay owner) {
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
