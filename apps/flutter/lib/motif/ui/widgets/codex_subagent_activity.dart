import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../codex/codex_navigation.dart';
import '../../codex/protocol/generated/codex_app_server_protocol.dart';
import '../theme/motif_theme.dart';

/// One lifecycle message at its original position in the parent conversation.
class CodexSubagentActivity extends StatelessWidget {
  const CodexSubagentActivity({
    required this.item,
    this.metadata,
    this.onOpenSubagent,
    super.key,
  });

  final CodexSubAgentActivityThreadItem item;
  final CodexThread? metadata;
  final CodexOpenSubagent? onOpenSubagent;

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final name = codexSubagentName(item, metadata: metadata);
    final identity = item.agentThreadId.codeUnits.fold<int>(
      0,
      (hash, unit) => (hash * 31 + unit) & 0x7fffffff,
    );
    final colors = [
      c.accent,
      c.success,
      c.danger,
      Theme.of(context).colorScheme.tertiary,
    ];
    const icons = [
      Icons.hub_outlined,
      Icons.blur_on,
      Icons.filter_vintage_outlined,
    ];
    final label = switch (item.kind) {
      CodexSubAgentActivityKind.started => 'started',
      CodexSubAgentActivityKind.interacted => 'updated',
      CodexSubAgentActivityKind.interrupted => 'interrupted',
      CodexSubAgentActivityKind.completed => 'finished',
    };
    final open = onOpenSubagent;
    return Semantics(
      link: open != null,
      child: Tooltip(
        message: 'Open $name in Side Chat',
        child: InkWell(
          key: ValueKey('codex-subagent-open-${item.id}'),
          borderRadius: BorderRadius.circular(MotifRadius.xs),
          onTap: open == null
              ? null
              : () => unawaited(
                  Future.sync(() => open(item.agentThreadId, name: name)),
                ),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: MotifSpacing.xs),
            child: Row(
              children: [
                Icon(
                  icons[identity % icons.length],
                  color: colors[identity % colors.length],
                  size: MotifIconSize.sm,
                ),
                const SizedBox(width: MotifSpacing.sm),
                Flexible(
                  child: Text(
                    '$name $label',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MotifType.subhead.copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String codexSubagentName(
  CodexSubAgentActivityThreadItem item, {
  CodexThread? metadata,
}) {
  final leaf = item.agentPath
      .split('/')
      .where((part) => part.isNotEmpty)
      .lastOrNull;
  final name = leaf?.replaceAll(RegExp(r'[_-]+'), ' ').trim();
  if (name != null && name.isNotEmpty) {
    return '${name.substring(0, 1).toUpperCase()}${name.substring(1)}';
  }
  return metadata?.agentNickname ?? metadata?.agentRole ?? 'Sub-agent';
}
