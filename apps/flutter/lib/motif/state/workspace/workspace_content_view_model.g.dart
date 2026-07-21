// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'workspace_content_view_model.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$WorkspaceContentViewModel with ObservableModelMixin {
  _$WorkspaceContentViewModel(int treeVersion, int gitVersion)
    : _treeVersion = treeVersion,
      _gitVersion = gitVersion {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_treeVersionKey, () => _treeVersion);
      observationRegisterDebugProperty(_gitVersionKey, () => _gitVersion);
    }
  }
  final ObservationKey<int> _treeVersionKey = ObservationKey<int>(
    'WorkspaceContentViewModel.treeVersion',
  );
  int _treeVersion;

  int get treeVersion {
    observationAccess(_treeVersionKey);
    return _treeVersion;
  }

  set treeVersion(int value) {
    if (_treeVersion == value) return;
    observationMutation(_treeVersionKey, () {
      _treeVersion = value;
    });
  }

  final ObservationKey<int> _gitVersionKey = ObservationKey<int>(
    'WorkspaceContentViewModel.gitVersion',
  );
  int _gitVersion;

  int get gitVersion {
    observationAccess(_gitVersionKey);
    return _gitVersion;
  }

  set gitVersion(int value) {
    if (_gitVersion == value) return;
    observationMutation(_gitVersionKey, () {
      _gitVersion = value;
    });
  }
}
