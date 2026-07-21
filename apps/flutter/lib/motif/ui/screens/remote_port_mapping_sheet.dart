import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/services.dart';

import '../../state/workspace/remote_port/remote_port_controller.dart';
import '../../state/workspace/remote_port/remote_port_mapping.dart';
import '../../state/workspace/remote_port/remote_ports_view_model.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/top_toast.dart';
import 'remote_port_webview_screen.dart';

part 'remote_port_mapping_sheet.g.dart';

final class _RemotePortPanelCoordinator {
  bool refreshStarted = false;
}

Future<void> showRemotePortMappingsSheet(
  BuildContext context,
  RemotePortController controller,
) {
  return showAdaptivePanel<void>(
    context,
    builder: (_) => _RemotePortMappingsPanel(
      key: ObjectKey(controller),
      controller: controller,
    ),
  );
}

@ObservationWidget()
class _RemotePortMappingsPanel extends _$_RemotePortMappingsPanel {
  const _RemotePortMappingsPanel({required this.controller, super.key});

  final RemotePortController controller;

  @PlainState(name: 'coordinator')
  _RemotePortPanelCoordinator createCoordinator() =>
      _RemotePortPanelCoordinator();

  @override
  bool shouldRecreateStates(covariant _RemotePortMappingsPanel oldWidget) =>
      !identical(oldWidget.controller, controller);

  Future<void> _refreshMappings(_RemotePortPanelCoordinator coordinator) async {
    coordinator.refreshStarted = true;
    try {
      await controller.refresh();
    } catch (_) {}
  }

  Future<void> _addMapping(BuildContext context) async {
    final request = await _showRemotePortForm(context);
    if (!context.mounted || request == null) return;
    try {
      await controller.add(
        remotePort: request.remotePort,
        localScheme: request.scheme,
      );
    } catch (e) {
      if (context.mounted) showMotifToast(context, 'Add port failed: $e');
    }
  }

  Future<void> _editMapping(
    BuildContext context,
    RemotePortMapping mapping,
  ) async {
    final request = await _showRemotePortForm(context, initial: mapping);
    if (!context.mounted || request == null) return;
    try {
      await controller.update(
        mapping.id,
        remotePort: request.remotePort,
        localScheme: request.scheme,
      );
    } catch (e) {
      if (context.mounted) showMotifToast(context, 'Update port failed: $e');
    }
  }

