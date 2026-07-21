import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/services.dart';

import '../../platform/services.dart';
import '../../state/app/app_state.dart';
import '../../state/app/motif_scope.dart';
import '../theme/motif_theme.dart';
import 'adaptive_modal.dart';
import 'motif_form.dart';
import 'top_toast.dart';

part 'tailscale_section.g.dart';

const _browserChannel = MethodChannel('motif/browser');

/// Single-row Tailscale entry plus setup/details sheets.
@ObservationWidget()
class TailscaleSection extends _$TailscaleSection {
  const TailscaleSection({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = readObservationScope<AppState>(context).platform.tailscale;
    final c = context.motif;
    final desc = _describe(svc.state, c);
    return MotifSectionRow(
      leading: desc.leading,
      title: desc.title,
      subtitle: desc.subtitle,
      titleWeight: desc.bold ? FontWeight.w700 : FontWeight.w500,
      onTap: () => showTailscaleConnectionSheet(context, svc: svc),
      showChevron: true,
    );
  }

  _EntryDescription _describe(TailscaleState st, MotifColors c) {
    return switch (st.status) {
      TailscaleStatus.stopped => _EntryDescription(
        leading: Icon(
          Icons.shield_outlined,
          color: c.accent,
          size: MotifIconSize.md,
        ),
        title: 'Setup Tailscale',
        subtitle: 'Sign in so motif can reach your servers',
        bold: true,
      ),
      TailscaleStatus.starting => _EntryDescription(
        leading: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: 'Connecting Tailscale…',
        subtitle: st.detail,
      ),
      TailscaleStatus.needsAuth => _EntryDescription(
        leading: Icon(
          Icons.warning_rounded,
          color: c.warning,
          size: MotifIconSize.md,
        ),
        title: 'Tailscale needs login',
        subtitle: st.detail ?? 'Tap to finish signing in',
        bold: true,
      ),
      TailscaleStatus.running => _EntryDescription(
        leading: Icon(
          Icons.verified_user,
          color: c.success,
          size: MotifIconSize.md,
        ),
        title: 'Tailscale connected',
        subtitle: st.detail,
      ),
      TailscaleStatus.degraded => _EntryDescription(
        leading: Icon(
          Icons.sync_problem,
          color: c.warning,
          size: MotifIconSize.md,
        ),
        title: 'Tailscale reconnecting…',
        subtitle: st.detail,
        bold: true,
      ),
      TailscaleStatus.failed => _EntryDescription(
        leading: Icon(
          Icons.error_outline,
          color: c.danger,
          size: MotifIconSize.md,
        ),
        title: 'Tailscale failed',
        subtitle: st.detail,
        bold: true,
      ),
    };
  }
}

Future<void> showTailscaleConnectionSheet(
  BuildContext context, {
  TailscaleService? svc,
}) {
  final service =
      svc ?? readObservationScope<AppState>(context).platform.tailscale;
  return showAdaptivePanel<void>(
    context,
    builder: (_) =>
        _TailscaleConnectionSheet(key: ObjectKey(service), svc: service),
  );
}

@ObservationWidget()
class _TailscaleConnectionSheet extends _$_TailscaleConnectionSheet {
  final TailscaleService svc;

  const _TailscaleConnectionSheet({required this.svc, super.key});

  @override
  Widget build(BuildContext context) {
    return _showsTailscaleDetails(svc.state.status)
        ? _TailscaleDetailsSheet(key: ObjectKey(svc), svc: svc)
        : _TailscaleSetupSheet(key: ObjectKey(svc), svc: svc);
  }
}

bool _showsTailscaleDetails(TailscaleStatus status) =>
    status == TailscaleStatus.running || status == TailscaleStatus.degraded;

class _EntryDescription {
  final Widget leading;
  final String title;
  final String? subtitle;
  final bool bold;

  const _EntryDescription({
    required this.leading,
    required this.title,
    this.subtitle,
    this.bold = false,
  });
}

@ObservableModel()
class _TailscaleSetupViewModel extends _$_TailscaleSetupViewModel {
  _TailscaleSetupViewModel({
    bool browserLoginRequested = false,
    String authKey = '',
    String? startError,
  }) : super(browserLoginRequested, authKey, startError);
}

final class _TailscaleSetupEffects {
  String? openedAuthUrl;
}

@ObservationWidget()
class _TailscaleSetupSheet extends _$_TailscaleSetupSheet {
  final TailscaleService svc;

