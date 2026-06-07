import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../theme/motif_theme.dart';

/// Whether adaptive modals present as bottom sheets (phones) instead of
/// dialogs (desktop / web).
bool get _useSheet =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

/// Shows [builder]'s widget as a modal bottom sheet on iOS/Android
/// (keyboard-aware, scrollable) and as a dialog elsewhere.
///
/// The builder should return an [AdaptiveModal], which renders the matching
/// container for the active presentation.
Future<T?> showAdaptiveModal<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  if (!_useSheet) {
    return showDialog<T>(context: context, builder: builder);
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: builder(context),
    ),
  );
}

/// Shows a full-page panel (own header/scaffold, scrolling body) as an
/// 86%-height bottom sheet on iOS/Android and as a fixed-size [Dialog]
/// elsewhere. Unlike [showAdaptiveModal] the builder's widget is used as-is;
/// it should not be an [AdaptiveModal].
Future<T?> showAdaptivePanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  if (!_useSheet) {
    return showDialog<T>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
          child: builder(context),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    clipBehavior: Clip.antiAlias,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: _DraggablePanelSheet(builder: builder),
    ),
  );
}

/// Sheet body for [showAdaptivePanel]: a [DraggableScrollableSheet] that
/// drives the panel's scrollable through the primary scroll controller, so
/// pulling past the top of the (scrolled-to-top) list keeps dragging the
/// sheet itself — tracking the finger the whole way down.
///
/// On release, the sheet's snap logic decides between spring-back and
/// dismissal (same >50%-or-fling rule as a plain bottom sheet). When it
/// starts settling downward with no finger on screen, the snap is frozen and
/// the route popped immediately, so the visible close is the standard
/// modal-bottom-sheet exit animation — identical to non-scrolling sheets.
class _DraggablePanelSheet extends StatefulWidget {
  final WidgetBuilder builder;

  const _DraggablePanelSheet({required this.builder});

  @override
  State<_DraggablePanelSheet> createState() => _DraggablePanelSheetState();
}

class _DraggablePanelSheetState extends State<_DraggablePanelSheet> {
  static const _restingSize = 0.86;

  final _controller = DraggableScrollableController();
  int _pointersDown = 0;
  double _lastExtent = _restingSize;
  bool _popped = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _onExtentChanged(DraggableScrollableNotification notification) {
    final extent = notification.extent;
    final settlingDown =
        _pointersDown == 0 &&
        extent < _lastExtent &&
        extent < _restingSize - 0.001;
    _lastExtent = extent;
    if (settlingDown && !_popped) {
      _popped = true;
      // Halt the sheet's own shrink-to-zero snap; the route's standard exit
      // animation takes over from the current position.
      _controller.jumpTo(extent);
      Navigator.pop(context);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _pointersDown++,
      onPointerUp: (_) {
        if (_pointersDown > 0) _pointersDown--;
      },
      onPointerCancel: (_) {
        if (_pointersDown > 0) _pointersDown--;
      },
      child: NotificationListener<DraggableScrollableNotification>(
        onNotification: _onExtentChanged,
        child: DraggableScrollableSheet(
          controller: _controller,
          expand: false,
          initialChildSize: _restingSize,
          minChildSize: 0,
          maxChildSize: _restingSize,
          snap: true,
          builder: (context, scrollController) => PrimaryScrollController(
            controller: scrollController,
            child: widget.builder(context),
          ),
        ),
      ),
    );
  }
}

/// Form-style modal body for [showAdaptiveModal]: an [AlertDialog] on
/// desktop, a sheet layout (title, content, trailing action row) on phones.
class AdaptiveModal extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;

  const AdaptiveModal({
    super.key,
    required this.title,
    required this.content,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    if (!_useSheet) {
      return AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: content),
        actions: actions,
      );
    }
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          MotifSpacing.lg,
          0,
          MotifSpacing.lg,
          MotifSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: MotifSpacing.sm),
            content,
            const SizedBox(height: MotifSpacing.sm),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
          ],
        ),
      ),
    );
  }
}
