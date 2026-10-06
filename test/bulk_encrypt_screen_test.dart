import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latch/core/bulk_plan.dart';
import 'package:latch/core/bulk_settings.dart';
import 'package:latch/features/encrypt/encrypt_bulk_progress_screen.dart';
import 'package:latch/features/encrypt/encrypt_bulk_result_screen.dart';
import 'package:latch/features/encrypt/encrypt_folder_screen.dart';
import 'package:latch/shared/theme/app_theme.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

BulkItem _item(String name, {int size = 100}) => BulkItem(
  sourcePath: '/r/$name',
  relativePath: name,
  sizeBytes: size,
  stampAtEnumeration: EntryStamp(
    kind: EntryKind.file,
    sizeBytes: size,
    modified: DateTime(2026),
  ),
  outRelPath: '$name.latch',
);

BulkInventory _inv({
  int files = 3,
  bool recursive = false,
  int excluded = 0,
  int containers = 0,
  List<SkippedEntry> skipped = const [],
}) => BulkInventory(
  root: '/r',
  mode: BulkMode.encrypt,
  recursive: recursive,
  items: [for (var i = 0; i < files; i++) _item('f$i.txt')],
  skipped: skipped,
  subfolders: recursive ? 2 : 0,
  excludedInSubfolders: recursive ? 0 : excluded,
  alreadyContainers: containers,
);

Object? lastExtra;

Widget _app(Widget home) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => home),
      GoRoute(
        path: '/encrypt/passphrase',
        builder: (_, s) {
          lastExtra = s.extra;
          return const Scaffold(body: Text('PASSPHRASE'));
        },
      ),
      GoRoute(path: '/home', builder: (_, _) => const Text('HOME')),
    ],
  );
  return MaterialApp.router(theme: buildTheme(), routerConfig: router);
}

Widget _folder({BulkInventory? inv, Map<bool, BulkInventory>? byRecursive}) =>
    _app(
      EncryptFolderScreen(
        pickFolder: () async => '/r',
        enumerate: (root, rec) async =>
            byRecursive?[rec] ?? inv ?? _inv(recursive: rec),
      ),
    );

