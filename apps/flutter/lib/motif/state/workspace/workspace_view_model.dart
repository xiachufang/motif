import 'package:flutter_observation/flutter_observation.dart';

import '../../models/motif_proto.dart';
import 'remote_port/remote_ports_view_model.dart';
import 'terminal/terminal_view_model.dart';
import 'view/view_tabs_view_model.dart';
import 'connection/workspace_connection_view_model.dart';
import 'workspace_content_view_model.dart';
import 'workspace_presence_view_model.dart';

part 'workspace_view_model.g.dart';

typedef WorkspaceKey = ({String serverId, String session});

/// Root observable state for exactly one `(serverId, session)` workspace.
@ObservableModel()
class WorkspaceViewModel extends _$WorkspaceViewModel {
  WorkspaceViewModel({
    @ObservationReadOnly() required String serverId,
    @ObservationReadOnly() required String session,
    @ObservationReadOnly() required WorkspaceConnectionViewModel connection,
    @ObservationReadOnly() required TerminalViewModel terminal,
    @ObservationReadOnly() required ViewTabsViewModel views,
    @ObservationReadOnly() required RemotePortsViewModel remotePorts,
    @ObservationReadOnly() required WorkspaceContentViewModel content,
    @ObservationReadOnly() required WorkspacePresenceViewModel presence,
  }) : super(
         serverId,
         session,
         connection,
         terminal,
         views,
         remotePorts,
         content,
         presence,
       );

  WorkspaceKey get key => (serverId: serverId, session: session);

  bool get hasSnapshot => terminal.ptys.isNotEmpty || views.items.isNotEmpty;

  ObservableList<ClientInfo> get clients => presence.clients;

  String? get sessionTheme => presence.sessionTheme;

  MotifNotification? get latestNotification => presence.latestNotification;

  String? get activePtyId {
    final spec = views.active?.spec;
    return spec is PtyViewSpec ? spec.ptyId : null;
  }
}
