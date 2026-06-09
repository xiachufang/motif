part of '../session_screen.dart';

/// Thin status line showing the active PTY's shell context (git branch, venv,
/// node version) from OSC 777 — hidden when there's nothing to show.
class _ShellContextBar extends StatelessWidget {
  final ShellContext? ctx;
  const _ShellContextBar({required this.ctx});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final items = <(IconData, String)>[
      if (ctx?.branch != null && ctx!.branch!.isNotEmpty)
        (Icons.call_split, ctx!.branch!),
      if (ctx?.venv != null && ctx!.venv!.isNotEmpty) (Icons.eco, ctx!.venv!),
      if (ctx?.node != null && ctx!.node!.isNotEmpty)
        (Icons.hexagon_outlined, ctx!.node!),
    ];
    if (items.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: c.surface,
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: 4,
      ),
      child: Row(
        children: [
          for (final (icon, text) in items) ...[
            Icon(icon, size: 12, color: c.textTertiary),
            const SizedBox(width: 3),
            Text(
              text,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: MotifSpacing.md),
          ],
        ],
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSend;
  final bool recording;
  final bool micStarting;
  final VoidCallback onMic;
  final VoidCallback onAttach;
  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.onSend,
    required this.recording,
    required this.micStarting,
    required this.onMic,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final speechAvailable = context
        .read<AppState>()
        .platform
        .speech
        .isAvailable;
    return Container(
      key: const ValueKey('bottom-bar'),
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: 10,
      ),
      color: c.background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 10,
        children: [
          MotifIconButton(
            icon: Icons.photo_outlined,
            onPressed: onAttach,
            tooltip: 'Attach photo',
            size: MotifButtonSize.large,
          ),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: c.subtleFill,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      autocorrect: false,
                      enableSuggestions: false,
                      minLines: 1,
                      maxLines: 5,
                      style: TextStyle(color: c.textPrimary, fontSize: 16),
                      decoration: InputDecoration(
                        hintText: speechAvailable ? 'type or speak…' : 'type…',
                        hintStyle: TextStyle(color: c.textTertiary),
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        isCollapsed: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                      onSubmitted: (_) => onSend(),
                    ),
                  ),
                  if (speechAvailable)
                    SizedBox(
                      width: 30,
                      height: 28,
                      child: IconButton(
                        onPressed: micStarting ? null : onMic,
                        tooltip: micStarting
                            ? 'Starting voice input'
                            : recording
                            ? 'Stop'
                            : 'Voice input',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: recording ? c.danger : c.textPrimary,
                          fixedSize: const Size(30, 28),
                          minimumSize: const Size(30, 28),
                          padding: EdgeInsets.zero,
                        ),
                        icon: micStarting
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: c.textSecondary,
                                ),
                              )
                            : Icon(
                                recording
                                    ? Icons.stop_circle_outlined
                                    : Icons.mic,
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          MotifIconButton(
            icon: Icons.arrow_upward,
            role: MotifButtonRole.filled,
            size: MotifButtonSize.large,
            onPressed: onSend,
            tooltip: 'Send',
          ),
        ],
      ),
    );
  }
}
