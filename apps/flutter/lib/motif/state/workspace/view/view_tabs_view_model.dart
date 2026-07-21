import 'package:flutter_observation/flutter_observation.dart';

import '../../../models/motif_proto.dart';

part 'view_tabs_view_model.g.dart';

@ObservableModel()
class ViewTabsViewModel extends _$ViewTabsViewModel {
  ViewTabsViewModel({
    @ObservationReadOnly() required ObservableList<ViewInfo> items,
    String? activeViewId,
  }) : super(items, activeViewId);

  ViewInfo? get active {
    final id = activeViewId;
    if (id == null) return null;
    return items.where((view) => view.id == id).firstOrNull;
  }
}
