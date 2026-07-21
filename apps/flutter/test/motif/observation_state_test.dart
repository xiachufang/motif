import 'package:flutter/material.dart';
import 'package:flutter_observation/flutter_observation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/state/app/app_ui_state.dart';
import 'package:motif/motif/state/app/motif_scope.dart';
import 'package:motif/motif/state/persistence/store_view_models.dart';

void main() {
  testWidgets('Observation scope rebuilds only an observed region', (
    tester,
  ) async {
    final state = AppShellViewModel(sidebar: SessionSidebarViewModel());
    var observedBuilds = 0;
    var staticBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: MotifValueScope<AppShellViewModel>(
          value: state,
          child: Column(
            children: [
              Builder(
                builder: (context) {
                  staticBuilds++;
                  return const Text('static');
                },
              ),
              Observer(
                builder: (context) {
                  observedBuilds++;
                  final presentation = ObservationScope.of<AppShellViewModel>(
                    context,
                  );
                  return Text(presentation.viewMode.name);
                },
              ),
            ],
          ),
        ),
      ),
    );

    expect(observedBuilds, 1);
    expect(staticBuilds, 1);
    expect(find.text('client'), findsOneWidget);

    state.pendingSessionOpen = const PendingSessionOpen(
      serverId: 'server',
      session: 'session',
    );
    await tester.pump();
    expect(observedBuilds, 1);

    state.viewMode = AppViewMode.server;
    await tester.pump();

    expect(observedBuilds, 2);
    expect(staticBuilds, 1);
    expect(find.text('server'), findsOneWidget);
  });

  testWidgets('generated models track properties independently', (
    tester,
  ) async {
    final state = AppShellViewModel(sidebar: SessionSidebarViewModel());
    var viewModeBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: MotifValueScope<AppShellViewModel>(
          value: state,
          child: Observer(
            builder: (context) {
              viewModeBuilds++;
              final presentation = ObservationScope.of<AppShellViewModel>(
                context,
              );
              return Text(presentation.viewMode.name);
            },
          ),
        ),
      ),
    );

    state.pendingSessionOpen = const PendingSessionOpen(
      serverId: 'server',
      session: 'session',
    );
    await tester.pump();
    expect(viewModeBuilds, 1);

    state.viewMode = AppViewMode.server;
    await tester.pump();
    expect(viewModeBuilds, 2);
    expect(find.text('server'), findsOneWidget);
  });

  test('generated store state tracks properties independently', () {
    final state = PushPreferencesViewModel(mutedSessions: ObservableSet());
    var enabledChanges = 0;
    final subscription = observe(
      () => state.enabled,
      onChange: (_) => enabledChanges++,
      scheduler: ObservationSchedulers.immediate,
    );

    state.mutedSessions.add('background');
    expect(enabledChanges, 0);

    state.enabled = false;
    expect(enabledChanges, 1);

    subscription.dispose();
  });

  test('observable collections support direct CRUD with stable identity', () {
    final items = ObservableList<String>();
    final entries = ObservableMap<String, int>();
    var listChanges = 0;
    var activeEntryChanges = 0;
    final listSubscription = observe(
      () => items.toList(),
      onChange: (_) => listChanges++,
      scheduler: ObservationSchedulers.immediate,
    );
    final mapSubscription = observe(
      () => entries['active'],
      onChange: (_) => activeEntryChanges++,
      scheduler: ObservationSchedulers.immediate,
    );

    items.add('one');
    items[0] = 'updated';
    items.removeAt(0);
    entries['background'] = 1;
    entries['active'] = 2;
    entries.remove('active');

    expect(listChanges, 3);
    expect(activeEntryChanges, 2);
    expect(items, isEmpty);
    expect(entries, {'background': 1});

    listSubscription.dispose();
    mapSubscription.dispose();
  });
}
