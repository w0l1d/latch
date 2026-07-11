import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/shared/widgets/latch_alert.dart';

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  group('LatchAlert', () {
    testWidgets('danger tone renders title, message, and button', (tester) async {
      await tester.pumpWidget(host(
        const LatchAlert(
          tone: LatchAlertTone.danger,
          icon: Icons.lock_outline,
          title: 'Wrong passphrase',
          message: "That passphrase didn't open these files.",
          buttonLabel: 'Try again',
          onPressed: _noop,
        ),
      ));

      expect(find.text('Wrong passphrase'), findsOneWidget);
      expect(find.text("That passphrase didn't open these files."),
          findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    });

    testWidgets('caution tone renders title, message, and button', (tester) async {
      await tester.pumpWidget(host(
        const LatchAlert(
          tone: LatchAlertTone.caution,
          icon: Icons.check_circle_outline,
          title: '2 files opened, 1 failed',
          message: 'report.pdf: error',
          buttonLabel: 'Continue',
          onPressed: _noop,
        ),
      ));

      expect(find.text('2 files opened, 1 failed'), findsOneWidget);
      expect(find.text('report.pdf: error'), findsOneWidget);
      expect(find.text('Continue'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('button press fires onPressed', (tester) async {
      var pressed = 0;
      await tester.pumpWidget(host(
        LatchAlert(
          tone: LatchAlertTone.danger,
          icon: Icons.error_outline,
          title: 'Encryption failed',
          message: 'Something went wrong.',
          buttonLabel: 'Go back',
          onPressed: () => pressed++,
        ),
      ));

      await tester.tap(find.text('Go back'));
      await tester.pump();
      expect(pressed, 1);
    });

    testWidgets('showLatchAlert presents a modal barrier that is not dismissible',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => showLatchAlert(
                context,
                tone: LatchAlertTone.danger,
                icon: Icons.warning_amber_rounded,
                title: "This file can't be trusted.",
                message: 'The file has been modified or is incomplete.',
                buttonLabel: 'Back to home',
                onPressed: () => Navigator.pop(context),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text("This file can't be trusted."), findsOneWidget);

      // Tapping outside must not dismiss (barrierDismissible: false).
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text("This file can't be trusted."), findsOneWidget);

      // The action button dismisses it.
      await tester.tap(find.text('Back to home'));
      await tester.pumpAndSettle();
      expect(find.text("This file can't be trusted."), findsNothing);
    });
  });
}

void _noop() {}
