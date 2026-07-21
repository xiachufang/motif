/// A real [TailscaleService] backed by `libtailscale` (tsnet) over FFI.
///
/// Brings up a tsnet node and starts the loopback SOCKS5/HTTP proxy; the proxy
/// address + credential are exposed so the RPC transport can route through the
/// tailnet (see `net/tailscale_proxy.dart`). Headless auth uses an auth key;
/// interactive auth starts the tsnet LocalAPI and surfaces the web sign-in URL.
///
/// `tailscale_up` blocks until the node is usable, so it runs on a worker
/// isolate — the Go runtime + handle are process-global, so the same `int`
/// handle is valid across isolates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;

import '../log/log.dart';
import '../models/motif_proto.dart';
import '../net/proxy_client.dart';
import '../state/platform/tailscale_runtime_controller.dart';
import '../state/runtime/runtime_effect.dart';
import 'services.dart';
import 'tailscale_ffi.dart';

class TailscaleNativeService extends TailscaleService {
  static const _logName = 'motif.tailscale';
  static const _healthProbeInterval = Duration(seconds: 5);
  static const _healthProbeTimeout = Duration(seconds: 2);
  static const _maxMissedHealthProbes = 2;
  static const _maxConsecutiveDegradedProbes = 4;
  static const _autoRestartMinInterval = Duration(minutes: 2);

  final String dylibPath;
  final String stateDir;
  final String hostname;
  final String? controlUrl;

  TailscaleNativeService({
    required this.dylibPath,
    required this.stateDir,
    this.hostname = 'motif-flutter',
    this.controlUrl,
  }) {
    _runtime = TailscaleRuntimeController(
      startNode: _startNativeNode,
      stopNode: _stopNativeNode,
      probeHealth: _probeNativeHealth,
      restartAuthKey: () => _lastAuthKey,
      onStateChanged: _applyRuntimeState,
      healthProbeInterval: _healthProbeInterval,
      maxMissedHealthProbes: _maxMissedHealthProbes,
      maxConsecutiveDegradedProbes: _maxConsecutiveDegradedProbes,
      autoRestartMinInterval: _autoRestartMinInterval,
    );
  }

  LibTailscale? _lib;
  int? _sd;
  TailscaleLoopback? _loopback;
  String? _lastAuthKey;
  late final TailscaleRuntimeController _runtime;

  @override
  TailscaleRuntimeState get runtimeState => _runtime.state;

  /// The active loopback proxy (host:port + credential), or null when not up.
  TailscaleLoopback? get proxy => _loopback;

  LibTailscale _openLib() => LibTailscale.open(dylibPath);

  @override
  ProxySettings? get loopbackProxy {
    if (state.status != TailscaleStatus.running &&
        state.status != TailscaleStatus.degraded) {
      return null;
    }
    final lb = _loopback;
    if (lb == null) return null;
    final parts = lb.proxyAddr.split(':');
    if (parts.length != 2) return null;
    return ProxySettings(
      proxyHost: parts[0],
      proxyPort: int.tryParse(parts[1]),
      username: 'tsnet', // tsnet loopback SOCKS5 requires user "tsnet"...
      password: lb.proxyCred, // ...with the loopback credential as the password
    );
  }

