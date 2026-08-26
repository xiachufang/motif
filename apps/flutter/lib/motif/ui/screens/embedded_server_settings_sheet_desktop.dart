/// Read-only status and transactional settings for the embedded motifd server
/// (desktop only). The page owns lifecycle controls; the Dialog keeps edits in
/// a draft until the user explicitly saves them.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../platform/desktop_launch_desktop.dart';
import '../../state/embedded/embedded_server_service.dart';
import '../../state/embedded/embedded_server_runtime_state.dart';
import '../../state/app/motif_scope.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/observation_select.dart';
import '../widgets/top_toast.dart';

part 'embedded_server_settings_sheet_desktop.g.dart';

/// Which control plane the embedded node joins. Derived from `tsControlUrl`
/// (empty ⇒ official Tailscale; set ⇒ a self-hosted Headscale URL), but held
/// as explicit UI state so "Custom" can stay selected while its URL field is
/// still blank.
enum _TsControl { official, custom }

/// How the node signs in. Derived from `tsAuthkey` (empty ⇒ interactive
/// browser/URL login; set ⇒ headless pre-shared key), held as UI state for the
/// same reason.
enum _TsAuth { browser, authKey }

enum _PushRelayHealth { idle, checking, healthy, failed }

const double _serverPageMaxWidth = 820;

class EmbeddedServerSettingsDialog extends StatefulWidget {
  final Future<bool> Function(String address)? pushRelayHealthChecker;

  const EmbeddedServerSettingsDialog({super.key, this.pushRelayHealthChecker});

  @override
  State<EmbeddedServerSettingsDialog> createState() =>
      _EmbeddedServerSettingsDialogState();
}

