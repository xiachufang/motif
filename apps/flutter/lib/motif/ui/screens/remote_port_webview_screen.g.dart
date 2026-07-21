// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'remote_port_webview_screen.dart';

// **************************************************************************
// ObservationWidgetGenerator
// **************************************************************************

abstract class _$_HistorySwipeEdge extends StatefulWidget
    with ObservationWidgetDiagnostics {
  const _$_HistorySwipeEdge({super.key});

  Widget build(
    BuildContext context, {
    required _HistorySwipeInteraction interaction,
  });

  bool shouldRecreateStates(covariant _$_HistorySwipeEdge oldWidget) => false;

  void didUpdateStates(
    covariant _$_HistorySwipeEdge oldWidget, {
    required _HistorySwipeInteraction interaction,
  }) {}

  void disposeStates({required _HistorySwipeInteraction interaction}) {}

  @override
  State<_HistorySwipeEdge> createState() => _$_HistorySwipeEdgeState();
}

final class _$_HistorySwipeEdgeState extends State<_HistorySwipeEdge>
    with ObservationStateMixin<_HistorySwipeEdge> {
  late _HistorySwipeInteraction _interaction;
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
  void didUpdateWidget(covariant _HistorySwipeEdge oldWidget) {
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

  void _disposeStates(_HistorySwipeEdge owner) {
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
