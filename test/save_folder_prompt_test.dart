import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/save_folder_prompt.dart';
import 'package:latch/core/saf_bridge.dart';

/// The folder-grant flow: a rationale dialog first explains WHY a folder
/// picker is about to appear (naming the source folder), then Continue opens
/// the system permission picker seeded at that folder. Backing out of either
/// step — or a picker that can't open — lands on the explicit Downloads /
/// custom-folder choices, never on a silent fallback. Every branch is pinned
/// here because this is the only thing standing between the user and files
/// landing somewhere unexpected.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const workFolder = '/storage/emulated/0/Documents/Work';

  late List<MethodCall> calls;

  setUp(() => calls = []);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, null);
  });

  /// Answers openTree calls with [replies] in order (extra calls get null).
  void mockPickTreeReplies(List<Object?> replies) {
    var i = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          return i < replies.length ? replies[i++] : null;
        });
  }

  /// Pumps a button that runs the prompt for [folder] and records its result.
  Future<void Function()> pumpPrompt(
    WidgetTester tester,
    String? folder,
    void Function(String?) onResult,
  ) async {
    late VoidCallback run;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            run = () async => onResult(await promptSaveFolder(context, folder));
            return const SizedBox();
          },
        ),
      ),
    );
    return run;
  }

  testWidgets('explains first; the picker only opens after Continue', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/granted']);
    String? result;
    final run = await pumpPrompt(tester, workFolder, (r) => result = r);
    run();
    await tester.pumpAndSettle();

    expect(find.text('Save beside the originals?'), findsOneWidget);
    expect(find.textContaining('"Work"'), findsOneWidget);
    expect(find.textContaining('The folder picker opens next'), findsOneWidget);
    expect(
      calls,
      isEmpty,
      reason: 'no folder picker may appear before the user knows why',
    );

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(calls.single.method, 'openTree');
    expect(
      calls.single.arguments,
      {'initialPath': workFolder},
      reason: 'the picker starts at the folder the files came from',
    );
    expect(result, 'content://tree/granted');
    expect(
      find.text('Use Downloads'),
      findsNothing,
      reason: 'a granted picker never shows the Downloads/custom options',
    );
  });

  testWidgets('Cancel on the rationale offers the explicit ways out', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/never']);
    final run = await pumpPrompt(tester, workFolder, (_) {});
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Where to save'), findsOneWidget);
    expect(find.textContaining('"Work"'), findsOneWidget);
    expect(find.text('Use Downloads'), findsOneWidget);
    expect(find.text('Choose folder'), findsOneWidget);
    expect(calls, isEmpty, reason: 'Cancel must not open the picker');
  });

  testWidgets('backing out of the picker offers the explicit ways out', (
    tester,
  ) async {
    mockPickTreeReplies([null]);
    final run = await pumpPrompt(tester, workFolder, (_) {});
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(calls.single.method, 'openTree');
    expect(find.text('Where to save'), findsOneWidget);
    expect(find.text('Use Downloads'), findsOneWidget);
    expect(find.text('Choose folder'), findsOneWidget);
  });

  testWidgets('"Use Downloads" returns null without opening the picker', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/never']);
    String? result = 'unset';
    final run = await pumpPrompt(tester, workFolder, (r) => result = r);
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use Downloads'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(calls, isEmpty, reason: 'declining must not open the folder picker');
  });

  testWidgets(
    '"Choose folder" opens the picker at the source folder and grants',
    (tester) async {
      mockPickTreeReplies(['content://tree/custom']);
      String? result;
      final run = await pumpPrompt(tester, workFolder, (r) => result = r);
      run();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();

      expect(calls.single.method, 'openTree');
      expect(
        calls.single.arguments,
        {'initialPath': workFolder},
        reason: 'the custom-location picker starts where the files came from',
      );
      expect(result, 'content://tree/custom');
    },
  );

  testWidgets('cancelling the custom-location picker returns null', (
    tester,
  ) async {
    mockPickTreeReplies([null]);
    String? result = 'unset';
    final run = await pumpPrompt(tester, workFolder, (r) => result = r);
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(calls.single.method, 'openTree');
    expect(result, isNull);
  });

  testWidgets('dismissing the options dialog counts as declining', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/never']);
    String? result = 'unset';
    final run = await pumpPrompt(tester, workFolder, (r) => result = r);
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    // Tap the barrier outside the dialog: showDialog completes with null.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(calls, isEmpty, reason: 'no picker after a dismiss');
  });

  testWidgets('a picker that fails to open still offers the ways out', (
    tester,
  ) async {
    var i = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          i++;
          // Devices without a handler for ACTION_OPEN_DOCUMENT_TREE throw
          // instead of opening the picker.
          if (i == 1) throw PlatformException(code: 'unavailable');
          return 'content://tree/recovered';
        });
    String? result;
    final run = await pumpPrompt(tester, workFolder, (r) => result = r);
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(
      find.text('Where to save'),
      findsOneWidget,
      reason:
          'a broken picker must not fail the batch — Downloads stays '
          'reachable and choosing a folder can still work',
    );
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(2));
    expect(result, 'content://tree/recovered');
  });

  testWidgets('a picker that can never open declines instead of throwing', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          throw PlatformException(code: 'unavailable');
        });
    String? result = 'unset';
    Object? thrown;
    late VoidCallback run;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            run = () async {
              try {
                result = await promptSaveFolder(context, workFolder);
              } catch (e) {
                thrown = e;
              }
            };
            return const SizedBox();
          },
        ),
      ),
    );
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    // The user takes the one option left that could still work.
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(2), reason: 'both pickers were attempted');
    expect(
      thrown,
      isNull,
      reason:
          'a device with no ACTION_OPEN_DOCUMENT_TREE handler must not abort '
          'the whole batch out of the prompt',
    );
    expect(result, isNull, reason: 'null = the caller saves to Downloads');
  });

  testWidgets('a context unmounted mid-picker declines without a dialog', (
    tester,
  ) async {
    final gate = Completer<String?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          return gate.future;
        });
    String? result = 'unset';
    late VoidCallback run;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            run = () async =>
                result = await promptSaveFolder(context, workFolder);
            return const SizedBox();
          },
        ),
      ),
    );
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pump(); // the openTree call is now in flight
    expect(calls.single.method, 'openTree');

    // The screen is gone by the time the picker answer arrives (e.g. the
    // user cancelled the batch): the prompt must quietly decline, not call
    // showDialog on a dead context.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gate.complete(null);
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('an unresolvable source goes straight to the choices', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/never']);
    final run = await pumpPrompt(tester, null, (_) {});
    run();
    await tester.pumpAndSettle();

    expect(
      find.text('Save beside the originals?'),
      findsNothing,
      reason: 'no folder to grant, so no permission rationale',
    );
    expect(
      find.textContaining('can\'t tell which folder these files came from'),
      findsOneWidget,
    );
    expect(find.text('Use Downloads'), findsOneWidget);
    expect(find.text('Choose folder'), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets(
    'an unknown folder picks a destination with the picker unseeded',
    (tester) async {
      mockPickTreeReplies(['content://tree/anywhere']);
      String? result;
      final run = await pumpPrompt(tester, null, (r) => result = r);
      run();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();

      expect(calls.single.arguments, {'initialPath': null});
      expect(result, 'content://tree/anywhere');
    },
  );
}