class _EmbeddedServerSettingsDialogState
    extends State<EmbeddedServerSettingsDialog> {
  late final TextEditingController _port;
  late final TextEditingController _tsHostname;
  late final TextEditingController _tsAuthkey;
  late final TextEditingController _tsControlUrl;
  late final TextEditingController _rzvRelay;
  late final TextEditingController _rzvJwt;
  late final TextEditingController _pushRelayUrl;

  // Derived UI state for the two Tailscale axes (see the enum docs above).
  late _TsControl _tsControl;
  late _TsAuth _tsAuth;
  late EmbeddedServerConfig _draft;
  bool _tailscaleExpanded = false;
  bool _rzvJwtObscured = true;
  bool _saving = false;
  String? _saveError;
  _PushRelayHealth _pushRelayHealth = _PushRelayHealth.idle;
  int _pushRelayHealthCheckId = 0;
  EmbeddedServerService get _svc =>
      readObservationScope<EmbeddedServerService>(context);

  @override
  void initState() {
    super.initState();
    final c = _svc.config;
    _draft = c;
    _port = TextEditingController(text: '${c.port}');
    _tsHostname = TextEditingController(text: c.tsHostname);
    _tsAuthkey = TextEditingController(text: c.tsAuthkey);
    _tsControlUrl = TextEditingController(text: c.tsControlUrl);
    _rzvRelay = TextEditingController(text: c.rzvRelay);
    _rzvJwt = TextEditingController(text: c.rzvJwt);
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
    _rzvJwt.dispose();
    _pushRelayUrl.dispose();
    super.dispose();
  }

  void _updateDraft(EmbeddedServerConfig next) {
    if (!mounted) return;
    setState(() {
      _draft = next;
      _saveError = null;
    });
  }

  bool _serverIsActive(EmbeddedServerService svc) {
    return svc.status.running || svc.status.starting;
  }

  Future<void> _restartServer(EmbeddedServerService svc) async {
    await svc.stop();
    await svc.start();
  }

  EmbeddedServerConfig _normalizedDraft() {
    final port = int.tryParse(_port.text.trim());
    return _draft.copyWith(
      port: port ?? _draft.port,
      tsHostname: _tsHostname.text.trim(),
      tsAuthkey: _tsAuth == _TsAuth.authKey ? _tsAuthkey.text.trim() : '',
      tsControlUrl: _tsControl == _TsControl.custom
          ? _tsControlUrl.text.trim()
          : '',
      rzvRelay: _rzvRelay.text.trim(),
      rzvJwt: _rzvJwt.text.trim(),
      pushRelayUrl: _pushRelayUrl.text.trim(),
    );
  }

  String? _validateDraft(EmbeddedServerConfig next) {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      return 'Port must be between 1 and 65535.';
    }
    if (next.rzvMode == EmbeddedRelayMode.custom && next.rzvRelay.isEmpty) {
      return 'Relay address is required for a Custom Relay.';
    }
    if (next.rzvMode == EmbeddedRelayMode.custom && next.rzvJwt.isEmpty) {
      return 'Relay owner JWT is required for a Custom Relay.';
    }
    if (next.tsEnabled &&
        _tsControl == _TsControl.custom &&
        next.tsControlUrl.isEmpty) {
      return 'A Headscale control URL is required.';
    }
    return null;
  }

  Future<void> _applySettings() async {
    if (_saving) return;
    final svc = _svc;
    final next = _normalizedDraft();
    final validationError = _validateDraft(next);
    if (validationError != null) {
      setState(() => _saveError = validationError);
      return;
    }

    if (_configsEqual(svc.config, next)) {
      Navigator.of(context).pop();
      return;
    }

    final restart = _serverIsActive(svc);
    if (restart) {
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Save and restart Server?'),
          content: const Text(
            'The new settings require a restart. Restarting closes every '
            'current Terminal and stops all running Codex Threads. Their '
            'current running state cannot be recovered.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Back to settings'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Save and restart'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }

    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await svc.updateConfig(next);
      if (restart) await _restartServer(svc);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = _friendlyError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) => ObservationSelect<Object?>(
    selector: () => null,
    builder: (context, _, _) {
      final c = context.motif;
      return Dialog(
        clipBehavior: Clip.antiAlias,
        backgroundColor: c.background,
        surfaceTintColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 520,
            maxWidth: 620,
            maxHeight: 720,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AdaptiveModalHeader(
                title: 'Server Settings',
                showCloseButton: false,
              ),
              Flexible(
                child: SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.fromLTRB(
                    MotifSpacing.lg,
                    MotifSpacing.md,
                    MotifSpacing.lg,
                    MotifSpacing.lg,
                  ),
                  child: _buildContent(context),
                ),
              ),
              Divider(height: 1, color: c.border),
              Padding(
                padding: const EdgeInsets.all(MotifSpacing.md),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _saving
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: MotifSpacing.sm),
                    FilledButton(
                      onPressed: _saving
                          ? null
                          : () => unawaited(_applySettings()),
                      child: _saving
                          ? const SizedBox.square(
                              dimension: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Save'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _buildContent(BuildContext context) {
    final svc = ObservationScope.of<EmbeddedServerService>(context);
    final cfg = _draft;
    final status = svc.status;
    final c = context.motif;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _listenSection(cfg, c),
        const SizedBox(height: MotifSpacing.lg),
        _relaySettingsSection(cfg, c),
        const SizedBox(height: MotifSpacing.lg),
        _notificationsSection(cfg, status, c),
        if (defaultTargetPlatform != TargetPlatform.windows) ...[
          const SizedBox(height: MotifSpacing.lg),
          _tailscaleSection(cfg, status, c),
        ],
        const SizedBox(height: MotifSpacing.lg),
        MotifSection(
          title: 'App',
          children: [
            MotifSectionRow(
              leading: Icon(Icons.screenshot_monitor_outlined, color: c.accent),
              title: 'Allow remote screenshots',
              subtitle: cfg.allowScreenCapture
                  ? 'Attached clients may capture this desktop or a window'
                  : 'Remote screen capture is disabled',
              onTap: () => _updateDraft(
                cfg.copyWith(allowScreenCapture: !cfg.allowScreenCapture),
              ),
              trailing: Switch(
                value: cfg.allowScreenCapture,
                onChanged: (value) =>
                    _updateDraft(cfg.copyWith(allowScreenCapture: value)),
              ),
            ),
            MotifSectionRow(
              leading: Icon(Icons.rocket_launch_outlined, color: c.accent),
              title: 'Start server on launch',
              subtitle: cfg.autostart
                  ? 'Server starts automatically with Motif'
                  : 'Start manually from this page or the tray',
              onTap: () =>
                  _updateDraft(cfg.copyWith(autostart: !cfg.autostart)),
              trailing: Switch(
                value: cfg.autostart,
                onChanged: (v) => _updateDraft(cfg.copyWith(autostart: v)),
              ),
            ),
          ],
        ),
        if (_saveError != null) ...[
          const SizedBox(height: MotifSpacing.lg),
          _InlineNotice(
            icon: Icons.error_outline,
            text: _saveError!,
            color: c.danger,
          ),
        ],
      ],
    );
  }

  // ── Listen address + port ──

  Widget _listenSection(EmbeddedServerConfig cfg, MotifColors c) {
    return MotifSection(
      title: 'Listen',
      children: [
        Padding(
          padding: const EdgeInsets.all(MotifSpacing.md),
          child: _ModeSummary(
            icon: Icons.lan_outlined,
            title: 'Local network',
            subtitle: 'Reachable on the LAN at 0.0.0.0; encrypted, pair via QR',
            tone: c.success,
          ),
        ),
        _field(
          _port,
          'Port',
          '7777',
          keyboard: TextInputType.number,
          onChanged: () {
            final p = int.tryParse(_port.text.trim());
            if (p != null && p > 0 && p < 65536) {
              _updateDraft(cfg.copyWith(port: p));
            }
          },
        ),
      ],
    );
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
              onTap: () =>
                  _updateDraft(cfg.copyWith(tsEnabled: !cfg.tsEnabled)),
              trailing: Switch(
                value: cfg.tsEnabled,
                onChanged: (v) => _updateDraft(cfg.copyWith(tsEnabled: v)),
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
                onChanged: () => _updateDraft(
                  cfg.copyWith(tsHostname: _tsHostname.text.trim()),
                ),
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
            _updateDraft(cfg.copyWith(tsControlUrl: ''));
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
            onChanged: () => _updateDraft(
              cfg.copyWith(tsControlUrl: _tsControlUrl.text.trim()),
            ),
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
            _updateDraft(cfg.copyWith(tsAuthkey: ''));
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
            onChanged: () =>
                _updateDraft(cfg.copyWith(tsAuthkey: _tsAuthkey.text.trim())),
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

  // ── Rendezvous relay ──

  Widget _relaySettingsSection(EmbeddedServerConfig cfg, MotifColors c) {
    return MotifSection(
      title: 'Connection Relay',
      footer:
          'Use a rendezvous relay to reach this Server without direct network '
          'connectivity. The pairing QR appears on the Server page while it is '
          'running.',
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: MotifSpacing.md,
            vertical: MotifSpacing.sm,
          ),
          child: DropdownButtonFormField<EmbeddedRelayMode>(
            key: ValueKey('relay-mode-${cfg.rzvMode.name}'),
            initialValue: cfg.rzvMode,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: 'Relay mode',
              helperText: switch (cfg.rzvMode) {
                EmbeddedRelayMode.free => kDefaultRzvRelayAddress,
                EmbeddedRelayMode.custom =>
                  'Use your own Relay address and owner JWT',
                EmbeddedRelayMode.off => 'Connection Relay is disabled',
              },
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(
                value: EmbeddedRelayMode.free,
                child: Text('Free'),
              ),
              DropdownMenuItem(
                value: EmbeddedRelayMode.custom,
                child: Text('Custom'),
              ),
              DropdownMenuItem(
                value: EmbeddedRelayMode.off,
                child: Text('Off'),
              ),
            ],
            onChanged: (mode) {
              if (mode != null) {
                _updateDraft(cfg.copyWith(rzvMode: mode));
              }
            },
          ),
        ),
        if (cfg.rzvMode == EmbeddedRelayMode.custom) ...[
          _field(
            _rzvRelay,
            'Relay address',
            'host:port of your WSS rendezvous relay',
            onChanged: () =>
                _updateDraft(cfg.copyWith(rzvRelay: _rzvRelay.text.trim())),
          ),
          _field(
            _rzvJwt,
            'Relay owner JWT',
            'Stored in the system credential vault',
            obscure: _rzvJwtObscured,
            suffix: _rzvJwtActions(),
            onChanged: () =>
                _updateDraft(cfg.copyWith(rzvJwt: _rzvJwt.text.trim())),
          ),
        ],
      ],
    );
  }

  Widget _rzvJwtActions() {
    final hasJwt = _rzvJwt.text.trim().isNotEmpty;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: _rzvJwtObscured
              ? 'Show Relay owner JWT'
              : 'Hide Relay owner JWT',
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(() => _rzvJwtObscured = !_rzvJwtObscured),
          icon: Icon(
            _rzvJwtObscured ? Icons.visibility_outlined : Icons.visibility_off,
            size: 18,
          ),
        ),
        IconButton(
          tooltip: 'Copy Relay owner JWT',
          visualDensity: VisualDensity.compact,
          onPressed: hasJwt
              ? () async {
                  await Clipboard.setData(
                    ClipboardData(text: _rzvJwt.text.trim()),
                  );
                  if (mounted) {
                    showMotifToast(context, 'Relay owner JWT copied');
                  }
                }
              : null,
          icon: const Icon(Icons.copy_outlined, size: 18),
        ),
      ],
    );
  }

  // ── Push notifications ──

  Widget _notificationsSection(
    EmbeddedServerConfig cfg,
    EmbeddedServerStatus status,
    MotifColors c,
  ) {
    return MotifSection(
      title: 'Notifications',
      children: [
        _field(
          _pushRelayUrl,
          'Push relay',
          kDefaultPushRelayAddress,
          keyboard: TextInputType.url,
          suffix: _pushRelayActions(cfg, c),
          onChanged: () {
            _pushRelayHealthCheckId += 1;
            setState(() => _pushRelayHealth = _PushRelayHealth.idle);
            _updateDraft(cfg.copyWith(pushRelayUrl: _pushRelayUrl.text.trim()));
          },
          onFocusLost: () {
            unawaited(_checkPushRelayHealth());
          },
        ),
        MotifSectionRow(
          leading: Icon(Icons.notifications_active_outlined, color: c.accent),
          title: 'Registered push tokens',
          subtitle: status.running
              ? 'View tokens and send a test push'
              : 'Start the server to inspect registered tokens',
          onTap: status.running ? () => unawaited(_showPushTokens()) : null,
          showChevron: status.running,
        ),
      ],
    );
  }

  Widget _pushRelayActions(EmbeddedServerConfig cfg, MotifColors c) {
    final isDefault = _pushRelayUrl.text.trim() == kDefaultPushRelayAddress;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _pushRelayHealthButton(c),
        TextButton(
          onPressed: isDefault ? null : () => unawaited(_resetPushRelay(cfg)),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(0, 28),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            overlayColor: Colors.transparent,
          ),
          child: const Text('Reset'),
        ),
      ],
    );
  }

  Future<void> _showPushTokens() {
    return showAdaptiveModal<void>(
      context,
      builder: (_) => AdaptiveModal(
        title: 'Registered Push Tokens',
        content: _PushTokensView(
          key: const ValueKey('embedded-push-tokens'),
          service: _svc,
        ),
      ),
    );
  }

  Widget _pushRelayHealthButton(MotifColors c) {
    final status = switch (_pushRelayHealth) {
      _PushRelayHealth.idle => (
        label: 'Health',
        color: c.textSecondary,
        icon: Icon(
          Icons.monitor_heart_outlined,
          size: 16,
          color: c.textSecondary,
        ),
      ),
      _PushRelayHealth.checking => (
        label: 'Checking',
        color: c.textSecondary,
        icon: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: c.textSecondary,
          ),
        ),
      ),
      _PushRelayHealth.healthy => (
        label: 'OK',
        color: c.success,
        icon: Icon(Icons.check_circle_outline, size: 16, color: c.success),
      ),
      _PushRelayHealth.failed => (
        label: 'Failed',
        color: c.danger,
        icon: Icon(Icons.error_outline, size: 16, color: c.danger),
      ),
    };

    return Tooltip(
      message: 'Check push relay health',
      child: TextButton.icon(
        onPressed: _pushRelayHealth == _PushRelayHealth.checking
            ? null
            : () => unawaited(_checkPushRelayHealth()),
        icon: status.icon,
        label: Text(status.label),
        style: TextButton.styleFrom(
          foregroundColor: status.color,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          overlayColor: Colors.transparent,
        ),
      ),
    );
  }

  Future<void> _checkPushRelayHealth() async {
    final address = _pushRelayUrl.text.trim();
    final checkId = ++_pushRelayHealthCheckId;
    if (address.isEmpty) {
      if (_pushRelayHealth != _PushRelayHealth.idle) {
        setState(() => _pushRelayHealth = _PushRelayHealth.idle);
      }
      return;
    }
    setState(() => _pushRelayHealth = _PushRelayHealth.checking);
    final checker =
        widget.pushRelayHealthChecker ?? _defaultPushRelayHealthCheck;
    final ok = await checker(address);
    if (!mounted || checkId != _pushRelayHealthCheckId) return;
    setState(
      () => _pushRelayHealth = ok
          ? _PushRelayHealth.healthy
          : _PushRelayHealth.failed,
    );
  }

  Future<void> _resetPushRelay(EmbeddedServerConfig cfg) async {
    _pushRelayHealthCheckId += 1;
    _pushRelayUrl.text = kDefaultPushRelayAddress;
    if (_pushRelayHealth != _PushRelayHealth.idle) {
      setState(() => _pushRelayHealth = _PushRelayHealth.idle);
    } else {
      // The controller was changed programmatically, so rebuild the suffix to
      // disable Reset even when the health state was already idle.
      setState(() {});
    }
    _updateDraft(cfg.copyWith(pushRelayUrl: kDefaultPushRelayAddress));
    if (!mounted) return;
    unawaited(_checkPushRelayHealth());
  }

  Widget _field(
    TextEditingController ctrl,
    String label,
    String hint, {
    TextInputType? keyboard,
    bool obscure = false,
    Widget? suffix,
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
            suffixIcon: suffix == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(left: MotifSpacing.sm),
                    child: suffix,
                  ),
            suffixIconConstraints: const BoxConstraints(
              minWidth: 0,
              minHeight: 0,
            ),
          ),
        ),
      ),
    );
  }
}

