import 'dart:async';

import 'package:motif/motif/codex/protocol/generated/codex_app_server_protocol.dart';

/// A persistent server queue shared by fake client sessions.
mixin FakeCodexQueue {
  final Map<String, List<CodexQueuedSubmission>> serverQueues = {};
  final List<CodexThreadQueueAddParams> queueAdds = [];
  final List<CodexThreadQueueListParams> queueLists = [];
  final List<CodexThreadQueueUpdateParams> queueUpdates = [];
  final List<CodexThreadQueueDeleteParams> queueDeletes = [];
  final List<CodexThreadQueueReorderParams> queueReorders = [];
  final List<CodexThreadQueueStartParams> queueStarts = [];
  Object? queueMutationError;
  Object? queueListError;
  Completer<CodexThreadQueueListResponse>? queueListGate;
  int queuePageSize = 100;
  int _queueId = 0;

  Future<CodexThreadQueueListResponse> listThreadQueue(
    CodexThreadQueueListParams params,
  ) async {
    queueLists.add(params);
    final gate = queueListGate;
    if (gate != null) {
      queueListGate = null;
      return gate.future;
    }
    if (queueListError != null) throw queueListError!;
    final items = serverQueues[params.threadId] ?? [];
    final offset = int.parse(params.cursor ?? '0');
    final size = (params.limit ?? 100) < queuePageSize
        ? params.limit!
        : queuePageSize;
    final page = items.skip(offset).take(size).toList();
    return CodexThreadQueueListResponse(
      data: page,
      nextCursor: offset + page.length < items.length
          ? '${offset + page.length}'
          : null,
    );
  }

  Future<CodexThreadQueueAddResponse> addThreadQueue(
    CodexThreadQueueAddParams params,
  ) async {
    queueAdds.add(params);
    if (queueMutationError != null) throw queueMutationError!;
    final item = CodexQueuedSubmission(
      id: 'server-queue-${++_queueId}',
      clientUserMessageId: params.clientUserMessageId,
      input: params.input,
    );
    serverQueues.putIfAbsent(params.threadId, () => []).add(item);
    return CodexThreadQueueAddResponse(queuedSubmission: item);
  }

  Future<CodexThreadQueueUpdateResponse> updateThreadQueue(
    CodexThreadQueueUpdateParams params,
  ) async {
    queueUpdates.add(params);
    if (queueMutationError != null) throw queueMutationError!;
    final items = serverQueues[params.threadId]!;
    final index = items.indexWhere(
      (item) => item.id == params.queuedSubmissionId,
    );
    if (index == -1) throw StateError('queued submission not found');
    final item = CodexQueuedSubmission(
      id: items[index].id,
      clientUserMessageId: items[index].clientUserMessageId,
      input: params.input,
    );
    items[index] = item;
    return CodexThreadQueueUpdateResponse(queuedSubmission: item);
  }

  Future<CodexThreadQueueDeleteResponse> deleteThreadQueue(
    CodexThreadQueueDeleteParams params,
  ) async {
    queueDeletes.add(params);
    if (queueMutationError != null) throw queueMutationError!;
    final items = serverQueues[params.threadId] ?? [];
    final count = items.length;
    items.removeWhere((item) => item.id == params.queuedSubmissionId);
    return CodexThreadQueueDeleteResponse(deleted: count != items.length);
  }

  Future<CodexThreadQueueReorderResponse> reorderThreadQueue(
    CodexThreadQueueReorderParams params,
  ) async {
    queueReorders.add(params);
    if (queueMutationError != null) throw queueMutationError!;
    final items = serverQueues[params.threadId]!;
    serverQueues[params.threadId] = [
      for (final id in params.queuedSubmissionIds)
        items.singleWhere((item) => item.id == id),
    ];
    return const CodexThreadQueueReorderResponse();
  }

  Future<CodexThreadQueueStartResponse> startThreadQueue(
    CodexThreadQueueStartParams params,
  ) async {
    queueStarts.add(params);
    if (queueMutationError != null) throw queueMutationError!;
    final items = serverQueues[params.threadId] ?? [];
    final id = params.queuedSubmissionId ?? items.first.id;
    if (!items.any((item) => item.id == id)) {
      throw StateError('queued submission not found');
    }
    items.removeWhere((item) => item.id == id);
    return const CodexThreadQueueStartResponse(
      turn: CodexTurn(
        id: 'server-queued-turn',
        items: [],
        status: CodexTurnStatus.inProgress,
      ),
    );
  }
}
