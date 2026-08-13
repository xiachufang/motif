import 'package:material_ui/material_ui.dart';

import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../../codex/side_chat_collection_controller.dart';
import '../theme/motif_theme.dart';
import '../widgets/codex_motion.dart';
import '../widgets/codex_sidebar_components.dart';

class SideChatSidebar extends StatelessWidget {
  const SideChatSidebar({
    required this.collection,
    required this.onSelected,
    super.key,
  });

  final SideChatCollectionController collection;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final entries = collection.entries;
    final priority = entries
        .where((entry) => entry.status is CodexActiveThreadStatus)
        .toList(growable: false);
    final dated = entries
        .where((entry) => entry.status is! CodexActiveThreadStatus)
        .toList(growable: false);
    final groups = <String, List<SideChatEntry>>{};
    for (final entry in dated) {
      groups.putIfAbsent(_dateLabel(entry.lastActivityAt), () => []).add(entry);
    }
    final rows = <Widget>[];
    if (priority.isNotEmpty) {
      rows.add(const CodexSidebarSectionHeading('Priority'));
      rows.addAll(priority.map(_entryRow));
    }
    for (final group in groups.entries) {
      rows.add(CodexSidebarSectionHeading(group.key));
      rows.addAll(group.value.map(_entryRow));
    }
    if (rows.isEmpty && !collection.creating) {
      rows.add(
        Padding(
          padding: const EdgeInsets.all(MotifSpacing.xl),
          child: Text(
            'No Side Chats',
            textAlign: TextAlign.center,
            style: MotifType.body.copyWith(color: c.textTertiary),
          ),
        ),
      );
    }
    return ColoredBox(
      key: const ValueKey('side-chat-sidebar'),
      color: c.surface,
      child: SafeArea(
        child: Column(
          children: [
            CodexSidebarHeader(
              label: 'Side Chats',
              actions: [
                CodexSidebarIconButton(
                  key: const ValueKey('new-side-chat'),
                  icon: Icons.add_comment_outlined,
                  tooltip: 'New Side Chat',
                  selected: false,
                  busy: collection.creating,
                  onTap: collection.creating ? null : collection.createSideChat,
                ),
              ],
            ),
            Divider(height: 1, color: c.border),
            Expanded(
              child: CodexMotionSwitcher(
                child: collection.creating && entries.isEmpty
                    ? const Center(
                        key: ValueKey('side-chat-sidebar-loading'),
                        child: CircularProgressIndicator(),
                      )
                    : ListView(
                        key: const ValueKey('side-chat-list'),
                        padding: const EdgeInsets.only(bottom: MotifSpacing.xl),
                        children: rows,
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entryRow(SideChatEntry entry) {
    final active = entry.status is CodexActiveThreadStatus;
    final failed = entry.status is CodexSystemErrorThreadStatus;
    return CodexSidebarThreadRow(
      key: ValueKey('side-chat-${entry.id}'),
      title: entry.name,
      selected: collection.selected?.id == entry.id,
      active: active,
      trailing: failed
          ? Builder(
              builder: (context) => Icon(
                Icons.error_outline_rounded,
                size: MotifIconSize.sm,
                color: context.motif.danger,
              ),
            )
          : null,
      onTap: () => onSelected(entry.id),
    );
  }
}

String _dateLabel(DateTime value, {DateTime? now}) {
  final date = value.toLocal();
  final localNow = (now ?? DateTime.now()).toLocal();
  final today = DateTime(localNow.year, localNow.month, localNow.day);
  final day = DateTime(date.year, date.month, date.day);
  final difference = today.difference(day).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  String two(int part) => part.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)}';
}
