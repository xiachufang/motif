import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../codex/codex_connection_controller.dart';
import '../../codex/codex_service_state.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../../codex/side_chat_collection_controller.dart';
import '../../models/resource_documents.dart';
import '../../platform/window_title.dart';
import '../theme/motif_theme.dart';
import '../widgets/codex_motion.dart';
import 'codex_resource_screens.dart';
import 'codex_thread_workspace.dart';
import 'side_chat_sidebar.dart';

class SideChatScreen extends StatefulWidget {
  const SideChatScreen({
    required this.collection,
    this.manageWindowTitle = true,
    super.key,
  });

  final SideChatCollectionController collection;
  final bool manageWindowTitle;

  @override
  State<SideChatScreen> createState() => _SideChatScreenState();
}

class _SideChatScreenState extends State<SideChatScreen> {
  static const _mobileBreakpoint = 768.0;
  static const _sidebarWidth = 288.0;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _desktopSidebarVisible = true;

  @override
  void initState() {
    super.initState();
    if (widget.manageWindowTitle) {
      unawaited(MotifWindowTitle.set('Side Chat — Motif').catchError((_) {}));
    }
    unawaited(widget.collection.ensureInitial());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.collection,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final mobile = constraints.maxWidth < _mobileBreakpoint;
          final sidebar = SideChatSidebar(
            collection: widget.collection,
            onSelected: (threadId) {
              unawaited(widget.collection.select(threadId));
              if (_scaffoldKey.currentState?.isEndDrawerOpen == true) {
                Navigator.of(context).pop();
              }
            },
          );
          final sidebarToggle = IconButton(
            key: const ValueKey('side-chat-sidebar-toggle'),
            tooltip: mobile
                ? 'Open Side Chat list'
                : _desktopSidebarVisible
                ? 'Hide Side Chat list'
                : 'Show Side Chat list',
            onPressed: () {
              if (mobile) {
                _scaffoldKey.currentState?.openEndDrawer();
              } else {
                setState(
                  () => _desktopSidebarVisible = !_desktopSidebarVisible,
                );
              }
            },
            icon: Icon(
              mobile || !_desktopSidebarVisible
                  ? Icons.menu_rounded
                  : Icons.menu_open_rounded,
            ),
          );
          return Scaffold(
            key: _scaffoldKey,
            backgroundColor: context.motif.surface,
            endDrawerEnableOpenDragGesture: mobile,
            drawerEdgeDragWidth: 48,
            endDrawer: mobile
                ? Drawer(width: _sidebarWidth, child: sidebar)
                : null,
            appBar: AppBar(
              leading: const BackButton(),
              title: CodexMotionSwitcher(
                offset: const Offset(0, 0.12),
                child: Text(
                  widget.collection.selected?.name ?? 'Side Chat',
                  key: ValueKey(
                    'side-chat-title-${widget.collection.selected?.id ?? 'empty'}',
                  ),
                ),
              ),
              actions: [
                sidebarToggle,
                IconButton(
                  key: const ValueKey('side-chat-new-toolbar'),
                  tooltip: 'New Side Chat',
                  onPressed: widget.collection.creating
                      ? null
                      : () => widget.collection.createSideChat(),
                  icon: CodexMotionSwitcher(
                    offset: Offset.zero,
                    child: widget.collection.creating
                        ? const SizedBox.square(
                            key: ValueKey('side-chat-creating'),
                            dimension: MotifIconSize.md,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.add_comment_outlined,
                            key: ValueKey('side-chat-create'),
                          ),
                  ),
                ),
              ],
            ),
            body: mobile
                ? _conversationSurface(widget.collection)
                : CodexAnimatedSidebarLayout(
                    visible: _desktopSidebarVisible,
                    sidebarExtent: _sidebarWidth + 1,
                    sidebar: Row(
                      children: [
                        SizedBox(width: _sidebarWidth, child: sidebar),
                        VerticalDivider(width: 1, color: context.motif.border),
                      ],
                    ),
                    mainContent: _conversationSurface(widget.collection),
                  ),
          );
        },
      ),
    );
  }

  Widget _conversationSurface(SideChatCollectionController collection) {
    final selected = collection.selected;
    final conversation = collection.selectedConversation;
    if (selected != null && conversation != null) {
      return CodexThreadWorkspace(
        key: ValueKey('side-chat-workspace-${selected.id}'),
        state: conversation,
        turnActionBuilder: _emptyTurnAction,
        onOpenFile: (path) => _openFile(conversation, path),
        onOpenImage: (path) => _openFile(conversation, path, image: true),
        onOpenTurnDiff: (document, {initialPath}) =>
            _openTurnDiff(conversation, document, initialPath: initialPath),
      );
    }
    final state = collection.connectionState;
    if (state.phase == CodexConnectionPhase.failed ||
        collection.error != null) {
      return CodexMotionSwitcher(
        child: _SideChatFailure(
          key: const ValueKey('side-chat-failure'),
          message: collection.error ?? state.error ?? 'Side Chat failed',
          onRetry: collection.creating
              ? null
              : () => collection.ensureInitial(),
        ),
      );
    }
    return const CodexMotionSwitcher(
      child: Center(
        key: ValueKey('side-chat-loading'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: MotifSpacing.md),
            Text('Creating Side Chat…'),
          ],
        ),
      ),
    );
  }

  Future<void> _openFile(
    CodexConversationState state,
    String path, {
    bool image = false,
  }) {
    final uri = Uri.tryParse(path);
    final networkImage =
        image &&
        uri != null &&
        const {'http', 'https', 'data'}.contains(uri.scheme);
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => networkImage
            ? CodexNetworkImageScreen(url: path)
            : CodexFilePreviewScreen(state: state, path: path, image: image),
      ),
    );
  }

  Future<void> _openTurnDiff(
    CodexConversationState state,
    DiffDocument document, {
    String? initialPath,
  }) => Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => CodexTurnDiffScreen(
        document: document,
        initialPath: initialPath,
        onOpenFile: (path) => _openFile(state, path),
      ),
    ),
  );
}

Widget _emptyTurnAction(
  BuildContext context,
  CodexConversationState state,
  CodexTurn turn,
) => const SizedBox.shrink();

class _SideChatFailure extends StatelessWidget {
  const _SideChatFailure({
    required this.message,
    required this.onRetry,
    super.key,
  });

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(MotifSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline_rounded,
              color: c.danger,
              size: MotifControlSize.md,
            ),
            const SizedBox(height: MotifSpacing.md),
            Text(
              message,
              textAlign: TextAlign.center,
              style: MotifType.body.copyWith(color: c.textSecondary),
            ),
            const SizedBox(height: MotifSpacing.lg),
            OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
