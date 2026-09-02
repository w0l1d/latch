import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/saf_bridge.dart';
import 'package:latch/features/encrypt/encrypt_options_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The encrypt options screen's custom-output-folder picker (Android) must
/// start at the folder the files came from — "choose a different folder"
/// begins somewhere familiar, not at the storage root. Pinned through the
/// platformIsAndroid seam since widget tests run off-device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, null);
  });

  void mockChannel(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          return handler(call);
        });
  }

  Future<void> pumpScreen(WidgetTester tester, List<String> files) async {
    await tester.pumpWidget(
      MaterialApp(
        home: EncryptOptionsScreen(
          files: files,
          passphrase: 'pw',
          platformIsAndroid: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapChooseFolder(WidgetTester tester) async {
    await tester.tap(find.text('Same folder as each original'));
    await tester.pumpAndSettle();
  }

  MethodCall openTreeCall() =>
      calls.where((c) => c.method == 'openTree').single;

  testWidgets('choose folder seeds the picker at the source file\'s folder', (
    tester,
  ) async {
    SafBridge.rememberUri('/cache/seeded.pdf', 'content://doc/seeded');
    mockChannel(
      (call) => switch (call.method) {
        'resolvePath' => '/storage/emulated/0/Documents/Work/seeded.pdf',
        'openTree' => 'content://tree/work',
        'treeUriToPath' => '/storage/emulated/0/Documents/Work',
        _ => null,
      },
    );
    await pumpScreen(tester, ['/cache/seeded.pdf']);
    await tapChooseFolder(tester);

    expect(
      calls.map((c) => c.method),
      orderedEquals(['resolvePath', 'openTree', 'treeUriToPath']),
      reason: 'the source folder is resolved before the picker opens',
    );
    expect(
      openTreeCall().arguments,
      {
        'initialPath': '/storage/emulated/0/Documents/Work',
        'initialDocUri': 'content://doc/seeded',
      },
      reason: 'the picker starts where the file came from',
    );
    // The row reflects the chosen folder (setState after the grant).
    expect(find.text('Work'), findsOneWidget);
  });

  testWidgets('the first file\'s folder seeds the picker when folders differ', (
    tester,
  ) async {
    SafBridge.rememberUri('/cache/first.pdf', 'content://doc/first');
    SafBridge.rememberUri('/cache/second.pdf', 'content://doc/second');
    mockChannel((call) {
      if (call.method == 'resolvePath') {
        return call.arguments['uri'] == 'content://doc/first'
            ? '/storage/emulated/0/Documents/first.pdf'
            : '/storage/emulated/0/Pictures/second.pdf';
      }
      if (call.method == 'openTree') return 'content://tree/x';
      if (call.method == 'treeUriToPath') {
        return '/storage/emulated/0/Documents';
      }
      return null;
    });
    await pumpScreen(tester, ['/cache/first.pdf', '/cache/second.pdf']);
    await tapChooseFolder(tester);

    expect(
      calls.where((c) => c.method == 'resolvePath'),
      hasLength(1),
      reason: 'only the first file\'s folder is resolved for seeding',
    );
    expect(openTreeCall().arguments, {
      'initialPath': '/storage/emulated/0/Documents',
      'initialDocUri': 'content://doc/first',
    });
  });

  testWidgets('an unresolvable folder still seeds the picker by document', (
    tester,
  ) async {
    // The picker's Downloads/Images/Videos shortcuts hand over a document
    // whose folder Android will not name (resolvePath → null). There is no
    // path to seed with, but the document URI itself is a valid seed — the
    // system navigator resolves its parent, which is the whole reason this
    // case no longer dumps the user at the storage root.
    SafBridge.rememberUri('/cache/shortcut.pdf', 'content://doc/msf-123');
    mockChannel(
      (call) => call.method == 'openTree' ? 'content://tree/any' : null,
    );
    await pumpScreen(tester, ['/cache/shortcut.pdf']);
    await tapChooseFolder(tester);

    expect(calls.where((c) => c.method == 'resolvePath'), hasLength(1));
    expect(openTreeCall().arguments, {
      'initialPath': null,
      'initialDocUri': 'content://doc/msf-123',
    });
  });

  testWidgets(
    'a source with no content URI at all leaves the picker unseeded',
    (tester) async {
      // No rememberUri: share-intent files have no registered content URI, so
      // neither seed exists — best-effort means unseeded, not broken.
      mockChannel(
        (call) => call.method == 'openTree' ? 'content://tree/any' : null,
      );
      await pumpScreen(tester, ['/cache/lonely.pdf']);
      await tapChooseFolder(tester);

      expect(calls.where((c) => c.method == 'resolvePath'), isEmpty);
      expect(openTreeCall().arguments, {
        'initialPath': null,
        'initialDocUri': null,
      });
    },
  );

  testWidgets('cancelling the picker keeps the default destination', (
    tester,
  ) async {
    mockChannel((call) => null); // openTree → null = user backed out
    await pumpScreen(tester, ['/cache/cancel.pdf']);
    await tapChooseFolder(tester);

    expect(
      find.text('Same folder as each original'),
      findsOneWidget,
      reason: 'a cancelled picker must not change the output destination',
    );
    expect(calls.where((c) => c.method == 'treeUriToPath'), isEmpty);
  });
}
