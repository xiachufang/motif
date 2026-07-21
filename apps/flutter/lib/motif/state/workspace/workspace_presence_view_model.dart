import 'package:flutter_observation/flutter_observation.dart';

import '../../models/motif_proto.dart';

part 'workspace_presence_view_model.g.dart';

/// Session-wide metadata projected into a workspace.
@ObservableModel()
class WorkspacePresenceViewModel extends _$WorkspacePresenceViewModel {
  WorkspacePresenceViewModel({
    @ObservationReadOnly() required ObservableList<ClientInfo> clients,
    String? sessionTheme,
    MotifNotification? latestNotification,
  }) : super(clients, sessionTheme, latestNotification);
}