  Future<void> _deleteMapping(
    BuildContext context,
    RemotePortMapping mapping,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete remote port?'),
        content: Text(mapping.displayTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (!context.mounted || ok != true) return;
    try {
      await controller.remove(mapping.id);
    } catch (e) {
      if (context.mounted) showMotifToast(context, 'Delete port failed: $e');
    }
  }

  Future<void> _openWebView(
    BuildContext context,
    RemotePortMapping mapping,
  ) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => RemotePortWebViewScreen(
          initialUrl: mapping.localUrl,
          title: mapping.displayTitle,
        ),
      ),
    );
  }

  @override
  Widget build(
    BuildContext context, {
    required _RemotePortPanelCoordinator coordinator,
  }) {
    if (!coordinator.refreshStarted) {
      coordinator.refreshStarted = true;
      Future.microtask(() => _refreshMappings(coordinator));
    }
    final viewModel = controller.viewModel;
    final mappings = viewModel.mappings;
    final loading =
        viewModel.phase == RemotePortsPhase.idle ||
        viewModel.phase == RemotePortsPhase.loading;
    final error = viewModel.error;
    final c = context.motif;
    return AdaptivePanel(
      title: 'Remote ports',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: loading
              ? null
              : () => unawaited(_refreshMappings(coordinator)),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: 'Add port',
          onPressed: loading ? null : () => _addMapping(context),
        ),
      ],
      body: Builder(
        builder: (context) {
          if (loading && mappings.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (error != null && mappings.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(MotifSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, size: 40, color: c.danger),
                    const SizedBox(height: MotifSpacing.md),
                    Text(
                      'Could not load ports',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: MotifSpacing.xs),
                    Text(
                      error,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: c.textTertiary),
                    ),
                    const SizedBox(height: MotifSpacing.lg),
                    FilledButton.icon(
                      onPressed: () => unawaited(_refreshMappings(coordinator)),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          if (mappings.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(MotifSpacing.xl),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.open_in_browser_outlined,
                      size: 40,
                      color: c.textTertiary,
                    ),
                    const SizedBox(height: MotifSpacing.md),
                    Text(
                      'No ports mapped',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: MotifSpacing.lg),
                    FilledButton.icon(
                      onPressed: () => _addMapping(context),
                      icon: const Icon(Icons.add),
                      label: const Text('Add port'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(MotifSpacing.lg),
            children: [
              MotifSection(
                title: 'Mapped ports',
                dividerIndent: 64,
                children: [
                  for (final mapping in mappings)
                    MotifSectionRow(
                      leading: const Icon(
                        Icons.open_in_browser_outlined,
                        size: 20,
                      ),
                      title: mapping.displayTitle,
                      subtitle:
                          'Local ${mapping.localUrl} -> ${mapping.remoteEndpoint}',
                      minHeight: 64,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit_outlined),
                            tooltip: 'Edit',
                            onPressed: () => _editMapping(context, mapping),
                          ),
                          IconButton(
                            icon: Icon(Icons.delete_outline, color: c.danger),
                            tooltip: 'Delete',
                            onPressed: () => _deleteMapping(context, mapping),
                          ),
                        ],
                      ),
                      onTap: () => _openWebView(context, mapping),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _RemotePortRequest {
  const _RemotePortRequest({required this.remotePort, required this.scheme});

  final int remotePort;
  final String scheme;
}

Future<_RemotePortRequest?> _showRemotePortForm(
  BuildContext context, {
  RemotePortMapping? initial,
}) {
  return showAdaptiveModal<_RemotePortRequest>(
    context,
    builder: (_) => _RemotePortFormModal(
      key: ValueKey('remote-port-form-${initial?.id ?? 'new'}'),
      initial: initial,
    ),
  );
}

@ObservableModel()
class _RemotePortFormViewModel extends _$_RemotePortFormViewModel {
  _RemotePortFormViewModel({String scheme = 'http', String? errorText})
    : super(scheme, errorText);
}

@ObservationWidget()
class _RemotePortFormModal extends _$_RemotePortFormModal {
  const _RemotePortFormModal({this.initial, super.key});

  final RemotePortMapping? initial;

  @PlainState(name: 'portController')
  TextEditingController createPortController() =>
      TextEditingController(text: '${initial?.remotePort ?? 3000}');

  @ObservableState(name: 'viewModel')
  _RemotePortFormViewModel createViewModel() =>
      _RemotePortFormViewModel(scheme: initial?.localScheme ?? 'http');

  @override
  bool shouldRecreateStates(covariant _RemotePortFormModal oldWidget) =>
      oldWidget.initial?.id != initial?.id;

  _RemotePortRequest? _buildRequest(
    TextEditingController portController,
    _RemotePortFormViewModel viewModel,
  ) {
    final port = int.tryParse(portController.text.trim());
    if (port == null || port <= 0 || port > 65535) return null;
    return _RemotePortRequest(remotePort: port, scheme: viewModel.scheme);
  }

  void _submit(
    BuildContext context,
    TextEditingController portController,
    _RemotePortFormViewModel viewModel,
  ) {
    final request = _buildRequest(portController, viewModel);
    if (request == null) {
      viewModel.errorText = 'Enter a port from 1 to 65535';
      return;
    }
    Navigator.of(context).pop(request);
  }

  @override
  Widget build(
    BuildContext context, {
    required TextEditingController portController,
    required _RemotePortFormViewModel viewModel,
  }) {
    return AdaptiveModal(
      title: initial == null ? 'Add port' : 'Edit port',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: portController,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Remote port',
              hintText: '3000',
              errorText: viewModel.errorText,
            ),
            onChanged: (_) {
              if (viewModel.errorText != null) viewModel.errorText = null;
            },
            onSubmitted: (_) => _submit(context, portController, viewModel),
          ),
          const SizedBox(height: MotifSpacing.md),
          DropdownButtonFormField<String>(
            initialValue: viewModel.scheme,
            decoration: const InputDecoration(labelText: 'Open as'),
            items: const [
              DropdownMenuItem(value: 'http', child: Text('http')),
              DropdownMenuItem(value: 'https', child: Text('https')),
            ],
            onChanged: (value) {
              if (value == null) return;
              viewModel.scheme = value;
            },
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => _submit(context, portController, viewModel),
          child: const Text('Save'),
        ),
      ],
    );
  }
}
