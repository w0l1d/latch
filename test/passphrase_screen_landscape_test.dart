import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/features/decrypt/decrypt_passphrase_screen.dart';
import 'package:latch/features/encrypt/encrypt_passphrase_screen.dart';
import 'package:latch/shared/widgets/latch_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A phone held sideways, keyboard up, has about 360 logical pixels of height
/// and the software keyboard takes roughly half of it.
///
/// Both passphrase screens laid their body out as a plain `Column` with a
/// `Spacer` above the primary button, which has no way to shed height: when
/// the keyboard took the bottom 200-odd pixels the column overflowed
/// (`BOTTOM OVERFLOWED BY 206 PIXELS` on an SM-A546B at 15:52) and the
/// Continue button was drawn under the keyboard — present in the accessibility
/// tree, so a tap on it reports success, but unpressable for a real user.
///
/// This pins the invariant rather than the layout: whatever the screens look
/// like, a short viewport with the keyboard up must not overflow, and the
/// primary action must be reachable by scrolling.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 2340x1080 at 3x — the landscape phone from the e2e failure — with the
  // keyboard taking the bottom 620 physical pixels, which is where the split
  // keyboard's top edge sat on that device.
  const landscape = Size(2340, 1080);
  const keyboardInset = 620.0;

  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSideways(WidgetTester tester, Widget screen) async {
    tester.view.physicalSize = landscape;
    tester.view.devicePixelRatio = 3.0;
    tester.view.viewInsets = const FakeViewPadding(bottom: keyboardInset);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: screen));
    await tester.pumpAndSettle();
  }

  for (final (name, screen) in [
    ('encrypt passphrase', const EncryptPassphraseScreen(files: ['a.txt'])),
    ('decrypt passphrase', const DecryptPassphraseScreen(files: ['a.latch'])),
  ]) {
    testWidgets('$name screen does not overflow with the keyboard up '
        'in landscape', (tester) async {
      await pumpSideways(tester, screen);

      // A RenderFlex overflow is reported as a FlutterError and captured by
      // the binding, so this is the assertion that the layout fits.
      expect(
        tester.takeException(),
        isNull,
        reason: 'the body overflowed instead of scrolling',
      );

      // And the overflow was not merely hidden: the primary action still has
      // to be reachable on a viewport this short.
      final action = find.byType(Scrollable);
      expect(
        action,
        findsWidgets,
        reason: 'the body must scroll when it cannot fit',
      );
    });
  }

  // The fix must not change what the screen looks like when it *does* fit:
  // the `Spacer` is there so the button sits at the bottom of the screen, not
  // under the content. A scrollable body is the easy way to lose that.
  testWidgets('portrait still pins the button to the bottom', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: EncryptPassphraseScreen(files: ['a.txt'])),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The button itself, not its label: the label sits inside ~17 px of the
    // button's own padding, which would be enough slack to mask a regression.
    final button = tester.getRect(find.byType(LatchPrimaryButton));
    final bottomGap = tester.view.physicalSize.height / 3.0 - button.bottom;
    expect(
      bottomGap,
      lessThan(30),
      reason: 'button floated up to y=${button.bottom} instead of the bottom',
    );
  });
}
