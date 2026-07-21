import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';

import '../../models/motif_proto.dart';
import '../../state/server/session_catalog_controller.dart';
import '../../state/workspace/workspace_api.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/top_toast.dart';
import 'change_directory_panel.dart';
import 'session_name_generator.dart';

part 'create_session_dialog.g.dart';

Future<SessionInfo?> createSessionWithDialog(
  BuildContext context,
  SessionCatalogController sessions,
  WorkspaceApi workspace,
) async {
  final result = await showAdaptiveModal<(String, String)>(
    context,
    builder: (_) => _CreateSessionDialog(
      key: const ValueKey('create-session-dialog'),
      sessions: sessions,
      workspace: workspace,
    ),
  );
  if (result == null) return null;
  try {
    return await sessions.create(result.$1, result.$2);
  } catch (e) {
    if (context.mounted) {
      showMotifToast(context, 'Create failed: $e');
    }
    return null;
  }
}

@ObservableModel()
class _CreateSessionDialogViewModel extends _$_CreateSessionDialogViewModel {
  _CreateSessionDialogViewModel({bool canCreate = true}) : super(canCreate);
}

@ObservationWidget()
class _CreateSessionDialog extends _$_CreateSessionDialog {
  const _CreateSessionDialog({
    required this.sessions,
    required this.workspace,
    super.key,
  });

  final SessionCatalogController sessions;
  final WorkspaceApi workspace;

  @PlainState(name: 'nameController')
  TextEditingController createNameController() => TextEditingController(
    text: generateSessionName(
      existingNames: sessions.viewModel.sessions.map((session) => session.name),
    ),
  );

  @PlainState(name: 'workdirController')
  TextEditingController createWorkdirController() =>
      TextEditingController(text: '~');

  @ObservableState(name: 'viewModel')
  _CreateSessionDialogViewModel createViewModel() =>
      _CreateSessionDialogViewModel();

  @override
  Widget build(
    BuildContext context, {
    required TextEditingController nameController,
    required TextEditingController workdirController,
    required _CreateSessionDialogViewModel viewModel,
  }) {
    return AdaptiveModal(
      title: 'New session',
      content: MotifSection(
        title: 'Session',
        dividerIndent: MotifSpacing.lg,
        children: [
          _sectionField(
            controller: nameController,
            label: 'Name',
            onChanged: (value) => viewModel.canCreate = value.trim().isNotEmpty,
          ),
          _sectionField(
            controller: workdirController,
            label: 'Working directory',
            trailing: IconButton(
              icon: const Icon(Icons.folder_open),
              tooltip: 'Browse',
              onPressed: () => _pickWorkdir(context, workdirController),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: viewModel.canCreate
              ? () => Navigator.pop(context, (
                  nameController.text.trim(),
                  workdirController.text.trim(),
                ))
              : null,
          child: const Text('Create'),
        ),
      ],
    );
  }

  void _pickWorkdir(
    BuildContext context,
    TextEditingController workdirController,
  ) {
    final current = workdirController.text.trim();
    showChangeDirectorySheet(
      context,
      workspace: workspace,
      baseDir: current.isEmpty ? '~' : current,
      onChoose: (path) => workdirController.text = path,
    );
  }

  Widget _sectionField({
    required TextEditingController controller,
    required String label,
    ValueChanged<String>? onChanged,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      child: TextField(
        controller: controller,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          isDense: true,
          suffixIcon: trailing,
        ),
        onChanged: onChanged,
      ),
    );
  }
}