  void _applyRuntimeState(TailscaleRuntimeState runtime) {
    final previousRuntime = viewModel.runtime;
    final previous = state;
    final next = runtime.visibleState;
    if (previous != next) {
      Log.i(
        'state ${previous.status.name} -> ${next.status.name}'
        '${next.detail == null ? '' : ' (${next.detail})'}',
        name: _logName,
      );
    }
    final previousHealth = previousRuntime.health;
    final nextHealth = runtime.health;
    if (nextHealth is TailscaleHealthMonitoring) {
      if (nextHealth.missedProbes > 0 &&
          (previousHealth is! TailscaleHealthMonitoring ||
              previousHealth.missedProbes != nextHealth.missedProbes)) {
        Log.w(
          'health probe missed (${nextHealth.missedProbes})',
          name: _logName,
        );
      }
      if (nextHealth.lastBackendState != null &&
          (previousHealth is! TailscaleHealthMonitoring ||
              previousHealth.lastBackendState != nextHealth.lastBackendState)) {
        Log.i(
          'health backendState=${nextHealth.lastBackendState}',
          name: _logName,
        );
      }
    }
    if (runtime.lifecycle is TailscaleLifecycleRestarting &&
        previousRuntime.lifecycle is! TailscaleLifecycleRestarting) {
      Log.w(
        'degraded for $_maxConsecutiveDegradedProbes consecutive probes; '
        'restarting tsnet node',
        name: _logName,
      );
    }
    viewModel.applyRuntime(runtime);
  }

  @override
  Future<void> start({String? authKey}) {
    final hasAuthKey = authKey != null && authKey.isNotEmpty;
    if (hasAuthKey) _lastAuthKey = authKey;
    return _runtime.start(authKey: authKey);
  }

  Future<TailscaleState> _startNativeNode(
    String? authKey,
    RuntimeEffectContext context,
    TailscaleProgressSink onProgress,
  ) async {
    final hasAuthKey = authKey != null && authKey.isNotEmpty;
    Log.i('start hasAuthKey=$hasAuthKey stateDir=$stateDir', name: _logName);
    try {
      if (_sd != null) {
        Log.i('closing stale node before start', name: _logName);
        _closeNativeNode();
      }
      if (!context.isCurrent) return TailscaleState.stopped;
      final lib = _openLib();
      final sd = lib.create();
      if (sd < 0) {
        Log.e('tailscale_new failed sd=$sd', name: _logName);
        return const TailscaleState(
          TailscaleStatus.failed,
          detail: 'tailscale_new failed',
        );
      }
      Directory(stateDir).createSync(recursive: true);
      lib.setDir(sd, stateDir);
      lib.setHostname(sd, hostname);
      if (controlUrl != null) lib.setControlUrl(sd, controlUrl!);
      if (hasAuthKey) lib.setAuthkey(sd, authKey);
      _lib = lib;
      _sd = sd;

      if (hasAuthKey) {
        return await _startWithAuthKey(lib, sd, context);
      }
      return await _startWithBrowserAuth(lib, sd, context, onProgress);
    } catch (e, st) {
      Log.e('start failed', name: _logName, error: e, stackTrace: st);
      rethrow;
    }
  }

  Future<TailscaleState> _startWithAuthKey(
    LibTailscale lib,
    int sd,
    RuntimeEffectContext context,
  ) async {
    final rc = await _runUp(sd);
    if (!context.isCurrent) return TailscaleState.stopped;
    final failure = _upFailure(lib, sd, rc);
    if (failure != null) {
      return TailscaleState(TailscaleStatus.failed, detail: failure);
    }
    return _ensureLoopback(lib, sd, context);
  }

