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
const double _sheetMaxHeightFraction = 0.86;

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
    return showDialog<T>(
      context: context,
      barrierDismissible: false,
      builder: builder,
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    clipBehavior: Clip.antiAlias,
    backgroundColor: background,
    builder: (context) => _KeyboardAwareSheet(
      maxHeightFraction: _sheetMaxHeightFraction,
      child: builder(context),
    ),
  );
}

/// Shows a full-page panel as an 86%-height bottom sheet on iOS/Android and as
/// a fixed-size [Dialog] elsewhere.
///
/// The builder should return an [AdaptivePanel], which renders the shared
/// header/frame while allowing the body to manage its own scrolling.
Future<T?> showAdaptivePanel<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  final background = context.motif.background;
  if (!_useSheet) {
    return showDialog<T>(
      context: context,
      barrierDismissible: false,
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
    backgroundColor: Colors.transparent,
    builder: (context) => _KeyboardAwareSheet(
      maxHeightFraction: _sheetMaxHeightFraction,
      fillHeight: true,
      child: _DraggablePanelSheet(
        backgroundColor: background,
        builder: builder,
      ),
    ),
  );
}

class _KeyboardAwareSheet extends StatefulWidget {
  final Widget child;
  final double maxHeightFraction;
  final bool fillHeight;

  const _KeyboardAwareSheet({
    required this.child,
    required this.maxHeightFraction,
    this.fillHeight = false,
  });

  @override
  State<_KeyboardAwareSheet> createState() => _KeyboardAwareSheetState();
}

class _KeyboardAwareSheetState extends State<_KeyboardAwareSheet> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusChanged);
    super.dispose();
  }

  void _onFocusChanged() {
    if (mounted) setState(() {});
  }

  bool _hasPrimaryFocusInSheet() {
    final focusedContext = FocusManager.instance.primaryFocus?.context;
    if (focusedContext is! Element || context is! Element) return false;
    final sheetElement = context as Element;
    if (identical(focusedContext, sheetElement)) return true;
    var containsFocus = false;
    focusedContext.visitAncestorElements((ancestor) {
      if (identical(ancestor, sheetElement)) {
        containsFocus = true;
        return false;
      }
      return true;
    });
    return containsFocus;
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboardInset = _hasPrimaryFocusInSheet()
        ? media.viewInsets.bottom
        : 0.0;
    final topGap = media.viewPadding.top + MotifSpacing.sm;
    final maxHeight = (media.size.height - topGap)
        .clamp(0.0, media.size.height)
        .toDouble();
    final sheetHeight = (media.size.height * widget.maxHeightFraction)
        .clamp(0.0, maxHeight)
        .toDouble();
    final minVisibleHeight = (kToolbarHeight + MotifSpacing.lg)
        .clamp(0.0, sheetHeight)
        .toDouble();
    final bottomInset = keyboardInset
        .clamp(0.0, sheetHeight - minVisibleHeight)
        .toDouble();
    final paddedChild = AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: widget.child,
    );
    final boundedChild = widget.fillHeight
        ? SizedBox(height: sheetHeight, child: paddedChild)
        : ConstrainedBox(
            constraints: BoxConstraints(maxHeight: sheetHeight),
            child: paddedChild,
          );
    return boundedChild;
  }
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
  final Color backgroundColor;

  static const restingSize = 1.0;

  const _DraggablePanelSheet({
    required this.backgroundColor,
    required this.builder,
  });

  @override
  State<_DraggablePanelSheet> createState() => _DraggablePanelSheetState();
}

class _DraggablePanelSheetState extends State<_DraggablePanelSheet> {
  final _controller = DraggableScrollableController();
  int _pointersDown = 0;
  double _lastExtent = _DraggablePanelSheet.restingSize;
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
        extent < _DraggablePanelSheet.restingSize - 0.001;
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
          initialChildSize: _DraggablePanelSheet.restingSize,
          minChildSize: 0,
          maxChildSize: _DraggablePanelSheet.restingSize,
          snap: true,
          builder: (context, scrollController) => PrimaryScrollController(
            controller: scrollController,
            child: Material(
              color: widget.backgroundColor,
              surfaceTintColor: Colors.transparent,
              clipBehavior: Clip.antiAlias,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(MotifRadius.xl),
                ),
              ),
              child: widget.builder(context),
            ),
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
            scrollContent: true,
            expandContent: false,
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
          scrollContent: true,
          expandContent: false,
        ),
      ),
    );
  }
}

/// Full-height panel body for [showAdaptivePanel].
///
/// Unlike [AdaptiveModal], the body is not wrapped in a scroll view. Pass a
/// [ListView], [CustomScrollView], or another self-managed layout.
class AdaptivePanel extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget> actions;
  final bool showCloseButton;
  final VoidCallback? onClose;

  const AdaptivePanel({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.showCloseButton = true,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: _AdaptiveModalFrame(
        title: title,
        showCloseButton: showCloseButton,
        actions: actions,
        onClose: onClose,
        content: body,
        contentPadding: EdgeInsets.zero,
        scrollContent: false,
        expandContent: true,
      ),
    );
  }
}

class _AdaptiveModalFrame extends StatelessWidget {
  final String title;
  final bool showCloseButton;
  final List<Widget> actions;
  final VoidCallback? onClose;
  final Widget content;
  final EdgeInsetsGeometry contentPadding;
  final bool scrollContent;
  final bool expandContent;

  const _AdaptiveModalFrame({
    required this.title,
    required this.showCloseButton,
    required this.actions,
    this.onClose,
    required this.content,
    required this.contentPadding,
    required this.scrollContent,
    required this.expandContent,
  });

  @override
  Widget build(BuildContext context) {
    final body = scrollContent
        ? SingleChildScrollView(
            padding: contentPadding,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: content,
          )
        : Padding(padding: contentPadding, child: content);
    return Column(
      mainAxisSize: expandContent ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AdaptiveModalHeader(
          title: title,
          showCloseButton: showCloseButton,
          actions: actions,
          onClose: onClose,
        ),
        if (expandContent) Expanded(child: body) else Flexible(child: body),
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
