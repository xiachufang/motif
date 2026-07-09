import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/ui/widgets/listenable_select.dart';

void main() {
  testWidgets('ListenableSelect rebuilds only when selector value changes', (
    tester,
  ) async {
    final notifier = _Counter();
    var builds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: ListenableSelect(
          listenable: notifier,
          selector: () => notifier.value ~/ 10,
          builder: (context, value, _) {
            builds++;
            return Text('bucket=$value', key: const ValueKey('label'));
          },
        ),
      ),
    );

    expect(find.text('bucket=0'), findsOneWidget);
    expect(builds, 1);

    notifier.value = 3;
    await tester.pump();
    expect(builds, 1);

    notifier.value = 10;
    await tester.pump();
    expect(find.text('bucket=1'), findsOneWidget);
    expect(builds, 2);
  });
}

class _Counter extends ChangeNotifier {
  int _value = 0;
  int get value => _value;
  set value(int v) {
    _value = v;
    notifyListeners();
  }
}