  Future<TailscaleState> _startWithBrowserAuth(
    LibTailscale lib,
    int sd,
    RuntimeEffectContext context,
    TailscaleProgressSink onProgress,
  ) async {
    final lb = lib.loopback(sd);
    if (lb == null) {
      final detail = _detail(lib, sd, 'loopback proxy failed');
      Log.e('loopback proxy failed: $detail', name: _logName);
      return TailscaleState(TailscaleStatus.degraded, detail: detail);
    }
    Log.i('loopback proxy at ${lb.proxyAddr}', name: _logName);
    _loopback = lb;
    final api = TailscaleLocalApiClient(loopback: lb);
    final upFuture = _runUp(
      sd,
    ).then<Object?>((rc) => rc, onError: (Object error) => error);
    final cancelled = Object();
    String? authUrl;
    String? lastBackend;
    try {
      while (context.isCurrent) {
        final local = await api.status().timeout(
          const Duration(seconds: 2),
          onTimeout: () => null,
        );
        if (!context.isCurrent) return TailscaleState.stopped;
        if (local != null) {
          if (local.backendState != lastBackend) {
            lastBackend = local.backendState;
            Log.i(
              'login backendState=$lastBackend hasAuthUrl=${local.authUrl != null}',
              name: _logName,
            );
          }
          authUrl = local.authUrl ?? authUrl;
          onProgress(local.toState(fallbackAuthUrl: authUrl));
        } else if (authUrl == null) {
          onProgress(
            const TailscaleState(
              TailscaleStatus.starting,
              detail: 'Waiting for Tailscale login URL…',
            ),
          );
        }

        final upResult = await Future.any<Object?>([
          upFuture,
          context
              .delay(const Duration(seconds: 2))
              .then<Object?>((elapsed) => elapsed ? null : cancelled),
        ]);
        if (identical(upResult, cancelled)) return TailscaleState.stopped;
        if (upResult == null) continue;
        if (!context.isCurrent) return TailscaleState.stopped;
        if (upResult is! int) throw upResult;
        final failure = _upFailure(lib, sd, upResult);
        if (failure != null) {
          return TailscaleState(TailscaleStatus.failed, detail: failure);
        }
        return const TailscaleState(TailscaleStatus.running);
      }
      return TailscaleState.stopped;
    } finally {
      api.close();
    }
  }

  Future<int> _runUp(int sd) {
    final path = dylibPath;
    return Isolate.run(() {
      // Re-open in the worker isolate; the Go runtime/handle is process-global.
      final l = LibTailscale.open(path);
      return l.up(sd);
    });
  }

  String? _upFailure(LibTailscale lib, int sd, int rc) {
    if (rc == 0) {
      Log.i('tailscale_up ok', name: _logName);
      return null;
    }
    final detail = _detail(lib, sd, 'tailscale_up rc=$rc');
    Log.e('tailscale_up failed rc=$rc detail=$detail', name: _logName);
    return detail;
  }

  TailscaleState _ensureLoopback(
    LibTailscale lib,
    int sd,
    RuntimeEffectContext context,
  ) {
    final lb = lib.loopback(sd);
    if (!context.isCurrent) return TailscaleState.stopped;
    if (lb == null) {
      final detail = _detail(lib, sd, 'loopback proxy failed');
      Log.e('loopback proxy failed: $detail', name: _logName);
      return TailscaleState(TailscaleStatus.degraded, detail: detail);
    }
    Log.i('loopback proxy at ${lb.proxyAddr}', name: _logName);
    _loopback = lb;
    return const TailscaleState(TailscaleStatus.running);
  }

  Future<TailscaleHealthSample?> _probeNativeHealth(
    RuntimeEffectContext context,
  ) async {
    final loopback = _loopback;
    if (loopback == null || !context.isCurrent) return null;
    final api = TailscaleLocalApiClient(loopback: loopback);
    try {
      final local = await api.status().timeout(
        _healthProbeTimeout,
        onTimeout: () => null,
      );
      if (!context.isCurrent || local == null) return null;
      return TailscaleHealthSample(
        state: local.toHealthState(),
        backendState: local.backendState,
      );
    } finally {
      api.close();
    }
  }

  String _detail(LibTailscale lib, int sd, String fallback) {
    final msg = lib.errmsg(sd).trim();
    return msg.isEmpty ? fallback : msg;
  }

  @override
  Future<void> stop() => _runtime.stop();

  Future<void> _stopNativeNode(RuntimeEffectContext context) async {
    Log.i('stop native node (was ${state.status.name})', name: _logName);
    _closeNativeNode();
  }

  void _closeNativeNode() {
    final lib = _lib, sd = _sd;
    if (lib != null && sd != null) {
      try {
        lib.close(sd);
      } catch (_) {}
    }
    _lib = null;
    _sd = null;
    _loopback = null;
  }

