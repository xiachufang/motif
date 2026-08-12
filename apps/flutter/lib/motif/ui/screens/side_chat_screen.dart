import 'dart:async';

import 'package:flutter/material.dart';

import '../../codex/codex_connection_controller.dart';
import '../../codex/codex_service_state.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../../codex/side_chat_collection_controller.dart';
import '../../models/resource_documents.dart';
import '../../platform/window_title.dart';
import '../theme/motif_theme.dart';
import 'codex_resource_screens.dart';
import 'codex_thread_workspace.dart';
import 'side_chat_sidebar.dart';

class SideChatScreen extends StatefulWidget {
  const SideChatScreen({required this.collection, super.key});

  final SideChatCollectionController collection;

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
    unawaited(MotifWindowTitle.set('Side Chat — Motif').catchError((_) {}));
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
              widget.collection.select(threadId);
              if (_scaffoldKey.currentState?.isDrawerOpen == true) {
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
                _scaffoldKey.currentState?.openDrawer();
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
            drawerEnableOpenDragGesture: mobile,
            drawerEdgeDragWidth: 48,
            drawer: mobile
                ? Drawer(width: _sidebarWidth, child: sidebar)
                : null,
            appBar: AppBar(
              leadingWidth: 96,
              leading: Row(children: [const BackButton(), sidebarToggle]),
              title: Text(widget.collection.selected?.name ?? 'Side Chat'),
              actions: [
                IconButton(
                  key: const ValueKey('side-chat-new-toolbar'),
                  tooltip: 'New Side Chat',
                  onPressed: widget.collection.creating
                      ? null
                      : () => widget.collection.createSideChat(),
                  icon: const Icon(Icons.add_comment_outlined),
                ),
              ],
            ),
            body: mobile
                ? _conversationSurface(widget.collection)
                : Row(
                    children: [
                      if (_desktopSidebarVisible) ...[
                        SizedBox(width: _sidebarWidth, child: sidebar),
                        VerticalDivider(width: 1, color: context.motif.border),
                      ],
                      Expanded(child: _conversationSurface(widget.collection)),
                    ],
                  ),
          );
        },
      ),
    );
  }

  Widget _conversationSurface(SideChatCollectionController collection) {
    final entries = collection.entries;
    final selectedId = collection.selected?.id;
    final selectedIndex = entries.indexWhere((entry) => entry.id == selectedId);
    if (selectedIndex != -1) {
      return IndexedStack(
        index: selectedIndex,
        children: [
          for (final entry in entries)
            CodexThreadWorkspace(
              key: ValueKey('side-chat-workspace-${entry.id}'),
              state: entry.conversation,
              turnActionBuilder: _emptyTurnAction,
              onOpenFile: (path) => _openFile(entry.conversation, path),
              onOpenImage: (path) =>
                  _openFile(entry.conversation, path, image: true),
              onOpenTurnDiff: (document, {initialPath}) => _openTurnDiff(
                entry.conversation,
                document,
                initialPath: initialPath,
              ),
            ),
        ],
      );
    }
    final state = collection.connectionState;
    if (state.phase == CodexConnectionPhase.failed ||
        collection.error != null) {
      return _SideChatFailure(
        message: collection.error ?? state.error ?? 'Side Chat failed',
        onRetry: collection.creating ? null : () => collection.ensureInitial(),
      );
    }
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: MotifSpacing.md),
          Text('Creating Side Chat…'),
        ],
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
  const _SideChatFailure({required this.message, required this.onRetry});

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
