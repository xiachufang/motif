part of '../session_screen.dart';

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final Object groupId;
  final VoidCallback onSend;
  final bool recording;
  final bool micStarting;
  final VoidCallback onMic;
  final VoidCallback onAttach;
  const _InputBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.groupId,
    required this.onSend,
    required this.recording,
    required this.micStarting,
    required this.onMic,
    required this.onAttach,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    // Voice input is backed by Doubao ASR (Simplified-Chinese-primary), so only
    // surface the mic when the device's system language is Simplified Chinese —
    // exclude Traditional (zh-Hant / zh-TW / zh-HK / zh-MO).
    final locale = WidgetsBinding.instance.platformDispatcher.locale;
    final systemLanguageIsChinese =
        locale.languageCode == 'zh' &&
        locale.scriptCode != 'Hant' &&
        !const {'TW', 'HK', 'MO'}.contains(locale.countryCode);
    final speechAvailable =
        systemLanguageIsChinese &&
        context.read<AppState>().platform.speech.isAvailable;
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
          IconButton(
            onPressed: onAttach,
            tooltip: 'Attach photo',
            icon: const Icon(Icons.photo_outlined),
          ),
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: c.subtleFill,
                borderRadius: BorderRadius.circular(MotifRadius.xl),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      groupId: groupId,
                      controller: controller,
                      focusNode: focusNode,
                      // Keep the default (multiline) keyboard — NOT
                      // `visiblePassword`, which on iOS is ASCII-capable with no
                      // language switch and blocks CJK IMEs. The English locale
                      // hint only biases a *fresh* keyboard toward English; the
                      // globe key still switches, and per-tab memory restores
                      // each tab's last-used input source.
                      hintLocales: terminalEnglishHintLocales,
                      // Keep the soft-keyboard action stable across focus / IME
                      // switches. A multiline field otherwise defaults to
                      // `newline`, so iOS/Android may replace Send with Return
                      // when they recreate the input connection.
                      textInputAction: TextInputAction.send,
                      autocorrect: false,
                      smartDashesType: SmartDashesType.disabled,
                      smartQuotesType: SmartQuotesType.disabled,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      enableInlinePrediction: false,
                      minLines: 1,
                      maxLines: 5,
                      style: MotifType.title.copyWith(
                        color: c.textPrimary,
                        fontWeight: FontWeight.w400,
                      ),
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
                        style: context.iconButtonStyle(
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
          Tooltip(
            message: 'Send',
            child: FilledButton(
              onPressed: onSend,
              style: FilledButton.styleFrom(
                fixedSize: const Size.square(MotifControlSize.lg),
                padding: EdgeInsets.zero,
                shape: const CircleBorder(),
              ).withoutFeedback(),
              child: const Icon(Icons.arrow_upward),
            ),
          ),
        ],
      ),
    );
  }
}