Future<bool> _defaultPushRelayHealthCheck(String address) async {
  final uri = _pushRelayHealthUri(address);
  if (uri == null) return false;

  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.getUrl(uri).timeout(const Duration(seconds: 5));
    final resp = await req.close().timeout(const Duration(seconds: 5));
    final body = await resp
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5));
    return resp.statusCode >= 200 &&
        resp.statusCode < 300 &&
        body.trim() == 'ok';
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

Uri? _pushRelayHealthUri(String address) {
  final trimmed = address.trim();
  if (trimmed.isEmpty) return null;
  final candidate = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  try {
    final uri = Uri.parse(candidate);
    if (uri.host.isEmpty) return null;
    return uri.replace(path: '/healthz', query: null, fragment: null);
  } catch (_) {
    return null;
  }
}

@ObservableModel()
class _PushTokensViewModel extends _$_PushTokensViewModel {
  _PushTokensViewModel({
    required Future<List<RegisteredPushToken>> tokens,
    @ObservationReadOnly() required ObservableSet<String> sending,
  }) : super(tokens, sending);
}

@ObservationWidget()
class _PushTokensView extends _$_PushTokensView {
  final EmbeddedServerService service;

  const _PushTokensView({required this.service, super.key});

  @ObservableState(name: 'viewModel')
  _PushTokensViewModel createViewModel() => _PushTokensViewModel(
    tokens: service.registeredPushTokens(),
    sending: ObservableSet(),
  );

