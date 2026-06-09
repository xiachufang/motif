import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/settings.dart';
import '../../platform/services.dart';
import '../../state/app_state.dart';
import '../theme/motif_theme.dart';
import '../widgets/adaptive_modal.dart';
import '../widgets/motif_form.dart';

/// Add or edit a server. Returns once saved/cancelled.
class ServerEditSheet extends StatefulWidget {
  final MotifServer? existing;
  final bool connectOnSave;
  const ServerEditSheet({super.key, this.existing, this.connectOnSave = false});

  @override
  State<ServerEditSheet> createState() => _ServerEditSheetState();
}

class _ServerEditSheetState extends State<ServerEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _port;
  late final TextEditingController _token;
  late ServerKind _kind;
  List<TailscalePeer> _discovered = const [];
  final Map<String, TailscalePingResult> _peerPing = {};
  final Set<String> _checkingPeers = {};
  bool _discoveryStarted = false;
  bool _discoveryLoading = false;
  bool _showAllPeers = false;
  bool _saving = false;
  bool _savingConnect = false;
  String? _selectedPeerId;
  String? _discoveryMessage;
  int _discoveryGeneration = 0;

  bool get _supportsTailscale => !kIsWeb;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: '${e?.port ?? 7777}');
    _token = TextEditingController(text: e?.token ?? '');
    _kind = _supportsTailscale
        ? (e?.kind ?? ServerKind.tailscale)
        : ServerKind.direct;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _host.text.trim().isNotEmpty &&
      int.tryParse(_port.text.trim()) != null;

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
    final store = context.read<AppState>().servers;
    final id =
        widget.existing?.id ?? 'srv-${DateTime.now().microsecondsSinceEpoch}';
    final server = MotifServer(
      id: id,
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      token: _token.text,
      kind: _kind,
    );
    if (widget.existing == null) {
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

  Future<void> _loadDiscovery() async {
    final generation = ++_discoveryGeneration;
    final svc = context.read<AppState>().platform.tailscale;
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
        _discoveryMessage = 'Connect Tailscale first to scan the tailnet.';
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
    final svc = context.read<AppState>().platform.tailscale;
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

  void _onKindChanged(Set<ServerKind> selected) {
    if (!_supportsTailscale) return;
    setState(() => _kind = selected.first);
    if (_isNew && _kind == ServerKind.tailscale) {
      _discoveryStarted = true;
      Future.microtask(_loadDiscovery);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.motif;
    final title = widget.existing == null
        ? (widget.connectOnSave ? 'Connect Server' : 'Add Server')
        : 'Edit Server';
    return SafeArea(
      top: false,
      child: Column(
        children: [
          AdaptiveModalHeader(
            title: title,
            actions: [
              TextButton(
                onPressed: _valid && !_saving
                    ? () => _save(connectAfterSave: widget.connectOnSave)
                    : null,
                child: Text(_primaryActionLabel),
              ),
            ],
          ),
          if (widget.connectOnSave) ...[
            Material(
              color: c.background,
              child: InkWell(
                key: const ValueKey('save-without-connecting'),
                onTap: _valid && !_saving
                    ? () => _save(connectAfterSave: false)
                    : null,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: MotifSpacing.lg,
                    vertical: MotifSpacing.sm,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Icon(
                        Icons.save_outlined,
                        color: _valid && !_saving
                            ? c.textSecondary
                            : c.textTertiary,
                        size: 16,
                      ),
                      const SizedBox(width: MotifSpacing.xs),
                      Text(
                        'Save without connecting',
                        style: TextStyle(
                          color: _valid && !_saving
                              ? c.textSecondary
                              : c.textTertiary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: c.border),
          ],
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                MotifSpacing.lg,
                MotifSpacing.md,
                MotifSpacing.lg,
                MediaQuery.of(context).viewInsets.bottom + MotifSpacing.xl,
              ),
              children: [
                if (_supportsTailscale) ...[
                  MotifSection(
                    title: 'Reach via',
                    dividerIndent: MotifSpacing.lg,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(MotifSpacing.sm),
                        child: SegmentedButton<ServerKind>(
                          segments: const [
                            ButtonSegment(
                              value: ServerKind.direct,
                              label: Text('Direct'),
                            ),
                            ButtonSegment(
                              value: ServerKind.tailscale,
                              label: Text('Tailscale'),
                            ),
                          ],
                          selected: {_kind},
                          onSelectionChanged: _onKindChanged,
                        ),
                      ),
                    ],
                  ),
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
                MotifSection(
                  title: 'motifd address',
                  dividerIndent: MotifSpacing.lg,
                  children: [
                    _field(_host, 'Host', 'hostname or IP'),
                    _field(
                      _port,
                      'Port',
                      '7777',
                      keyboard: TextInputType.number,
                      onChanged: () {
                        if (_discovered.isNotEmpty) {
                          Future.microtask(_refreshVisiblePeerPings);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: MotifSpacing.xl),
                MotifSection(
                  title: 'Token',
                  footer:
                      'Required only if motifd was started with a non-empty token. Leave blank for an unauthenticated server.',
                  dividerIndent: MotifSpacing.lg,
                  children: [
                    _field(_token, 'Token (optional)', '', obscure: true),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
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
        onChanged: (_) {
          setState(() {});
          onChanged?.call();
        },
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
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
    final peers = _visiblePeers;
    return MotifSection(
      title: 'Discovered on tailnet',
      headerTrailing: Row(
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
      ),
      footer: widget.connectOnSave
          ? 'Choose a reachable peer, then connect. Token still has to be entered manually.'
          : 'Tap a peer to fill in the address. Token still has to be entered manually.',
      children: [
        if (_discoveryLoading)
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
            style: TextStyle(color: c.textSecondary, fontSize: 12),
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
          style: TextStyle(
            color: reachable ? c.success : c.danger,
            fontSize: 12,
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
  bool connectOnSave = false,
}) {
  return showAdaptivePanel<ServerEditResult>(
    context,
    builder: (_) =>
        ServerEditSheet(existing: existing, connectOnSave: connectOnSave),
  );
}
