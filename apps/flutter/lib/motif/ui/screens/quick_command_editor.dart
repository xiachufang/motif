import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/key_picker.dart';
import '../widgets/motif_form.dart';
import 'quick_command_sets_view.dart';

/// Reorderable editor for the global or per-program quick-command list.
class QuickCommandEditor extends StatelessWidget {
  /// null = global list; otherwise a per-program set id.
  final String? setId;
  const QuickCommandEditor({super.key, this.setId});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppState>().commands;
    final c = context.motif;
    final cmds = store.commandsForScope(setId);
    final title = setId == null
        ? 'Quick commands'
        : (store.setById(setId!)?.name ?? 'Set');
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          if (setId == null)
            IconButton(
              icon: const Icon(Icons.apps),
              tooltip: 'Command sets',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const QuickCommandSetsView(),
                ),
              ),
            ),
          if (setId == null)
            PopupMenuButton<String>(
              style: motifNoButtonFeedback,
              onSelected: (v) {
                if (v == 'reset') store.resetToDefaults();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'reset', child: Text('Reset to defaults')),
              ],
            ),
          PopupMenuButton<String>(
            style: motifNoButtonFeedback,
            icon: const Icon(Icons.add),
            tooltip: 'Add command',
            onSelected: (v) => _add(context, v),
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'snippet',
                child: Text('Key or text snippet'),
              ),
              PopupMenuItem(
                value: 'paste',
                enabled: !cmds.any((c) => c.kind == QuickCommandKind.paste),
                child: const Text('Paste from clipboard'),
              ),
              PopupMenuItem(
                value: 'ctrl',
                enabled: !cmds.any((c) => c.kind == QuickCommandKind.ctrl),
                child: const Text('Ctrl modifier'),
              ),
              PopupMenuItem(
                value: 'alt',
                enabled: !cmds.any((c) => c.kind == QuickCommandKind.alt),
                child: const Text('Alt modifier'),
              ),
              PopupMenuItem(
                value: 'shift',
                enabled: !cmds.any((c) => c.kind == QuickCommandKind.shift),
                child: const Text('Shift modifier'),
              ),
              PopupMenuItem(
                value: 'cd',
                enabled: !cmds.any((c) => c.kind == QuickCommandKind.cd),
                child: const Text('Change directory'),
              ),
            ],
          ),
        ],
      ),
      // Inset-grouped to match the rest of the settings surfaces. The
      // ReorderableListView / onReorderItem / item keys are unchanged — only
      // each row's chrome is restyled — so the reorder behaviour is preserved.
      body: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        padding: const EdgeInsets.fromLTRB(
          MotifSpacing.lg,
          MotifSpacing.md,
          MotifSpacing.lg,
          MotifSpacing.xl,
        ),
        itemCount: cmds.length,
        onReorderItem: (o, n) => store.moveItemIn(setId, o, n),
        itemBuilder: (context, i) {
          final cmd = cmds[i];
          final editable = cmd.kind == QuickCommandKind.bytes;
          final first = i == 0;
          final last = i == cmds.length - 1;
          return DecoratedBox(
            key: ValueKey(cmd.id),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(first ? MotifRadius.sm : 0),
                bottom: Radius.circular(last ? MotifRadius.sm : 0),
              ),
              border: Border(
                left: BorderSide(color: c.border),
                right: BorderSide(color: c.border),
                top: BorderSide(color: c.border),
                bottom: last ? BorderSide(color: c.border) : BorderSide.none,
              ),
            ),
            child: MotifSectionRow(
              leading: Icon(
                _iconFor(cmd.kind),
                color: c.textSecondary,
                size: MotifIconSize.md,
              ),
              title: cmd.label,
              subtitle: _describe(cmd),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (editable)
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _edit(context, cmd),
                    ),
                  IconButton(
                    icon: Icon(Icons.delete_outline, color: c.danger),
                    onPressed: () => store.removeAtIn(setId, i),
                  ),
                  ReorderableDragStartListener(
                    index: i,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MotifSpacing.sm,
                      ),
                      child: Icon(
                        Icons.drag_handle,
                        color: c.textSecondary,
                        size: MotifIconSize.md,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  IconData _iconFor(QuickCommandKind k) => switch (k) {
    QuickCommandKind.paste => Icons.content_paste,
    QuickCommandKind.ctrl ||
    QuickCommandKind.alt ||
    QuickCommandKind.shift => Icons.keyboard_option_key,
    QuickCommandKind.cd => Icons.folder_outlined,
    QuickCommandKind.bytes => Icons.keyboard,
  };

  String _describe(QuickCommand cmd) {
    if (cmd.kind != QuickCommandKind.bytes) {
      return switch (cmd.kind) {
        QuickCommandKind.paste => 'clipboard',
        QuickCommandKind.ctrl ||
        QuickCommandKind.alt ||
        QuickCommandKind.shift => 'sticky modifier',
        QuickCommandKind.cd => 'directory picker',
        QuickCommandKind.bytes => '',
      };
    }
    final preview = _payloadPreview(cmd.payload);
    final mods = cmd.modifiers.glyphs;
    final action = cmd.sendImmediately ? 'send' : 'insert';
    return mods.isEmpty ? '$action · $preview' : '$action · $mods $preview';
  }

  Future<void> _add(BuildContext context, String value) async {
    final store = context.read<AppState>().commands;
    final id = newQuickCommandId();
    switch (value) {
      case 'snippet':
        await _edit(context, null);
      case 'paste':
        await store.addTo(setId, QuickCommand.paste(id));
      case 'ctrl':
        await store.addTo(setId, QuickCommand.ctrlModifier(id));
      case 'alt':
        await store.addTo(setId, QuickCommand.altModifier(id));
      case 'shift':
        await store.addTo(setId, QuickCommand.shiftModifier(id));
      case 'cd':
        await store.addTo(setId, QuickCommand.cd(id));
    }
  }

  Future<void> _edit(BuildContext context, QuickCommand? existing) async {
    final store = context.read<AppState>().commands;
    final result = await showAdaptiveModal<QuickCommand>(
      context,
      builder: (_) => _EditDialog(existing: existing),
    );
    if (result == null) return;
    if (existing == null) {
      await store.addTo(setId, result);
    } else {
      await store.updateIn(setId, result);
    }
  }
}

