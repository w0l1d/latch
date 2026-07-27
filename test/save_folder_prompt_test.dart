import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/save_folder_prompt.dart';
import 'package:latch/core/saf_bridge.dart';

/// The folder-grant flow: the system permission picker goes first (seeded at
/// the source folder, so granting is one tap), and the Downloads / custom-
/// folder options only come up when the user backs out of that picker. It is
/// the only thing standing between the user and a silent Downloads fallback,
/// so every branch is pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  testWidgets('the permission picker goes first, seeded at the source folder', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/granted']);
    String? result;
    final run = await pumpPrompt(
      tester,
      '/storage/emulated/0/Documents/Work',
      (r) => result = r,
    );
    run();
    await tester.pumpAndSettle();

    expect(calls.single.method, 'openTree');
    expect(
      calls.single.arguments,
      {'initialPath': '/storage/emulated/0/Documents/Work'},
      reason: 'granting the source folder must be a single tap',
    );
    expect(result, 'content://tree/granted');
    expect(
      find.text('Where to save'),
      findsNothing,
      reason: 'a granted picker never shows the Downloads/custom options',
    );
  });

  testWidgets('an unknown source folder opens the picker unseeded', (
    tester,
  ) async {
    mockPickTreeReplies(['content://tree/anywhere']);
    String? result;
    final run = await pumpPrompt(tester, null, (r) => result = r);
    run();
    await tester.pumpAndSettle();

    expect(calls.single.arguments, {'initialPath': null});
    expect(result, 'content://tree/anywhere');
    expect(find.text('Where to save'), findsNothing);
  });

  testWidgets('backing out of the picker shows the explicit ways out', (
    tester,
  ) async {
    mockPickTreeReplies([null]);
    final run = await pumpPrompt(
      tester,
      '/storage/emulated/0/Documents/Work',
      (_) {},
    );
    run();
    await tester.pumpAndSettle();

    expect(find.text('Where to save'), findsOneWidget);
    expect(find.textContaining('"Work"'), findsOneWidget);
    expect(
      find.textContaining('the folder these files came from'),
      findsOneWidget,
    );
    expect(find.text('Choose folder'), findsOneWidget);
    expect(find.text('Use Downloads'), findsOneWidget);
  });

  testWidgets('the unknown-folder dialog asks for any destination', (
    tester,
  ) async {
    mockPickTreeReplies([null]);
    final run = await pumpPrompt(tester, null, (_) {});
    run();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('can\'t tell which folder these files came from'),
      findsOneWidget,
    );
    expect(find.text('Choose folder'), findsOneWidget);
  });

  testWidgets('"Use Downloads" returns null without reopening the picker', (
    tester,
  ) async {
    mockPickTreeReplies([null, 'content://tree/never']);
    String? result = 'unset';
    final run = await pumpPrompt(
      tester,
      '/storage/emulated/0/Documents',
      (r) => result = r,
    );
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use Downloads'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(
      calls.single.method,
      'openTree',
      reason: 'declining must not reopen the folder picker',
    );
  });

  testWidgets(
    '"Choose folder" reopens the picker at the source folder and grants',
    (tester) async {
      mockPickTreeReplies([null, 'content://tree/custom']);
      String? result;
      final run = await pumpPrompt(
        tester,
        '/storage/emulated/0/Documents',
        (r) => result = r,
      );
      run();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose folder'));
      await tester.pumpAndSettle();

      expect(calls, hasLength(2));
      expect(calls[1].method, 'openTree');
      expect(
        calls[1].arguments,
        {'initialPath': '/storage/emulated/0/Documents'},
        reason: 'the custom-location picker starts where the files came from',
      );
      expect(result, 'content://tree/custom');
    },
  );

  testWidgets('an unknown folder reopens the picker unseeded', (tester) async {
    mockPickTreeReplies([null, 'content://tree/anywhere']);
    String? result;
    final run = await pumpPrompt(tester, null, (r) => result = r);
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(2));
    expect(calls[1].arguments, {'initialPath': null});
    expect(result, 'content://tree/anywhere');
  });

  testWidgets('cancelling the second picker returns null', (tester) async {
    mockPickTreeReplies([null, null]);
    String? result = 'unset';
    final run = await pumpPrompt(
      tester,
      '/storage/emulated/0/Documents',
      (r) => result = r,
    );
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(2));
    expect(result, isNull);
  });

  testWidgets('dismissing the dialog counts as declining', (tester) async {
    mockPickTreeReplies([null, 'content://tree/never']);
    String? result = 'unset';
    final run = await pumpPrompt(
      tester,
      '/storage/emulated/0/Documents',
      (r) => result = r,
    );
    run();
    await tester.pumpAndSettle();
    // Tap the barrier outside the dialog: showDialog completes with null.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(calls, hasLength(1), reason: 'no picker reopen after a dismiss');
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
    final run = await pumpPrompt(
      tester,
      '/storage/emulated/0/Documents',
      (r) => result = r,
    );
    run();
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
                result = await promptSaveFolder(context, '/storage/x');
            return const SizedBox();
          },
        ),
      ),
    );
    run();
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
}
