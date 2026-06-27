import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/settings.dart';
import '../../state/sticky_modifiers.dart';
import '../../terminal/terminal_paste.dart';
import '../theme/motif_theme.dart';

/// Horizontal scrollable row of sticky modifier chips + quick-command capsules.
/// Mirrors the iOS QuickCommandRow. Pure Flutter; no native dependency.
class QuickCommandRow extends StatelessWidget {
  final List<QuickCommand> commands;
  final StickyModifiers modifiers;

  /// Send raw bytes to the active PTY now.
  final void Function(Uint8List bytes) onSendBytes;

  /// Insert text into the composer (for non-immediate commands).
  final void Function(String text) onInsertText;

  /// Open the cd picker.
  final VoidCallback? onChangeDirectory;

  /// Open the quick-command editor.
  final VoidCallback? onEdit;

  const QuickCommandRow({
    super.key,
    required this.commands,
    required this.modifiers,
    required this.onSendBytes,
    required this.onInsertText,
    this.onChangeDirectory,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return ListenableBuilder(
      listenable: modifiers,
      builder: (context, _) {
        return SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: MotifSpacing.md,
              vertical: 6,
            ),
            children: [
              for (final cmd in commands) ...[
                switch (cmd.kind) {
                  QuickCommandKind.ctrl => _modChip(
                    context,
                    cmd.label,
                    cmd.symbol,
                    modifiers.ctrl,
                    modifiers.toggleCtrl,
                  ),
                  QuickCommandKind.alt => _modChip(
                    context,
                    cmd.label,
                    cmd.symbol,
                    modifiers.alt,
                    modifiers.toggleAlt,
                  ),
                  QuickCommandKind.shift => _modChip(
                    context,
                    cmd.label,
                    cmd.symbol,
                    modifiers.shift,
                    modifiers.toggleShift,
                  ),
                  _ => _commandChip(context, c, cmd),
                },
                _gap,
              ],
              if (onEdit != null)
                Tooltip(
                  message: 'Edit quick commands',
                  child: GestureDetector(
                    onTap: onEdit,
                    child: Container(
                      width: 40,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.subtleFill,
                        borderRadius: BorderRadius.circular(MotifRadius.pill),
                      ),
                      child: Icon(
                        Icons.edit_outlined,
                        size: MotifIconSize.sm,
                        color: c.textSecondary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget get _gap => const SizedBox(width: MotifSpacing.sm);

  Widget _modChip(
    BuildContext context,
    String label,
    String? symbol,
    StickyLevel level,
    VoidCallback onTap,
  ) {
    final c = context.motif;
    final (bg, fg, border) = switch (level) {
      StickyLevel.inactive => (c.subtleFill, c.textPrimary, null),
      StickyLevel.armed => (c.accentFill(), c.accent, c.accent),
      StickyLevel.locked => (c.accent, c.textOnAccent, null),
    };
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.md),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(MotifRadius.pill),
            border: border == null ? null : Border.all(color: border, width: 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _chipLabel(label: label, symbol: symbol, color: fg),
              if (level == StickyLevel.locked)
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(color: fg, shape: BoxShape.circle),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _commandChip(BuildContext context, MotifColors c, QuickCommand cmd) {
    final glyphs = QuickCommandModifiers(
      ctrl: cmd.modifiers.ctrl,
      alt: cmd.modifiers.alt,
      shift: cmd.modifiers.shift,
    ).glyphs;
    return Tooltip(
      message: cmd.label,
      child: _RepeatingQuickCommandChip(
        repeatable: _canRepeat(cmd),
        onActivate: () => _handleTap(context, cmd),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: MotifSpacing.md),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.subtleFill,
            borderRadius: BorderRadius.circular(MotifRadius.pill),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (glyphs.isNotEmpty)
                Text(
                  glyphs,
                  style: MotifType.callout.copyWith(color: c.textPrimary),
                ),
              _chipLabel(
                label: cmd.label,
                symbol: cmd.symbol,
                color: c.textPrimary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _canRepeat(QuickCommand cmd) {
    if (cmd.kind != QuickCommandKind.bytes || !cmd.sendImmediately) {
      return false;
    }
    if (!cmd.modifiers.isEmpty) return false;
    return !modifiers.ctrlActive &&
        !modifiers.altActive &&
        !modifiers.shiftActive;
  }

  Widget _chipLabel({
    required String label,
    required String? symbol,
    required Color color,
  }) {
    final icon = _iconForSymbol(symbol);
    if (icon != null) {
      return Icon(icon, size: 16, color: color);
    }
    return Text(
      label,
      style: MotifType.mono.copyWith(color: color, fontWeight: FontWeight.w500),
    );
  }

  IconData? _iconForSymbol(String? symbol) => switch (symbol) {
    'control' => Icons.keyboard_control_key,
    'option' => Icons.keyboard_option_key,
    'shift' => Icons.keyboard_capslock,
    'arrow.right.to.line' => Icons.keyboard_tab,
    'arrow.left.to.line' => Icons.keyboard_tab,
    'arrow.up' => Icons.arrow_upward,
    'arrow.down' => Icons.arrow_downward,
    'arrow.left' => Icons.arrow_back,
    'arrow.right' => Icons.arrow_forward,
    'delete.left' => Icons.backspace_outlined,
    'delete.right' => Icons.keyboard_double_arrow_right,
    'doc.on.clipboard' => Icons.content_paste,
    'arrow.turn.down.right' => Icons.subdirectory_arrow_right,
    'folder' => Icons.folder_outlined,
    _ => null,
  };

  Future<void> _handleTap(BuildContext context, QuickCommand cmd) async {
    switch (cmd.kind) {
      case QuickCommandKind.cd:
        onChangeDirectory?.call();
        return;
      case QuickCommandKind.paste:
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text ?? '';
        if (text.isEmpty) return;
        onSendBytes(bracketedPasteBytes(text));
        modifiers.consumeArmed();
        return;
      case QuickCommandKind.ctrl:
      case QuickCommandKind.alt:
      case QuickCommandKind.shift:
        return; // handled by the modifier chips
      case QuickCommandKind.bytes:
        if (cmd.sendImmediately) {
          final out = applyModifiers(
            cmd.payload,
            ctrl: modifiers.ctrlActive || cmd.modifiers.ctrl,
            alt: modifiers.altActive || cmd.modifiers.alt,
            shift: modifiers.shiftActive || cmd.modifiers.shift,
          );
          onSendBytes(out);
          modifiers.consumeArmed();
        } else {
          onInsertText(String.fromCharCodes(cmd.payload));
        }
    }
  }
}

class _RepeatingQuickCommandChip extends StatefulWidget {
  final bool repeatable;
  final Future<void> Function() onActivate;
  final Widget child;

  const _RepeatingQuickCommandChip({
    required this.repeatable,
    required this.onActivate,
    required this.child,
  });

  @override
  State<_RepeatingQuickCommandChip> createState() =>
      _RepeatingQuickCommandChipState();
}

class _RepeatingQuickCommandChipState
    extends State<_RepeatingQuickCommandChip> {
  static const _repeatInterval = Duration(milliseconds: 90);
  Timer? _repeatTimer;

  @override
  void didUpdateWidget(covariant _RepeatingQuickCommandChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.repeatable) _stopRepeating();
  }

  void _activate() {
    unawaited(widget.onActivate());
  }

  void _startRepeating() {
    _stopRepeating();
    _activate();
    if (!widget.repeatable) return;
    _repeatTimer = Timer.periodic(_repeatInterval, (_) => _activate());
  }

  void _stopRepeating() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  @override
  void dispose() {
    _stopRepeating();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _activate,
      onLongPressStart: (_) => _startRepeating(),
      onLongPressEnd: (_) => _stopRepeating(),
      onLongPressCancel: _stopRepeating,
      child: widget.child,
    );
  }
}