class _EditDialog extends StatefulWidget {
  final QuickCommand? existing;
  const _EditDialog({this.existing});

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

enum _PayloadMode { text, key }

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController _label;
  late final TextEditingController _symbol;
  late final TextEditingController _text;
  late bool _sendImmediately;
  late bool _ctrl;
  late bool _alt;
  late bool _shift;
  late _PayloadMode _mode;
  TerminalKeyDef? _key;

  @override
  void initState() {
    super.initState();
    _label = TextEditingController(text: widget.existing?.label ?? '');
    _symbol = TextEditingController(text: widget.existing?.symbol ?? '');
    _text = TextEditingController(
      text: widget.existing == null ? '' : _qcDecode(widget.existing!.payload),
    );
    _sendImmediately = widget.existing?.sendImmediately ?? true;
    _ctrl = widget.existing?.modifiers.ctrl ?? false;
    _alt = widget.existing?.modifiers.alt ?? false;
    _shift = widget.existing?.modifiers.shift ?? false;
    // Existing payloads that match a known key open in key mode.
    _key = widget.existing == null
        ? null
        : terminalKeyForBytes(widget.existing!.payload);
    _mode = _key == null ? _PayloadMode.text : _PayloadMode.key;
  }

  @override
  void dispose() {
    _label.dispose();
    _symbol.dispose();
    _text.dispose();
    super.dispose();
  }

  void _save() {
    final symbol = _symbol.text.trim();
    final isKey = _mode == _PayloadMode.key;
    Navigator.pop(
      context,
      QuickCommand(
        id: widget.existing?.id ?? newQuickCommandId(),
        label: _label.text.trim(),
        symbol: symbol.isEmpty ? null : symbol,
        payload: isKey
            ? Uint8List.fromList(_key!.bytes)
            : _qcEncode(_text.text),
        // Keys are escape sequences; inserting them into the composer is
        // meaningless, so they always send.
        sendImmediately: isKey || _sendImmediately,
        modifiers: QuickCommandModifiers(ctrl: _ctrl, alt: _alt, shift: _shift),
      ),
    );
  }

  Future<void> _pickKey() async {
    final previous = _key;
    final picked = await showKeyPicker(context);
    if (picked == null) return;
    setState(() {
      _key = picked;
      // Follow the picked key unless the user typed a custom label/symbol.
      if (_label.text.trim().isEmpty || _label.text == previous?.label) {
        _label.text = picked.label;
      }
      if (_symbol.text.trim().isEmpty || _symbol.text == previous?.symbol) {
        _symbol.text = picked.symbol ?? '';
      }
    });
  }

