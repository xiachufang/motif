import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motif/motif/ui/theme/motif_theme.dart';
import 'package:motif/motif/ui/widgets/top_toast.dart';

void main() {
  testWidgets('shows toast from a pushed route through the global host', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: motifTheme(Brightness.light),
        builder: (context, child) =>
            MotifToastHost(child: child ?? const SizedBox.shrink()),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const _ToastRoute()),
                ),
                child: const Text('Open route'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open route'));
    await tester.pumpAndSettle();

    expect(find.text('Second route'), findsOneWidget);

    await tester.tap(find.text('Show toast'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('Route toast'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _ToastRoute extends StatelessWidget {
  const _ToastRoute();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Second route')),
      body: Center(
        child: FilledButton(
          onPressed: () => showMotifToast(context, 'Route toast'),
          child: const Text('Show toast'),
        ),
      ),
    );
  }
}
