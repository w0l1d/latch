import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latch/core/bulk_plan.dart';
import 'package:latch/core/bulk_settings.dart';
import 'package:latch/core/saf_bridge.dart';
import 'package:latch/features/decrypt/decrypt_folder_screen.dart';
import 'package:latch/features/decrypt/decrypt_bulk_progress_screen.dart';
import 'package:latch/features/encrypt/encrypt_bulk_progress_screen.dart';
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

  group('destination defaults to the grant just taken', () {
    const other = 'content://tree/primary%3AElsewhere';
    setUp(() {
      SharedPreferences.setMockInitialValues({
        BulkSettings.outputPlacementKey: BulkPlacement.mirroredFolder.name,
      });
    });

    BulkDestination sent() =>
        (lastExtra as Map)['bulk']['destination'] as BulkDestination;

    Future<void> pickSource(WidgetTester tester) async {
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
    }

    testWidgets('encrypt: mirrored layout is ready right after the pick', (
      tester,
    ) async {
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async => _inv(BulkMode.encrypt),
          ),
          '/encrypt/passphrase',
        ),
      );
      await pickSource(tester);
      expect(find.text('No folder chosen yet'), findsNothing);

      await tester.tap(find.text('Set a passphrase'));
      await tester.pumpAndSettle();
      expect(sent().placement, BulkPlacement.mirroredFolder);
      expect(sent().treeUri, _tree);
    });

    testWidgets('decrypt: mirrored layout is ready right after the pick', (
      tester,
    ) async {
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          DecryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async => _inv(BulkMode.decrypt),
          ),
          '/decrypt/passphrase',
        ),
      );
      await pickSource(tester);
      expect(find.text('No folder chosen yet'), findsNothing);

      await tester.tap(find.text('Enter passphrase'));
      await tester.pumpAndSettle();
      expect(sent().treeUri, _tree);
    });

    testWidgets('a folder the user chose is not replaced by a later pick', (
      tester,
    ) async {
      var picks = 0;
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickTree: () async => picks++ == 0 ? _tree : 'content://tree/next',
            enumerateTree: (u, rec) async => _inv(BulkMode.encrypt),
            pickDestination: (_) async =>
                (dir: null, treeUri: other, label: 'Elsewhere'),
          ),
          '/encrypt/passphrase',
        ),
      );
      await pickSource(tester);
      await tester.tap(find.text('Change'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose a different folder'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Set a passphrase'));
      await tester.pumpAndSettle();
      expect(sent().treeUri, other);
    });

    testWidgets('a grant defaulted from the source follows a new source', (
      tester,
    ) async {
      var picks = 0;
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickTree: () async => picks++ == 0 ? _tree : 'content://tree/next',
            enumerateTree: (u, rec) async => _inv(BulkMode.encrypt),
          ),
          '/encrypt/passphrase',
        ),
      );
      await pickSource(tester);
      await tester.tap(find.text('Choose a different folder'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Set a passphrase'));
      await tester.pumpAndSettle();
      expect(sent().treeUri, 'content://tree/next');
    });

    testWidgets('the default is per run and never saved', (tester) async {
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (u, rec) async => _inv(BulkMode.encrypt),
          ),
          '/encrypt/passphrase',
        ),
      );
      await pickSource(tester);
      expect(
        await BulkSettings.outputPlacement(),
        BulkPlacement.mirroredFolder,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), {BulkSettings.outputPlacementKey});
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

  group('what the user is told while waiting', () {
    testWidgets('the scan spinner names what it is doing (encrypt)', (
      tester,
    ) async {
      final listing = Completer<BulkInventory>();
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (_, _) => listing.future,
          ),
          '/encrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Looking through the folder…'), findsOneWidget);
      expect(find.bySemanticsLabel('Reading the folder'), findsOneWidget);

      listing.complete(_inv(BulkMode.encrypt));
      await tester.pumpAndSettle();
      expect(find.text('Looking through the folder…'), findsNothing);
    });

    testWidgets('the scan spinner names what it is doing (decrypt)', (
      tester,
    ) async {
      final listing = Completer<BulkInventory>();
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          DecryptFolderScreen(
            pickTree: () async => _tree,
            enumerateTree: (_, _) => listing.future,
          ),
          '/decrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Looking through the folder…'), findsOneWidget);
      listing.complete(_inv(BulkMode.decrypt));
      await tester.pumpAndSettle();
    });

    for (final decrypt in [false, true]) {
      testWidgets(
        '${decrypt ? 'unlock' : 'lock'} review warns about the second copy on a grant',
        (tester) async {
          await _tall(tester);
          final mode = decrypt ? BulkMode.decrypt : BulkMode.encrypt;
          await tester.pumpWidget(
            _app(
              decrypt
                  ? DecryptFolderScreen(
                      pickTree: () async => _tree,
                      enumerateTree: (_, _) async => _inv(mode),
                    )
                  : EncryptFolderScreen(
                      pickTree: () async => _tree,
                      enumerateTree: (_, _) async => _inv(mode),
                    ),
              decrypt ? '/decrypt/passphrase' : '/encrypt/passphrase',
            ),
          );
          await tester.tap(find.text('Choose a folder'));
          await tester.pumpAndSettle();
          expect(find.text(bulkStagingNote), findsOneWidget);
        },
      );
    }

    testWidgets('a folder read by path is not staged, so no warning', (
      tester,
    ) async {
      await _tall(tester);
      await tester.pumpWidget(
        _app(
          EncryptFolderScreen(
            pickFolder: () async => '/storage/Docs',
            enumerate: (r, rec) async => BulkInventory(
              root: r,
              mode: BulkMode.encrypt,
              recursive: rec,
              items: [_item('a.txt', 'a.txt.latch')],
              skipped: const [],
              subfolders: 0,
              excludedInSubfolders: 0,
              alreadyContainers: 0,
            ),
          ),
          '/encrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      expect(find.text(bulkStagingNote), findsNothing);
    });
  });

  group('staging progress', () {
    late List<Completer<void>> copies;

    setUp(() {
      copies = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) {
            if (call.method != 'copyToCache') return Future.value(null);
            final c = Completer<void>();
            copies.add(c);
            return c.future;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, null);
    });

    for (final decrypt in [false, true]) {
      testWidgets(
        '${decrypt ? 'unlock' : 'lock'} shows copied-of-total while reading',
        (tester) async {
          final mode = decrypt ? BulkMode.decrypt : BulkMode.encrypt;
          final inv = _inv(mode, files: 3);
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(),
              home: decrypt
                  ? DecryptBulkProgressScreen(
                      inventory: inv,
                      passphrase: 'x',
                      deleteSources: false,
                    )
                  : EncryptBulkProgressScreen(
                      inventory: inv,
                      passphrase: 'x',
                      deleteSources: false,
                    ),
            ),
          );
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();

          expect(find.text('Reading your files…'), findsOneWidget);
          expect(find.text('0 of 3'), findsOneWidget);

          await tester.runAsync(() async {
            copies[0].complete();
            await Future<void>.delayed(Duration.zero);
          });
          await tester.pump();
          expect(find.text('1 of 3'), findsOneWidget);

          // Leaving the screen stops the copy: the second is never followed
          // by a third.
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(() async {
            copies[1].complete();
            await Future<void>.delayed(Duration.zero);
          });
          expect(copies, hasLength(2));
        },
      );
    }
  });
}
