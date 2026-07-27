import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/save_folder_prompt.dart';
import 'package:latch/core/saf_bridge.dart';

/// The folder-grant dialog: what it says, and what it does with each answer.
/// It is the only thing standing between the user and a silent Downloads
/// fallback, so both branches (grant / decline) are pinned here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() => calls = []);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, null);
  });

  void mockPickTree(Object? reply) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          return reply;
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

  testWidgets('names the source folder and offers both ways out', (
    tester,
  ) async {
    mockPickTree(null);
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

  testWidgets('an unknown source folder asks for any destination', (
    tester,
  ) async {
    mockPickTree(null);
    final run = await pumpPrompt(tester, null, (_) {});
    run();
    await tester.pumpAndSettle();

    expect(
      find.textContaining('can\'t tell which folder these files came from'),
      findsOneWidget,
    );
    expect(find.text('Choose folder'), findsOneWidget);
  });

  testWidgets('"Choose folder" opens the picker seeded at the folder', (
    tester,
  ) async {
    mockPickTree('content://tree/granted');
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

    expect(calls.single.method, 'openTree');
    expect(
      calls.single.arguments,
      {'initialPath': '/storage/emulated/0/Documents'},
      reason: 'the picker opens at the folder the files came from',
    );
    expect(result, 'content://tree/granted');
  });

  testWidgets('an unknown folder opens the picker unseeded', (tester) async {
    mockPickTree('content://tree/anywhere');
    String? result;
    final run = await pumpPrompt(tester, null, (r) => result = r);
    run();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();

    expect(calls.single.arguments, {'initialPath': null});
    expect(result, 'content://tree/anywhere');
  });

  testWidgets('"Use Downloads" returns null without opening the picker', (
    tester,
  ) async {
    mockPickTree('content://tree/never');
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
    expect(calls, isEmpty, reason: 'declining must not open the folder picker');
  });

  testWidgets('dismissing the dialog counts as declining', (tester) async {
    mockPickTree('content://tree/never');
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
    expect(calls, isEmpty);
  });

  testWidgets('cancelling the system picker returns null', (tester) async {
    mockPickTree(null); // openTree → null = user backed out of the picker
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

    expect(calls.single.method, 'openTree');
    expect(result, isNull);
  });
}
