import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../state/app/app_state.dart';
import '../../state/app/motif_scope.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import 'quick_command_editor.dart';

part 'quick_command_sets_view.g.dart';

/// Manage the global list + per-program quick-command sets (mirrors the iOS
/// QuickCommandSetsView). A set overrides the global list when the running
/// program matches one of its names.
@ObservationWidget()
class QuickCommandSetsView extends _$QuickCommandSetsView {
  const QuickCommandSetsView({super.key});

  @override
  Widget build(BuildContext context) {
    final store = ObservationScope.of<AppState>(context).commands;
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
                // PopupMenuButton feeds the ambient icon color into its internal
                // IconButton, which regenerates a non-transparent hover overlay;
                // this shared style forces it back to transparent.
                style: motifNoButtonFeedback,
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
    final store = readObservationScope<AppState>(context).commands;
    final result = await _promptNameMatches(context, title: 'New set');
    if (result == null) return;
    await store.createSet(result.$1, result.$2);
  }

  Future<void> _rename(BuildContext context, String id, String current) async {
    final store = readObservationScope<AppState>(context).commands;
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
    final store = readObservationScope<AppState>(context).commands;
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
      content: MotifSection(
        title: 'Details',
        dividerIndent: MotifSpacing.lg,
        children: [
          _sectionField(controller: ctrl, label: 'Name', autofocus: true),
        ],
      ),
      actions: [
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
      content: MotifSection(
        title: 'Details',
        dividerIndent: MotifSpacing.lg,
        children: [
          _sectionField(controller: name, label: 'Name', autofocus: true),
          _sectionField(
            controller: matches,
            label: 'Programs',
            hint: 'e.g. vim, nano',
          ),
        ],
      ),
      actions: [
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

Widget _sectionField({
  required TextEditingController controller,
  required String label,
  String? hint,
  bool autofocus = false,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: MotifSpacing.md,
      vertical: MotifSpacing.sm,
    ),
    child: TextField(
      controller: controller,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
        isDense: true,
      ),
    ),
  );
}