  @override
  bool shouldRecreateStates(covariant _PushTokensView oldWidget) =>
      !identical(oldWidget.service, service);

  void _refresh(_PushTokensViewModel viewModel) =>
      viewModel.tokens = service.registeredPushTokens();

  Future<void> _sendTest(
    BuildContext context,
    _PushTokensViewModel viewModel,
    RegisteredPushToken token,
  ) async {
    if (viewModel.sending.contains(token.deviceToken)) return;
    viewModel.sending.add(token.deviceToken);
    try {
      final result = await service.sendTestPush(token.deviceToken);
      if (!context.mounted) return;
      final message = result.pruned
          ? 'Token was rejected by the relay and removed'
          : result.sent
          ? 'Test push sent'
          : 'Test push was not sent';
      showMotifToast(context, message);
      if (result.pruned) _refresh(viewModel);
    } catch (e) {
      if (!context.mounted) return;
      showMotifToast(context, _friendlyError(e));
    } finally {
      viewModel.sending.remove(token.deviceToken);
    }
  }

  @override
  Widget build(
    BuildContext context, {
    required _PushTokensViewModel viewModel,
  }) {
    final c = context.motif;
    return FutureBuilder<List<RegisteredPushToken>>(
      future: viewModel.tokens,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return SizedBox(
            height: 180,
            child: Center(child: CircularProgressIndicator(color: c.accent)),
          );
        }
        if (snap.hasError) {
          return MotifSection(
            children: [
              MotifSectionRow(
                leading: Icon(Icons.error_outline, color: c.danger),
                title: 'Could not load push tokens',
                subtitle: _friendlyError(snap.error!),
                trailing: TextButton.icon(
                  onPressed: () => _refresh(viewModel),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                ),
              ),
            ],
          );
        }

        final tokens = snap.data ?? const [];
        if (tokens.isEmpty) {
          return MotifSection(
            children: [
              MotifSectionRow(
                leading: Icon(Icons.notifications_none, color: c.textTertiary),
                title: 'No registered push tokens',
                subtitle:
                    'Connected devices will appear here after registration',
                titleColor: c.textSecondary,
                titleWeight: FontWeight.w400,
              ),
            ],
          );
        }

        return MotifSection(
          headerTrailing: IconButton(
            tooltip: 'Refresh push tokens',
            onPressed: () => _refresh(viewModel),
            icon: const Icon(Icons.refresh, size: 18),
          ),
          footer:
              'Use Test to send an encrypted push through the configured relay.',
          dividerIndent: 60,
          children: [
            for (final token in tokens)
              _PushTokenRow(
                token: token,
                sending: viewModel.sending.contains(token.deviceToken),
                onSend: () => unawaited(_sendTest(context, viewModel, token)),
              ),
          ],
        );
      },
    );
  }
}

