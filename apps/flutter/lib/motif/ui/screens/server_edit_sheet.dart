import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/settings.dart';
import '../../net/ssh/ssh_config_discovery.dart';
import '../../platform/services.dart';
import '../../platform/tailscale_support.dart';
import '../../state/app/app_state.dart';
import '../../state/app/motif_scope.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';
import '../widgets/observation_select.dart';
import '../widgets/tailscale_section.dart';

typedef SshConfigDiscoveryLoader = Future<SshConfigSnapshot> Function();

/// Add or edit a server. Returns once saved/cancelled.
class ServerEditSheet extends StatefulWidget {
  final MotifServer? existing;
  final ServerKind? initialKind;
  final bool connectOnSave;
  final SshConfigDiscoveryLoader? sshConfigDiscoveryLoader;

  const ServerEditSheet({
    super.key,
    this.existing,
    this.initialKind,
    this.connectOnSave = false,
    this.sshConfigDiscoveryLoader,
  });

  @override
  State<ServerEditSheet> createState() => _ServerEditSheetState();
}

class _ServerEditSheetState extends State<ServerEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _sshHost;
  late final TextEditingController _sshPort;
  late final TextEditingController _sshUsername;
  late final TextEditingController _sshPassword;
  late final TextEditingController _sshPrivateKey;
  late final TextEditingController _sshPrivateKeyPassphrase;
  late final TextEditingController _wslDistribution;
  late final TextEditingController _relay;
  late final TextEditingController _psk;
  late final TextEditingController _pubKey;
  late final TextEditingController _directHosts;
  late ServerKind _kind;
  late SshAuthMethod _sshAuthMethod;
  late bool _sshAutoInitialize;
  List<SshConfigHost> _sshConfigHosts = const [];
  List<SshIdentity> _sshIdentities = const [];
  List<TailscalePeer> _discovered = const [];
  final Map<String, TailscalePingResult> _peerPing = {};
  final Set<String> _checkingPeers = {};
  bool _discoveryStarted = false;
  bool _discoveryLoading = false;
  bool _sshDiscoveryStarted = false;
  bool _sshDiscoveryLoading = false;
  bool _showAllPeers = false;
  bool _saving = false;
  bool _savingConnect = false;
  String? _selectedPeerId;
  String? _discoveryMessage;
  String? _sshDiscoveryMessage;
  int _discoveryGeneration = 0;

  bool get _supportsTailscale => tailscaleSupported;
  bool get _supportsSsh => !kIsWeb;
  bool get _supportsWsl =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 7777}');
    _sshHost = TextEditingController(text: e?.sshHost ?? '');
    _sshPort = TextEditingController(text: '${e?.sshPort ?? 22}');
    _sshUsername = TextEditingController(text: e?.sshUsername ?? '');
    _sshPassword = TextEditingController(text: e?.sshPassword ?? '');
    _sshPrivateKey = TextEditingController(text: e?.sshPrivateKey ?? '');
    _sshPrivateKeyPassphrase = TextEditingController(
      text: e?.sshPrivateKeyPassphrase ?? '',
    );
    _wslDistribution = TextEditingController(text: e?.wslDistribution ?? '');
    _relay = TextEditingController(text: e?.relay ?? '');
    _psk = TextEditingController(text: e?.psk ?? '');
    _pubKey = TextEditingController(text: e?.pubKey ?? '');
    _directHosts = TextEditingController(
      text: _formatDirectHosts(e?.directHosts ?? const []),
    );
    _sshAuthMethod = e?.sshAuthMethod ?? SshAuthMethod.password;
    _sshAutoInitialize = e?.sshAutoInitialize ?? false;
    final existingKind = e?.kind ?? widget.initialKind;
    if (existingKind == ServerKind.tailscale && !_supportsTailscale) {
      _kind = ServerKind.direct;
    } else if (existingKind == ServerKind.ssh && !_supportsSsh) {
      _kind = ServerKind.direct;
    } else if (existingKind == ServerKind.wsl && !_supportsWsl) {
      _kind = ServerKind.direct;
    } else {
      // Direct is no longer offered as a choice for new servers. Windows
      // prefers WSL; other native clients prefer Tailscale, then SSH. Web
      // falls back to direct and shows no "Reach via" selector.
      _kind =
          existingKind ??
          (_supportsWsl
              ? ServerKind.wsl
              : (_supportsTailscale
                    ? ServerKind.tailscale
                    : (_supportsSsh ? ServerKind.ssh : ServerKind.direct)));
    }
    if ((_kind == ServerKind.ssh || _kind == ServerKind.wsl) &&
        _host.text.trim().isEmpty) {
      _host.text = '127.0.0.1';
    }
    if (_kind == ServerKind.ssh) {
      Future.microtask(_loadSshDiscovery);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _sshHost.dispose();
    _sshPort.dispose();
    _sshUsername.dispose();
    _sshPassword.dispose();
    _sshPrivateKey.dispose();
    _sshPrivateKeyPassphrase.dispose();
    _wslDistribution.dispose();
    _relay.dispose();
    _psk.dispose();
    _pubKey.dispose();
    _directHosts.dispose();
    super.dispose();
  }

  bool get _valid {
    final motifdPort = int.tryParse(_port.text.trim());
    final base =
        _name.text.trim().isNotEmpty &&
        _host.text.trim().isNotEmpty &&
        motifdPort != null &&
        motifdPort > 0 &&
        motifdPort <= 65535;
    if (!base) return false;
    if (_kind == ServerKind.direct && !_pairingFieldsValid()) return false;
    if (_kind != ServerKind.ssh) return true;
    final sshPort = int.tryParse(_sshPort.text.trim());
    if (_sshHost.text.trim().isEmpty ||
        _sshUsername.text.trim().isEmpty ||
        sshPort == null ||
        sshPort <= 0 ||
        sshPort > 65535) {
      return false;
    }
    return switch (_sshAuthMethod) {
      SshAuthMethod.password => _sshPassword.text.isNotEmpty,
      SshAuthMethod.privateKey => _sshPrivateKey.text.trim().isNotEmpty,
    };
  }

  bool get _isNew => widget.existing == null;

  String get _primaryActionLabel {
    if (_saving) return _savingConnect ? 'Connecting…' : 'Saving…';
    if (!widget.connectOnSave) return 'Save';
    final peer = _selectedPeer;
    if (peer != null) return 'Connect to ${peer.hostname}';
    return _isNew ? 'Save and Connect' : 'Save and Reconnect';
  }

  List<TailscalePeer> get _visiblePeers => _showAllPeers
      ? _discovered
      : _discovered.where((p) => p.isLikelyMotifd).toList();

  TailscalePeer? get _selectedPeer {
    final id = _selectedPeerId;
    if (id == null) return null;
    for (final peer in _discovered) {
      if (peer.id == id) return peer;
    }
    return null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_supportsTailscale &&
        !_discoveryStarted &&
        _isNew &&
        _kind == ServerKind.tailscale) {
      _discoveryStarted = true;
      Future.microtask(_loadDiscovery);
    }
  }

  Future<void> _save({required bool connectAfterSave}) async {
    if (_saving || !_valid) return;
    setState(() {
      _saving = true;
      _savingConnect = connectAfterSave;
    });
    final store = readObservationScope<AppState>(context).servers;
    final existing = widget.existing;
    final id = existing?.id ?? 'srv-${DateTime.now().microsecondsSinceEpoch}';
    final isDirect = _kind == ServerKind.direct;
    final directHosts = isDirect
        ? _directHostsForSave(existing)
        : const <String>[];
    final server = MotifServer(
      id: id,
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      scheme: isDirect
          ? _schemeForDirectSave(existing, directHosts)
          : existing?.scheme ?? 'http',
      token: '',
      kind: _kind,
      psk: isDirect ? _psk.text.trim() : '',
      pubKey: isDirect ? _pubKey.text.trim() : '',
      directHosts: directHosts,
      sshHost: _sshHost.text.trim(),
      sshPort: int.tryParse(_sshPort.text.trim()) ?? 22,
      sshUsername: _sshUsername.text.trim(),
      sshAuthMethod: _sshAuthMethod,
      sshPassword: _sshPassword.text,
      sshPrivateKey: _sshPrivateKey.text,
      sshPrivateKeyPassphrase: _sshPrivateKeyPassphrase.text,
      sshAutoInitialize: _sshAutoInitialize,
      wslDistribution: _wslDistribution.text.trim(),
    );
    if (existing == null) {
      await store.add(server);
    } else {
      await store.update(server);
    }
    if (mounted) {
      Navigator.of(context).pop(
        ServerEditResult(server: server, connectAfterSave: connectAfterSave),
      );
    }
  }

  List<String> _directHostsForSave(MotifServer? existing) {
    if (_kind != ServerKind.direct) return const [];
    final parsed = _parseDirectHosts(_directHosts.text);
    final host = _host.text.trim();
    final pubKeyPresent = _pubKey.text.trim().isNotEmpty;
    if (existing == null || existing.kind != ServerKind.direct) {
      if (parsed.isEmpty && pubKeyPresent && host.isNotEmpty) return [host];
      return parsed;
    }
    if (host.isEmpty) return parsed;
    if (host == existing.host) {
      if (parsed.isEmpty && pubKeyPresent) return [host];
      return parsed;
    }
    if (listEquals(parsed, existing.directHosts)) return [host];
    if (parsed.isEmpty) return pubKeyPresent ? [host] : const [];
    if (parsed.contains(host)) {
      return [host, ...parsed.where((h) => h != host)];
    }
    return [host, ...parsed];
  }

  String _schemeForDirectSave(MotifServer? existing, List<String> directHosts) {
    if (_pubKey.text.trim().isNotEmpty) return 'https';
    if (directHosts.isNotEmpty) return 'http';
    return existing?.scheme ?? 'http';
  }

  bool _pairingFieldsValid({bool pskRequired = false}) =>
      _keyFieldError(_psk.text.trim(), required: pskRequired) == null &&
      _keyFieldError(_pubKey.text.trim()) == null;

  bool get _rendezvousValid =>
      _name.text.trim().isNotEmpty &&
      MotifServer.splitRelayEndpoint(_relay.text.trim()) != null &&
      _pairingFieldsValid(pskRequired: true);

  String? _keyFieldError(String value, {bool required = false}) {
    if (value.isEmpty) return required ? 'Required' : null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(value));
      if (bytes.length != 32) return 'Must decode to 32 bytes';
    } on FormatException {
      return 'Not base64url';
    }
    return null;
  }

  String? _relayError() {
    final relay = _relay.text.trim();
    if (relay.isEmpty) return 'Required';
    return MotifServer.splitRelayEndpoint(relay) == null
        ? 'Expected host:port or wss:// URL'
        : null;
  }

  static String _formatDirectHosts(List<String> hosts) => hosts.join(', ');

  static List<String> _parseDirectHosts(String raw) => raw
      .split(RegExp(r'[\s,]+'))
      .map((h) => h.trim())
      .where((h) => h.isNotEmpty)
      .toList(growable: false);

  Future<void> _loadDiscovery() async {
    final generation = ++_discoveryGeneration;
    final svc = readObservationScope<AppState>(context).platform.tailscale;
    setState(() {
      _discoveryLoading = true;
      _discoveryMessage = null;
      _peerPing.clear();
      _checkingPeers.clear();
    });
    if (svc.state.status != TailscaleStatus.running) {
      if (!mounted || generation != _discoveryGeneration) return;
      setState(() {
        _discoveryLoading = false;
        _discovered = const [];
        _discoveryMessage = null;
      });
      return;
    }
    final peers = await svc.discoverPeers();
    if (!mounted || generation != _discoveryGeneration) return;
    setState(() {
      _discoveryLoading = false;
      _discovered = peers;
      _discoveryMessage = null;
    });
    await _refreshVisiblePeerPings(generation: generation);
  }

  Future<void> _refreshVisiblePeerPings({int? generation}) async {
    final currentGeneration = generation ?? ++_discoveryGeneration;
    if (!_supportsTailscale ||
        !_isNew ||
        _kind != ServerKind.tailscale ||
        _discoveryLoading) {
      return;
    }
    final svc = readObservationScope<AppState>(context).platform.tailscale;
    final port = int.tryParse(_port.text.trim());
    final peers = _visiblePeers;
    if (peers.isEmpty || port == null) return;
    if (svc.state.status != TailscaleStatus.running) {
      setState(() {
        for (final peer in peers) {
          _peerPing[peer.id] = const TailscalePingResult.unreachable(
            'Tailscale off',
          );
        }
      });
      return;
    }
    setState(() {
      _checkingPeers
        ..clear()
        ..addAll(peers.map((p) => p.id));
    });
    for (final peer in peers) {
      final result = await svc.pingMotifServer(
        host: peer.preferredAddress,
        port: port,
      );
      if (!mounted || currentGeneration != _discoveryGeneration) return;
      setState(() {
        _checkingPeers.remove(peer.id);
        _peerPing[peer.id] = result;
      });
    }
  }

  void _applyDiscoveredPeer(TailscalePeer peer) {
    _host.text = peer.preferredAddress;
    if (_name.text.trim().isEmpty) _name.text = peer.hostname;
    _selectedPeerId = peer.id;
    setState(() {});
  }

  Future<void> _openTailscaleSetup(TailscaleService svc) async {
    await showTailscaleConnectionSheet(context, svc: svc);
    if (!mounted || _kind != ServerKind.tailscale) return;
    if (svc.state.status == TailscaleStatus.running) {
      await _loadDiscovery();
    } else {
      setState(() {});
    }
  }

  void _onKindChanged(Set<ServerKind> selected) {
    final next = selected.first;
    if (next == ServerKind.tailscale && !_supportsTailscale) return;
    if (next == ServerKind.ssh && !_supportsSsh) return;
    if (next == ServerKind.wsl && !_supportsWsl) return;
    setState(() {
      _kind = next;
      if (_kind == ServerKind.wsl) {
        _host.text = '127.0.0.1';
      } else if (_kind == ServerKind.ssh && _host.text.trim().isEmpty) {
        _host.text = '127.0.0.1';
      }
    });
    if (_isNew && _kind == ServerKind.tailscale) {
      _discoveryStarted = true;
      Future.microtask(_loadDiscovery);
    } else if (_kind == ServerKind.ssh) {
      Future.microtask(_loadSshDiscovery);
    }
  }

  void _onSshAuthChanged(Set<SshAuthMethod> selected) {
    setState(() => _sshAuthMethod = selected.first);
    if (_sshAuthMethod == SshAuthMethod.privateKey) {
      Future.microtask(_loadSshDiscovery);
    }
  }

  Future<void> _loadSshDiscovery({bool force = false}) async {
    if (!_supportsSsh || _sshDiscoveryLoading) return;
    if (_sshDiscoveryStarted && !force) return;
    _sshDiscoveryStarted = true;
    setState(() {
      _sshDiscoveryLoading = true;
      _sshDiscoveryMessage = null;
    });
    try {
      final loader = widget.sshConfigDiscoveryLoader;
      final snapshot = loader == null
          ? await const SshConfigDiscovery().load()
          : await loader();
      if (!mounted) return;
      setState(() {
        _sshConfigHosts = snapshot.hosts;
        _sshIdentities = snapshot.identities;
        _sshDiscoveryLoading = false;
        _sshDiscoveryMessage = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sshDiscoveryLoading = false;
        _sshDiscoveryMessage = '$e';
      });
    }
  }

  void _applySshConfigHost(SshConfigHost host) {
    final identity = _sshIdentityForPath(host.identityFile);
    setState(() {
      _sshHost.text = host.hostName.isEmpty ? host.alias : host.hostName;
      if (host.user != null && host.user!.isNotEmpty) {
        _sshUsername.text = host.user!;
      }
      if (host.port != null) _sshPort.text = '${host.port}';
      if (_name.text.trim().isEmpty) _name.text = host.alias;
      if (identity != null) {
        _sshAuthMethod = SshAuthMethod.privateKey;
        _sshPrivateKey.text = identity.contents;
      }
    });
  }

  void _applySshIdentity(SshIdentity identity) {
    setState(() {
      _sshAuthMethod = SshAuthMethod.privateKey;
      _sshPrivateKey.text = identity.contents;
    });
  }

  Future<void> _saveRendezvousName() async {
    final existing = widget.existing!;
    if (_saving || !_rendezvousValid) return;
    setState(() => _saving = true);
    final name = _name.text.trim();
    final relay = _relay.text.trim();
    final hp = MotifServer.splitRelayEndpoint(relay)!;
    final updated = existing.copyWith(
      name: name.isEmpty ? existing.name : name,
      host: hp.host,
      port: hp.port,
      relay: relay,
      psk: _psk.text.trim(),
      pubKey: _pubKey.text.trim(),
    );
    await readObservationScope<AppState>(context).servers.update(updated);
    if (mounted) {
      Navigator.of(
        context,
      ).pop(ServerEditResult(server: updated, connectAfterSave: false));
    }
  }

  Widget _buildRendezvous(BuildContext context, MotifServer server) {
    final c = context.motif;
    final pinned = _pubKey.text.trim().isNotEmpty;
    return AdaptivePanel(
      title: 'Rendezvous Server',
      actions: [
        TextButton(
          onPressed: _saving || !_rendezvousValid ? null : _saveRendezvousName,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
      body: ListView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        padding: EdgeInsets.fromLTRB(
          MotifSpacing.lg,
          MotifSpacing.md,
          MotifSpacing.lg,
          MotifSpacing.xl,
        ),
        children: [
          MotifSection(
            title: 'Name',
            dividerIndent: MotifSpacing.lg,
            children: [_field(_name, 'Name', 'e.g. Studio Mac')],
          ),
          const SizedBox(height: MotifSpacing.xl),
          MotifSection(
            title: 'Pairing',
            footer:
                'Reached through a rendezvous relay — both sides dial out '
                'and pair by a scanned link. These values are copied from '
                'the pairing QR.',
            dividerIndent: MotifSpacing.lg,
            children: [
              _field(
                _relay,
                'Relay',
                'relay.example.com:8765',
                errorText: _relayError(),
              ),
              _field(
                _psk,
                'Pairing Secret (psk)',
                '',
                minLines: 1,
                maxLines: 3,
                errorText: _keyFieldError(_psk.text.trim(), required: true),
              ),
              _field(
                _pubKey,
                'Certificate Pin (pubKey)',
                '',
                minLines: 1,
                maxLines: 3,
                errorText: _keyFieldError(_pubKey.text.trim()),
              ),
              _rzvInfoRow(
                c,
                pinned ? Icons.lock_outline : Icons.lock_open_outlined,
                'Encryption',
                pinned
                    ? 'End-to-end encrypted (cert pinned)'
                    : 'Plaintext through the relay',
                valueColor: pinned ? c.success : c.warning,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _rzvInfoRow(
    MotifColors c,
    IconData icon,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: MotifSpacing.sm,
        vertical: MotifSpacing.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: valueColor ?? c.textSecondary),
          const SizedBox(width: MotifSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: MotifType.caption.copyWith(color: c.textTertiary),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: MotifType.body.copyWith(
                    color: valueColor ?? c.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ObservationSelect<Object?>(
    selector: () => null,
    builder: (context, _, _) {
      // A rendezvous server has no host/port/token/transport to edit (it's reached
      // through a relay via a scanned pairing link). Show a safe read-only panel
      // instead of the Direct/Tailscale form, which can't represent it.
      final existing = widget.existing;
      if (existing != null && existing.kind == ServerKind.rendezvous) {
        return _buildRendezvous(context, existing);
      }
      final title = widget.existing == null
          ? (widget.connectOnSave ? 'Connect Server' : 'Add Server')
          : 'Edit Server';
      return AdaptivePanel(
        title: title,
        actions: [
          TextButton(
            onPressed: _valid && !_saving
                ? () => _save(connectAfterSave: widget.connectOnSave)
                : null,
            child: Text(_primaryActionLabel),
          ),
        ],
        body: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(
            MotifSpacing.lg,
            MotifSpacing.md,
            MotifSpacing.lg,
            MotifSpacing.xl,
          ),
          children: [
            if (_supportsTailscale || _supportsSsh || _supportsWsl) ...[
              _reachViaSection(),
              const SizedBox(height: MotifSpacing.xl),
            ],
            if (_supportsTailscale &&
                _isNew &&
                _kind == ServerKind.tailscale) ...[
              _discoverySection(context),
              const SizedBox(height: MotifSpacing.xl),
            ],
            MotifSection(
              title: 'Name',
              dividerIndent: MotifSpacing.lg,
              children: [_field(_name, 'Name', 'e.g. Dev box')],
            ),
            const SizedBox(height: MotifSpacing.xl),
            if (_kind == ServerKind.ssh) ...[
              _sshLoginSection(),
              const SizedBox(height: MotifSpacing.xl),
              _sshAuthSection(),
              const SizedBox(height: MotifSpacing.xl),
              _sshMotifdSection(),
              const SizedBox(height: MotifSpacing.xl),
            ],
            if (_kind == ServerKind.wsl) ...[
              _wslSection(),
              const SizedBox(height: MotifSpacing.xl),
            ],
            _motifdAddressSection(),
            if (_kind == ServerKind.direct) ...[
              const SizedBox(height: MotifSpacing.xl),
              _pairingFieldsSection(),
            ],
          ],
        ),
      );
    },
  );

  Widget _pairingFieldsSection() {
    return MotifSection(
      title: 'Pairing',
      footer:
          'Values copied from a motif://pair link. Leave blank for a plain manually entered direct server.',
      dividerIndent: MotifSpacing.lg,
      children: [
        _field(
          _psk,
          'Pairing Secret (psk)',
          '',
          minLines: 1,
          maxLines: 3,
          errorText: _keyFieldError(_psk.text.trim()),
        ),
        _field(
          _pubKey,
          'Certificate Pin (pubKey)',
          '',
          minLines: 1,
          maxLines: 3,
          errorText: _keyFieldError(_pubKey.text.trim()),
        ),
        _field(
          _directHosts,
          'Direct Hosts',
          '192.168.1.9, 10.0.0.4',
          minLines: 1,
          maxLines: 3,
        ),
      ],
    );
  }

  Widget _reachViaSection() {
    final segments = <ButtonSegment<ServerKind>>[
      // Direct is no longer offered when adding a server. Only surface it while
      // editing a server that is already direct, so its transport still shows
      // (and isn't silently rewritten on save).
      if (_kind == ServerKind.direct)
        const ButtonSegment(
          value: ServerKind.direct,
          icon: Icon(Icons.public, size: 16),
          label: Text('Direct'),
        ),
      if (_supportsSsh)
        const ButtonSegment(
          value: ServerKind.ssh,
          icon: Icon(Icons.key_outlined, size: 16),
          label: Text('SSH'),
        ),
      if (_supportsWsl)
        const ButtonSegment(
          value: ServerKind.wsl,
          icon: Icon(Icons.developer_mode_outlined, size: 16),
          label: Text('WSL'),
        ),
      if (_supportsTailscale)
        const ButtonSegment(
          value: ServerKind.tailscale,
          icon: Icon(Icons.hub_outlined, size: 16),
          label: Text('Tailscale'),
        ),
    ];
    return MotifSection(
      title: 'Reach via',
      footer: 'Choose the network path Motif uses before it talks to motifd.',
      dividerIndent: MotifSpacing.lg,
      children: [
        Padding(
          padding: const EdgeInsets.all(MotifSpacing.sm),
          child: SegmentedButton<ServerKind>(
            showSelectedIcon: false,
            segments: segments,
            selected: {_kind},
            onSelectionChanged: _onKindChanged,
          ),
        ),
      ],
    );
  }

  Widget _sshLoginSection() {
    return MotifSection(
      title: 'SSH login',
      dividerIndent: MotifSpacing.lg,
      children: [
        _sshConfigHostRow(),
        _field(_sshHost, 'SSH Host', 'ssh.example.com'),
        _field(_sshPort, 'SSH Port', '22', keyboard: TextInputType.number),
        _field(_sshUsername, 'Username', 'user'),
      ],
    );
  }

  Widget _sshAuthSection() {
    return MotifSection(
      title: 'SSH auth',
      dividerIndent: MotifSpacing.lg,
      children: [
        Padding(
          padding: const EdgeInsets.all(MotifSpacing.sm),
          child: SegmentedButton<SshAuthMethod>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: SshAuthMethod.password,
                icon: Icon(Icons.password_outlined, size: 16),
                label: Text('Password'),
              ),
              ButtonSegment(
                value: SshAuthMethod.privateKey,
                icon: Icon(Icons.vpn_key_outlined, size: 16),
                label: Text('Private Key'),
              ),
            ],
            selected: {_sshAuthMethod},
            onSelectionChanged: _onSshAuthChanged,
          ),
        ),
        if (_sshAuthMethod == SshAuthMethod.password)
          _field(_sshPassword, 'SSH Password', '', obscure: true)
        else ...[
          _sshIdentityRow(),
          _field(
            _sshPrivateKey,
            'Private Key PEM',
            '-----BEGIN OPENSSH PRIVATE KEY-----',
            minLines: 4,
            maxLines: 8,
          ),
          _field(
            _sshPrivateKeyPassphrase,
            'Key Passphrase (optional)',
            '',
            obscure: true,
          ),
        ],
      ],
    );
  }

  Widget _sshConfigHostRow() {
    return MotifSectionRow(
      leading: const Icon(Icons.list_alt_outlined, size: 18),
      title: 'SSH Config Host',
      subtitle: _sshDiscoveryLoading
          ? 'Scanning ~/.ssh/config'
          : _sshConfigHosts.isEmpty
          ? (_sshDiscoveryMessage ?? 'No Host entries found')
          : 'Choose a saved Host entry',
      trailing: _sshDiscoveryLoading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _sshConfigHosts.isEmpty
          ? IconButton(
              tooltip: 'Refresh SSH config',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => _loadSshDiscovery(force: true),
            )
          : PopupMenuButton<int>(
              style: motifNoButtonFeedback,
              tooltip: 'Choose SSH host',
              icon: const Icon(Icons.arrow_drop_down_circle_outlined),
              onSelected: (index) =>
                  _applySshConfigHost(_sshConfigHosts[index]),
              itemBuilder: (context) => [
                for (var i = 0; i < _sshConfigHosts.length; i++)
                  PopupMenuItem(
                    value: i,
                    child: ListTile(
                      leading: const Icon(Icons.dns_outlined),
                      title: Text(_sshConfigHosts[i].alias),
                      subtitle: Text(_sshHostSummary(_sshConfigHosts[i])),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _sshIdentityRow() {
    final selected = _selectedSshIdentity;
    return MotifSectionRow(
      leading: const Icon(Icons.key_outlined, size: 18),
      title: 'Current Key',
      subtitle: _sshDiscoveryLoading
          ? 'Scanning ~/.ssh'
          : selected?.name ??
                (_sshDiscoveryMessage ?? 'Choose a private key from ~/.ssh'),
      trailing: _sshDiscoveryLoading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _sshIdentities.isEmpty
          ? IconButton(
              tooltip: 'Refresh SSH keys',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: () => _loadSshDiscovery(force: true),
            )
          : PopupMenuButton<int>(
              style: motifNoButtonFeedback,
              tooltip: 'Choose SSH key',
              icon: const Icon(Icons.arrow_drop_down_circle_outlined),
              onSelected: (index) => _applySshIdentity(_sshIdentities[index]),
              itemBuilder: (context) => [
                for (var i = 0; i < _sshIdentities.length; i++)
                  PopupMenuItem(
                    value: i,
                    child: ListTile(
                      leading: const Icon(Icons.vpn_key_outlined),
                      title: Text(_sshIdentities[i].name),
                      subtitle: Text(_sshIdentities[i].path),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
            ),
    );
  }

  String _sshHostSummary(SshConfigHost host) {
    final parts = <String>[host.hostName.isEmpty ? host.alias : host.hostName];
    if (host.user != null && host.user!.isNotEmpty) {
      parts.add(host.user!);
    }
    if (host.port != null) parts.add('${host.port}');
    return parts.join(' / ');
  }

  SshIdentity? _sshIdentityForPath(String? path) {
    if (path == null || path.isEmpty) return null;
    for (final identity in _sshIdentities) {
      if (identity.path == path) return identity;
    }
    return null;
  }

  SshIdentity? get _selectedSshIdentity {
    final key = _sshPrivateKey.text;
    if (key.isEmpty) return null;
    for (final identity in _sshIdentities) {
      if (identity.contents == key) return identity;
    }
    return null;
  }

  Widget _sshMotifdSection() {
    return MotifSection(
      title: 'Remote motifd',
      footer:
          'Uses the latest GitHub Release when the remote binary is missing; existing installs are reused.',
      dividerIndent: MotifSpacing.lg,
      children: [
        MotifSectionRow(
          leading: const Icon(Icons.download_for_offline_outlined, size: 18),
          title: 'Auto initialize',
          subtitle: 'Install and start motifd over SSH when needed.',
          trailing: Switch(
            value: _sshAutoInitialize,
            onChanged: (value) => setState(() => _sshAutoInitialize = value),
          ),
          onTap: () => setState(() => _sshAutoInitialize = !_sshAutoInitialize),
        ),
      ],
    );
  }

  Widget _wslSection() {
    return MotifSection(
      title: 'WSL',
      footer:
          'Motif runs the same bootstrap used for SSH: it installs the latest '
          'Linux motifd release when missing and reuses an existing process.',
      dividerIndent: MotifSpacing.lg,
      children: [
        _field(
          _wslDistribution,
          'Distribution (optional)',
          'Default WSL distribution',
        ),
        const MotifSectionRow(
          leading: Icon(Icons.download_for_offline_outlined, size: 18),
          title: 'Auto initialize',
          subtitle: 'Install and start motifd inside WSL when needed.',
          trailing: Icon(Icons.check_circle_outline, size: 18),
        ),
      ],
    );
  }

  Widget _motifdAddressSection() {
    final isSsh = _kind == ServerKind.ssh;
    final isWsl = _kind == ServerKind.wsl;
    return MotifSection(
      title: isSsh
          ? 'motifd target'
          : (isWsl ? 'WSL motifd' : 'motifd address'),
      footer: isSsh
          ? 'Host and port as seen from the SSH server. Use 127.0.0.1 when motifd only listens locally on that machine.'
          : (isWsl
                ? 'Windows connects to this port through WSL localhost forwarding.'
                : null),
      dividerIndent: MotifSpacing.lg,
      children: [
        if (!isWsl)
          _field(
            _host,
            isSsh ? 'Remote Host' : 'Host',
            isSsh ? '127.0.0.1' : 'hostname or IP',
          ),
        _field(
          _port,
          isSsh ? 'Remote Port' : (isWsl ? 'WSL Port' : 'Port'),
          '7777',
          keyboard: TextInputType.number,
          onChanged: () {
            if (_discovered.isNotEmpty) {
              Future.microtask(_refreshVisiblePeerPings);
            }
          },
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
    int? minLines,
    int? maxLines,
    String? errorText,
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
        minLines: obscure ? 1 : minLines,
        maxLines: obscure ? 1 : maxLines ?? 1,
        autocorrect: false,
        enableSuggestions: false,
        onChanged: (_) {
          setState(() {});
          onChanged?.call();
        },
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          errorText: errorText,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          errorBorder: InputBorder.none,
          focusedErrorBorder: InputBorder.none,
          isDense: true,
        ),
      ),
    );
  }

  Widget _discoverySection(BuildContext context) {
    final svc = readObservationScope<AppState>(context).platform.tailscale;
    final state = svc.state;
    final ready = state.status == TailscaleStatus.running;
    final peers = _visiblePeers;
    return MotifSection(
      title: 'Discovered on tailnet',
      headerTrailing: ready ? _discoveryHeaderActions() : null,
      footer: ready
          ? (widget.connectOnSave
                ? 'Choose a reachable peer, then connect.'
                : 'Tap a peer to fill in the address.')
          : 'Set up Tailscale to discover and prefill tailnet hosts.',
      children: [
        if (!ready)
          _TailscaleSetupMessageRow(
            state: state,
            onSetup: () => unawaited(_openTailscaleSetup(svc)),
          )
        else if (_discoveryLoading)
          const _DiscoveryMessageRow(
            message: 'Scanning tailnet…',
            loading: true,
          )
        else if (_discoveryMessage != null)
          _DiscoveryMessageRow(message: _discoveryMessage!)
        else if (_discovered.isEmpty)
          const _DiscoveryMessageRow(
            message: 'No peers visible on the tailnet.',
          )
        else if (peers.isEmpty)
          const _DiscoveryMessageRow(
            message:
                'No motifd-named peers. Use Show all to pick a renamed host.',
          )
        else
          for (final peer in peers)
            _DiscoveredPeerRow(
              peer: peer,
              ping: _peerPing[peer.id],
              checking: _checkingPeers.contains(peer.id),
              selected: peer.id == _selectedPeerId,
              onTap: () => _applyDiscoveredPeer(peer),
            ),
      ],
    );
  }

  Widget _discoveryHeaderActions() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          onPressed: () {
            setState(() => _showAllPeers = !_showAllPeers);
            Future.microtask(_refreshVisiblePeerPings);
          },
          icon: Icon(
            _showAllPeers ? Icons.check_box : Icons.check_box_outline_blank,
            size: 17,
          ),
          label: const Text('Show all'),
        ),
        IconButton(
          icon: const Icon(Icons.refresh, size: 18),
          tooltip: 'Refresh peers',
          onPressed: _discoveryLoading ? null : _loadDiscovery,
        ),
      ],
    );
  }
}

class _TailscaleSetupMessageRow extends StatelessWidget {
  final TailscaleState state;
  final VoidCallback onSetup;

  const _TailscaleSetupMessageRow({required this.state, required this.onSetup});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final title = switch (state.status) {
      TailscaleStatus.stopped => 'Tailscale is not connected',
      TailscaleStatus.starting => 'Tailscale is starting',
      TailscaleStatus.needsAuth => 'Tailscale needs login',
      TailscaleStatus.running => 'Tailscale connected',
      TailscaleStatus.degraded => 'Tailscale is reconnecting',
      TailscaleStatus.failed => 'Tailscale failed',
    };
    final subtitle =
        state.detail ??
        switch (state.status) {
          TailscaleStatus.stopped =>
            'Sign in before scanning for tailnet servers.',
          TailscaleStatus.starting =>
            'Waiting for the embedded Tailscale service.',
          TailscaleStatus.needsAuth => 'Finish signing in to continue.',
          TailscaleStatus.running => 'Ready to scan the tailnet.',
          TailscaleStatus.degraded =>
            'Open setup to inspect the current Tailscale state.',
          TailscaleStatus.failed => 'Open setup to retry sign-in.',
        };
    final actionLabel = switch (state.status) {
      TailscaleStatus.needsAuth => 'Sign in',
      TailscaleStatus.starting => 'Open',
      TailscaleStatus.failed => 'Retry',
      _ => 'Setup',
    };
    return MotifSectionRow(
      leading: state.status == TailscaleStatus.starting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.shield_outlined, color: c.warning),
      title: title,
      subtitle: subtitle,
      titleWeight: FontWeight.w600,
      trailing: OutlinedButton(
        key: const ValueKey('tailscale-setup-from-server-edit'),
        onPressed: onSetup,
        child: Text(actionLabel),
      ),
      minHeight: 68,
    );
  }
}

class _DiscoveryMessageRow extends StatelessWidget {
  final String message;
  final bool loading;

  const _DiscoveryMessageRow({required this.message, this.loading = false});

  @override
  Widget build(BuildContext context) {
    return MotifSectionRow(
      leading: loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(Icons.info_outline, color: context.motif.textSecondary),
      title: message,
      titleColor: context.motif.textSecondary,
      titleWeight: FontWeight.w400,
      minHeight: 52,
    );
  }
}

class _DiscoveredPeerRow extends StatelessWidget {
  final TailscalePeer peer;
  final TailscalePingResult? ping;
  final bool checking;
  final bool selected;
  final VoidCallback onTap;

  const _DiscoveredPeerRow({
    required this.peer,
    required this.ping,
    required this.checking,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    return MotifSectionRow(
      leading: Icon(
        peer.isLikelyMotifd ? Icons.terminal : Icons.computer,
        color: peer.isLikelyMotifd ? c.accent : c.textSecondary,
      ),
      title: peer.hostname,
      subtitle: peer.preferredAddress,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _PingBadge(ping: ping, checking: checking),
          const SizedBox(width: MotifSpacing.sm),
          Icon(
            selected ? Icons.check_circle : Icons.chevron_right,
            color: selected ? c.success : c.textTertiary,
            size: selected ? 18 : 20,
          ),
        ],
      ),
      titleWeight: peer.isLikelyMotifd ? FontWeight.w700 : FontWeight.w500,
      titleColor: peer.isOnline ? c.textPrimary : c.textSecondary,
      onTap: onTap,
      leadingWidth: 30,
    );
  }
}

class _PingBadge extends StatelessWidget {
  final TailscalePingResult? ping;
  final bool checking;

  const _PingBadge({required this.ping, required this.checking});

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    if (checking || ping == null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 4),
          Text(
            'Checking',
            style: MotifType.caption.copyWith(color: c.textSecondary),
          ),
        ],
      );
    }
    final reachable = ping!.reachable;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          reachable ? Icons.check_circle : Icons.cancel,
          size: 14,
          color: reachable ? c.success : c.danger,
        ),
        const SizedBox(width: 4),
        Text(
          reachable ? 'Reachable' : ping!.message,
          style: MotifType.caption.copyWith(
            color: reachable ? c.success : c.danger,
          ),
        ),
      ],
    );
  }
}

class ServerEditResult {
  final MotifServer server;
  final bool connectAfterSave;

  const ServerEditResult({
    required this.server,
    required this.connectAfterSave,
  });
}

Future<ServerEditResult?> showServerEditSheet(
  BuildContext context, {
  MotifServer? existing,
  ServerKind? initialKind,
  bool connectOnSave = false,
}) {
  return showAdaptivePanel<ServerEditResult>(
    context,
    builder: (_) => ServerEditSheet(
      existing: existing,
      initialKind: initialKind,
      connectOnSave: connectOnSave,
    ),
  );
}
