import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/saf_bridge.dart';
import 'package:latch/features/settings/save_folders_screen.dart';

/// Rows shaped the way `listTreeGrants` on the native side shapes them.
Map<String, Object?> _row(
  String id, {
  String? path,
  String? label,
  int grantedAt = 0,
}) => {
  'uri': 'content://tree/$id',
  'path': path,
  'label': label ?? path ?? id,
  'grantedAt': grantedAt,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  /// Serves a mutable grant table so a revoke can actually change what the
  /// screen sees on its reload — the whole point of not caching the list.
  void mockPlatform({
    required List<Map<String, Object?>> Function() grants,
    int limit = 512,
    bool releaseSucceeds = true,
  }) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'listTreeGrants':
              return {'grants': grants(), 'limit': limit};
            case 'releaseTreeGrant':
              return releaseSucceeds;
          }
          return null;
        });
  }

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, null);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SaveFoldersScreen()));
    await tester.pumpAndSettle();
  }

  group('Save folders', () {
    testWidgets('lists every granted folder with its full path', (
      tester,
    ) async {
      mockPlatform(
        grants: () => [
          _row('docs', path: '/storage/emulated/0/Documents'),
          _row('work', path: '/storage/emulated/0/Documents/Work'),
        ],
      );
      await pumpScreen(tester);

      expect(find.text('Documents'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      // The path disambiguates two folders that share a basename.
      expect(find.text('/storage/emulated/0/Documents/Work'), findsOneWidget);
      expect(find.text('2 folders'), findsOneWidget);
      // A count nobody is near must not invite "of what?".
      expect(find.textContaining('512'), findsNothing);
      expect(find.byIcon(Icons.link_off), findsNWidgets(2));
    });

    testWidgets('a grant with no filesystem path still shows a name', (
      tester,
    ) async {
      mockPlatform(
        grants: () => [_row('cloud%3Aabc', path: null, label: 'Team drive')],
      );
      await pumpScreen(tester);

      expect(find.text('Team drive'), findsOneWidget);
      expect(find.text('1 folder'), findsOneWidget);
    });

    testWidgets('names the ceiling only when it is close', (tester) async {
      mockPlatform(
        grants: () =>
            List.generate(102, (i) => _row('f$i', path: '/storage/f$i')),
        limit: 128,
      );
      await pumpScreen(tester);

      expect(
        find.text('102 of 128 folders this device allows'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Android drops the oldest folder'),
        findsOneWidget,
      );
    });

    testWidgets('empty state explains when Latch will ask', (tester) async {
      mockPlatform(grants: () => []);
      await pumpScreen(tester);

      expect(
        find.textContaining('cannot save to any folder yet'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.link_off), findsNothing);
    });

    testWidgets('platform failure renders as no access, not an error', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) async {
            throw PlatformException(code: 'saf_error');
          });
      await pumpScreen(tester);

      expect(
        find.textContaining('cannot save to any folder yet'),
        findsOneWidget,
      );
    });

    testWidgets('revoke asks first, and Keep changes nothing', (tester) async {
      mockPlatform(
        grants: () => [_row('docs', path: '/storage/emulated/0/Documents')],
      );
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.link_off));
      await tester.pumpAndSettle();
      expect(find.text('Stop saving to this folder?'), findsOneWidget);
      // The dialog must say no file is touched.
      expect(find.textContaining('untouched'), findsOneWidget);

      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'releaseTreeGrant'),
        isEmpty,
        reason: 'declining the dialog must not touch the grant',
      );
      expect(find.text('Documents'), findsOneWidget);
    });

    testWidgets('revoke releases the grant and re-reads the table', (
      tester,
    ) async {
      var table = [
        _row('docs', path: '/storage/emulated/0/Documents'),
        _row('work', path: '/storage/emulated/0/Documents/Work'),
      ];
      mockPlatform(grants: () => table);
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.link_off).first);
      await tester.pumpAndSettle();
      table = [_row('work', path: '/storage/emulated/0/Documents/Work')];
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();

      final release = calls.singleWhere((c) => c.method == 'releaseTreeGrant');
      expect(release.arguments, {'uri': 'content://tree/docs'});
      // The list is the platform's answer, not a locally-removed row.
      expect(
        calls.where((c) => c.method == 'listTreeGrants').length,
        2,
        reason: 'the table must be re-read after a revoke',
      );
      expect(find.text('Documents'), findsNothing);
      expect(find.text('1 folder'), findsOneWidget);
    });

    testWidgets('a refused revoke says so and keeps the row', (tester) async {
      mockPlatform(
        grants: () => [_row('docs', path: '/storage/emulated/0/Documents')],
        releaseSucceeds: false,
      );
      await pumpScreen(tester);

      await tester.tap(find.byIcon(Icons.link_off));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();

      expect(
        find.text('Android would not release this folder.'),
        findsOneWidget,
      );
      expect(find.text('Documents'), findsOneWidget);
    });
  });
}