  @override
  Future<String> resolveHost(String host) async {
    if (_looksLikeIP(host)) return host;
    final normalized = _trimTrailingDot(host).toLowerCase();
    final peers = await discoverPeers();
    for (final peer in peers) {
      final dns = _trimTrailingDot(peer.dnsName).toLowerCase();
      final shortName = peer.hostname.toLowerCase();
      if (dns == normalized ||
          dns.startsWith('$normalized.') ||
          shortName == normalized) {
        return peer.primaryIP ?? peer.preferredAddress;
      }
    }
    return host;
  }

  @override
  Future<List<TailscalePeer>> discoverPeers() async {
    final lb = _loopback;
    if (lb == null || state.status != TailscaleStatus.running) return const [];
    final api = TailscaleLocalApiClient(loopback: lb);
    try {
      final status = await api.status(peers: true);
      final peers = status?.peers ?? const <TailscalePeer>[];
      return [...peers]..sort(compareDiscoveredPeers);
    } finally {
      api.close();
    }
  }

  @override
  Future<TailscalePingResult> pingMotifServer({
    required String host,
    required int port,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (state.status != TailscaleStatus.running) {
      return const TailscalePingResult.unreachable('Tailscale off');
    }
    final proxy = loopbackProxy;
    if (proxy == null || !proxy.isActive) {
      return const TailscalePingResult.unreachable('Tailscale off');
    }

    final resolvedHost = await resolveHost(host);
    final client = makeHttpClient(proxy);
    try {
      final uri = Uri(
        scheme: 'http',
        host: resolvedHost,
        port: port,
        path: '/ping',
      );
      final response = await client.get(uri).timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return TailscalePingResult.unreachable('HTTP ${response.statusCode}');
      }
      final json = jsonDecode(response.body);
      if (json is! Map) {
        return const TailscalePingResult.unreachable('Not motifd');
      }
      final info = PingInfo.fromJson(json.cast<String, Object?>());
      if (!info.isMotifServer) {
        return const TailscalePingResult.unreachable('Not motifd');
      }
      return TailscalePingResult.reachable(info.version);
    } on TimeoutException {
      return const TailscalePingResult.unreachable('No response');
    } on SocketException catch (e) {
      return TailscalePingResult.unreachable(_socketFailureMessage(e));
    } catch (_) {
      return const TailscalePingResult.unreachable('Ping failed');
    } finally {
      client.close();
    }
  }

  static bool _looksLikeIP(String host) {
    if (host.contains(':')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    return parts.every(
      (part) => int.tryParse(part)?.clamp(0, 255).toString() == part,
    );
  }

  static String _trimTrailingDot(String value) =>
      value.endsWith('.') ? value.substring(0, value.length - 1) : value;

  static int compareDiscoveredPeers(TailscalePeer a, TailscalePeer b) {
    if (a.isOnline != b.isOnline) return a.isOnline ? -1 : 1;
    if (a.isLikelyMotifd != b.isLikelyMotifd) {
      return a.isLikelyMotifd ? -1 : 1;
    }
    return a.hostname.toLowerCase().compareTo(b.hostname.toLowerCase());
  }

  static String _socketFailureMessage(SocketException e) {
    final message = e.message.toLowerCase();
    if (message.contains('failed host lookup')) return 'Host not found';
    if (message.contains('connection refused')) return 'Port closed';
    return 'Ping failed';
  }

  @override
  void dispose() {
    _runtime.dispose();
    _closeNativeNode();
  }
}

class TailscaleLocalApiClient {
  final TailscaleLoopback loopback;
  final http.Client _http;

  TailscaleLocalApiClient({required this.loopback, http.Client? httpClient})
    : _http = httpClient ?? http.Client();

