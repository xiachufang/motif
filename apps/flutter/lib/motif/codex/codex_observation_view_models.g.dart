// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'codex_observation_view_models.dart';

// **************************************************************************
// ObservableGenerator
// **************************************************************************

abstract class _$CodexConversationViewModel with ObservableModelMixin {
  _$CodexConversationViewModel(
    CodexConnectionState connectionState,
    CodexThread? selectedThread,
    String? readingThreadId,
    int catalogRevision,
    int streamRevision,
    ObservableList<CodexTurnViewModel> turns,
  ) : _connectionState = connectionState,
      _selectedThread = selectedThread,
      _readingThreadId = readingThreadId,
      _catalogRevision = catalogRevision,
      _streamRevision = streamRevision,
      _turns = turns {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(
        _connectionStateKey,
        () => _connectionState,
      );
      observationRegisterDebugProperty(
        _selectedThreadKey,
        () => _selectedThread,
      );
      observationRegisterDebugProperty(
        _readingThreadIdKey,
        () => _readingThreadId,
      );
      observationRegisterDebugProperty(
        _catalogRevisionKey,
        () => _catalogRevision,
      );
      observationRegisterDebugProperty(
        _streamRevisionKey,
        () => _streamRevision,
      );
      observationRegisterDebugProperty(_turnsKey, () => _turns);
    }
  }
  final ObservationKey<CodexConnectionState> _connectionStateKey =
      ObservationKey<CodexConnectionState>(
        'CodexConversationViewModel.connectionState',
      );
  CodexConnectionState _connectionState;

  CodexConnectionState get connectionState {
    observationAccess(_connectionStateKey);
    return _connectionState;
  }

  set connectionState(CodexConnectionState value) {
    if (_connectionState == value) return;
    observationMutation(_connectionStateKey, () {
      _connectionState = value;
    });
  }

  final ObservationKey<CodexThread?> _selectedThreadKey =
      ObservationKey<CodexThread?>('CodexConversationViewModel.selectedThread');
  CodexThread? _selectedThread;

  CodexThread? get selectedThread {
    observationAccess(_selectedThreadKey);
    return _selectedThread;
  }

  set selectedThread(CodexThread? value) {
    if (_selectedThread == value) return;
    observationMutation(_selectedThreadKey, () {
      _selectedThread = value;
    });
  }

  final ObservationKey<String?> _readingThreadIdKey = ObservationKey<String?>(
    'CodexConversationViewModel.readingThreadId',
  );
  String? _readingThreadId;

  String? get readingThreadId {
    observationAccess(_readingThreadIdKey);
    return _readingThreadId;
  }

  set readingThreadId(String? value) {
    if (_readingThreadId == value) return;
    observationMutation(_readingThreadIdKey, () {
      _readingThreadId = value;
    });
  }

  final ObservationKey<int> _catalogRevisionKey = ObservationKey<int>(
    'CodexConversationViewModel.catalogRevision',
  );
  int _catalogRevision;

  int get catalogRevision {
    observationAccess(_catalogRevisionKey);
    return _catalogRevision;
  }

  set catalogRevision(int value) {
    if (_catalogRevision == value) return;
    observationMutation(_catalogRevisionKey, () {
      _catalogRevision = value;
    });
  }

  final ObservationKey<int> _streamRevisionKey = ObservationKey<int>(
    'CodexConversationViewModel.streamRevision',
  );
  int _streamRevision;

  int get streamRevision {
    observationAccess(_streamRevisionKey);
    return _streamRevision;
  }

  set streamRevision(int value) {
    if (_streamRevision == value) return;
    observationMutation(_streamRevisionKey, () {
      _streamRevision = value;
    });
  }

  final ObservationKey<ObservableList<CodexTurnViewModel>> _turnsKey =
      ObservationKey<ObservableList<CodexTurnViewModel>>(
        'CodexConversationViewModel.turns',
      );
  final ObservableList<CodexTurnViewModel> _turns;

  ObservableList<CodexTurnViewModel> get turns {
    observationAccess(_turnsKey);
    return _turns;
  }
}

abstract class _$CodexTurnViewModel with ObservableModelMixin {
  _$CodexTurnViewModel(
    String id,
    CodexTurn turn,
    ObservableList<CodexItemViewModel> items,
  ) : _id = id,
      _turn = turn,
      _items = items {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_idKey, () => _id);
      observationRegisterDebugProperty(_turnKey, () => _turn);
      observationRegisterDebugProperty(_itemsKey, () => _items);
    }
  }
  final ObservationKey<String> _idKey = ObservationKey<String>(
    'CodexTurnViewModel.id',
  );
  final String _id;

  String get id {
    observationAccess(_idKey);
    return _id;
  }

  final ObservationKey<CodexTurn> _turnKey = ObservationKey<CodexTurn>(
    'CodexTurnViewModel.turn',
  );
  CodexTurn _turn;

  CodexTurn get turn {
    observationAccess(_turnKey);
    return _turn;
  }

  set turn(CodexTurn value) {
    if (_turn == value) return;
    observationMutation(_turnKey, () {
      _turn = value;
    });
  }

  final ObservationKey<ObservableList<CodexItemViewModel>> _itemsKey =
      ObservationKey<ObservableList<CodexItemViewModel>>(
        'CodexTurnViewModel.items',
      );
  final ObservableList<CodexItemViewModel> _items;

  ObservableList<CodexItemViewModel> get items {
    observationAccess(_itemsKey);
    return _items;
  }
}

abstract class _$CodexItemViewModel with ObservableModelMixin {
  _$CodexItemViewModel(
    CodexThreadItem item,
    CodexThreadItem structuralItem,
    bool streaming,
  ) : _item = item,
      _structuralItem = structuralItem,
      _streaming = streaming {
    if (!ObservationDebug.isReleaseMode) {
      observationRegisterDebugProperty(_itemKey, () => _item);
      observationRegisterDebugProperty(_streamingKey, () => _streaming);
    }
  }
  final ObservationKey<CodexThreadItem> _itemKey =
      ObservationKey<CodexThreadItem>('CodexItemViewModel.item');
  CodexThreadItem _item;

  CodexThreadItem get item {
    observationAccess(_itemKey);
    return _item;
  }

  set item(CodexThreadItem value) {
    if (_item == value) return;
    observationMutation(_itemKey, () {
      _item = value;
    });
  }

  CodexThreadItem _structuralItem;

  CodexThreadItem get structuralItem {
    return _structuralItem;
  }

  set structuralItem(CodexThreadItem value) {
    if (_structuralItem == value) return;
    _structuralItem = value;
  }

  final ObservationKey<bool> _streamingKey = ObservationKey<bool>(
    'CodexItemViewModel.streaming',
  );
  bool _streaming;

  bool get streaming {
    observationAccess(_streamingKey);
    return _streaming;
  }

  set streaming(bool value) {
    if (_streaming == value) return;
    observationMutation(_streamingKey, () {
      _streaming = value;
    });
  }
}
