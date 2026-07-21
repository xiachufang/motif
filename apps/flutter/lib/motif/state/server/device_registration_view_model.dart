import 'package:flutter_observation/flutter_observation.dart';

import 'device_runtime_state.dart';

part 'device_registration_view_model.g.dart';

enum DeviceRegistrationPhase { idle, registering, registered, failed }

@ObservableModel()
class DeviceRegistrationViewModel extends _$DeviceRegistrationViewModel {
  DeviceRegistrationViewModel({
    DeviceRuntimeState runtime = const DeviceRuntimeState.initial(),
    DeviceRegistrationPhase phase = DeviceRegistrationPhase.idle,
    String? instanceId,
    String? error,
  }) : super(runtime, phase, instanceId, error);
}
