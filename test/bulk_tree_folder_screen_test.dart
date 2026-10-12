import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latch/core/bulk_plan.dart';
import 'package:latch/core/bulk_settings.dart';
import 'package:latch/features/decrypt/decrypt_folder_screen.dart';
import 'package:latch/features/encrypt/encrypt_folder_screen.dart';
import 'package:latch/shared/theme/app_theme.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tree = 'content://tree/primary%3ADocs';

BulkItem _item(String name, String out) => BulkItem(
  sourcePath: '/cache/latch_src/Docs/$name',
  relativePath: name,
  sizeBytes: 10,
  stampAtEnumeration: EntryStamp(
    kind: EntryKind.file,
    sizeBytes: 10,
    modified: DateTime(2026),
  ),
  outRelPath: out,
  docUri: 'content://doc/$name',
);

BulkInventory _inv(BulkMode mode, {int files = 3, bool recursive = false}) =>
    BulkInventory(
      root: '/cache/latch_src/Docs',
      mode: mode,
      recursive: recursive,
      items: [
        for (var i = 0; i < files; i++)
          mode == BulkMode.encrypt
              ? _item('f$i.txt', 'f$i.txt.latch')
              : _item('f$i.txt.latch', 'f$i.txt'),
      ],
      skipped: const [],
      subfolders: recursive ? 2 : 0,
      excludedInSubfolders: 0,
      alreadyContainers: 0,
      sourceTreeUri: _tree,
    );

Object? lastExtra;

Widget _app(Widget home, String continueRoute) => MaterialApp.router(
  theme: buildTheme(),
  routerConfig: GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => home),
      GoRoute(
        path: continueRoute,
        builder: (_, s) {
          lastExtra = s.extra;
          return const Scaffold(body: Text('NEXT'));
        },
      ),
      GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
    ],
  ),
);

Future<void> _tall(WidgetTester tester) async {
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  setUp(() {
    lastExtra = null;
    SharedPreferences.setMockInitialValues({
      BulkSettings.outputPlacementKey: BulkPlacement.besideOriginals.name,
    });
  });

  group('encrypt folder, picked as a grant', () {
    testWidgets('lists the files the grant can see and carries the grant on', (
      tester,
    ) async {
      final picked = <String>[];
      final listed = <(String, bool)>[];
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickFolder: null,
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async {
              listed.add((u, rec));
              return _inv(BulkMode.encrypt, files: 4, recursive: rec);
            },
            pickDestination: (_) async {
              picked.add('dest');
              return null;
            },
          ),
          '/encrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();

      expect(listed, [(_tree, false)]);
      expect(find.textContaining('4 files ·'), findsOneWidget);
      expect(find.text('There is nothing to lock here.'), findsNothing);

      await tester.tap(find.text('Set a passphrase'));
      await tester.pumpAndSettle();
      final bulk = (lastExtra as Map)['bulk'] as Map;
      expect((bulk['inventory'] as BulkInventory).sourceTreeUri, _tree);
      expect(picked, isEmpty);
    });

    testWidgets('Include subfolders re-lists through the same grant', (
      tester,
    ) async {
      final listed = <(String, bool)>[];
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async {
              listed.add((u, rec));
              return _inv(BulkMode.encrypt, files: rec ? 9 : 2, recursive: rec);
            },
          ),
          '/encrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 files ·'), findsOneWidget);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('9 files ·'), findsOneWidget);
      expect(listed, [(_tree, false), (_tree, true)]);
    });

    testWidgets('a folder the grant shows as empty still says so', (
      tester,
    ) async {
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async => _inv(BulkMode.encrypt, files: 0),
          ),
          '/encrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      expect(
        find.text('There is nothing to lock here.', skipOffstage: false),
        findsOneWidget,
      );
    });

    testWidgets('backing out of the picker changes nothing', (tester) async {
      var listed = 0;
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickTree: () async => null,
            enumerateTree: (u, rec) async {
              listed++;
              return _inv(BulkMode.encrypt);
            },
          ),
          '/encrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      expect(listed, 0);
      expect(find.text('Choose a folder'), findsWidgets);
    });

    testWidgets('a listing failure shows the error, not an empty folder', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async => throw StateError('denied'),
          ),
          '/encrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Couldn\'t read that folder'), findsOneWidget);
      expect(find.textContaining('nothing to lock'), findsNothing);
    });

    testWidgets('the path flow is untouched when only pickFolder is given', (
      tester,
    ) async {
      var treeCalls = 0;
      final roots = <String>[];
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickFolder: () async => '/r',
            enumerate: (root, rec) async {
              roots.add(root);
              return BulkInventory(
                root: '/r',
                mode: BulkMode.encrypt,
                recursive: rec,
                items: const [],
                skipped: const [],
                subfolders: 0,
                excludedInSubfolders: 0,
                alreadyContainers: 0,
              );
            },
            enumerateTree: (u, rec) async {
              treeCalls++;
              return _inv(BulkMode.encrypt);
            },
          ),
          '/encrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      expect(roots, ['/r']);
      expect(treeCalls, 0);
    });
  });

  group('decrypt folder, picked as a grant', () {
    testWidgets('lists the locked files and carries the grant on', (
      tester,
    ) async {
      final listed = <(String, bool)>[];
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          DecryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async {
              listed.add((u, rec));
              return _inv(BulkMode.decrypt, files: 5, recursive: rec);
            },
          ),
          '/decrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      expect(listed, [(_tree, false)]);
      expect(find.textContaining('5 locked files ·'), findsOneWidget);

      await tester.tap(find.text('Enter passphrase'));
      await tester.pumpAndSettle();
      final bulk = (lastExtra as Map)['bulk'] as Map;
      expect((bulk['inventory'] as BulkInventory).sourceTreeUri, _tree);
    });

    testWidgets('Include subfolders re-lists through the same grant', (
      tester,
    ) async {
      final listed = <(String, bool)>[];
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          DecryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async {
              listed.add((u, rec));
              return _inv(BulkMode.decrypt, files: rec ? 8 : 1, recursive: rec);
            },
          ),
          '/decrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('8 locked files ·'), findsOneWidget);
      expect(listed, [(_tree, false), (_tree, true)]);
    });

    testWidgets('a folder with no containers says so and cannot continue', (
      tester,
    ) async {
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          DecryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async => _inv(BulkMode.decrypt, files: 0),
          ),
          '/decrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'There are no .latch files to unlock here.',
          skipOffstage: false,
        ),
        findsOneWidget,
      );
      final btn = tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text('Enter passphrase'),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(btn.onPressed, isNull);
    });
  });
}
