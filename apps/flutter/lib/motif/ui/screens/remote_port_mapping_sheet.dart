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
    return AdaptivePanel(
      title: 'Remote ports',
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: 'Add port',
          onPressed: () => _addMapping(context),
        ),
      ],
      body: ListenableBuilder(
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
    builder: (_) => _RemotePortFormModal(initial: initial),
  );
}

class _RemotePortFormModal extends StatefulWidget {
  const _RemotePortFormModal({this.initial});

  final RemotePortMapping? initial;

  @override
  State<_RemotePortFormModal> createState() => _RemotePortFormModalState();
}

class _RemotePortFormModalState extends State<_RemotePortFormModal> {
  late final TextEditingController _portController;
  late String _scheme;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _portController = TextEditingController(
      text: '${widget.initial?.remotePort ?? 3000}',
    );
    _scheme = widget.initial?.localScheme ?? 'http';
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  _RemotePortRequest? _buildRequest() {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port <= 0 || port > 65535) return null;
    return _RemotePortRequest(remotePort: port, scheme: _scheme);
  }

  void _submit() {
    final request = _buildRequest();
    if (request == null) {
      setState(() => _errorText = 'Enter a port from 1 to 65535');
      return;
    }
    Navigator.of(context).pop(request);
  }

  @override
  Widget build(BuildContext context) {
    return AdaptiveModal(
      title: widget.initial == null ? 'Add port' : 'Edit port',
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _portController,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Remote port',
              hintText: '3000',
              errorText: _errorText,
            ),
            onChanged: (_) {
              if (_errorText != null) {
                setState(() => _errorText = null);
              }
            },
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: MotifSpacing.md),
          DropdownButtonFormField<String>(
            initialValue: _scheme,
            decoration: const InputDecoration(labelText: 'Open as'),
            items: const [
              DropdownMenuItem(value: 'http', child: Text('http')),
              DropdownMenuItem(value: 'https', child: Text('https')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _scheme = value);
            },
          ),
        ],
      ),
      actions: [TextButton(onPressed: _submit, child: const Text('Save'))],
    );
  }
}
