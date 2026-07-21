import 'package:flutter_observation/flutter_observation.dart';

import 'remote_port_mapping.dart';
import 'remote_port_runtime.dart';

part 'remote_ports_view_model.g.dart';

enum RemotePortsPhase { idle, loading, ready, failed }

/// Observable projection of one workspace's persisted remote-port mappings.
@ObservableModel()
class RemotePortsViewModel extends _$RemotePortsViewModel {
  RemotePortsViewModel({
    RemotePortRuntimeState runtime = const RemotePortRuntimeIdle(),
    RemotePortsPhase phase = RemotePortsPhase.idle,
    @ObservationReadOnly() required ObservableList<RemotePortMapping> mappings,
    String? error,
  }) : super(runtime, phase, mappings, error);
}