Future<void> _choose(WidgetTester tester) async {
  // The placement section pushes later rows below a phone-sized fold.
  tester.view.physicalSize = const Size(800, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.tap(find.text('Choose a folder'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    lastExtra = null;
    SharedPreferences.setMockInitialValues({
      BulkSettings.outputPlacementKey: BulkPlacement.besideOriginals.name,
    });
  });

  testWidgets('review states the saved key mode and forwards it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      BulkSettings.keyModeKey: BulkKeyMode.sharedPerBatch.name,
      BulkSettings.outputPlacementKey: BulkPlacement.besideOriginals.name,
    });
    await tester.pumpWidget(_folder());
    await _choose(tester);
    expect(
      find.textContaining('One key is made for this whole run'),
      findsOneWidget,
    );
    expect(find.text('Each file gets its own key.'), findsNothing);
    await tester.tap(find.text('Set a passphrase'));
    await tester.pumpAndSettle();
    final bulk = (lastExtra as Map)['bulk'] as Map;
    expect(bulk['keyMode'], BulkKeyMode.sharedPerBatch);
  });

  testWidgets('review defaults to a separate key per file', (tester) async {
    await tester.pumpWidget(_folder());
    await _choose(tester);
    expect(find.text('Each file gets its own key.'), findsOneWidget);
    await tester.tap(find.text('Set a passphrase'));
    await tester.pumpAndSettle();
    expect(((lastExtra as Map)['bulk'] as Map)['keyMode'], BulkKeyMode.perFile);
  });

  testWidgets('shows the privacy disclosure before the start action', (
    tester,
  ) async {
    await tester.pumpWidget(_folder());
    await _choose(tester);
    expect(find.text(bulkPrivacyDisclosure), findsOneWidget);
    final disclosureY = tester.getTopLeft(find.text(bulkPrivacyDisclosure)).dy;
    final buttonY = tester.getTopLeft(find.text('Set a passphrase')).dy;
    expect(disclosureY, lessThan(buttonY));
  });

  testWidgets('summary shows count, key mode and empty-folder state', (
    tester,
  ) async {
    await tester.pumpWidget(_folder(inv: _inv(files: 1)));
    await _choose(tester);
    expect(find.textContaining('1 file ·'), findsOneWidget);
    expect(find.text('Each file gets its own key.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_folder(inv: _inv(files: 0)));
    await _choose(tester);
    expect(
      find.text('There is nothing to lock here.', skipOffstage: false),
      findsOneWidget,
    );
    final btn = tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Set a passphrase'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('already-container count and skipped entries are named', (
    tester,
  ) async {
    await tester.pumpWidget(
      _folder(
        inv: _inv(
          containers: 2,
          skipped: const [SkippedEntry('link', 'symbolic link')],
        ),
      ),
    );
    await _choose(tester);
    expect(find.textContaining('2 already look like Latch'), findsOneWidget);
    expect(find.text('1 skipped'), findsOneWidget);
    expect(find.textContaining('link — symbolic link'), findsOneWidget);
  });

  testWidgets('toggling subfolders rescans with the new setting', (
    tester,
  ) async {
    await tester.pumpWidget(
      _folder(
        byRecursive: {
          false: _inv(files: 2, excluded: 5),
          true: _inv(files: 7, recursive: true),
        },
      ),
    );
    await _choose(tester);
    expect(find.textContaining('5 files in subfolders'), findsOneWidget);
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('7 files ·'), findsOneWidget);
    expect(find.textContaining('2 subfolders included'), findsOneWidget);
  });

  testWidgets('subfolders switch starts off on every fresh entry', (
    tester,
  ) async {
    for (var i = 0; i < 2; i++) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        _folder(
          byRecursive: {
            false: _inv(files: 2, excluded: 3),
            true: _inv(files: 5, recursive: true),
          },
        ),
      );
      await _choose(tester);
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
    }
  });

  testWidgets('large batches require explicit confirmation', (tester) async {
    await tester.pumpWidget(
      _folder(inv: _inv(files: bulkConfirmThreshold + 1)),
    );
    await _choose(tester);
    ElevatedButton btn() => tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Set a passphrase'),
        matching: find.byType(ElevatedButton),
      ),
    );
    expect(btn().onPressed, isNull);
    await tester.scrollUntilVisible(
      find.byType(CheckboxListTile),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(btn().onPressed, isNotNull);
  });

  testWidgets('continue hands inventory and delete choice to the passphrase', (
    tester,
  ) async {
    final inv = _inv();
    await tester.pumpWidget(_folder(inv: inv));
    await _choose(tester);
    await tester.tap(find.text('Delete originals afterwards'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Set a passphrase'));
    await tester.pumpAndSettle();
    expect(find.text('PASSPHRASE'), findsOneWidget);
    final extra = lastExtra as Map;
    expect((extra['files'] as List).length, 3);
    final bulk = extra['bulk'] as Map;
    expect(bulk['inventory'], same(inv));
    expect(bulk['deleteSources'], isTrue);
  });

  testWidgets('a failing scan shows a message instead of crashing', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        EncryptFolderScreen(
          pickFolder: () async => '/r',
          enumerate: (_, _) async => throw StateError('boom'),
        ),
      ),
    );
    await _choose(tester);
    expect(find.textContaining('Couldn\'t read that folder'), findsOneWidget);
  });

  group('result screen', () {
    BulkRunSummary summary({int failed = 0, bool del = false}) =>
        BulkRunSummary(
          root: '/r',
          total: 3,
          outcomes: [
            for (var i = 0; i < 3 - failed; i++)
              BulkFileOutcome(
                path: '/r/f$i.txt',
                ok: true,
                outPath: '/r/f$i.txt.latch',
                verified: del,
                sourceRemoved: del,
              ),
            for (var i = 0; i < failed; i++)
              BulkFileOutcome(
                path: '/r/bad$i.txt',
                ok: false,
                errorMessage: 'disk full',
              ),
          ],
          outputs: const [],
          deleteSources: del,
          skipped: 0,
        );

    testWidgets('full success reads as done', (tester) async {
      await tester.pumpWidget(
        _app(EncryptBulkResultScreen(summary: summary())),
      );
      expect(find.text('3 files locked'), findsOneWidget);
    });

    testWidgets('partial failure never reads as done and names the files', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(EncryptBulkResultScreen(summary: summary(failed: 2, del: true))),
      );
      expect(find.text('1 locked, 2 failed'), findsOneWidget);
      expect(find.textContaining('bad0.txt: disk full'), findsOneWidget);
      expect(find.textContaining('bad1.txt: disk full'), findsOneWidget);
      expect(find.textContaining('Empty folders were left'), findsOneWidget);
    });
  });
}
