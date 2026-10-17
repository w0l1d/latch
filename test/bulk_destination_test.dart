import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latch/core/bulk_plan.dart';
import 'package:latch/core/bulk_settings.dart';
import 'package:latch/features/decrypt/decrypt_folder_screen.dart';
import 'package:latch/features/encrypt/encrypt_folder_screen.dart';
import 'package:latch/shared/theme/app_theme.dart';
import 'package:latch/shared/widgets/bulk_destination_section.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

BulkItem _item(String rel, {String suffix = '.latch'}) => BulkItem(
  sourcePath: '/r/$rel',
  relativePath: rel,
  sizeBytes: 10,
  stampAtEnumeration: EntryStamp(
    kind: EntryKind.file,
    sizeBytes: 10,
    modified: DateTime(2026),
  ),
  outRelPath: '$rel$suffix',
);

BulkInventory _inv(List<String> rels, {BulkMode mode = BulkMode.encrypt}) =>
    BulkInventory(
      root: '/r',
      mode: mode,
      recursive: true,
      items: [for (final r in rels) _item(r)],
      skipped: const [],
      subfolders: 1,
      excludedInSubfolders: 0,
      alreadyContainers: 0,
    );

void main() {
  group('BulkDestination', () {
    test('beside-originals is ready without a folder', () {
      const d = BulkDestination(placement: BulkPlacement.besideOriginals);
      expect(d.needsFolder, isFalse);
      expect(d.isReady, isTrue);
    });

    test('mirrored and flat are not ready until a folder is chosen', () {
      for (final p in [
        BulkPlacement.mirroredFolder,
        BulkPlacement.flatFolder,
      ]) {
        final d = BulkDestination(placement: p);
        expect(d.needsFolder, isTrue);
        expect(d.isReady, isFalse);
        expect(d.withFolder(dir: '/out').isReady, isTrue);
        expect(d.withFolder(treeUri: 'content://t').isReady, isTrue);
      }
    });

    test('default placement is a mirrored folder', () {
      expect(const BulkDestination().placement, BulkPlacement.mirroredFolder);
    });

    test('a folder picked earlier is ignored by the planner under beside', () {
      final d = const BulkDestination(
        placement: BulkPlacement.mirroredFolder,
      ).withFolder(dir: '/out', treeUri: 'content://t');
      expect(d.plannerDir, '/out');
      expect(d.plannerTreeUri, 'content://t');
      final beside = d.withPlacement(BulkPlacement.besideOriginals);
      expect(beside.plannerDir, isNull);
      expect(beside.plannerTreeUri, isNull);
      expect(beside.dir, '/out', reason: 'kept so switching back is free');
    });

    test('switching placement keeps the picked folder', () {
      final d = const BulkDestination()
          .withFolder(dir: '/out', label: '/out')
          .withPlacement(BulkPlacement.flatFolder);
      expect(d.dir, '/out');
      expect(d.label, '/out');
      expect(d.placement, BulkPlacement.flatFolder);
    });
  });

  group('BulkPlan.applyPlacement', () {
    final items = [_item('a.txt'), _item('sub/deep/b.txt'), _item('sub/a.txt')];

    test('mirrored and beside leave the relative layout alone', () {
      for (final p in [
        BulkPlacement.mirroredFolder,
        BulkPlacement.besideOriginals,
      ]) {
        expect(BulkPlan.applyPlacement(items, p), same(items));
      }
    });

    test('flat strips every directory and keeps one entry per input', () {
      final out = BulkPlan.applyPlacement(items, BulkPlacement.flatFolder);
      expect(out.map((i) => i.outRelPath), [
        'a.txt.latch',
        'b.txt.latch',
        'a.txt.latch',
      ]);
      expect(out.map((i) => i.sourcePath), items.map((i) => i.sourcePath));
    });

    test('flat also strips backslash separators', () {
      final out = BulkPlan.applyPlacement([
        BulkItem(
          sourcePath: '/r/x',
          relativePath: r'sub\x',
          sizeBytes: 1,
          stampAtEnumeration: items.first.stampAtEnumeration,
          outRelPath: r'sub\x.latch',
        ),
      ], BulkPlacement.flatFolder);
      expect(out.single.outRelPath, 'x.latch');
    });
  });

  group('bulkSavedWhere', () {
    String where(
      BulkDestination? d, {
      bool fell = false,
      String first = '/r/sub/a.latch',
    }) => bulkSavedWhere(
      destination: d,
      firstOut: first,
      fellBackToDownloads: fell,
      sourceNoun: 'originals',
    );

    test('no destination reads as beside the originals', () {
      expect(where(null), 'Saved under /r/sub.');
    });

    test('beside names the folder, and the Downloads fallback honestly', () {
      const d = BulkDestination(placement: BulkPlacement.besideOriginals);
      expect(where(d), 'Saved under /r/sub.');
      expect(where(d, fell: true), contains('saved to Downloads instead'));
      expect(where(d, fell: true), contains('beside the originals'));
    });

    test('mirrored names the picked folder and the layout', () {
      final d = const BulkDestination().withFolder(
        dir: '/x/Out',
        label: '/x/Out',
      );
      expect(where(d), 'Saved in Out, with the same folder layout.');
      expect(where(d, fell: true), contains('saved to Downloads instead'));
    });

    test('flat names the folder and says duplicates were numbered', () {
      final d = const BulkDestination(
        placement: BulkPlacement.flatFolder,
      ).withFolder(dir: '/x/Out', label: '/x/Out');
      expect(where(d), startsWith('Saved together in Out.'));
      expect(where(d), contains('given a number'));
    });

    test('a folder with no readable label still gets a plain name', () {
      final d = const BulkDestination().withFolder(treeUri: 'content://t');
      expect(bulkFolderName(d), 'A folder you picked');
    });
  });

  group('BulkDestinationSection', () {
    Widget host(
      BulkDestination initial,
      void Function(BulkDestination) seen, {
      BulkFolderPicker? pick,
      bool decrypt = false,
    }) {
      var value = initial;
      return MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => SingleChildScrollView(
              child: BulkDestinationSection(
                value: value,
                sourceRoot: '/r',
                decrypt: decrypt,
                pickFolder: pick,
                onChanged: (d) {
                  seen(d);
                  setState(() => value = d);
                },
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('choosing a folder reports it and shows its name', (
      tester,
    ) async {
      BulkDestination? last;
      await tester.pumpWidget(
        host(
          const BulkDestination(),
          (d) => last = d,
          pick: (root) async {
            expect(root, '/r');
            return (dir: '/x/Out', treeUri: null, label: '/x/Out');
          },
        ),
      );
      expect(find.text('No folder chosen yet'), findsOneWidget);
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(last?.dir, '/x/Out');
      expect(find.text('Out'), findsOneWidget);
      expect(find.text('Change'), findsOneWidget);
    });

    testWidgets('backing out of the picker changes nothing', (tester) async {
      var calls = 0;
      await tester.pumpWidget(
        host(const BulkDestination(), (_) => calls++, pick: (_) async => null),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('No folder chosen yet'), findsOneWidget);
    });

    testWidgets('a picker that throws is reported, not propagated', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          const BulkDestination(),
          (_) {},
          pick: (_) async => throw StateError('no handler'),
        ),
      );
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(find.text('Could not open the folder picker.'), findsOneWidget);
    });

    testWidgets('beside hides the folder row; other choices show it', (
      tester,
    ) async {
      BulkDestination? last;
      await tester.pumpWidget(host(const BulkDestination(), (d) => last = d));
      await tester.tap(find.text('Next to each original'));
      await tester.pumpAndSettle();
      expect(last?.placement, BulkPlacement.besideOriginals);
      expect(find.text('No folder chosen yet'), findsNothing);
      await tester.tap(find.text('One folder, all together'));
      await tester.pumpAndSettle();
      expect(last?.placement, BulkPlacement.flatFolder);
      expect(find.text('No folder chosen yet'), findsOneWidget);
    });

    testWidgets('decrypt wording talks about locked files', (tester) async {
      await tester.pumpWidget(
        host(const BulkDestination(), (_) {}, decrypt: true),
      );
      expect(find.text('Where the unlocked files go'), findsOneWidget);
      expect(find.text('Next to each locked file'), findsOneWidget);
    });
  });

  group('per-run override (FR-029)', () {
    Object? extra;
    Widget app(Widget home, String route) => MaterialApp.router(
      theme: buildTheme(),
      routerConfig: GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => home),
          GoRoute(
            path: route,
            builder: (_, s) {
              extra = s.extra;
              return const Scaffold(body: Text('NEXT'));
            },
          ),
        ],
      ),
    );

    setUp(() {
      extra = null;
      SharedPreferences.setMockInitialValues({});
    });

    Future<void> tall(WidgetTester t) async {
      t.view.physicalSize = const Size(800, 2600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
    }

    testWidgets('encrypt: starts from the saved default, never writes back', (
      tester,
    ) async {
      await tall(tester);
      SharedPreferences.setMockInitialValues({
        BulkSettings.outputPlacementKey: BulkPlacement.flatFolder.name,
      });
      await tester.pumpWidget(
        app(
          EncryptFolderScreen(
            pickFolder: () async => '/r',
            enumerate: (_, _) async => _inv(['a']),
            pickDestination: (_) async =>
                (dir: '/x/Out', treeUri: null, label: '/x/Out'),
          ),
          '/encrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RadioGroup<BulkPlacement>>(
              find.byType(RadioGroup<BulkPlacement>),
            )
            .groupValue,
        BulkPlacement.flatFolder,
      );
      ElevatedButton btn() => tester.widget<ElevatedButton>(
        find.ancestor(
          of: find.text('Set a passphrase'),
          matching: find.byType(ElevatedButton),
        ),
      );
      expect(btn().onPressed, isNull, reason: 'no folder picked yet');

      await tester.tap(find.text('One folder, same layout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose'));
      await tester.pumpAndSettle();
      expect(btn().onPressed, isNotNull);
      await tester.tap(find.text('Set a passphrase'));
      await tester.pumpAndSettle();

      final dest =
          ((extra as Map)['bulk'] as Map)['destination'] as BulkDestination;
      expect(dest.placement, BulkPlacement.mirroredFolder);
      expect(dest.dir, '/x/Out');
      expect(
        await BulkSettings.outputPlacement(),
        BulkPlacement.flatFolder,
        reason: 'a one-run override must not change the saved default',
      );
    });

    testWidgets('decrypt: beside needs no pick and is forwarded', (
      tester,
    ) async {
      await tall(tester);
      SharedPreferences.setMockInitialValues({
        BulkSettings.outputPlacementKey: BulkPlacement.besideOriginals.name,
      });
      await tester.pumpWidget(
        app(
          DecryptFolderScreen(
            pickFolder: () async => '/r',
            enumerate: (_, _) async => _inv(['a'], mode: BulkMode.decrypt),
          ),
          '/decrypt/passphrase',
        ),
      );
      await tester.tap(find.text('Choose a folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enter passphrase'));
      await tester.pumpAndSettle();
      final dest =
          ((extra as Map)['bulk'] as Map)['destination'] as BulkDestination;
      expect(dest.placement, BulkPlacement.besideOriginals);
      expect(dest.isReady, isTrue);
    });
  });
}
