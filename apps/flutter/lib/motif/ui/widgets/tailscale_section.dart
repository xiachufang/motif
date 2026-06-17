import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../platform/services.dart';
import '../../state/app_state.dart';
import '../theme/motif_theme.dart';
import 'adaptive_modal.dart';
import 'motif_form.dart';
import 'top_toast.dart';

const _browserChannel = MethodChannel('motif/browser');

/// Single-row Tailscale entry plus setup/details sheets.
class TailscaleSection extends StatelessWidget {
  const TailscaleSection({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = context.read<AppState>().platform.tailscale;
    final c = context.motif;
    return StreamBuilder<TailscaleState>(
      stream: svc.states,
      initialData: svc.state,
      builder: (context, snap) {
        final st = snap.data ?? TailscaleState.stopped;
        final desc = _describe(st, c);
        return MotifSectionRow(
          leading: desc.leading,
          title: desc.title,
          subtitle: desc.subtitle,
          titleWeight: desc.bold ? FontWeight.w700 : FontWeight.w500,
          onTap: () => showTailscaleConnectionSheet(context, svc: svc),
          showChevron: true,
        );
      },
    );
  }

  _EntryDescription _describe(TailscaleState st, MotifColors c) {
    return switch (st.status) {
      TailscaleStatus.stopped => _EntryDescription(
        leading: Icon(Icons.shield_outlined, color: c.accent, size: 22),
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
        leading: Icon(Icons.warning_rounded, color: c.warning, size: 22),
        title: 'Tailscale needs login',
        subtitle: st.detail ?? 'Tap to finish signing in',
        bold: true,
      ),
      TailscaleStatus.running => _EntryDescription(
        leading: Icon(Icons.verified_user, color: c.success, size: 22),
        title: 'Tailscale connected',
        subtitle: st.detail,
      ),
      TailscaleStatus.degraded => _EntryDescription(
        leading: Icon(Icons.sync_problem, color: c.warning, size: 22),
        title: 'Tailscale reconnecting…',
        subtitle: st.detail,
        bold: true,
      ),
      TailscaleStatus.failed => _EntryDescription(
        leading: Icon(Icons.error_outline, color: c.danger, size: 22),
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
  final service = svc ?? context.read<AppState>().platform.tailscale;
  return showAdaptivePanel<void>(
    context,
    builder: (_) => _TailscaleConnectionSheet(svc: service),
  );
}

class _TailscaleConnectionSheet extends StatelessWidget {
  final TailscaleService svc;

  const _TailscaleConnectionSheet({required this.svc});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TailscaleState>(
      stream: svc.states,
      initialData: svc.state,
      builder: (context, snap) {
        final status = (snap.data ?? svc.state).status;
        return _showsTailscaleDetails(status)
            ? _TailscaleDetailsSheet(svc: svc)
            : _TailscaleSetupSheet(svc: svc);
      },
    );
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

class _TailscaleSetupSheet extends StatefulWidget {
  final TailscaleService svc;

  const _TailscaleSetupSheet({required this.svc});

  @override
  State<_TailscaleSetupSheet> createState() => _TailscaleSetupSheetState();
}

class _TailscaleSetupSheetState extends State<_TailscaleSetupSheet> {
  final _key = TextEditingController();
  bool _browserLoginRequested = false;
  String? _openedAuthUrl;
  String? _startError;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TailscaleState>(
      stream: widget.svc.states,
      initialData: widget.svc.state,
      builder: (context, snap) {
        final st = snap.data ?? TailscaleState.stopped;
        final starting = st.status == TailscaleStatus.starting;
        final authUrl = st.authUrl;
        if (_browserLoginRequested && authUrl != null) {
          _openAuthUrlOnce(authUrl);
        }
        return _SheetScaffold(
          title: 'Setup Tailscale',
          child: ListView(
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
                      subtitle: _startError,
                      titleColor: context.motif.accent,
                      titleWeight: FontWeight.w700,
                      onTap: starting ? null : _startBrowserLogin,
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
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: TextField(
                      controller: _key,
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
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  MotifSectionRow(
                    leading: Icon(Icons.key, color: context.motif.accent),
                    title: 'Connect with auth key',
                    titleColor: context.motif.accent,
                    titleWeight: FontWeight.w700,
                    onTap: _key.text.trim().isEmpty || starting
                        ? null
                        : () async {
                            final key = _key.text.trim();
                            await widget.svc.start(authKey: key);
                            _key.clear();
                            if (mounted) setState(() {});
                          },
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  void _startBrowserLogin() {
    setState(() {
      _browserLoginRequested = true;
      _startError = null;
    });
    unawaited(_startTailscaleLogin());
    _showUnavailableIfStartDidNothing();
  }

  Future<void> _startTailscaleLogin() async {
    try {
      await widget.svc.start();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _startError = 'Could not start embedded Tailscale: $e';
      });
    }
  }

  void _showUnavailableIfStartDidNothing() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final st = widget.svc.state;
      if (st.status != TailscaleStatus.stopped) return;
      setState(() {
        _startError =
            'Embedded Tailscale is unavailable in this build. Bundle libtailscale for this device, or use a direct server.';
      });
    });
  }

  void _openAuthUrlOnce(String url) {
    if (_openedAuthUrl == url) return;
    _openedAuthUrl = url;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(openTailscaleAuthUrl(context, url));
    });
  }
}

class _TailscaleDetailsSheet extends StatelessWidget {
  final TailscaleService svc;

  const _TailscaleDetailsSheet({required this.svc});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<TailscaleState>(
      stream: svc.states,
      initialData: svc.state,
      builder: (context, snap) {
        final st = snap.data ?? TailscaleState.stopped;
        return _SheetScaffold(
          title: 'Tailscale',
          child: ListView(
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
      },
    );
  }
}

class _SheetScaffold extends StatelessWidget {
  final String title;
  final Widget child;

  const _SheetScaffold({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        children: [
          AdaptiveModalHeader(title: title),
          Expanded(child: child),
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
        vertical: 11,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(
                'Status',
                style: TextStyle(color: c.textPrimary, fontSize: 15),
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
              Text(value, style: TextStyle(color: color, fontSize: 15)),
            ],
          ),
          if (state.detail != null) ...[
            const SizedBox(height: MotifSpacing.xs),
            Text(
              state.detail!,
              style: TextStyle(color: c.textSecondary, fontSize: 13),
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
