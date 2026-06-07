import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';

import '../theme/motif_theme.dart';

/// Whether adaptive modals present as bottom sheets (phones) instead of
/// dialogs (desktop / web).
bool get _useSheet =>
    defaultTargetPlatform == TargetPlatform.iOS ||
    defaultTargetPlatform == TargetPlatform.android;

const double _modalMinWidth = 360;
const double _modalMaxWidth = 440;
const double _modalMaxHeight = 640;

/// Shows [builder]'s widget as a modal bottom sheet on iOS/Android
/// (keyboard-aware, scrollable) and as a dialog elsewhere.
///
/// The builder should return an [AdaptiveModal], which renders the matching
/// container for the active presentation.
Future<T?> showAdaptiveModal<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final background = context.motif.background;
  if (!_useSheet) {
    return showDialog<T>(context: context, builder: builder);
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    clipBehavior: Clip.antiAlias,
    backgroundColor: background,
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
  final background = context.motif.background;
  if (!_useSheet) {
    return showDialog<T>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
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
    backgroundColor: background,
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
/// desktop and a sheet layout on phones. Dismiss is always the leading xmark;
/// form submit actions live in the trailing header slot.
class AdaptiveModal extends StatelessWidget {
  final String title;
  final Widget content;
  final List<Widget> actions;
  final bool showCloseButton;

  const AdaptiveModal({
    super.key,
    required this.title,
    required this.content,
    this.actions = const [],
    this.showCloseButton = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!_useSheet) {
      return Dialog(
        clipBehavior: Clip.antiAlias,
        backgroundColor: context.motif.background,
        surfaceTintColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: _modalMinWidth,
            maxWidth: _modalMaxWidth,
            maxHeight: _modalMaxHeight,
          ),
          child: _AdaptiveModalFrame(
            title: title,
            showCloseButton: showCloseButton,
            actions: actions,
            content: content,
            contentPadding: const EdgeInsets.fromLTRB(
              MotifSpacing.lg,
              MotifSpacing.md,
              MotifSpacing.lg,
              MotifSpacing.lg,
            ),
          ),
        ),
      );
    }
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: _AdaptiveModalFrame(
          title: title,
          showCloseButton: showCloseButton,
          actions: actions,
          content: content,
          contentPadding: const EdgeInsets.fromLTRB(
            MotifSpacing.lg,
            MotifSpacing.md,
            MotifSpacing.lg,
            MotifSpacing.lg,
          ),
        ),
      ),
    );
  }
}

class _AdaptiveModalFrame extends StatelessWidget {
  final String title;
  final bool showCloseButton;
  final List<Widget> actions;
  final Widget content;
  final EdgeInsetsGeometry contentPadding;

  const _AdaptiveModalFrame({
    required this.title,
    required this.showCloseButton,
    required this.actions,
    required this.content,
    required this.contentPadding,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveModalHeader(
          title: title,
          showCloseButton: showCloseButton,
          actions: actions,
        ),
        Flexible(
          child: SingleChildScrollView(padding: contentPadding, child: content),
        ),
      ],
    );
  }
}

class AdaptiveModalHeader extends StatelessWidget
    implements PreferredSizeWidget {
  final String title;
  final bool showCloseButton;
  final List<Widget> actions;
  final VoidCallback? onClose;

  const AdaptiveModalHeader({
    super.key,
    required this.title,
    this.showCloseButton = true,
    this.actions = const [],
    this.onClose,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      automaticallyImplyLeading: false,
      primary: false,
      leading: showCloseButton
          ? CloseButton(
              onPressed: onClose ?? () => Navigator.of(context).maybePop(),
            )
          : null,
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      centerTitle: true,
      actions: actions,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
    );
  }
}