  const _TailscaleSetupSheet({required this.svc, super.key});

  @PlainState(name: 'keyController')
  TextEditingController createKeyController() => TextEditingController();

  @ObservableState(name: 'viewModel')
  _TailscaleSetupViewModel createViewModel() => _TailscaleSetupViewModel();

  @PlainState(name: 'effects')
  _TailscaleSetupEffects createEffects() => _TailscaleSetupEffects();

  @override
  bool shouldRecreateStates(covariant _TailscaleSetupSheet oldWidget) =>
      !identical(oldWidget.svc, svc);

  @override
  Widget build(
    BuildContext context, {
    required TextEditingController keyController,
    required _TailscaleSetupViewModel viewModel,
    required _TailscaleSetupEffects effects,
  }) {
    final st = svc.state;
    final starting = st.status == TailscaleStatus.starting;
    final authUrl = st.authUrl;
    if (viewModel.browserLoginRequested && authUrl != null) {
      _openAuthUrlOnce(context, authUrl, effects);
    }
    return AdaptivePanel(
      title: 'Setup Tailscale',
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(
          MotifSpacing.lg,
          MotifSpacing.md,
          MotifSpacing.lg,
          MotifSpacing.xl,
        ),
        children: [
          MotifSection(
            title: 'Status',
            children: [_TailscaleStatusRow(state: st)],
          ),
          if (st.authUrl != null) ...[
            const SizedBox(height: MotifSpacing.xl),
            MotifSection(
              title: 'Web auth',
              footer: 'Open this URL in a browser to finish signing in.',
              children: [_AuthUrlRow(url: st.authUrl!)],
            ),
          ],
          if (st.authUrl == null) ...[
            const SizedBox(height: MotifSpacing.xl),
            MotifSection(
              title: 'Browser login',
              footer: 'Creates a Tailscale sign-in URL for this device.',
              children: [
                MotifSectionRow(
                  leading: Icon(
                    Icons.open_in_browser,
                    color: context.motif.accent,
                  ),
                  title: starting
                      ? 'Preparing sign-in URL…'
                      : 'Connect with browser',
                  subtitle: viewModel.startError,
                  titleColor: context.motif.accent,
                  titleWeight: FontWeight.w700,
                  onTap: starting
                      ? null
                      : () => _startBrowserLogin(context, viewModel),
                ),
              ],
            ),
          ],
          const SizedBox(height: MotifSpacing.xl),
          MotifSection(
            title: 'Auth key',
            footer:
                'Pre-shared key from your Tailscale admin console. Headless; no browser needed.',
            dividerIndent: MotifSpacing.lg,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  MotifSpacing.md,
                  MotifSpacing.sm,
                  MotifSpacing.md,
                  MotifSpacing.sm,
                ),
                child: TextField(
                  controller: keyController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    hintText: 'tskey-…',
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    isDense: true,
                  ),
                  onChanged: (value) => viewModel.authKey = value,
                ),
              ),
              MotifSectionRow(
                leading: Icon(Icons.key, color: context.motif.accent),
                title: 'Connect with auth key',
                titleColor: context.motif.accent,
                titleWeight: FontWeight.w700,
                onTap: viewModel.authKey.trim().isEmpty || starting
                    ? null
                    : () async {
                        final key = viewModel.authKey.trim();
                        await svc.start(authKey: key);
                        keyController.clear();
                        viewModel.authKey = '';
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _startBrowserLogin(
    BuildContext context,
    _TailscaleSetupViewModel viewModel,
  ) {
    observationTransaction(() {
      viewModel
        ..browserLoginRequested = true
        ..startError = null;
    });
    unawaited(_startTailscaleLogin(context, viewModel));
    _showUnavailableIfStartDidNothing(context, viewModel);
  }

  Future<void> _startTailscaleLogin(
    BuildContext context,
    _TailscaleSetupViewModel viewModel,
  ) async {
    try {
      await svc.start();
    } catch (e) {
      if (!context.mounted) return;
      viewModel.startError = 'Could not start embedded Tailscale: $e';
    }
  }

  void _showUnavailableIfStartDidNothing(
    BuildContext context,
    _TailscaleSetupViewModel viewModel,
  ) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final st = svc.state;
      if (st.status != TailscaleStatus.stopped) return;
      viewModel.startError =
          'Embedded Tailscale is unavailable in this build. Bundle libtailscale for this device, or use a direct server.';
    });
  }

