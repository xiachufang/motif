import 'package:flutter_observation/flutter_observation.dart';

part 'device_registration_view_model.g.dart';

enum DeviceRegistrationPhase { idle, registering, registered, failed }

@ObservableModel()
class DeviceRegistrationViewModel extends _$DeviceRegistrationViewModel {
  DeviceRegistrationViewModel({
    DeviceRegistrationPhase phase = DeviceRegistrationPhase.idle,
    String? instanceId,
    String? error,
  }) : super(phase, instanceId, error);
}
