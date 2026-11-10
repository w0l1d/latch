import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/shared/widgets/latch_button.dart';

/// Pins the reason the shared buttons key their semantics node on its id.
///
/// Flutter's `SemanticsNode.updateWith` assigns a changed `identifier`, but
/// `_isDifferentFromCurrentSemanticAnnotation` — the check that decides whether
/// the node is dirty — compares both *traversal* identifiers and omits this one.
/// So a node whose only change is its identifier is never re-sent to the engine,
/// and Android keeps reporting the old `resource-id` while the Dart tree (and
/// therefore `find.bySemanticsIdentifier`) reports the new one.
///
/// That is not a hypothetical: an on-device flow asserted
/// `id: encrypt_folder_continue` on the folder screen's primary button, which
/// reads "Set a passphrase" once a folder is scanned but is the same widget
/// position that read "Choose a folder" (`encrypt_folder_pick`) before. The
/// button was correct on screen and the widget test passed; only the id was
/// stale, so the flow failed on a build that had nothing wrong with it.
///
/// These tests are about element identity, not about what the framework reports:
/// a widget test can never observe the platform-tree staleness itself, because
/// the staleness exists only between the framework and the engine.
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('a bare Semantics reuses its element when only the id changes', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      host(Semantics(identifier: 'a', child: SizedBox())),
    );
    final before = tester.element(find.bySemanticsIdentifier('a'));

    await tester.pumpWidget(
      host(Semantics(identifier: 'b', child: SizedBox())),
    );

    expect(find.bySemanticsIdentifier('b'), findsOneWidget);
    // Reused, and so — for the reason in the file header — still reported to
    // Android under the old id. This is the framework behaviour being worked
    // around; if Flutter ever starts marking identifier changes dirty, this
    // expectation fails and the workaround below can be reconsidered.
    expect(
      identical(tester.element(find.bySemanticsIdentifier('b')), before),
      isTrue,
    );
    handle.dispose();
  });

  testWidgets('LatchPrimaryButton rebuilds its node when its id changes', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      host(
        LatchPrimaryButton(
          label: 'Choose a folder',
          semanticsId: 'encrypt_folder_pick',
          onPressed: () {},
        ),
      ),
    );
    final before = tester.element(
      find.bySemanticsIdentifier('encrypt_folder_pick'),
    );

    await tester.pumpWidget(
      host(
        LatchPrimaryButton(
          label: 'Set a passphrase',
          semanticsId: 'encrypt_folder_continue',
          onPressed: () {},
        ),
      ),
    );

    expect(find.bySemanticsIdentifier('encrypt_folder_pick'), findsNothing);
    expect(
      find.bySemanticsIdentifier('encrypt_folder_continue'),
      findsOneWidget,
    );
    // Different element ⇒ different SemanticsNode ⇒ the engine is told about it,
    // so `resource-id` on the device matches what the tree says.
    expect(
      identical(
        tester.element(find.bySemanticsIdentifier('encrypt_folder_continue')),
        before,
      ),
      isFalse,
    );
    handle.dispose();
  });

  testWidgets('LatchSecondaryButton rebuilds its node when its id changes', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      host(
        LatchSecondaryButton(
          label: 'First',
          semanticsId: 'id_first',
          onPressed: () {},
        ),
      ),
    );
    final before = tester.element(find.bySemanticsIdentifier('id_first'));

    await tester.pumpWidget(
      host(
        LatchSecondaryButton(
          label: 'Second',
          semanticsId: 'id_second',
          onPressed: () {},
        ),
      ),
    );

    expect(find.bySemanticsIdentifier('id_first'), findsNothing);
    expect(find.bySemanticsIdentifier('id_second'), findsOneWidget);
    expect(
      identical(
        tester.element(find.bySemanticsIdentifier('id_second')),
        before,
      ),
      isFalse,
    );
    handle.dispose();
  });

  testWidgets('a button with no id carries no identifier at all', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      host(LatchPrimaryButton(label: 'Plain', onPressed: () {})),
    );

    // No wrapper means no id-bearing node — the label is the only anchor, which
    // is the intended fallback for buttons no flow needs to address.
    final identified = find.byWidgetPredicate(
      (w) => w is Semantics && w.properties.identifier != null,
    );
    expect(identified, findsNothing);
    expect(find.text('Plain'), findsOneWidget);
    handle.dispose();
  });
}
