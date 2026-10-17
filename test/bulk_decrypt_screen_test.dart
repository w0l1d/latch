import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latch/core/bulk_plan.dart';
import 'package:latch/features/decrypt/decrypt_bulk_result_screen.dart';
import 'package:latch/features/decrypt/decrypt_folder_screen.dart';
import 'package:latch/features/encrypt/encrypt_bulk_progress_screen.dart';
import 'package:latch/features/encrypt/encrypt_folder_screen.dart'
    show bulkPrivacyDisclosure, bulkConfirmThreshold;
import 'package:latch/shared/theme/app_theme.dart';
import 'package:latch/core/bulk_settings.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

BulkItem _item(String name, {int size = 100}) => BulkItem(
  sourcePath: '/r/$name.latch',
  relativePath: '$name.latch',
  sizeBytes: size,
  stampAtEnumeration: EntryStamp(
    kind: EntryKind.file,
    sizeBytes: size,
    modified: DateTime(2026),
  ),
  outRelPath: name,
);

BulkInventory _inv({
  int files = 3,
  bool recursive = false,
  int excluded = 0,
  List<SkippedEntry> skipped = const [],
}) => BulkInventory(
  root: '/r',
  mode: BulkMode.decrypt,
  recursive: recursive,
  items: [for (var i = 0; i < files; i++) _item('f$i.txt')],
  skipped: skipped,
  subfolders: recursive ? 2 : 0,
  excludedInSubfolders: recursive ? 0 : excluded,
  alreadyContainers: 0,
);

Object? lastExtra;

Widget _app(Widget home) {
  final router = GoRouter(
    routes: [
      GoRoute(path: '/', builder: (_, _) => home),
      GoRoute(
        path: '/decrypt/passphrase',
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
      DecryptFolderScreen(
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

ElevatedButton _continueButton(WidgetTester tester) =>
    tester.widget<ElevatedButton>(
      find.ancestor(
        of: find.text('Enter passphrase'),
        matching: find.byType(ElevatedButton),
      ),
    );

void main() {
  setUp(() {
    lastExtra = null;
    SharedPreferences.setMockInitialValues({
      BulkSettings.outputPlacementKey: BulkPlacement.besideOriginals.name,
    });
  });

  testWidgets('shows the privacy disclosure before the start action', (
    tester,
  ) async {
    await tester.pumpWidget(_folder());
    await _choose(tester);
    expect(find.text(bulkPrivacyDisclosure), findsOneWidget);
    final disclosureY = tester.getTopLeft(find.text(bulkPrivacyDisclosure)).dy;
    final buttonY = tester.getTopLeft(find.text('Enter passphrase')).dy;
    expect(disclosureY, lessThan(buttonY));
  });

  testWidgets('summary counts locked files and lists skips with reasons', (
    tester,
  ) async {
    await tester.pumpWidget(
      _folder(
        inv: _inv(
          files: 1,
          skipped: const [
            SkippedEntry('notes.txt', 'not a Latch file'),
            SkippedEntry('new.latch', 'made by a newer version of Latch'),
          ],
        ),
      ),
    );
    await _choose(tester);
    expect(find.textContaining('1 locked file ·'), findsOneWidget);
    expect(find.textContaining('2 skipped'), findsOneWidget);
    expect(find.text('notes.txt — not a Latch file'), findsOneWidget);
    expect(
      find.text('new.latch — made by a newer version of Latch'),
      findsOneWidget,
    );
  });

  testWidgets('an empty folder cannot continue', (tester) async {
    await tester.pumpWidget(_folder(inv: _inv(files: 0)));
    await _choose(tester);
    expect(
      find.text(
        'There are no .latch files to unlock here.',
        skipOffstage: false,
      ),
      findsOneWidget,
    );
    expect(_continueButton(tester).onPressed, isNull);
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
    expect(find.textContaining('7 locked files ·'), findsOneWidget);
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
    expect(_continueButton(tester).onPressed, isNull);
    await tester.scrollUntilVisible(
      find.byType(CheckboxListTile),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    expect(_continueButton(tester).onPressed, isNotNull);
  });

  testWidgets('delete-containers is off by default and is passed on', (
    tester,
  ) async {
    final inv = _inv();
    await tester.pumpWidget(_folder(inv: inv));
    await _choose(tester);
    await tester.tap(find.text('Enter passphrase'));
    await tester.pumpAndSettle();
    expect(((lastExtra as Map)['bulk'] as Map)['deleteSources'], isFalse);

    await tester.pumpWidget(const SizedBox());
    lastExtra = null;
    await tester.pumpWidget(_folder(inv: inv));
    await _choose(tester);
    await tester.tap(find.text('Delete locked files afterwards'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Enter passphrase'));
    await tester.pumpAndSettle();
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
        DecryptFolderScreen(
          pickFolder: () async => '/r',
          enumerate: (_, _) async => throw StateError('boom'),
        ),
      ),
    );
    await _choose(tester);
    expect(find.textContaining('Couldn\'t read that folder'), findsOneWidget);
  });

  group('result screen', () {
    BulkRunSummary summary({
      int failed = 0,
      bool del = false,
      String error = 'CorruptedFileError: bad chunk',
    }) => BulkRunSummary(
      root: '/r',
      total: 3,
      outcomes: [
        for (var i = 0; i < 3 - failed; i++)
          BulkFileOutcome(
            path: '/r/f$i.txt.latch',
            ok: true,
            outPath: '/r/f$i.txt',
            verified: del,
            sourceRemoved: del,
          ),
        for (var i = 0; i < failed; i++)
          BulkFileOutcome(
            path: '/r/bad$i.txt.latch',
            ok: false,
            errorMessage: error,
          ),
      ],
      outputs: const [],
      deleteSources: del,
      skipped: 0,
    );

    testWidgets('full success reads as done', (tester) async {
      await tester.pumpWidget(
        _app(DecryptBulkResultScreen(summary: summary())),
      );
      expect(find.text('3 files unlocked'), findsOneWidget);
    });

    testWidgets('partial failure names each file with a human message', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(DecryptBulkResultScreen(summary: summary(failed: 2, del: true))),
      );
      expect(find.text('1 unlocked, 2 failed'), findsOneWidget);
      expect(find.textContaining('bad0.txt.latch: This .latch'), findsOne);
      expect(find.textContaining('bad1.txt.latch: This .latch'), findsOne);
      expect(find.textContaining('CorruptedFileError'), findsNothing);
      expect(find.textContaining('Empty folders were left'), findsOneWidget);
    });

    testWidgets('a wrong passphrase on every file is reported as such', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          DecryptBulkResultScreen(
            summary: summary(failed: 3, error: 'WrongPassphraseError'),
          ),
        ),
      );
      expect(find.text('0 unlocked, 3 failed'), findsOneWidget);
      expect(
        find.textContaining('passphrase did not match any of these files'),
        findsOneWidget,
      );
      expect(find.textContaining('Incorrect passphrase'), findsNWidgets(3));
    });
  });
}
