import 'package:flutter_observation/flutter_observation.dart';

part 'workspace_content_view_model.g.dart';

@ObservableModel()
class WorkspaceContentViewModel extends _$WorkspaceContentViewModel {
  WorkspaceContentViewModel({int treeVersion = 0, int gitVersion = 0})
    : super(treeVersion, gitVersion);

  void invalidateTree() => treeVersion++;

  void invalidateGit() => gitVersion++;
}
