import 'dart:async';

import 'package:flutter_observation/flutter_observation.dart';

import '../../../net/remote_port_forwarder.dart';
import 'remote_port_mapping.dart';
import 'remote_ports_view_model.dart';

typedef RemotePortRpcCall =
    Future<Map<String, Object?>> Function(
      String method, [
      Map<String, Object?> params,
    ]);
typedef RequireRemotePortAttachment = void Function();
typedef RemotePortForwarderFactory =
    Future<RemotePortForwarder> Function({
      required String remoteHost,
      required int remotePort,
      int? localPort,
      required String localScheme,
    });

/// Narrow transport boundary required by [RemotePortController].
final class RemotePortTransport {
  const RemotePortTransport({
    required this.call,
    required this.requireAttachment,
    required this.startForwarder,
  });

  final RemotePortRpcCall call;
  final RequireRemotePortAttachment requireAttachment;
  final RemotePortForwarderFactory startForwarder;
}

final class _RemotePortMappingConfig {
  const _RemotePortMappingConfig({
    required this.id,
    required this.remoteHost,
    required this.remotePort,
    required this.localScheme,
    required this.createdAt,
  });

  final String id;
  final String remoteHost;
  final int remotePort;
  final String localScheme;
  final DateTime createdAt;

  factory _RemotePortMappingConfig.fromJson(Map<String, Object?> json) {
    final createdAtMs = (json['created_at'] as num?)?.toInt();
    return _RemotePortMappingConfig(
      id: json['id'] as String,
      remoteHost: (json['remote_host'] as String?) ?? '127.0.0.1',
      remotePort: (json['remote_port'] as num).toInt(),
      localScheme: (json['local_scheme'] as String?) ?? 'http',
      createdAt: createdAtMs == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(createdAtMs),
    );
  }
}

/// Owns remote-port commands and every live local forwarder for one workspace.
///
/// The injected callbacks are its only dependency on the attachment/transport
/// layer. Neither the ViewModel nor [RemotePortMapping] retains network
/// resources.
final class RemotePortController {
  RemotePortController({
    required this.transport,
    RemotePortsViewModel? viewModel,
  }) : viewModel =
           viewModel ??
           RemotePortsViewModel(mappings: ObservableList<RemotePortMapping>());

  final RemotePortsViewModel viewModel;
  final RemotePortTransport transport;
  final Map<String, RemotePortForwarder> _forwarders = {};

  Future<List<RemotePortMapping>> refresh() async {
    transport.requireAttachment();
    viewModel
      ..phase = RemotePortsPhase.loading
      ..error = null;
    try {
      final body = await transport.call('remote_port.list');
      final configs = ((body['mappings'] as List?) ?? [])
          .map(
            (mapping) => _RemotePortMappingConfig.fromJson(
              (mapping as Map).cast<String, Object?>(),
            ),
          )
          .toList();
      await _reconcile(configs);
      viewModel.phase = RemotePortsPhase.ready;
      return List.unmodifiable(viewModel.mappings);
    } catch (error) {
      viewModel
        ..phase = RemotePortsPhase.failed
        ..error = '$error';
      rethrow;
    }
  }

  Future<RemotePortMapping> add({
    String remoteHost = '127.0.0.1',
    required int remotePort,
    String localScheme = 'http',
  }) async {
    final body = await transport.call('remote_port.add', {
      'remote_host': remoteHost,
      'remote_port': remotePort,
      'local_scheme': localScheme,
    });
    final config = _RemotePortMappingConfig.fromJson(
      ((body['mapping'] as Map?) ?? const {}).cast<String, Object?>(),
    );
    final started = await _start(config);
    _upsert(started);
    viewModel
      ..phase = RemotePortsPhase.ready
      ..error = null;
    return started.mapping;
  }

  Future<RemotePortMapping> update(
    String id, {
    String remoteHost = '127.0.0.1',
    required int remotePort,
    String localScheme = 'http',
  }) async {
    final body = await transport.call('remote_port.update', {
      'id': id,
      'remote_host': remoteHost,
      'remote_port': remotePort,
      'local_scheme': localScheme,
    });
    final config = _RemotePortMappingConfig.fromJson(
      ((body['mapping'] as Map?) ?? const {}).cast<String, Object?>(),
    );
    final existing = viewModel.mappings
        .where((mapping) => mapping.id == id)
        .firstOrNull;
    if (existing != null && _matchesConfig(existing, config)) return existing;

    final started = await _start(config);
    _upsert(started);
    viewModel
      ..phase = RemotePortsPhase.ready
      ..error = null;
    return started.mapping;
  }

