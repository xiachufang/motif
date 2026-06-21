import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/motif_client.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/top_toast.dart';
import 'remote_port_webview_screen.dart';

Future<void> showRemotePortMappingsSheet(
  BuildContext context,
  MotifClient motif,
) {
  return showAdaptivePanel<void>(
    context,
    builder: (_) => _RemotePortMappingsPanel(motif: motif),
  );
}

class _RemotePortMappingsPanel extends StatelessWidget {
  const _RemotePortMappingsPanel({required this.motif});

  final MotifClient motif;

  Future<void> _addMapping(BuildContext context) async {
    final request = await _showRemotePortForm(context);
    if (!context.mounted || request == null) return;
    try {
      await motif.addRemotePortMapping(
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
      await motif.updateRemotePortMapping(
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
      await motif.removeRemotePortMapping(mapping.id);
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
  Widget build(BuildContext context) {
    final c = context.motif;
    return ColoredBox(
      color: c.background,
      child: Column(
        children: [
          AdaptiveModalHeader(
            title: 'Remote ports',
            actions: [
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Add port',
                onPressed: () => _addMapping(context),
              ),
            ],
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: motif,
              builder: (context, _) {
                final mappings = motif.remotePortMappings;
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
                                  onPressed: () =>
                                      _editMapping(context, mapping),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline,
                                    color: c.danger,
                                  ),
                                  tooltip: 'Delete',
                                  onPressed: () =>
                                      _deleteMapping(context, mapping),
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
          ),
        ],
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
}) async {
  final portController = TextEditingController(
    text: '${initial?.remotePort ?? 3000}',
  );
  var scheme = initial?.localScheme ?? 'http';
  String? errorText;

  _RemotePortRequest? buildRequest() {
    final port = int.tryParse(portController.text.trim());
    if (port == null || port <= 0 || port > 65535) return null;
    return _RemotePortRequest(remotePort: port, scheme: scheme);
  }

  try {
    return await showAdaptiveModal<_RemotePortRequest>(
      context,
      builder: (modalContext) => StatefulBuilder(
        builder: (context, setModalState) {
          void submit() {
            final request = buildRequest();
            if (request == null) {
              setModalState(() => errorText = 'Enter a port from 1 to 65535');
              return;
            }
            Navigator.of(modalContext).pop(request);
          }

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
                    errorText: errorText,
                  ),
                  onChanged: (_) {
                    if (errorText != null) {
                      setModalState(() => errorText = null);
                    }
                  },
                  onSubmitted: (_) => submit(),
                ),
                const SizedBox(height: MotifSpacing.md),
                DropdownButtonFormField<String>(
                  initialValue: scheme,
                  decoration: const InputDecoration(labelText: 'Open as'),
                  items: const [
                    DropdownMenuItem(value: 'http', child: Text('http')),
                    DropdownMenuItem(value: 'https', child: Text('https')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setModalState(() => scheme = value);
                  },
                ),
              ],
            ),
            actions: [TextButton(onPressed: submit, child: const Text('Save'))],
          );
        },
      ),
    );
  } finally {
    portController.dispose();
  }
}
