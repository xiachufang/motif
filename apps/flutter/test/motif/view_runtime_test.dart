import 'dart:async';

import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/models/motif_proto.dart';
import 'package:motif/motif/state/workspace/view/view_controller.dart';
import 'package:motif/motif/state/workspace/view/view_runtime_state.dart';
import 'package:motif/motif/state/workspace/view/view_tabs_view_model.dart';

void main() {
  test('activation is optimistic but settles only on matching event', () async {
    final sent = Completer<void>();
    var calls = 0;
    late final ViewController controller;
    controller = ViewController(
      viewModel: _tabs(),
      transport: ViewTransport(
        isAvailable: () => true,
        call: (method, [params = const {}]) async {
          calls++;
          await sent.future;
          return const {};
        },
      ),
      callbacks: const ViewProjectionCallbacks(
        onTabsChanged: _noop,
        onActiveChanged: _noop,
      ),
    );
    addTearDown(controller.dispose);

    var settled = false;
    final activation = controller
        .activate('v2')
        .whenComplete(() => settled = true);
    expect(controller.viewModel.activeViewId, 'v2');
    expect(controller.runtimeState.activation, isA<ViewActivationPending>());
    expect(calls, 1);

    sent.complete();
    await _flushEffects();
    expect(settled, isFalse);

    controller.handleActiveChanged('v1');
    await _flushEffects();
    expect(settled, isFalse);

    controller.handleActiveChanged('v2');
    await activation;
    expect(controller.runtimeState.activation, isA<ViewActivationIdle>());
    expect(controller.pendingLocalViewId, isNull);
  });

  test('same activation target joins one request', () async {
    var calls = 0;
    late final ViewController controller;
    controller = ViewController(
      viewModel: _tabs(),
      transport: ViewTransport(
        isAvailable: () => true,
        call: (method, [params = const {}]) async {
          calls++;
          return const {};
        },
      ),
      callbacks: const ViewProjectionCallbacks(
        onTabsChanged: _noop,
        onActiveChanged: _noop,
      ),
    );
    addTearDown(controller.dispose);

    final first = controller.activate('v2');
    final second = controller.activate('v2');
    await _flushEffects();
    expect(calls, 1);

    controller.handleActiveChanged('v2');
    await Future.wait([first, second]);
  });

  test('failed activation rolls back optimistic selection', () async {
    final controller = ViewController(
      viewModel: _tabs(),
      transport: ViewTransport(
        isAvailable: () => true,
        call: (method, [params = const {}]) async =>
            throw StateError('offline'),
      ),
      callbacks: const ViewProjectionCallbacks(
        onTabsChanged: _noop,
        onActiveChanged: _noop,
      ),
    );
    addTearDown(controller.dispose);

    await expectLater(controller.activate('v2'), throwsStateError);
    expect(controller.viewModel.activeViewId, 'v1');
    expect(controller.runtimeState.activation, isA<ViewActivationFailed>());
  });
}

ViewTabsViewModel _tabs() => ViewTabsViewModel(
  items: ObservableList<ViewInfo>()
    ..addAll(const [
      ViewInfo(id: 'v1', spec: PtyViewSpec('p1')),
      ViewInfo(id: 'v2', spec: PtyViewSpec('p2')),
    ]),
  activeViewId: 'v1',
);

void _noop() {}

Future<void> _flushEffects() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