class _PushTokenRow extends StatelessWidget {
  final RegisteredPushToken token;
  final bool sending;
  final VoidCallback onSend;

  const _PushTokenRow({
    required this.token,
    required this.sending,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.md,
        vertical: MotifSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 28,
            child: Icon(Icons.phone_iphone, color: c.accent, size: 20),
          ),
          const SizedBox(width: MotifSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _pushTokenTitle(token),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.headline.copyWith(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                SelectableText(
                  token.deviceToken,
                  style: MotifType.monoSmall.copyWith(
                    color: c.textSecondary,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _pushTokenSubtitle(token),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.caption.copyWith(color: c.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: MotifSpacing.sm),
          TextButton.icon(
            onPressed: sending ? null : onSend,
            icon: sending
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: c.textSecondary,
                    ),
                  )
                : const Icon(Icons.send_outlined, size: 16),
            label: const Text('Test'),
          ),
        ],
      ),
    );
  }
}

String _pushTokenTitle(RegisteredPushToken token) {
  final parts = <String>[
    token.platform.trim().isEmpty ? 'Unknown platform' : token.platform.trim(),
    if ((token.environment ?? '').trim().isNotEmpty) token.environment!.trim(),
    if ((token.appVersion ?? '').trim().isNotEmpty)
      'v${token.appVersion!.trim()}',
  ];
  return parts.join(' · ');
}

