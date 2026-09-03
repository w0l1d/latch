import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/output_plan.dart';
import 'package:latch/core/save_folder_prompt.dart';
import 'package:latch/core/saf_bridge.dart';

/// The folder-grant flow: a rationale dialog first explains WHY a folder
/// picker is about to appear (naming the source folder), then Continue opens
/// the system permission picker seeded at that folder. Backing out of either
/// step — or a picker that can't open — lands on the explicit Cancel /
/// Downloads / custom-folder choices, never on a silent fallback. Every branch
/// is pinned here because this is the only thing standing between the user and
/// files landing somewhere unexpected.
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
    void Function(SaveFolderDecision) onResult, {
    String? sourcePath,
  }) async {
    late VoidCallback run;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            run = () async => onResult(
              await promptSaveFolder(context, folder, sourcePath: sourcePath),
            );
            return const SizedBox();
          },
        ),
      ),
    );
    return run;
  }

  /// Taps the Cancel of the rationale dialog — the only dialog on screen at
  /// that point, so the ambiguity with the destinations dialog's Cancel can't
  /// arise.
  Future<void> backOutOfRationale(WidgetTester tester) async {
    expect(find.text('Save beside the originals?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  }

  testWidgets('explains first; the picker only opens after Continue', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/granted']);
    SaveFolderDecision? result;
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
      {'initialPath': workFolder, 'initialDocUri': null},
      reason: 'the picker starts at the folder the files came from',
    );
    expect(result!.outcome, SaveFolderOutcome.granted);
    expect(result!.treeUri, 'content://tree/granted');
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
    await backOutOfRationale(tester);

    expect(find.text('Where to save'), findsOneWidget);
    expect(find.textContaining('"Work"'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
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

  testWidgets(
    '"Use Downloads" is an explicit choice, made without the picker',
    (tester) async {
      mockPickTreeReplies(['content://tree/never']);
      SaveFolderDecision? result;
      final run = await pumpPrompt(tester, workFolder, (r) => result = r);
      run();
      await tester.pumpAndSettle();
      await backOutOfRationale(tester);
      await tester.tap(find.text('Use Downloads'));
      await tester.pumpAndSettle();

      expect(result!.outcome, SaveFolderOutcome.useDownloads);
      expect(result!.treeUri, isNull);
      expect(
        calls,
        isEmpty,
        reason: 'declining must not open the folder picker',
      );
    },
  );

  // The bug this whole enum exists for: "Cancel" and "Use Downloads" used to be
  // the same answer, so a user who wanted out got their files written somewhere
  // they never picked. Cancelling now stops the batch and nothing is written.
  testWidgets('Cancel is its own answer, distinct from Downloads', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/never']);
    SaveFolderDecision? result;
    final run = await pumpPrompt(tester, workFolder, (r) => result = r);
    run();
    await tester.pumpAndSettle();
    await backOutOfRationale(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result!.outcome, SaveFolderOutcome.cancelled);
    expect(result!.isCancelled, isTrue);
    expect(calls, isEmpty);
  });

  testWidgets(
    '"Choose folder" opens the picker at the source folder and grants',
    (tester) async {
      mockPickTreeReplies(['content://tree/custom']);
      SaveFolderDecision? result;
      final run = await pumpPrompt(tester, workFolder, (r) => result = r);
      run();
      await tester.pumpAndSettle();
      await backOutOfRationale(tester);
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();

      expect(calls.single.method, 'openTree');
      expect(
        calls.single.arguments,
        {'initialPath': workFolder, 'initialDocUri': null},
        reason: 'the custom-location picker starts where the files came from',
      );
      expect(result!.treeUri, 'content://tree/custom');
    },
  );

  // An empty picker after "Choose folder" is ambiguous — the user backed out,
  // or the device never opened one. Re-offering keeps Downloads reachable
  // instead of guessing, but only once: a second empty picker is an answer.
  testWidgets('an empty custom-location picker re-offers the choices once', (
    tester,
  ) async {
    mockPickTreeReplies([null, null]);
    SaveFolderDecision? result;
    final run = await pumpPrompt(tester, workFolder, (r) => result = r);
    run();
    await tester.pumpAndSettle();
    await backOutOfRationale(tester);
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(find.text('Where to save'), findsOneWidget, reason: 'asked again');
    expect(result, isNull, reason: 'still waiting on the user');

    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(2));
    expect(
      result!.outcome,
      SaveFolderOutcome.cancelled,
      reason: 'a second empty picker is taken as the answer',
    );
    expect(find.text('Where to save'), findsNothing);
  });

  testWidgets('the options dialog cannot be dismissed into a silent fallback', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/chosen']);
    SaveFolderDecision? result;
    final run = await pumpPrompt(tester, workFolder, (r) => result = r);
    run();
    await tester.pumpAndSettle();
    await backOutOfRationale(tester);

    // A barrier tap (like a back-press) used to complete showDialog with null,
    // which read as "Use Downloads" — the user's files silently went somewhere
    // they never chose. The dialog is now modal: it stays until they answer.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('Where to save'), findsOneWidget);
    expect(result, isNull, reason: 'still waiting on the user');

    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    expect(result!.treeUri, 'content://tree/chosen');
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
    SaveFolderDecision? result;
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
    expect(result!.treeUri, 'content://tree/recovered');
  });

  testWidgets('a picker that can never open declines instead of throwing', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          throw PlatformException(code: 'unavailable');
        });
    SaveFolderDecision? result;
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
    // The user takes the one option left that could still work; it can't, so
    // the choices come back and Downloads is still there to take.
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use Downloads'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(2), reason: 'both pickers were attempted');
    expect(
      thrown,
      isNull,
      reason:
          'a device with no ACTION_OPEN_DOCUMENT_TREE handler must not abort '
          'the whole batch out of the prompt',
    );
    expect(
      result!.outcome,
      SaveFolderOutcome.useDownloads,
      reason: 'Downloads stays reachable on a device with no picker at all',
    );
  });

  testWidgets('a context unmounted mid-picker cancels without a dialog', (
    tester,
  ) async {
    final gate = Completer<String?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          return gate.future;
        });
    SaveFolderDecision? result;
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
    // user cancelled the batch): the prompt must quietly stop, not call
    // showDialog on a dead context — and not pick Downloads for a user who
    // is no longer there to be asked.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    gate.complete(null);
    await tester.pumpAndSettle();

    expect(result!.outcome, SaveFolderOutcome.cancelled);
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
    // The copy names Android as the reason rather than reading like a Latch
    // malfunction: there is no supported way to ask which folder a document
    // picked this way came from.
    expect(
      find.textContaining(
        'Android doesn\'t tell apps which folder a file came from',
      ),
      findsOneWidget,
    );
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Use Downloads'), findsOneWidget);
    expect(find.text('Choose folder'), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets(
    'an unknown folder with no document URI leaves the picker unseeded',
    (tester) async {
      mockPickTreeReplies(['content://tree/anywhere']);
      SaveFolderDecision? result;
      final run = await pumpPrompt(tester, null, (r) => result = r);
      run();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();

      expect(calls.single.arguments, {
        'initialPath': null,
        'initialDocUri': null,
      });
      expect(result!.treeUri, 'content://tree/anywhere');
    },
  );

  // The whole point of the document seed: for sources whose folder Android
  // refuses to name (the picker's Downloads/Images/Videos shortcuts) the app
  // has no path to seed with, but it still holds the picked document's own
  // content:// URI — and EXTRA_INITIAL_URI accepts a document URI, letting the
  // *system* navigator resolve its parent. Without this the user lands at the
  // storage root and has to find the folder by hand.
  testWidgets('an unknown folder seeds the picker with the source document', (
    tester,
  ) async {
    const picked = '/data/user/0/com.latch.latch/cache/file_picker/report.pdf';
    const docUri =
        'content://com.android.providers.downloads.documents/'
        'document/msf%3A1000000123';
    SafBridge.rememberUri(picked, docUri);

    mockPickTreeReplies(['content://tree/resolved-by-system']);
    SaveFolderDecision? result;
    final run = await pumpPrompt(
      tester,
      null,
      (r) => result = r,
      sourcePath: picked,
    );
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(calls.single.arguments, {
      'initialPath': null,
      'initialDocUri': docUri,
    });
    expect(result!.treeUri, 'content://tree/resolved-by-system');
  });

  testWidgets('a resolved folder still passes the document as a second seed', (
    tester,
  ) async {
    const picked = '/data/user/0/com.latch.latch/cache/file_picker/notes.txt';
    const docUri =
        'content://com.android.externalstorage.documents/'
        'document/primary%3ADocuments%2FWork%2Fnotes.txt';
    SafBridge.rememberUri(picked, docUri);

    mockPickTreeReplies(['content://tree/granted']);
    final run = await pumpPrompt(
      tester,
      workFolder,
      (_) {},
      sourcePath: picked,
    );
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(calls.single.arguments, {
      'initialPath': workFolder,
      'initialDocUri': docUri,
    });
  });
}