  List<Widget> _buildFields() {
    final isKey = _mode == _PayloadMode.key;
    return [
      MotifSection(
        title: 'Payload type',
        dividerIndent: MotifSpacing.lg,
        children: [
          Padding(
            padding: const EdgeInsets.all(MotifSpacing.sm),
            child: SegmentedButton<_PayloadMode>(
              segments: const [
                ButtonSegment(value: _PayloadMode.text, label: Text('Text')),
                ButtonSegment(value: _PayloadMode.key, label: Text('Key')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
          ),
        ],
      ),
      const SizedBox(height: MotifSpacing.xl),
      MotifSection(
        title: 'Display',
        dividerIndent: MotifSpacing.lg,
        children: [
          _sectionField(
            controller: _label,
            label: 'Label',
            onChanged: (_) => setState(() {}),
          ),
          _sectionField(
            controller: _symbol,
            label: 'Symbol (optional)',
            helperText: 'Known names: arrow.up, delete.left, control...',
          ),
        ],
      ),
      const SizedBox(height: MotifSpacing.xl),
      MotifSection(
        title: 'Modifiers',
        dividerIndent: MotifSpacing.lg,
        children: [
          _modifierRow('Ctrl', _ctrl, (v) => _ctrl = v),
          _modifierRow('Alt / Option', _alt, (v) => _alt = v),
          _modifierRow('Shift', _shift, (v) => _shift = v),
        ],
      ),
      const SizedBox(height: MotifSpacing.xl),
      if (isKey)
        MotifSection(
          title: 'Key',
          children: [
            MotifSectionRow(
              leading: const Icon(Icons.keyboard),
              title: _key == null ? 'Choose a key…' : _key!.name,
              showChevron: true,
              onTap: _pickKey,
            ),
          ],
        )
      else
        MotifSection(
          title: 'Text',
          dividerIndent: MotifSpacing.lg,
          children: [
            _sectionField(
              controller: _text,
              label: 'Text to send/insert',
              helperText: r'\n / \t / \r / \e are interpreted',
              minLines: 1,
              maxLines: 3,
            ),
            MotifSectionRow(
              title: 'Send immediately',
              onTap: () => setState(() => _sendImmediately = !_sendImmediately),
              trailing: Switch(
                value: _sendImmediately,
                onChanged: (v) => setState(() => _sendImmediately = v),
              ),
            ),
          ],
        ),
    ];
  }

  Widget _sectionField({
    required TextEditingController controller,
    required String label,
    String? helperText,
    int? minLines,
    int? maxLines = 1,
    ValueChanged<String>? onChanged,
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
        minLines: minLines,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          helperText: helperText,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          isDense: true,
        ),
        onChanged: onChanged,
      ),
    );
  }

  Widget _modifierRow(String title, bool value, ValueChanged<bool> update) {
    void setValue(bool next) => setState(() => update(next));
    return MotifSectionRow(
      title: title,
      onTap: () => setValue(!value),
      trailing: Checkbox(value: value, onChanged: (v) => setValue(v ?? false)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final canSave =
        _label.text.trim().isNotEmpty &&
        (_mode == _PayloadMode.text || _key != null);
    return AdaptiveModal(
      title: widget.existing == null ? 'New command' : 'Edit command',
      content: Column(mainAxisSize: MainAxisSize.min, children: _buildFields()),
      actions: [
        TextButton(
          onPressed: canSave ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

String _payloadPreview(Uint8List data) {
  if (data.isEmpty) return '(empty)';
  final out = StringBuffer();
  for (final b in data) {
    switch (b) {
      case 0x09:
        out.write(r'\t');
      case 0x0a:
        out.write(r'\n');
      case 0x0d:
        out.write(r'\r');
      case 0x1b:
        out.write(r'\e');
      case >= 0x20 && <= 0x7e:
        out.writeCharCode(b);
      case >= 0x01 && <= 0x1a:
        out.write('^${String.fromCharCode(0x40 + b)}');
      default:
        out.write('\\x${b.toRadixString(16).padLeft(2, '0')}');
    }
  }
  return out.toString();
}

Uint8List _qcEncode(String input) {
  final out = <int>[];
  for (var i = 0; i < input.length; i++) {
    final code = input.codeUnitAt(i);
    if (code == 0x5c && i + 1 < input.length) {
      switch (input.codeUnitAt(i + 1)) {
        case 0x6e:
          out.add(0x0a);
          i++;
          continue;
        case 0x74:
          out.add(0x09);
          i++;
          continue;
        case 0x72:
          out.add(0x0d);
          i++;
          continue;
        case 0x65:
          out.add(0x1b);
          i++;
          continue;
        case 0x5c:
          out.add(0x5c);
          i++;
          continue;
      }
    }
    out.addAll(utf8.encode(String.fromCharCode(code)));
  }
  return Uint8List.fromList(out);
}

String _qcDecode(Uint8List data) {
  final out = StringBuffer();
  for (final b in data) {
    switch (b) {
      case 0x0a:
        out.write(r'\n');
      case 0x09:
        out.write(r'\t');
      case 0x0d:
        out.write(r'\r');
      case 0x1b:
        out.write(r'\e');
      case 0x5c:
        out.write(r'\\');
      case >= 0x20 && <= 0x7e:
        out.writeCharCode(b);
      default:
        out.write('\\x${b.toRadixString(16).padLeft(2, '0')}');
    }
  }
  return out.toString();
}