String _pushTokenSubtitle(RegisteredPushToken token) {
  final parts = <String>[
    'Registered ${_formatRegisteredAt(token.registeredAt)}',
  ];
  if (token.mutedSessions.isNotEmpty) {
    parts.add(
      '${token.mutedSessions.length} muted session${token.mutedSessions.length == 1 ? '' : 's'}',
    );
  }
  return parts.join(' · ');
}

String _formatRegisteredAt(int ms) {
  if (ms <= 0) return 'at unknown time';
  final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

String _friendlyError(Object error) {
  final text = error.toString();
  return text.startsWith('Bad state: ') ? text.substring(11) : text;
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
        borderRadius: BorderRadius.circular(MotifRadius.pill),
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
            style: MotifType.caption.copyWith(
              color: c.textPrimary,
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
          borderRadius: BorderRadius.circular(MotifRadius.pill),
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
                style: MotifType.caption.copyWith(
                  color: c.textSecondary,
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
              style: MotifType.subhead.copyWith(color: color),
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
                  style: MotifType.body.copyWith(
                    color: c.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: MotifType.caption.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showEmbeddedServerSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const EmbeddedServerSettingsDialog(),
  );
}

bool _configsEqual(EmbeddedServerConfig a, EmbeddedServerConfig b) {
  return a.port == b.port &&
      a.tsEnabled == b.tsEnabled &&
      a.tsHostname == b.tsHostname &&
      a.tsAuthkey == b.tsAuthkey &&
      a.tsControlUrl == b.tsControlUrl &&
      a.rzvMode == b.rzvMode &&
      a.rzvRelay == b.rzvRelay &&
      a.rzvJwt == b.rzvJwt &&
      a.pushRelayUrl == b.pushRelayUrl &&
      a.autostart == b.autostart &&
      a.allowScreenCapture == b.allowScreenCapture;
}

String? _relayErrorText(
  EmbeddedServerConfig config,
  EmbeddedServerStatus status,
) {
  if (!config.rzvEnabled) return null;
  final relayError = status.relayError;
  if (relayError != null && relayError.trim().isNotEmpty) {
    final lower = relayError.toLowerCase();
    if (config.rzvMode == EmbeddedRelayMode.free &&
        (lower.contains('jwt') ||
            lower.contains('401') ||
            lower.contains('403') ||
            lower.contains('unauthorized') ||
            lower.contains('forbidden'))) {
      return 'Free Relay credentials are being refreshed automatically.';
    }
    return embeddedRelayErrorMessage(relayError);
  }
  final startError = status.error;
  if (startError == null || startError.trim().isEmpty) return null;
  final lower = startError.toLowerCase();
  if (!lower.contains('relay') && !lower.contains('jwt')) return null;
  return embeddedRelayErrorMessage(startError);
}

String? _relayPairingUri(EmbeddedServerStatus status) {
  final value = status.pairingUri;
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  final relay = uri?.queryParameters['rzv'];
  return relay == null || relay.isEmpty ? null : value;
}

/// Read-only status and controls for this computer's embedded motifd. Editing
/// happens in [EmbeddedServerSettingsDialog], where changes remain a local
/// draft until the user explicitly saves them.
@ObservationWidget()
class EmbeddedServerPage extends _$EmbeddedServerPage {
  const EmbeddedServerPage({super.key});

  @PlainState(name: 'scrollController')
  ScrollController createScrollController() => ScrollController();

  Future<void> _start(
    BuildContext context,
    EmbeddedServerService service,
  ) async {
    try {
      await service.start();
    } catch (error) {
      if (context.mounted) showMotifToast(context, _friendlyError(error));
    }
  }

  Future<void> _stop(
    BuildContext context,
    EmbeddedServerService service,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Stop Server?'),
        content: const Text(
          'Stopping the Server closes every current Terminal and stops all '
          'running Codex Threads. Their current running state cannot be '
          'recovered.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: dialogContext.motif.danger,
              foregroundColor: dialogContext.motif.textOnAccent,
              overlayColor: Colors.transparent,
            ),
            child: const Text('Stop Server'),
          ),
        ],
      ),
    );
    if (!context.mounted || confirmed != true) return;
    try {
      await service.stop();
    } catch (error) {
      if (context.mounted) showMotifToast(context, _friendlyError(error));
    }
  }

  @override
  Widget build(
    BuildContext context, {
    required ScrollController scrollController,
  }) {
    final service = ObservationScope.of<EmbeddedServerService>(context);
    final config = service.config;
    final status = service.status;
    final lifecycle = service.runtimeState.lifecycle;
    final running = lifecycle is EmbeddedServerRunning || status.running;

    return Scaffold(
      backgroundColor: context.motif.background,
      body: SafeArea(
        top: false,
        child: CustomScrollView(
          controller: scrollController,
          primary: false,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.only(top: MotifSpacing.lg),
              sliver: SliverToBoxAdapter(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: _serverPageMaxWidth,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: MotifSpacing.lg,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _ServerOverview(
                            config: config,
                            status: status,
                            lifecycle: lifecycle,
                          ),
                          if (running && config.rzvEnabled) ...[
                            const SizedBox(height: MotifSpacing.lg),
                            _RelayPairingSection(
                              config: config,
                              status: status,
                            ),
                          ],
                          const SizedBox(height: MotifSpacing.lg),
                          _ServerPageActions(
                            lifecycle: lifecycle,
                            onStart: () => unawaited(_start(context, service)),
                            onStop: () => unawaited(_stop(context, service)),
                            onSettings: () => unawaited(
                              showEmbeddedServerSettingsDialog(context),
                            ),
                          ),
                          const SizedBox(height: MotifSpacing.xl),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerOverview extends StatelessWidget {
  final EmbeddedServerConfig config;
  final EmbeddedServerStatus status;
  final EmbeddedServerLifecycleState lifecycle;

  const _ServerOverview({
    required this.config,
    required this.status,
    required this.lifecycle,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final running = lifecycle is EmbeddedServerRunning || status.running;
    final busy =
        lifecycle is EmbeddedServerStarting ||
        lifecycle is EmbeddedServerStopping;
    final (label, color) = switch (lifecycle) {
      EmbeddedServerRunning() => ('Running', c.success),
      EmbeddedServerStarting() => ('Starting…', c.warning),
      EmbeddedServerStopping() => ('Stopping…', c.warning),
      EmbeddedServerFailed() => ('Failed', c.danger),
      EmbeddedServerUnavailable() => ('Unavailable', c.danger),
      EmbeddedServerStopped() => ('Stopped', c.textTertiary),
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
                          style: MotifType.title.copyWith(
                            color: c.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _subtitle(running),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: MotifType.subhead.copyWith(
                            color: c.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: MotifSpacing.md),
                  _StatusPill(label: label, color: color, starting: busy),
                ],
              ),
              if (running) ...[
                const SizedBox(height: MotifSpacing.md),
                _statusChips(),
              ],
              if (status.error != null) ...[
                const SizedBox(height: MotifSpacing.md),
                _InlineNotice(
                  icon: Icons.error_outline,
                  text: status.error!,
                  color: c.danger,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _subtitle(bool running) {
    if (!running) {
      return 'Configured for 0.0.0.0:${config.port}';
    }
    final endpointCount = status.boundAddrs.length;
    final endpoints = switch (endpointCount) {
      0 => 'No active connections',
      1 => '1 active connection',
      _ => '$endpointCount active connections',
    };
    return '$endpoints · ${status.sessionCount} Terminal${status.sessionCount == 1 ? '' : 's'}';
  }

  Widget _statusChips() {
    final chips = <Widget>[
      for (final address in status.boundAddrs)
        _InfoChip(
          icon: _endpointPresentation(address).icon,
          label: _endpointPresentation(address).label,
        ),
      _InfoChip(
        icon: Icons.terminal_outlined,
        label:
            '${status.sessionCount} Terminal${status.sessionCount == 1 ? '' : 's'}',
      ),
      if (status.tailscaleState != null)
        _InfoChip(
          icon: Icons.hub_outlined,
          label: 'Tailscale ${status.tailscaleState}',
        ),
    ];
    return Wrap(
      spacing: MotifSpacing.sm,
      runSpacing: MotifSpacing.sm,
      children: chips,
    );
  }

  ({IconData icon, String label}) _endpointPresentation(String address) {
    if (address.startsWith('tcp://')) {
      return (
        icon: Icons.lan_outlined,
        label: address.substring('tcp://'.length),
      );
    }
    if (address.startsWith('rzv://')) {
      var relay = address.substring('rzv://'.length);
      if (relay.startsWith('wss://')) relay = relay.substring('wss://'.length);
      return (icon: Icons.cloud_outlined, label: 'Relay · $relay');
    }
    if (address.startsWith('tailscale://')) {
      return (
        icon: Icons.hub_outlined,
        label: 'Tailscale · ${address.substring('tailscale://'.length)}',
      );
    }
    return (icon: Icons.link_outlined, label: address);
  }
}

class _RelayPairingSection extends StatelessWidget {
  final EmbeddedServerConfig config;
  final EmbeddedServerStatus status;

  const _RelayPairingSection({required this.config, required this.status});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final uri = _relayPairingUri(status);
    final error = _relayErrorText(config, status);
    return MotifSection(
      title: 'Relay',
      children: [
        Padding(
          padding: const EdgeInsets.all(MotifSpacing.lg),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final qr = uri == null
                  ? _PairingQrUnavailable(color: c.textTertiary)
                  : _PairingQr(uri: uri);
              final details = _RelayPairingDetails(
                relay: config.effectiveRzvRelay,
                uri: uri,
                error: error,
              );
              if (constraints.maxWidth < 560) {
                return Column(
                  children: [
                    qr,
                    const SizedBox(height: MotifSpacing.lg),
                    details,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  qr,
                  const SizedBox(width: MotifSpacing.xl),
                  Expanded(child: details),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PairingQr extends StatelessWidget {
  final String uri;

  const _PairingQr({required this.uri});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return Container(
      padding: const EdgeInsets.all(MotifSpacing.sm),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(MotifRadius.sm),
        border: Border.all(color: c.border),
      ),
      child: QrImageView(data: uri, size: 188, backgroundColor: Colors.white),
    );
  }
}

class _PairingQrUnavailable extends StatelessWidget {
  final Color color;

  const _PairingQrUnavailable({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 206,
      height: 206,
      decoration: BoxDecoration(
        color: context.motif.subtleFill,
        borderRadius: BorderRadius.circular(MotifRadius.sm),
        border: Border.all(color: context.motif.border),
      ),
      child: Icon(Icons.qr_code_2_outlined, size: 54, color: color),
    );
  }
}

class _RelayPairingDetails extends StatelessWidget {
  final String relay;
  final String? uri;
  final String? error;

  const _RelayPairingDetails({
    required this.relay,
    required this.uri,
    required this.error,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final healthy = error == null && uri != null;
    final tone = healthy ? c.success : c.danger;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _IconTile(
              icon: healthy
                  ? Icons.cloud_done_outlined
                  : Icons.cloud_off_outlined,
              color: tone,
            ),
            const SizedBox(width: MotifSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    healthy ? 'Ready to pair' : 'Relay unavailable',
                    style: MotifType.body.copyWith(
                      color: c.textPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _displayRelayAddress(relay),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: MotifType.subhead.copyWith(color: c.textSecondary),
                  ),
                ],
              ),
            ),
            _StatusPill(
              label: healthy ? 'Connected' : 'Error',
              color: tone,
              starting: false,
            ),
          ],
        ),
        const SizedBox(height: MotifSpacing.lg),
        if (error != null)
          _InlineNotice(
            icon: Icons.error_outline,
            text: error!,
            color: c.danger,
          )
        else
          Text(
            'Scan the code with Motif on another device to connect through '
            'the Relay.',
            style: MotifType.subhead.copyWith(color: c.textSecondary),
          ),
        const SizedBox(height: MotifSpacing.md),
        OutlinedButton.icon(
          onPressed: uri == null
              ? null
              : () async {
                  await Clipboard.setData(ClipboardData(text: uri!));
                  if (context.mounted) {
                    showMotifToast(context, 'Pairing link copied');
                  }
                },
          icon: const Icon(Icons.copy_outlined, size: 16),
          label: const Text('Copy pairing link'),
        ),
      ],
    );
  }
}

String _displayRelayAddress(String value) {
  final trimmed = value.trim();
  final uri = Uri.tryParse(
    trimmed.contains('://') ? trimmed : 'wss://$trimmed',
  );
  if (uri == null || uri.host.isEmpty) return trimmed;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

class _ServerPageActions extends StatelessWidget {
  final EmbeddedServerLifecycleState lifecycle;
  final VoidCallback onStart;
  final VoidCallback onStop;
  final VoidCallback onSettings;

  const _ServerPageActions({
    required this.lifecycle,
    required this.onStart,
    required this.onStop,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final running = lifecycle is EmbeddedServerRunning;
    final busy =
        lifecycle is EmbeddedServerStarting ||
        lifecycle is EmbeddedServerStopping;
    final unavailable = lifecycle is EmbeddedServerUnavailable;

    final Widget lifecycleButton;
    if (busy) {
      lifecycleButton = OutlinedButton.icon(
        onPressed: null,
        icon: const SizedBox.square(
          dimension: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        label: Text(
          lifecycle is EmbeddedServerStopping ? 'Stopping…' : 'Starting…',
        ),
      );
    } else if (running) {
      lifecycleButton = OutlinedButton.icon(
        onPressed: onStop,
        icon: const Icon(Icons.stop),
        label: const Text('Stop Server'),
        style: OutlinedButton.styleFrom(
          foregroundColor: c.danger,
          side: BorderSide(color: c.danger.withValues(alpha: 0.45)),
          overlayColor: Colors.transparent,
        ),
      );
    } else {
      lifecycleButton = FilledButton.icon(
        onPressed: unavailable ? null : onStart,
        icon: const Icon(Icons.play_arrow),
        label: const Text('Start Server'),
      );
    }

    final settingsButton = OutlinedButton.icon(
      onPressed: onSettings,
      icon: const Icon(Icons.settings_outlined),
      label: const Text('Settings'),
    );

    if (MediaQuery.sizeOf(context).width < 500) {
      return Row(
        children: [
          Expanded(child: lifecycleButton),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(child: settingsButton),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        SizedBox(width: 156, child: lifecycleButton),
        const SizedBox(width: MotifSpacing.sm),
        SizedBox(width: 156, child: settingsButton),
      ],
    );
  }
}
