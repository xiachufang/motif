import 'package:flutter_observation/flutter_observation.dart';

import 'codex_connection_controller.dart';
import 'protocol/generated/codex_app_server_protocol.dart';

part 'codex_observation_view_models.g.dart';

/// Observable presentation state for one Codex conversation.
///
/// The protocol controller owns transport and command side effects. Widgets
/// observe this object instead of listening to the controller as one coarse
/// [ChangeNotifier]. Conversation structure is represented directly by nested
/// observable lists, while high-frequency stream updates stay item-scoped.
@ObservableModel()
class CodexConversationViewModel extends _$CodexConversationViewModel {
  CodexConversationViewModel({
    required CodexConnectionState connectionState,
    CodexThread? selectedThread,
    String? readingThreadId,
    int catalogRevision = 0,
    int streamRevision = 0,
    @ObservationReadOnly() required ObservableList<CodexTurnViewModel> turns,
  }) : super(
         connectionState,
         selectedThread,
         readingThreadId,
         catalogRevision,
         streamRevision,
         turns,
       );
}

/// Stable observable identity for one turn and its ordered item structure.
@ObservableModel()
class CodexTurnViewModel extends _$CodexTurnViewModel {
  CodexTurnViewModel({
    @ObservationReadOnly() required String id,
    required CodexTurn turn,
    @ObservationReadOnly() required ObservableList<CodexItemViewModel> items,
  }) : super(id, turn, items);
}

/// Stable observable identity for a protocol item.
///
/// A delta updates only this model. Completed turns and unrelated page chrome
/// therefore do not rebuild while another item is streaming.
@ObservableModel()
class CodexItemViewModel extends _$CodexItemViewModel {
  CodexItemViewModel({
    required CodexThreadItem item,
    @ObservationIgnored() required CodexThreadItem structuralItem,
    bool streaming = false,
  }) : super(item, structuralItem, streaming);
}
