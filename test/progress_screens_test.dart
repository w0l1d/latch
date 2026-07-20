import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latch/features/decrypt/decrypt_progress_screen.dart';
import 'package:latch/features/encrypt/encrypt_progress_screen.dart';

/// Regression tests for the forever-spinner class of bug: a progress screen
/// whose worker stream completes without delivering every per-file result
/// must surface an error, never spin forever with Cancel as the only exit.
///
/// The empty-file-list case is the deterministic reproduction: the router's
/// defensive `extra` decoding can produce `[]`, and `AppCrypto.encryptFiles`
/// /`decryptFiles` return immediately for an empty list. Before the fix this
/// left the indeterminate spinner running with no dialog and no navigation.
///
/// These tests deliberately avoid `pumpAndSettle` (an indeterminate spinner
/// never settles — it would mask exactly the hang we're testing for).
void main() {
  GoRouter buildRouter(Widget progressScreen) {
    return GoRouter(
      initialLocation: '/prev',
      routes: [
        GoRoute(
          path: '/prev',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('previous screen'))),
        ),
        GoRoute(path: '/progress', builder: (_, _) => progressScreen),
        GoRoute(
          path: '/encrypt/success',
          builder: (_, _) => const Scaffold(body: Text('encrypt success')),
        ),
        GoRoute(
          path: '/decrypt/success',
          builder: (_, _) => const Scaffold(body: Text('decrypt success')),
        ),
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('home')),
        ),
      ],
    );
  }

  Future<GoRouter> pumpProgress(WidgetTester tester, Widget screen) async {
    final router = buildRouter(screen);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    router.push('/progress');
    // Bounded pumps only — never pumpAndSettle around an indeterminate spinner.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    return router;
  }

  testWidgets(
    'encrypt progress with an empty file list shows an error, not an eternal spinner',
    (tester) async {
      final router = await pumpProgress(
        tester,
        const EncryptProgressScreen(
          files: [],
          passphrase: 'x',
          deleteOriginals: false,
        ),
      );

      expect(
        find.text('Nothing to lock'),
        findsOneWidget,
        reason: 'an empty batch must fail visibly instead of spinning forever',
      );

      // The escape hatch works: dialog button pops back to the previous screen.
      await tester.tap(find.text('Go back'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('previous screen'), findsOneWidget);
      expect(router.state.matchedLocation, '/prev');
    },
  );

  testWidgets(
    'decrypt progress with an empty file list shows an error, not an eternal spinner',
    (tester) async {
      final router = await pumpProgress(
        tester,
        const DecryptProgressScreen(files: [], passphrase: 'x'),
      );

      expect(
        find.text('Nothing to unlock'),
        findsOneWidget,
        reason: 'an empty batch must fail visibly instead of spinning forever',
      );

      await tester.tap(find.text('Try again'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('previous screen'), findsOneWidget);
      expect(router.state.matchedLocation, '/prev');
    },
  );
}