  Future<void> remove(String id) async {
    await transport.call('remote_port.remove', {'id': id});
    final index = viewModel.mappings.indexWhere((mapping) => mapping.id == id);
    if (index < 0) return;
    viewModel.mappings.removeAt(index);
    await _forwarders.remove(id)?.stop();
  }

  /// Transitional compatibility for callers that need the raw forwarder.
  Future<RemotePortForwarder> open({
    String remoteHost = '127.0.0.1',
    required int remotePort,
    int? localPort,
    String localScheme = 'http',
  }) async {
    final body = await transport.call('remote_port.add', {
      'remote_host': remoteHost,
      'remote_port': remotePort,
      'local_scheme': localScheme,
    });
    final config = _RemotePortMappingConfig.fromJson(
      ((body['mapping'] as Map?) ?? const {}).cast<String, Object?>(),
    );
    final started = await _start(config, localPort: localPort);
    _upsert(started);
    return started.forwarder;
  }

  Future<void> stop(RemotePortForwarder forwarder) async {
    final id = _forwarders.entries
        .where((entry) => identical(entry.value, forwarder))
        .map((entry) => entry.key)
        .firstOrNull;
    if (id != null) {
      await transport.call('remote_port.remove', {'id': id});
      viewModel.mappings.removeWhere((mapping) => mapping.id == id);
      _forwarders.remove(id);
    }
    await forwarder.stop();
  }

  Future<void> stopAll() async {
    final forwarders = _forwarders.values.toList();
    viewModel.mappings.clear();
    _forwarders.clear();
    await Future.wait([for (final forwarder in forwarders) forwarder.stop()]);
  }

  Future<({RemotePortMapping mapping, RemotePortForwarder forwarder})> _start(
    _RemotePortMappingConfig config, {
    int? localPort,
  }) async {
    final forwarder = await transport.startForwarder(
      remoteHost: config.remoteHost,
      remotePort: config.remotePort,
      localPort: localPort,
      localScheme: config.localScheme,
    );
    return (
      mapping: RemotePortMapping(
        id: config.id,
        remoteHost: config.remoteHost,
        remotePort: config.remotePort,
        localScheme: config.localScheme,
        createdAt: config.createdAt,
        localPort: forwarder.localPort,
        localUrl: forwarder.localUrl,
      ),
      forwarder: forwarder,
    );
  }

  Future<void> _reconcile(List<_RemotePortMappingConfig> configs) async {
    final existingById = {
      for (final mapping in viewModel.mappings) mapping.id: mapping,
    };
    final next = <RemotePortMapping>[];
    final nextForwarders = <String, RemotePortForwarder>{};
    final started = <RemotePortForwarder>[];
    final stopAfterSwap = <RemotePortForwarder>[];

    try {
      for (final config in configs) {
        final existing = existingById.remove(config.id);
        if (existing != null && _matchesConfig(existing, config)) {
          next.add(existing);
          final forwarder = _forwarders[existing.id];
          if (forwarder != null) nextForwarders[existing.id] = forwarder;
          continue;
        }
        final created = await _start(config);
        started.add(created.forwarder);
        next.add(created.mapping);
        nextForwarders[created.mapping.id] = created.forwarder;
        if (existing != null) {
          final oldForwarder = _forwarders[existing.id];
          if (oldForwarder != null) stopAfterSwap.add(oldForwarder);
        }
      }
    } catch (_) {
      await Future.wait([for (final forwarder in started) forwarder.stop()]);
      rethrow;
    }

    for (final mapping in existingById.values) {
      final forwarder = _forwarders[mapping.id];
      if (forwarder != null) stopAfterSwap.add(forwarder);
    }
    viewModel.mappings.replaceRange(0, viewModel.mappings.length, next);
    _forwarders
      ..clear()
      ..addAll(nextForwarders);
    await Future.wait([
      for (final forwarder in stopAfterSwap) forwarder.stop(),
    ]);
  }

  void _upsert(
    ({RemotePortMapping mapping, RemotePortForwarder forwarder}) started,
  ) {
    final mapping = started.mapping;
    final index = viewModel.mappings.indexWhere(
      (candidate) => candidate.id == mapping.id,
    );
    if (index < 0) {
      viewModel.mappings.add(mapping);
      _forwarders[mapping.id] = started.forwarder;
      return;
    }
    final oldForwarder = _forwarders[mapping.id];
    viewModel.mappings[index] = mapping;
    _forwarders[mapping.id] = started.forwarder;
    if (oldForwarder != null) unawaited(oldForwarder.stop());
  }

  bool _matchesConfig(
    RemotePortMapping mapping,
    _RemotePortMappingConfig config,
  ) =>
      mapping.id == config.id &&
      mapping.remoteHost == config.remoteHost &&
      mapping.remotePort == config.remotePort &&
      mapping.localScheme == config.localScheme;
}