  Future<TailscaleLocalStatus?> status({bool peers = false}) async {
    try {
      final response = await _http.get(
        Uri.parse(
          'http://${loopback.proxyAddr}/localapi/v0/status',
        ).replace(queryParameters: peers ? null : const {'peers': 'false'}),
        headers: {
          'Authorization':
              'Basic ${base64Encode(utf8.encode(':${loopback.localApiCred}'))}',
          'Sec-Tailscale': 'localapi',
        },
      );
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      if (json is! Map) return null;
      return TailscaleLocalStatus.fromJson(json.cast<String, Object?>());
    } catch (_) {
      return null;
    }
  }

  void close() => _http.close();
}

class TailscaleLocalStatus {
  final String? backendState;
  final String? authUrl;
  final List<TailscalePeer> peers;

  const TailscaleLocalStatus({
    this.backendState,
    this.authUrl,
    this.peers = const [],
  });

  factory TailscaleLocalStatus.fromJson(Map<String, Object?> json) {
    final authUrl = json['AuthURL'] as String?;
    final peers = <TailscalePeer>[
      if (json['Self'] is Map)
        _peerFromJson((json['Self'] as Map).cast<String, Object?>()),
      if (json['SelfStatus'] is Map)
        _peerFromJson((json['SelfStatus'] as Map).cast<String, Object?>()),
      if (json['Peer'] is Map)
        for (final value in (json['Peer'] as Map).values)
          if (value is Map) _peerFromJson(value.cast<String, Object?>()),
    ];
    return TailscaleLocalStatus(
      backendState: json['BackendState'] as String?,
      authUrl: authUrl == null || authUrl.isEmpty ? null : authUrl,
      peers: peers,
    );
  }

  TailscaleState toState({String? fallbackAuthUrl}) {
    final url = authUrl ?? fallbackAuthUrl;
    return switch (backendState) {
      'Running' => const TailscaleState(
        TailscaleStatus.starting,
        detail: 'Finalizing Tailscale session…',
      ),
      'NeedsLogin' => TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: url,
        detail: url == null
            ? 'Waiting for Tailscale login URL…'
            : 'Open the Tailscale login URL to continue.',
      ),
      'NeedsMachineAuth' => TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: url,
        detail: 'Waiting for tailnet admin approval.',
      ),
      'Stopped' => const TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale stopped while signing in.',
      ),
      'Starting' || 'NoState' || null => const TailscaleState(
        TailscaleStatus.starting,
        detail: 'Waiting for Tailscale login URL…',
      ),
      _ => TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale state: $backendState',
      ),
    };
  }

  TailscaleState toHealthState() {
    return switch (backendState) {
      'Running' => const TailscaleState(TailscaleStatus.running),
      'NeedsLogin' => TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: authUrl,
        detail: authUrl == null
            ? 'Tailscale login is required.'
            : 'Open the Tailscale login URL to continue.',
      ),
      'NeedsMachineAuth' => TailscaleState(
        TailscaleStatus.needsAuth,
        authUrl: authUrl,
        detail: 'Waiting for tailnet admin approval.',
      ),
      'Stopped' => const TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale disconnected.',
      ),
      'Starting' || 'NoState' || null => const TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale reconnecting…',
      ),
      _ => TailscaleState(
        TailscaleStatus.degraded,
        detail: 'Tailscale state: $backendState',
      ),
    };
  }

  static TailscalePeer _peerFromJson(Map<String, Object?> json) {
    final hostname = (json['HostName'] as String?) ?? '';
    final dnsName = (json['DNSName'] as String?) ?? '';
    final ips = ((json['TailscaleIPs'] as List?) ?? const [])
        .whereType<String>()
        .toList();
    final primaryIP = ips.firstWhere(
      (ip) => ip.contains('.'),
      orElse: () => ips.isEmpty ? '' : ips.first,
    );
    final lower = hostname.toLowerCase();
    return TailscalePeer(
      hostname: hostname,
      dnsName: dnsName,
      primaryIP: primaryIP.isEmpty ? null : primaryIP,
      isLikelyMotifd: lower == 'motifd' || lower.startsWith('motifd-'),
      isOnline: (json['Online'] as bool?) ?? false,
    );
  }
}
