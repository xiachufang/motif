/// Settings for the *embedded* motifd server (desktop only). Lets the user
/// configure and Start/Stop the in-process server the app runs from the tray —
/// the native-screen replacement for the Tauri menu-bar app's settings webview.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../platform/desktop_launch.dart';
import '../../state/app_state.dart';
import '../../state/embedded_server_service.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';

class EmbeddedServerSettingsSheet extends StatefulWidget {
  const EmbeddedServerSettingsSheet({super.key});

  @override
  State<EmbeddedServerSettingsSheet> createState() =>
      _EmbeddedServerSettingsSheetState();
}

class _EmbeddedServerSettingsSheetState
    extends State<EmbeddedServerSettingsSheet> {
  late final TextEditingController _port;
  late final TextEditingController _token;
  late final TextEditingController _tsHostname;
  late final TextEditingController _tsAuthkey;
  late final TextEditingController _tsControlUrl;

  EmbeddedServerService get _svc => context.read<AppState>().embeddedServer!;

  @override
  void initState() {
    super.initState();
    final c = _svc.config;
    _port = TextEditingController(text: '${c.port}');
    _token = TextEditingController(text: c.authToken);
    _tsHostname = TextEditingController(text: c.tsHostname);
    _tsAuthkey = TextEditingController(text: c.tsAuthkey);
    _tsControlUrl = TextEditingController(text: c.tsControlUrl);
  }

  @override
  void dispose() {
    _port.dispose();
    _token.dispose();
    _tsHostname.dispose();
    _tsAuthkey.dispose();
    _tsControlUrl.dispose();
    super.dispose();
  }

  Future<void> _save(EmbeddedServerConfig next) => _svc.updateConfig(next);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final svc = app.embeddedServer!;
    final cfg = svc.config;
    final status = svc.status;
    final c = context.motif;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _serverSection(svc, status, c),
        const SizedBox(height: MotifSpacing.xl),
        _listenSection(cfg, c),
        const SizedBox(height: MotifSpacing.xl),
        _authSection(cfg, c),
        const SizedBox(height: MotifSpacing.xl),
        _tailscaleSection(cfg, c),
        const SizedBox(height: MotifSpacing.xl),
        MotifSection(
          title: 'App',
          children: [
            MotifSectionRow(
              leading: Icon(Icons.rocket_launch_outlined, color: c.accent),
              title: 'Start server on launch',
              subtitle: 'Bring the server up automatically when Motif opens',
              onTap: () => _save(cfg.copyWith(autostart: !cfg.autostart)),
              trailing: Switch(
                value: cfg.autostart,
                onChanged: (v) => _save(cfg.copyWith(autostart: v)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Server status + Start/Stop ──

  Widget _serverSection(
    EmbeddedServerService svc,
    EmbeddedServerStatus status,
    MotifColors c,
  ) {
    final running = status.running;
    final starting = status.starting;
    final (label, color) = switch (status.phase) {
      EmbeddedRunState.running => ('Running', c.success),
      EmbeddedRunState.starting => ('Starting…', c.warning),
      EmbeddedRunState.failed => ('Failed', c.danger),
      EmbeddedRunState.stopped => ('Stopped', c.textTertiary),
    };

    return MotifSection(
      title: 'Server',
      children: [
        MotifSectionRow(
          leading: Icon(Icons.dns_outlined, color: c.accent),
          title: 'Status',
          subtitle: _statusSubtitle(status),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (starting)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
              const SizedBox(width: MotifSpacing.sm),
              Text(label, style: TextStyle(color: c.textSecondary)),
            ],
          ),
        ),
        if (status.error != null)
          MotifSectionRow(
            leading: Icon(Icons.error_outline, color: c.danger),
            title: status.error!,
            titleColor: c.danger,
          ),
        if (status.authUrl != null)
          MotifSectionRow(
            leading: Icon(Icons.login, color: c.accent),
            title: 'Sign in to Tailscale',
            subtitle: status.authUrl,
            onTap: () => openExternalUrl(status.authUrl!),
            showChevron: true,
          ),
        Padding(
          padding: const EdgeInsets.all(MotifSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: running || starting ? null : () => svc.start(),
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start'),
                ),
              ),
              const SizedBox(width: MotifSpacing.md),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: running || starting ? () => svc.stop() : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String? _statusSubtitle(EmbeddedServerStatus status) {
    if (!status.running) return null;
    final parts = <String>[];
    if (status.boundAddrs.isNotEmpty) parts.add(status.boundAddrs.join(', '));
    parts.add(
      '${status.sessionCount} session${status.sessionCount == 1 ? '' : 's'}',
    );
    if (status.tailscaleState != null) {
      parts.add('Tailscale: ${status.tailscaleState}');
    }
    return parts.join(' · ');
  }

  // ── Listen mode + port ──

  Widget _listenSection(EmbeddedServerConfig cfg, MotifColors c) {
    Widget modeRow(EmbeddedListenMode mode, String title, String subtitle) {
      final selected = cfg.listenMode == mode;
      return MotifSectionRow(
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
          color: selected ? c.accent : c.textTertiary,
        ),
        title: title,
        subtitle: subtitle,
        onTap: () => _save(cfg.copyWith(listenMode: mode)),
      );
    }

    return MotifSection(
      title: 'Listen',
      children: [
        modeRow(
          EmbeddedListenMode.loopback,
          'Loopback only',
          'This computer (127.0.0.1) — private',
        ),
        modeRow(
          EmbeddedListenMode.lan,
          'Local network',
          'Reachable on the LAN (0.0.0.0) — use a token',
        ),
        modeRow(
          EmbeddedListenMode.off,
          'Off',
          'No local listener; Tailscale only',
        ),
        if (cfg.listenMode != EmbeddedListenMode.off)
          _field(
            _port,
            'Port',
            '7777',
            keyboard: TextInputType.number,
            onChanged: () {
              final p = int.tryParse(_port.text.trim());
              if (p != null && p > 0 && p < 65536) {
                _save(cfg.copyWith(port: p));
              }
            },
          ),
      ],
    );
  }

  // ── Auth ──

  Widget _authSection(EmbeddedServerConfig cfg, MotifColors c) {
    return MotifSection(
      title: 'Authentication',
      children: [
        MotifSectionRow(
          leading: Icon(Icons.key_outlined, color: c.accent),
          title: 'Require a token',
          onTap: () => _save(cfg.copyWith(authEnabled: !cfg.authEnabled)),
          trailing: Switch(
            value: cfg.authEnabled,
            onChanged: (v) => _save(cfg.copyWith(authEnabled: v)),
          ),
        ),
        if (cfg.authEnabled) ...[
          _field(
            _token,
            'Token',
            'bearer token',
            onChanged: () => _save(cfg.copyWith(authToken: _token.text.trim())),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: MotifSpacing.md,
              vertical: MotifSpacing.sm,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () {
                  final t = _svc.generateToken();
                  if (t.isEmpty) return;
                  _token.text = t;
                  _save(cfg.copyWith(authToken: t));
                  setState(() {});
                },
                icon: const Icon(Icons.casino_outlined),
                label: const Text('Generate token'),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ── Tailscale ──

  Widget _tailscaleSection(EmbeddedServerConfig cfg, MotifColors c) {
    return MotifSection(
      title: 'Tailscale',
      footer: 'Serve the embedded server over your tailnet, reachable from '
          'anywhere without exposing a port.',
      children: [
        MotifSectionRow(
          leading: Icon(Icons.hub_outlined, color: c.accent),
          title: 'Enable Tailscale',
          onTap: () => _save(cfg.copyWith(tsEnabled: !cfg.tsEnabled)),
          trailing: Switch(
            value: cfg.tsEnabled,
            onChanged: (v) => _save(cfg.copyWith(tsEnabled: v)),
          ),
        ),
        if (cfg.tsEnabled) ...[
          _field(
            _tsHostname,
            'Hostname',
            'defaults to motifd-<host>',
            onChanged: () =>
                _save(cfg.copyWith(tsHostname: _tsHostname.text.trim())),
          ),
          _field(
            _tsAuthkey,
            'Auth key',
            'optional — for headless login',
            obscure: true,
            onChanged: () =>
                _save(cfg.copyWith(tsAuthkey: _tsAuthkey.text.trim())),
          ),
          _field(
            _tsControlUrl,
            'Control URL',
            'optional — Headscale base URL',
            onChanged: () =>
                _save(cfg.copyWith(tsControlUrl: _tsControlUrl.text.trim())),
          ),
        ],
      ],
    );
  }

  Widget _field(
    TextEditingController ctrl,
    String label,
    String hint, {
    TextInputType? keyboard,
    bool obscure = false,
    VoidCallback? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      child: TextField(
        controller: ctrl,
        keyboardType: keyboard,
        obscureText: obscure,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) => onChanged?.call(),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          isDense: true,
        ),
      ),
    );
  }
}

Future<void> showEmbeddedServerSettingsSheet(BuildContext context) {
  return showAdaptiveModal<void>(
    context,
    builder: (_) => const AdaptiveModal(
      title: 'Local Server',
      content: EmbeddedServerSettingsSheet(),
    ),
  );
}
