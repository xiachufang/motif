import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import 'quick_command_editor.dart';

/// Manage the global list + per-program quick-command sets (mirrors the iOS
/// QuickCommandSetsView). A set overrides the global list when the running
/// program matches one of its names.
class QuickCommandSetsView extends StatelessWidget {
  const QuickCommandSetsView({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppState>().commands;
    final c = context.motif;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Command sets'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New set',
            onPressed: () => _newSet(context),
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: Icon(Icons.public, color: c.accent),
            title: const Text('Global'),
            subtitle: Text('${store.commands.length} commands · default'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const QuickCommandEditor(),
              ),
            ),
          ),
          const Divider(height: 1),
          for (final s in store.sets)
            ListTile(
              leading: const Icon(Icons.apps),
              title: Text(s.name),
              subtitle: Text(
                s.matches.isEmpty
                    ? 'matches: (none)'
                    : 'matches: ${s.matches.join(", ")}',
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  if (v == 'matches') {
                    await _editMatches(context, s.id, s.matches);
                  } else if (v == 'rename') {
                    await _rename(context, s.id, s.name);
                  } else if (v == 'delete') {
                    await store.removeSet(s.id);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'matches', child: Text('Edit matches')),
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => QuickCommandEditor(setId: s.id),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _newSet(BuildContext context) async {
    final store = context.read<AppState>().commands;
    final result = await _promptNameMatches(context, title: 'New set');
    if (result == null) return;
    await store.createSet(result.$1, result.$2);
  }

  Future<void> _rename(BuildContext context, String id, String current) async {
    final store = context.read<AppState>().commands;
    final name = await _promptText(
      context,
      title: 'Rename set',
      initial: current,
    );
    if (name != null && name.trim().isNotEmpty) {
      await store.renameSet(id, name.trim());
    }
  }

  Future<void> _editMatches(
    BuildContext context,
    String id,
    List<String> current,
  ) async {
    final store = context.read<AppState>().commands;
    final text = await _promptText(
      context,
      title: 'Matched programs (comma-separated)',
      initial: current.join(', '),
    );
    if (text != null) {
      final matches = text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      await store.updateMatches(id, matches);
    }
  }
}

Future<String?> _promptText(
  BuildContext context, {
  required String title,
  String initial = '',
}) {
  final ctrl = TextEditingController(text: initial);
  return showAdaptiveModal<String>(
    context,
    builder: (context) => AdaptiveModal(
      title: title,
      content: TextField(controller: ctrl, autofocus: true),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, ctrl.text),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

Future<(String, List<String>)?> _promptNameMatches(
  BuildContext context, {
  required String title,
}) async {
  final name = TextEditingController();
  final matches = TextEditingController();
  return showAdaptiveModal<(String, List<String>)>(
    context,
    builder: (context) => AdaptiveModal(
      title: title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            decoration: const InputDecoration(labelText: 'Name'),
            autofocus: true,
          ),
          TextField(
            controller: matches,
            decoration: const InputDecoration(
              labelText: 'Programs (e.g. vim, nano)',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () {
            if (name.text.trim().isEmpty) return;
            final m = matches.text
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList();
            Navigator.pop(context, (name.text.trim(), m));
          },
          child: const Text('Create'),
        ),
      ],
    ),
  );
}
