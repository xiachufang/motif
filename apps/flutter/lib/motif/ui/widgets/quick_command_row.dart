import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/services.dart';

import '../../models/settings.dart';
import '../../state/workspace/terminal/sticky_modifiers.dart';
import '../../terminal/terminal_session.dart';
import '../theme/motif_theme.dart';

part 'quick_command_row.g.dart';

/// Horizontal scrollable row of sticky modifier chips + quick-command capsules.
/// Mirrors the iOS QuickCommandRow. Pure Flutter; no native dependency.
@ObservationWidget()
class QuickCommandRow extends _$QuickCommandRow {
  final List<QuickCommand> commands;
  final StickyModifiers modifiers;

  /// Send raw bytes to the active PTY now.
  final void Function(Uint8List bytes) onSendBytes;

  /// Send a semantic key event through the active Ghostty terminal surface.
  final FutureOr<void> Function(TerminalKeyInput input) onSendKey;

  /// Paste raw UTF-8 through Ghostty's mode-aware paste encoder.
  final FutureOr<void> Function(Uint8List bytes) onPaste;

  /// Send an immediate quick-command payload.
  ///
  /// This is separate from [onSendBytes] so callers can apply command-specific
  /// behavior without changing raw key/paste byte handling.
  final void Function(Uint8List bytes)? onSendCommandBytes;

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
    required this.onSendKey,
    required this.onPaste,
    this.onSendCommandBytes,
    required this.onInsertText,
    this.onChangeDirectory,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
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
        key: ValueKey('quick-command-repeat-${cmd.id}'),
        repeatable: _canRepeat(cmd),
        onActivate: () => _handleTap(context, cmd),
        onRepeatStart: _canRepeat(cmd)
            ? () => _handleRepeatStart(context, cmd)
            : null,
        onRepeat: _canRepeat(cmd) ? () => _handleRepeat(context, cmd) : null,
        onRepeatEnd: _canRepeat(cmd) && cmd.kind == QuickCommandKind.key
            ? () => _sendKeyAction(
                cmd,
                TerminalKeyAction.release,
                consumeModifiers: true,
              )
            : null,
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
    if ((cmd.kind != QuickCommandKind.bytes &&
            cmd.kind != QuickCommandKind.key) ||
        !cmd.sendImmediately) {
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
        await onPaste(Uint8List.fromList(utf8.encode(text)));
        modifiers.consumeArmed();
        return;
      case QuickCommandKind.ctrl:
      case QuickCommandKind.alt:
      case QuickCommandKind.shift:
        return; // handled by the modifier chips
      case QuickCommandKind.key:
        await _sendKeyAction(cmd, TerminalKeyAction.press);
        await _sendKeyAction(
          cmd,
          TerminalKeyAction.release,
          consumeModifiers: true,
        );
        return;
      case QuickCommandKind.bytes:
        if (cmd.sendImmediately) {
          final out = applyModifiers(
            cmd.payload,
            ctrl: modifiers.ctrlActive || cmd.modifiers.ctrl,
            alt: modifiers.altActive || cmd.modifiers.alt,
            shift: modifiers.shiftActive || cmd.modifiers.shift,
          );
          (onSendCommandBytes ?? onSendBytes)(out);
          modifiers.consumeArmed();
        } else {
          onInsertText(utf8.decode(cmd.payload, allowMalformed: true));
        }
    }
  }

  Future<void> _handleRepeatStart(BuildContext context, QuickCommand cmd) =>
      cmd.kind == QuickCommandKind.key
      ? _sendKeyAction(cmd, TerminalKeyAction.press)
      : _handleTap(context, cmd);

  Future<void> _handleRepeat(BuildContext context, QuickCommand cmd) =>
      cmd.kind == QuickCommandKind.key
      ? _sendKeyAction(cmd, TerminalKeyAction.repeat)
      : _handleTap(context, cmd);

  Future<void> _sendKeyAction(
    QuickCommand cmd,
    TerminalKeyAction action, {
    bool consumeModifiers = false,
  }) async {
    final keyId = cmd.keyId;
    if (keyId == null || keyId.isEmpty) return;
    await onSendKey(
      TerminalKeyInput(
        keyId: keyId,
        action: action,
        modifiers: TerminalKeyModifiers(
          ctrl: modifiers.ctrlActive || cmd.modifiers.ctrl,
          alt: modifiers.altActive || cmd.modifiers.alt,
          shift: modifiers.shiftActive || cmd.modifiers.shift,
        ),
      ),
    );
    if (consumeModifiers) modifiers.consumeArmed();
  }
}

final class _QuickCommandRepeatTimer {
  Timer? timer;

  void cancel() {
    timer?.cancel();
    timer = null;
  }

  void dispose() => cancel();
}

@ObservationWidget()
class _RepeatingQuickCommandChip extends _$_RepeatingQuickCommandChip {
  final bool repeatable;
  final Future<void> Function() onActivate;
  final Future<void> Function()? onRepeatStart;
  final Future<void> Function()? onRepeat;
  final Future<void> Function()? onRepeatEnd;
  final Widget child;

  const _RepeatingQuickCommandChip({
    required this.repeatable,
    required this.onActivate,
    this.onRepeatStart,
    this.onRepeat,
    this.onRepeatEnd,
    required this.child,
    super.key,
  });

  static const _repeatInterval = Duration(milliseconds: 90);

  @PlainState(name: 'repeatTimer')
  _QuickCommandRepeatTimer createRepeatTimer() => _QuickCommandRepeatTimer();

  @override
  void didUpdateStates(
    covariant _RepeatingQuickCommandChip oldWidget, {
    required _QuickCommandRepeatTimer repeatTimer,
  }) {
    if (!repeatable) oldWidget._finishRepeating(repeatTimer);
  }

  @override
  void disposeStates({required _QuickCommandRepeatTimer repeatTimer}) {
    _finishRepeating(repeatTimer);
  }

  void _activate() {
    unawaited(onActivate());
  }

  void _startRepeating(_QuickCommandRepeatTimer repeatTimer) {
    repeatTimer.cancel();
    unawaited((onRepeatStart ?? onActivate)());
    if (!repeatable) return;
    repeatTimer.timer = Timer.periodic(
      _repeatInterval,
      (_) => unawaited((onRepeat ?? onActivate)()),
    );
  }

  void _finishRepeating(_QuickCommandRepeatTimer repeatTimer) {
    final wasRepeating = repeatTimer.timer != null;
    repeatTimer.cancel();
    if (wasRepeating && onRepeatEnd != null) unawaited(onRepeatEnd!());
  }

  @override
  Widget build(
    BuildContext context, {
    required _QuickCommandRepeatTimer repeatTimer,
  }) {
    return GestureDetector(
      onTap: _activate,
      onLongPressStart: (_) => _startRepeating(repeatTimer),
      onLongPressEnd: (_) => _finishRepeating(repeatTimer),
      onLongPressCancel: () => _finishRepeating(repeatTimer),
      child: child,
    );
  }
}