  void _openAuthUrlOnce(
    BuildContext context,
    String url,
    _TailscaleSetupEffects effects,
  ) {
    if (effects.openedAuthUrl == url) return;
    effects.openedAuthUrl = url;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      unawaited(openTailscaleAuthUrl(context, url));
    });
  }
}

@ObservationWidget()
class _TailscaleDetailsSheet extends _$_TailscaleDetailsSheet {
  final TailscaleService svc;

  const _TailscaleDetailsSheet({required this.svc, super.key});

  @override
  Widget build(BuildContext context) {
    final st = svc.state;
    return AdaptivePanel(
      title: 'Tailscale',
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: const EdgeInsets.fromLTRB(
          MotifSpacing.lg,
          MotifSpacing.md,
          MotifSpacing.lg,
          MotifSpacing.xl,
        ),
        children: [
          MotifSection(
            title: 'Connection',
            children: [_TailscaleStatusRow(state: st)],
          ),
          const SizedBox(height: MotifSpacing.xl),
          MotifSection(
            footer:
                'Disconnect drops the tsnet session. Cached credentials stay on device.',
            children: [
              MotifSectionRow(
                leading: Icon(
                  Icons.power_settings_new,
                  color: context.motif.danger,
                ),
                title: 'Disconnect',
                titleColor: context.motif.danger,
                titleWeight: FontWeight.w700,
                onTap: () async {
                  await svc.stop();
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TailscaleStatusRow extends StatelessWidget {
  final TailscaleState state;

  const _TailscaleStatusRow({required this.state});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final value = switch (state.status) {
      TailscaleStatus.stopped => 'Stopped',
      TailscaleStatus.starting => 'Starting…',
      TailscaleStatus.running => 'Connected',
      TailscaleStatus.needsAuth => 'Needs login',
      TailscaleStatus.degraded => 'Reconnecting…',
      TailscaleStatus.failed => 'Failed',
    };
    final color = switch (state.status) {
      TailscaleStatus.failed => c.danger,
      TailscaleStatus.degraded => c.warning,
      _ => c.textPrimary,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Status',
                style: MotifType.body.copyWith(color: c.textPrimary),
              ),
              const Spacer(),
              if (state.status == TailscaleStatus.starting) ...[
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: MotifSpacing.sm),
              ],
              Text(value, style: MotifType.body.copyWith(color: color)),
            ],
          ),
          if (state.detail != null) ...[
            const SizedBox(height: MotifSpacing.xs),
            Text(
              state.detail!,
              style: MotifType.subhead.copyWith(color: c.textSecondary),
            ),
          ],
        ],
      ),
    );
  }
}

class _AuthUrlRow extends StatelessWidget {
  final String url;

  const _AuthUrlRow({required this.url});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return MotifSectionRow(
      leading: Icon(Icons.link, color: c.accent),
      title: url,
      titleColor: c.accent,
      titleWeight: FontWeight.w500,
      onTap: () => unawaited(openTailscaleAuthUrl(context, url)),
      trailing: IconButton(
        icon: const Icon(Icons.copy, size: 18),
        tooltip: 'Copy sign-in URL',
        onPressed: () => Clipboard.setData(ClipboardData(text: url)),
      ),
    );
  }
}

Future<void> openTailscaleAuthUrl(BuildContext context, String url) async {
  final opened = await _openExternalUrl(url);
  if (opened) return;
  if (!context.mounted) return;
  showMotifToast(context, 'Could not open the browser for this URL.');
}

Future<bool> _openExternalUrl(String url) async {
  try {
    return await _browserChannel.invokeMethod<bool>('openUrl', {'url': url}) ??
        false;
  } on MissingPluginException {
    return false;
  } on PlatformException {
    return false;
  }
}
