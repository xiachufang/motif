/// Settings for the *embedded* motifd server (desktop only). Lets the user
/// configure and Start/Stop the in-process server the app runs from the tray —
/// the native-screen replacement for the Tauri menu-bar app's settings webview.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../platform/desktop_launch_desktop.dart';
import '../../state/embedded_server_service.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';

/// Which control plane the embedded node joins. Derived from `tsControlUrl`
/// (empty ⇒ official Tailscale; set ⇒ a self-hosted Headscale URL), but held
/// as explicit UI state so "Custom" can stay selected while its URL field is
/// still blank.
enum _TsControl { official, custom }

/// How the node signs in. Derived from `tsAuthkey` (empty ⇒ interactive
/// browser/URL login; set ⇒ headless pre-shared key), held as UI state for the
/// same reason.
enum _TsAuth { browser, authKey }

class EmbeddedServerSettingsSheet extends StatefulWidget {
  const EmbeddedServerSettingsSheet({super.key});

  @override
  State<EmbeddedServerSettingsSheet> createState() =>
      _EmbeddedServerSettingsSheetState();
}

class _EmbeddedServerSettingsSheetState
    extends State<EmbeddedServerSettingsSheet> {
  late final TextEditingController _port;
  late final TextEditingController _tsHostname;
  late final TextEditingController _tsAuthkey;
  late final TextEditingController _tsControlUrl;
  late final TextEditingController _rzvRelay;
  late final TextEditingController _pushRelayUrl;

  // Derived UI state for the two Tailscale axes (see the enum docs above).
  late _TsControl _tsControl;
  late _TsAuth _tsAuth;
  bool _tailscaleExpanded = false;
  Timer? _restartPromptTimer;
  bool _restartPromptShowing = false;
  bool _restartPromptDeferred = false;
  bool _restartPromptPendingOnBlur = false;

  EmbeddedServerService get _svc => context.read<EmbeddedServerService>();

  @override
  void initState() {
    super.initState();
    final c = _svc.config;
    _port = TextEditingController(text: '${c.port}');
    _tsHostname = TextEditingController(text: c.tsHostname);
    _tsAuthkey = TextEditingController(text: c.tsAuthkey);
    _tsControlUrl = TextEditingController(text: c.tsControlUrl);
    _rzvRelay = TextEditingController(text: c.rzvRelay);
    _pushRelayUrl = TextEditingController(text: c.pushRelayUrl);
    _tsControl = c.tsControlUrl.trim().isEmpty
        ? _TsControl.official
        : _TsControl.custom;
    _tsAuth = c.tsAuthkey.trim().isEmpty ? _TsAuth.browser : _TsAuth.authKey;
  }

  @override
  void dispose() {
    _port.dispose();
    _tsHostname.dispose();
    _tsAuthkey.dispose();
    _tsControlUrl.dispose();
    _rzvRelay.dispose();
    _pushRelayUrl.dispose();
    _restartPromptTimer?.cancel();
    super.dispose();
  }

  Future<void> _save(
    EmbeddedServerConfig next, {
    bool restartRequired = false,
    bool restartOnBlur = false,
  }) async {
    final svc = _svc;
    final previous = svc.config;
    await svc.updateConfig(next);
    if (!restartRequired || !_restartRelevantChanged(previous, next)) return;
    if (restartOnBlur) {
      _markRestartPromptPending(svc);
      return;
    }
    _scheduleRestartPrompt(svc);
  }

  bool _restartRelevantChanged(
    EmbeddedServerConfig previous,
    EmbeddedServerConfig next,
  ) {
    return previous.listenMode != next.listenMode ||
        previous.port != next.port ||
        previous.tsEnabled != next.tsEnabled ||
        previous.tsHostname != next.tsHostname ||
        previous.tsAuthkey != next.tsAuthkey ||
        previous.tsControlUrl != next.tsControlUrl ||
        previous.rzvEnabled != next.rzvEnabled ||
        previous.rzvRelay != next.rzvRelay ||
        previous.pushRelayUrl != next.pushRelayUrl;
  }

  bool _serverIsActive(EmbeddedServerService svc) {
    return svc.status.running || svc.status.starting;
  }

  void _scheduleRestartPrompt(EmbeddedServerService svc) {
    _restartPromptTimer?.cancel();
    if (!_serverIsActive(svc)) {
      _restartPromptDeferred = false;
      _restartPromptPendingOnBlur = false;
      return;
    }
    if (_restartPromptShowing || _restartPromptDeferred) return;
    _restartPromptPendingOnBlur = false;
    _restartPromptTimer = Timer(Duration.zero, () {
      if (!mounted) return;
      unawaited(_showRestartPrompt());
    });
  }

  void _markRestartPromptPending(EmbeddedServerService svc) {
    if (!_serverIsActive(svc)) {
      _restartPromptPendingOnBlur = false;
      return;
    }
    if (_restartPromptShowing || _restartPromptDeferred) return;
    _restartPromptPendingOnBlur = true;
  }

  void _showPendingRestartPrompt() {
    if (!_restartPromptPendingOnBlur) return;
    _restartPromptPendingOnBlur = false;
    _scheduleRestartPrompt(_svc);
  }

  Future<void> _showRestartPrompt() async {
    final svc = _svc;
    if (_restartPromptShowing ||
        _restartPromptDeferred ||
        !_serverIsActive(svc)) {
      return;
    }
    _restartPromptShowing = true;
    _restartPromptPendingOnBlur = false;
    final restart = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Restart server?'),
        content: const Text(
          'This setting is saved, but the running server needs to restart '
          'before it takes effect.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Restart'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    _restartPromptShowing = false;
    if (restart == true) {
      await _restartServer(svc);
    } else {
      _restartPromptDeferred = true;
    }
  }

  Future<void> _startServer(EmbeddedServerService svc) async {
    _restartPromptTimer?.cancel();
    _restartPromptDeferred = false;
    _restartPromptPendingOnBlur = false;
    await svc.start();
  }

  Future<void> _stopServer(EmbeddedServerService svc) async {
    _restartPromptTimer?.cancel();
    _restartPromptDeferred = false;
    _restartPromptPendingOnBlur = false;
    await svc.stop();
  }

  Future<void> _restartServer(EmbeddedServerService svc) async {
    _restartPromptTimer?.cancel();
    _restartPromptDeferred = false;
    _restartPromptPendingOnBlur = false;
    await svc.stop();
    await svc.start();
  }

  @override
  Widget build(BuildContext context) {
    final svc = context.watch<EmbeddedServerService>();
    final cfg = svc.config;
    final status = svc.status;
    final c = context.motif;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _serverSection(svc, status, c),
        const SizedBox(height: MotifSpacing.lg),
        _listenSection(cfg, c),
        const SizedBox(height: MotifSpacing.lg),
        _pairingSection(cfg, status, c),
        const SizedBox(height: MotifSpacing.lg),
        _notificationsSection(cfg),
        const SizedBox(height: MotifSpacing.lg),
        _tailscaleSection(cfg, status, c),
        const SizedBox(height: MotifSpacing.lg),
        MotifSection(
          title: 'App',
          children: [
            MotifSectionRow(
              leading: Icon(Icons.rocket_launch_outlined, color: c.accent),
              title: 'Start server on launch',
              subtitle: cfg.autostart
                  ? 'Server starts automatically with Motif'
                  : 'Start manually from this page or the tray',
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
        Padding(
          padding: const EdgeInsets.all(MotifSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _IconTile(icon: Icons.dns_outlined, color: c.accent),
                  const SizedBox(width: MotifSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Local Server',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _statusSubtitle(status) ??
                              'Ready to serve sessions from this computer',
                          // Single line keeps this block's height constant as
                          // the status updates, so the page doesn't reflow (and
                          // yank a bottom-pinned scroll) every poll.
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: MotifSpacing.md),
                  _StatusPill(label: label, color: color, starting: starting),
                ],
              ),
              if (status.running) ...[
                const SizedBox(height: MotifSpacing.md),
                _statusChips(status),
              ],
              if (status.error != null) ...[
                const SizedBox(height: MotifSpacing.md),
                _InlineNotice(
                  icon: Icons.error_outline,
                  text: status.error!,
                  color: c.danger,
                ),
              ],
              const SizedBox(height: MotifSpacing.lg),
              Row(
                children: [
                  Expanded(
                    child: running || starting
                        ? OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Start'),
                          )
                        : FilledButton.icon(
                            onPressed: () => unawaited(_startServer(svc)),
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Start'),
                          ),
                  ),
                  const SizedBox(width: MotifSpacing.md),
                  Expanded(
                    child: running || starting
                        ? FilledButton.icon(
                            onPressed: () => unawaited(_stopServer(svc)),
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop'),
                            style: FilledButton.styleFrom(
                              backgroundColor: c.danger,
                              foregroundColor: c.textOnAccent,
                            ),
                          )
                        : OutlinedButton.icon(
                            onPressed: null,
                            icon: const Icon(Icons.stop),
                            label: const Text('Stop'),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _statusChips(EmbeddedServerStatus status) {
    final chips = <Widget>[];
    for (final addr in status.boundAddrs) {
      chips.add(_InfoChip(icon: Icons.link_outlined, label: addr));
    }
    chips.add(
      _InfoChip(
        icon: Icons.terminal_outlined,
        label:
            '${status.sessionCount} session${status.sessionCount == 1 ? '' : 's'}',
      ),
    );
    if (status.tailscaleState != null) {
      chips.add(
        _InfoChip(
          icon: Icons.hub_outlined,
          label: 'Tailscale ${status.tailscaleState}',
        ),
      );
    }
    // A single horizontal row (scrolls if it overflows) instead of a Wrap, so
    // the block's height stays constant as bound addresses / session count /
    // tailscale state change — otherwise the row count flips and reflows the
    // page, jittering a bottom-pinned scroll.
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i++) ...[
            if (i > 0) const SizedBox(width: MotifSpacing.sm),
            chips[i],
          ],
        ],
      ),
    );
  }

  String? _statusSubtitle(EmbeddedServerStatus status) {
    if (!status.running) return null;
    final endpointCount = status.boundAddrs.length;
    final endpoints = switch (endpointCount) {
      0 =>
        status.tailscaleState == null
            ? 'No active endpoints'
            : 'Tailscale ${status.tailscaleState}',
      1 => '1 active endpoint',
      _ => '$endpointCount active endpoints',
    };
    return '$endpoints · ${status.sessionCount} session${status.sessionCount == 1 ? '' : 's'}';
  }

  // ── Listen mode + port ──

  Widget _listenSection(EmbeddedServerConfig cfg, MotifColors c) {
    final selected = _listenModeText(cfg.listenMode);
    return MotifSection(
      title: 'Listen',
      children: [
        Padding(
          padding: const EdgeInsets.all(MotifSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<EmbeddedListenMode>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: EmbeddedListenMode.loopback,
                    label: Text('Loopback'),
                    icon: Icon(Icons.computer_outlined),
                  ),
                  ButtonSegment(
                    value: EmbeddedListenMode.lan,
                    label: Text('LAN'),
                    icon: Icon(Icons.lan_outlined),
                  ),
                  ButtonSegment(
                    value: EmbeddedListenMode.off,
                    label: Text('Off'),
                    icon: Icon(Icons.power_settings_new),
                  ),
                ],
                selected: {cfg.listenMode},
                onSelectionChanged: (next) => _save(
                  cfg.copyWith(listenMode: next.first),
                  restartRequired: true,
                ),
              ),
              const SizedBox(height: MotifSpacing.md),
              _ModeSummary(
                icon: selected.icon,
                title: selected.title,
                subtitle: selected.subtitle,
                tone: selected.tone(c),
              ),
            ],
          ),
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
                _save(
                  cfg.copyWith(port: p),
                  restartRequired: true,
                  restartOnBlur: true,
                );
              }
            },
            onFocusLost: _showPendingRestartPrompt,
          ),
      ],
    );
  }

  ({
    IconData icon,
    String title,
    String subtitle,
    Color Function(MotifColors) tone,
  })
  _listenModeText(EmbeddedListenMode mode) {
    return switch (mode) {
      EmbeddedListenMode.loopback => (
        icon: Icons.lock_outline,
        title: 'Loopback only',
        subtitle: 'Private to this computer at 127.0.0.1',
        tone: (MotifColors c) => c.success,
      ),
      EmbeddedListenMode.lan => (
        icon: Icons.lan_outlined,
        title: 'Local network',
        subtitle: 'Reachable on the LAN at 0.0.0.0; encrypted, pair via QR',
        tone: (MotifColors c) => c.success,
      ),
      EmbeddedListenMode.off => (
        icon: Icons.power_settings_new,
        title: 'Local listener off',
        subtitle: 'Use Tailscale or relay pairing only',
        tone: (MotifColors c) => c.textTertiary,
      ),
    };
  }

  // ── Tailscale ──

  Widget _tailscaleSection(
    EmbeddedServerConfig cfg,
    EmbeddedServerStatus status,
    MotifColors c,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MotifSection(
          title: 'Tailscale',
          footer:
              'Serve the embedded server over your tailnet, reachable from '
              'anywhere without exposing a port.',
          children: [
            MotifSectionRow(
              leading: Icon(Icons.hub_outlined, color: c.accent),
              title: 'Enable Tailscale',
              subtitle: cfg.tsEnabled
                  ? 'Tailnet access is configured for this server'
                  : 'Reach this server from your tailnet',
              onTap: () => _save(
                cfg.copyWith(tsEnabled: !cfg.tsEnabled),
                restartRequired: true,
              ),
              trailing: Switch(
                value: cfg.tsEnabled,
                onChanged: (v) =>
                    _save(cfg.copyWith(tsEnabled: v), restartRequired: true),
              ),
            ),
            if (cfg.tsEnabled)
              MotifSectionRow(
                leading: Icon(Icons.tune_outlined, color: c.textSecondary),
                title: 'Tailscale settings',
                subtitle: _tailscaleSummary(cfg),
                onTap: () =>
                    setState(() => _tailscaleExpanded = !_tailscaleExpanded),
                trailing: Icon(
                  _tailscaleExpanded
                      ? Icons.keyboard_arrow_up
                      : Icons.keyboard_arrow_down,
                  color: c.textTertiary,
                ),
              ),
          ],
        ),
        if (cfg.tsEnabled && _tailscaleExpanded) ...[
          const SizedBox(height: MotifSpacing.lg),
          MotifSection(
            title: 'Tailscale settings',
            children: [
              _field(
                _tsHostname,
                'Hostname',
                'defaults to motifd-<host>',
                onChanged: () => _save(
                  cfg.copyWith(tsHostname: _tsHostname.text.trim()),
                  restartRequired: true,
                  restartOnBlur: true,
                ),
                onFocusLost: _showPendingRestartPrompt,
              ),
            ],
          ),
          const SizedBox(height: MotifSpacing.lg),
          _tsControlSection(cfg, c),
          const SizedBox(height: MotifSpacing.lg),
          _tsSignInSection(cfg, status, c),
        ],
      ],
    );
  }

  String _tailscaleSummary(EmbeddedServerConfig cfg) {
    final host = cfg.tsHostname.trim().isEmpty
        ? 'Default hostname'
        : cfg.tsHostname.trim();
    final control = _tsControl == _TsControl.custom ? 'Headscale' : 'Official';
    final auth = _tsAuth == _TsAuth.authKey ? 'Auth key' : 'Browser login';
    return '$host · $control · $auth';
  }

  // Which control plane the node joins: official Tailscale or a custom
  // (Headscale) server. "Custom" simply means a non-empty control URL.
  Widget _tsControlSection(EmbeddedServerConfig cfg, MotifColors c) {
    return MotifSection(
      title: 'Control server',
      footer: 'Use Tailscale, or point at a self-hosted Headscale server.',
      children: [
        _tsRadio(
          c,
          selected: _tsControl == _TsControl.official,
          title: 'Tailscale (official)',
          subtitle: 'login.tailscale.com',
          onTap: () {
            _tsControlUrl.clear();
            setState(() => _tsControl = _TsControl.official);
            _save(cfg.copyWith(tsControlUrl: ''), restartRequired: true);
          },
        ),
        _tsRadio(
          c,
          selected: _tsControl == _TsControl.custom,
          title: 'Custom (Headscale)',
          subtitle: 'self-hosted control server',
          onTap: () => setState(() => _tsControl = _TsControl.custom),
        ),
        if (_tsControl == _TsControl.custom)
          _field(
            _tsControlUrl,
            'Control URL',
            'https://headscale.example.com',
            onChanged: () => _save(
              cfg.copyWith(tsControlUrl: _tsControlUrl.text.trim()),
              restartRequired: true,
              restartOnBlur: true,
            ),
            onFocusLost: _showPendingRestartPrompt,
          ),
      ],
    );
  }

  // How the node authenticates: an interactive browser URL, or a headless
  // pre-shared auth key. "Auth key" simply means a non-empty key.
  Widget _tsSignInSection(
    EmbeddedServerConfig cfg,
    EmbeddedServerStatus status,
    MotifColors c,
  ) {
    return MotifSection(
      title: 'Sign-in',
      footer:
          'Browser login opens a one-time URL after you start the server. '
          'An auth key signs in headlessly — paste one from your admin console.',
      children: [
        _tsRadio(
          c,
          selected: _tsAuth == _TsAuth.browser,
          title: 'Browser login',
          subtitle: 'open a sign-in URL',
          onTap: () {
            _tsAuthkey.clear();
            setState(() => _tsAuth = _TsAuth.browser);
            _save(cfg.copyWith(tsAuthkey: ''), restartRequired: true);
          },
        ),
        _tsRadio(
          c,
          selected: _tsAuth == _TsAuth.authKey,
          title: 'Auth key',
          subtitle: 'headless, no browser',
          onTap: () => setState(() => _tsAuth = _TsAuth.authKey),
        ),
        if (_tsAuth == _TsAuth.authKey)
          _field(
            _tsAuthkey,
            'Auth key',
            'tskey-…',
            obscure: true,
            onChanged: () => _save(
              cfg.copyWith(tsAuthkey: _tsAuthkey.text.trim()),
              restartRequired: true,
              restartOnBlur: true,
            ),
            onFocusLost: _showPendingRestartPrompt,
          ),
        if (_tsAuth == _TsAuth.browser && status.authUrl != null)
          MotifSectionRow(
            leading: Icon(Icons.login, color: c.accent),
            title: 'Sign in to Tailscale',
            subtitle: status.authUrl,
            onTap: () => openExternalUrl(status.authUrl!),
            showChevron: true,
          ),
      ],
    );
  }

  Widget _tsRadio(
    MotifColors c, {
    required bool selected,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return MotifSectionRow(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? c.accent : c.textTertiary,
      ),
      title: title,
      subtitle: subtitle,
      onTap: onTap,
    );
  }

  // ── Pairing (QR + link) + optional relay ──

  Widget _pairingSection(
    EmbeddedServerConfig cfg,
    EmbeddedServerStatus status,
    MotifColors c,
  ) {
    final pairingUri = status.pairingUri;
    return MotifSection(
      title: 'Pairing',
      footer:
          'Pair a device by scanning this QR (or copying the link). It is the '
          'only credential — the connection is encrypted and the device pins '
          'this server. On the LAN it connects directly; enable a relay to also '
          'reach it without direct connectivity.',
      children: [
        if (pairingUri != null)
          _pairingQr(pairingUri, c)
        else
          MotifSectionRow(
            leading: Icon(Icons.info_outline, color: c.textTertiary),
            title: status.running
                ? 'Use LAN or a relay to generate the QR.'
                : 'Start the server to generate the QR.',
            titleColor: c.textSecondary,
            titleWeight: FontWeight.w400,
          ),
        MotifSectionRow(
          leading: Icon(Icons.cloud_outlined, color: c.accent),
          title: 'Pair over a relay',
          subtitle: cfg.rzvEnabled
              ? 'Reach it without direct connectivity'
              : 'Off — pair directly on the LAN',
          onTap: () => _save(
            cfg.copyWith(rzvEnabled: !cfg.rzvEnabled),
            restartRequired: true,
          ),
          trailing: Switch(
            value: cfg.rzvEnabled,
            onChanged: (v) =>
                _save(cfg.copyWith(rzvEnabled: v), restartRequired: true),
          ),
        ),
        if (cfg.rzvEnabled)
          _field(
            _rzvRelay,
            'Relay address',
            'host:port of your rendezvous relay',
            onChanged: () => _save(
              cfg.copyWith(rzvRelay: _rzvRelay.text.trim()),
              restartRequired: true,
              restartOnBlur: true,
            ),
            onFocusLost: _showPendingRestartPrompt,
          ),
      ],
    );
  }

  Widget _pairingQr(String uri, MotifColors c) {
    return Padding(
      padding: const EdgeInsets.all(MotifSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(MotifSpacing.md),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
            ),
            child: QrImageView(
              data: uri,
              size: 220,
              backgroundColor: Colors.white,
            ),
          ),
          const SizedBox(height: MotifSpacing.sm),
          Text(
            'Scan in the Motif app on another device, or copy the link.',
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: MotifSpacing.xs),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: uri));
              if (mounted) {
                ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                  const SnackBar(content: Text('Pairing link copied')),
                );
              }
            },
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy pairing link'),
          ),
        ],
      ),
    );
  }

  // ── Push notifications ──

  Widget _notificationsSection(EmbeddedServerConfig cfg) {
    return MotifSection(
      title: 'Notifications',
      footer: 'Leave blank to disable background push.',
      children: [
        _field(
          _pushRelayUrl,
          'Push relay',
          kDefaultPushRelayAddress,
          keyboard: TextInputType.url,
          onChanged: () => _save(
            cfg.copyWith(pushRelayUrl: _pushRelayUrl.text.trim()),
            restartRequired: true,
            restartOnBlur: true,
          ),
          onFocusLost: _showPendingRestartPrompt,
        ),
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
    VoidCallback? onFocusLost,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      child: Focus(
        onFocusChange: (hasFocus) {
          if (!hasFocus) onFocusLost?.call();
        },
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
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  final IconData icon;
  final Color color;

  const _IconTile({required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(MotifRadius.xs),
      ),
      child: Icon(icon, color: color, size: 20),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  final bool starting;

  const _StatusPill({
    required this.label,
    required this.color,
    required this.starting,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.sm,
        vertical: 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (starting)
            SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2, color: color),
            )
          else
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: MotifSpacing.sm,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: c.subtleFill,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: c.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: c.textSecondary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;

  const _InlineNotice({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(MotifSpacing.sm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(MotifRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeSummary extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color tone;

  const _ModeSummary({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      padding: const EdgeInsets.all(MotifSpacing.md),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(MotifRadius.xs),
        border: Border.all(color: tone.withValues(alpha: 0.22)),
      ),
      child: Row(
        children: [
          Icon(icon, color: tone, size: 20),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
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

/// Full-page form of the embedded-server settings, for the desktop shell's
/// "Server" view. Same content as the sheet, given room to breathe (and a
/// bigger pairing QR).
class EmbeddedServerPage extends StatelessWidget {
  const EmbeddedServerPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.motif.background,
      body: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            MotifSpacing.lg,
            MotifSpacing.lg,
            MotifSpacing.lg,
            MotifSpacing.xl,
          ),
          child: const EmbeddedServerSettingsSheet(),
        ),
      ),
    );
  }
}
