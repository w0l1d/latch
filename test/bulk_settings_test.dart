import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/bulk_plan.dart';
import 'package:latch/core/bulk_settings.dart';
import 'package:latch/features/settings/bulk_settings_screen.dart';
import 'package:latch/shared/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app() =>
    MaterialApp(theme: buildTheme(), home: const BulkSettingsScreen());

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('BulkSettings', () {
    test('key mode defaults to a separate key per file', () async {
      expect(await BulkSettings.keyMode(), BulkKeyMode.perFile);
    });

    test('key mode round-trips', () async {
      await BulkSettings.setKeyMode(BulkKeyMode.sharedPerBatch);
      expect(await BulkSettings.keyMode(), BulkKeyMode.sharedPerBatch);
      await BulkSettings.setKeyMode(BulkKeyMode.perFile);
      expect(await BulkSettings.keyMode(), BulkKeyMode.perFile);
    });

    test('an unknown stored value falls back to the safe default', () async {
      SharedPreferences.setMockInitialValues({
        BulkSettings.keyModeKey: 'from-the-future',
        BulkSettings.outputPlacementKey: 'nonsense',
      });
      expect(await BulkSettings.keyMode(), BulkKeyMode.perFile);
      expect(
        await BulkSettings.outputPlacement(),
        BulkPlacement.mirroredFolder,
      );
    });

    test(
      'output placement defaults to a mirrored folder and round-trips',
      () async {
        expect(
          await BulkSettings.outputPlacement(),
          BulkPlacement.mirroredFolder,
        );
        for (final p in BulkPlacement.values) {
          await BulkSettings.setOutputPlacement(p);
          expect(await BulkSettings.outputPlacement(), p);
        }
      },
    );
  });

  group('BulkSettingsScreen', () {
    testWidgets('shows both options with the per-file one selected', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.text('A separate key for each file'), findsOneWidget);
      expect(find.text('One key for each run'), findsOneWidget);
      final group = tester.widget<RadioGroup<BulkKeyMode>>(
        find.byType(RadioGroup<BulkKeyMode>),
      );
      expect(group.groupValue, BulkKeyMode.perFile);
    });

    testWidgets('choosing shared warns first and saves only on confirm', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('One key for each run'));
      await tester.pumpAndSettle();
      expect(find.text('Use one key for the whole run?'), findsOneWidget);
      expect(await BulkSettings.keyMode(), BulkKeyMode.perFile);

      await tester.tap(find.text('Use one key'));
      await tester.pumpAndSettle();
      expect(await BulkSettings.keyMode(), BulkKeyMode.sharedPerBatch);
    });

    testWidgets('declining the warning leaves the setting unchanged', (
      tester,
    ) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('One key for each run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep separate keys'));
      await tester.pumpAndSettle();
      expect(await BulkSettings.keyMode(), BulkKeyMode.perFile);
      final group = tester.widget<RadioGroup<BulkKeyMode>>(
        find.byType(RadioGroup<BulkKeyMode>),
      );
      expect(group.groupValue, BulkKeyMode.perFile);
    });

    testWidgets('going back to per-file needs no warning', (tester) async {
      SharedPreferences.setMockInitialValues({
        BulkSettings.keyModeKey: BulkKeyMode.sharedPerBatch.name,
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.tap(find.text('A separate key for each file'));
      await tester.pumpAndSettle();
      expect(find.text('Use one key for the whole run?'), findsNothing);
      expect(await BulkSettings.keyMode(), BulkKeyMode.perFile);
    });

    testWidgets('placement defaults to a mirrored folder and saves a change', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      RadioGroup<BulkPlacement> group() =>
          tester.widget<RadioGroup<BulkPlacement>>(
            find.byType(RadioGroup<BulkPlacement>),
          );
      expect(group().groupValue, BulkPlacement.mirroredFolder);
      await tester.ensureVisible(find.text('Next to each original'));
      await tester.tap(find.text('Next to each original'));
      await tester.pumpAndSettle();
      expect(group().groupValue, BulkPlacement.besideOriginals);
      expect(
        await BulkSettings.outputPlacement(),
        BulkPlacement.besideOriginals,
      );
      await tester.ensureVisible(find.text('One folder, all together'));
      await tester.tap(find.text('One folder, all together'));
      await tester.pumpAndSettle();
      expect(await BulkSettings.outputPlacement(), BulkPlacement.flatFolder);
    });

    testWidgets('a saved placement is shown on entry', (tester) async {
      SharedPreferences.setMockInitialValues({
        BulkSettings.outputPlacementKey: BulkPlacement.flatFolder.name,
      });
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<RadioGroup<BulkPlacement>>(
              find.byType(RadioGroup<BulkPlacement>),
            )
            .groupValue,
        BulkPlacement.flatFolder,
      );
    });

    testWidgets('changing placement leaves the key mode alone', (tester) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('One folder, all together'));
      await tester.tap(find.text('One folder, all together'));
      await tester.pumpAndSettle();
      expect(await BulkSettings.keyMode(), BulkKeyMode.perFile);
    });
  });
}
