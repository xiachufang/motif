import 'package:flutter_observation/flutter_observation.dart';

import 'remote_port_mapping.dart';

part 'remote_ports_view_model.g.dart';

enum RemotePortsPhase { idle, loading, ready, failed }

/// Observable projection of one workspace's persisted remote-port mappings.
@ObservableModel()
class RemotePortsViewModel extends _$RemotePortsViewModel {
  RemotePortsViewModel({
    RemotePortsPhase phase = RemotePortsPhase.idle,
    @ObservationReadOnly() required ObservableList<RemotePortMapping> mappings,
    String? error,
  }) : super(phase, mappings, error);
}
