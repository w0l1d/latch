import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart'
    show TestFlutterSecureStoragePlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latch/core/app_crypto.dart';
import 'package:latch/core/device_key_service.dart';
import 'package:latch/core/passphrase_storage_service.dart';
import 'package:latch/core/recipient_key_service.dart';
import 'package:latch/core/router.dart' as router_file;
import 'package:latch/main.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// End-to-end widget tests that drive the real Latch app (real GoRouter, all
/// real screens) through every button-bearing screen: onboarding, home, the
/// encrypt/decrypt pick→passphrase→options→review flows, and settings.
///
/// WHY NOT THE PROGRESS SCREENS HERE: the encrypt/decrypt *progress* screens
/// spawn the crypto worker isolate via `AppCrypto.*Files().listen()` from
/// `initState`. Under `testWidgets` (FakeAsync) a spawned isolate leaves a
/// dangling ReceivePort that hangs teardown — so rendering the progress
/// screen is not reliably drivable from `flutter test`. The actual crypto
/// completion + the "last result before final 1.0" invariant the progress
/// screens rely on are instead pinned by `test/app_crypto_batch_test.dart`
/// (plain `test()`, real event loop, real isolate). Anything needing real
/// isolate work below is run inside `tester.runAsync` so it executes on the
/// real event loop and tears down cleanly.

// --- shared harness --------------------------------------------------------
// Platform fakes live in test/support/fakes.dart so other suites can reuse
// them.

late FakeFilePicker _picker;
late FakePathProvider _pathProvider;
late FakeLocalAuth _fakeAuth;
late Map<String, String> _secureStorage;

GoRouter get _router => router_file.router;

Future<void> _pumpApp(WidgetTester tester) async {
  await tester.pumpWidget(const LatchApp());
  await tester.pump();
}

/// Reset the (shared) app router to a known location and settle.
Future<void> _resetTo(WidgetTester tester, String location) async {
  _router.go(location);
  await tester.pumpAndSettle();
}

/// Pump until [finder] appears, interleaving a real wall-clock wait
/// (`runAsync`, so real-async/sodium/main-isolate work can progress) with
/// frame pumps (so the fake clock advances and setState/navigation land).
Future<bool> _waitUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    if (tester.any(finder)) return true;
    await tester.runAsync(
        () async => await Future.delayed(const Duration(milliseconds: 200)));
  }
  return tester.any(finder);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PackageInfo.setMockInitialValues(
      appName: 'latch',
      packageName: 'com.latch.latch',
      version: '1.0.0',
      buildNumber: '1',
      buildSignature: '',
    );
    await AppCrypto.init();
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _secureStorage = {};
    FlutterSecureStoragePlatform.instance =
        TestFlutterSecureStoragePlatform(_secureStorage);

    _fakeAuth = FakeLocalAuth();
    _picker = FakeFilePicker();
    FilePicker.platform = _picker;
    _pathProvider = FakePathProvider();

    AppCrypto.passphraseStorage = PassphraseStorageService(
      storage: const FlutterSecureStorage(),
      auth: _fakeAuth,
    );
    AppCrypto.deviceKeyService =
        DeviceKeyService(storage: const FlutterSecureStorage());
    AppCrypto.recipientKeys = RecipientKeyService(
      storage: const FlutterSecureStorage(),
      keygen: AppCrypto.generateShareKeypair,
    );

    ReceiveSharingIntent.setMockValues(
      initialMedia: const [],
      mediaStream: const Stream<List<SharedMediaFile>>.empty(),
    );
  });

  tearDown(() async {
    _secureStorage.clear();
  });

  group('onboarding flow', () {
    testWidgets('welcome Get started → how-it-works → Next advances',
        (tester) async {
      await _pumpApp(tester);
      await tester.pumpAndSettle();
      expect(find.text('Get started'), findsOneWidget);

      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      expect(find.text('How it works'), findsOneWidget);

      // "Next" leaves how-it-works (it goes to device-check, which on a fast
      // host may already have auto-advanced to loss-moment — so assert we left
      // how-it-works rather than pinning the transient benchmark screen).
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('How it works'), findsNothing);
    });

    testWidgets('loss-moment checkbox gates Continue → ready → Go to home',
        (tester) async {
      await _pumpApp(tester);
      await _resetTo(tester, '/onboarding/loss-moment');

      expect(find.text('There is no reset.'), findsOneWidget);
      final continueBtn = find.widgetWithText(ElevatedButton, 'Continue');
      expect(tester.widget<ElevatedButton>(continueBtn).onPressed, isNull);

      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(tester.widget<ElevatedButton>(continueBtn).onPressed, isNotNull);

      await tester.tap(continueBtn);
      await tester.pumpAndSettle();
      expect(find.text("You're set."), findsOneWidget);

      await tester.tap(find.text('Go to home'));
      await tester.pumpAndSettle();
      expect(find.text('Encrypt files'), findsOneWidget);

      // "Go to home" marks onboarding complete so it never runs again.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('onboarding_complete'), isTrue);
    });

    testWidgets('completed onboarding: app starts at home, not welcome',
        (tester) async {
      SharedPreferences.setMockInitialValues({'onboarding_complete': true});
      await _pumpApp(tester);
      await tester.pumpAndSettle();

      expect(find.text('Encrypt files'), findsOneWidget);
      expect(find.text('Get started'), findsNothing);
    });

    testWidgets('completed onboarding: navigating to /onboarding/* redirects home',
        (tester) async {
      SharedPreferences.setMockInitialValues({'onboarding_complete': true});
      await _pumpApp(tester);
      await tester.pumpAndSettle();

      _router.go('/onboarding/loss-moment');
      await tester.pumpAndSettle();
      expect(find.text('There is no reset.'), findsNothing);
      expect(find.text('Encrypt files'), findsOneWidget);
    });

    testWidgets('device-check benchmark auto-advances to loss-moment',
        (tester) async {
      await _pumpApp(tester);
      await _resetTo(tester, '/onboarding/welcome');

      await tester.tap(find.text('Get started'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      // The Argon2id benchmark + sodium init run on the main isolate (real
      // FFI / real event loop). Let that finish on the real loop, then pump
      // the fake clock past the trailing 200ms delay so the screen navigates.
      await tester.runAsync(
          () async => await Future.delayed(const Duration(seconds: 5)));
      final found = await _waitUntil(tester, find.text('There is no reset.'),
          timeout: const Duration(seconds: 30));
      expect(found, isTrue,
          reason: 'device-check did not auto-advance to loss-moment');

      // Fresh install: the benchmark writes both the active KDF params and
      // the calibration record that Settings' "Auto" preset restores.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('kdf_opslimit'), isNotNull);
      expect(prefs.getInt('kdf_memlimit'), isNotNull);
      expect(prefs.getInt('kdf_calibrated_opslimit'), isNotNull);
      expect(prefs.getInt('kdf_calibrated_memlimit'), isNotNull);
    }, timeout: const Timeout(Duration(seconds: 60)));

    testWidgets('device-check never clobbers an existing KDF choice',
        (tester) async {
      // A user-picked "High" preset already stored.
      SharedPreferences.setMockInitialValues({
        'kdf_opslimit': 4,
        'kdf_memlimit': 262144,
      });
      await _pumpApp(tester);
      await _resetTo(tester, '/onboarding/device-check');

      await tester.runAsync(
          () async => await Future.delayed(const Duration(seconds: 5)));
      final found = await _waitUntil(tester, find.text('There is no reset.'),
          timeout: const Duration(seconds: 30));
      expect(found, isTrue,
          reason: 'device-check did not auto-advance to loss-moment');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('kdf_opslimit'), 4,
          reason: 'benchmark must not overwrite a user-picked KDF preset');
      expect(prefs.getInt('kdf_memlimit'), 262144);
      // Calibration is still recorded for the "Auto" preset.
      expect(prefs.getInt('kdf_calibrated_opslimit'), isNotNull);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('home screen buttons', () {
    testWidgets('Encrypt files → encrypt/pick; Decrypt a file → decrypt/pick',
        (tester) async {
      await _pumpApp(tester);
      await _resetTo(tester, '/home');

      await tester.tap(find.text('Encrypt files'));
      await tester.pumpAndSettle();
      expect(find.text('Choose files to lock'), findsWidgets);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('Decrypt a file'), findsOneWidget);

      await tester.tap(find.text('Decrypt a file'));
      await tester.pumpAndSettle();
      expect(find.text('Choose locked files'), findsWidgets);
    });

    testWidgets('settings icon navigates to settings', (tester) async {
      await _pumpApp(tester);
      await _resetTo(tester, '/home');

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Passphrase storage'), findsOneWidget);
    });
  });

  group('encrypt flow up to lock', () {
    testWidgets(
        'pick → passphrase → options → review, Lock button is wired & enabled',
        (tester) async {
      final tmp = Directory.systemTemp.createTempSync('latch_e2e_encrypt');
      try {
        _pathProvider.configure(tmp.path);
        final src = File('${tmp.path}/secret.txt')
          ..writeAsStringSync('top secret contents');
        _picker.configure(paths: [src.path]);

        await _pumpApp(tester);
        await _resetTo(tester, '/home');

        await tester.tap(find.text('Encrypt files'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose files to lock'));
        await tester.pumpAndSettle();

        // "Set a passphrase" is disabled until files are picked; now enabled.
        final setPassBtn = find.text('Set a passphrase');
        expect(setPassBtn, findsOneWidget);
        await tester.tap(setPassBtn);
        await tester.pumpAndSettle();

        // passphrase screen: Continue disabled until text entered.
        final continueBtn = find.widgetWithText(ElevatedButton, 'Continue');
        expect(tester.widget<ElevatedButton>(continueBtn).onPressed, isNull);
        await tester.enterText(
            find.byType(TextField).first, 'a strong passphrase');
        await tester.pumpAndSettle();
        expect(tester.widget<ElevatedButton>(continueBtn).onPressed, isNotNull);
        // The save-for-quick-unlock offer is shown by default (device
        // supports auth, no restrictive storage mode chosen).
        expect(find.text('Save for quick unlock'), findsOneWidget);
        await tester.tap(continueBtn);
        await tester.pumpAndSettle();

        // options — default destination is beside the originals (the app
        // documents folder is invisible to Android file managers).
        expect(find.text('After locking…'), findsOneWidget);
        expect(find.text('Same folder as each original'), findsOneWidget);
        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        // review
        expect(find.text('Ready to lock'), findsOneWidget);
        final lockBtn = find.widgetWithText(ElevatedButton, 'Lock 1 file');
        expect(lockBtn, findsOneWidget);
        expect(tester.widget<ElevatedButton>(lockBtn).onPressed, isNotNull,
            reason: '"Lock 1 file" must be tappable');
      } finally {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });
  });

  group('decrypt flow up to unlock', () {
    testWidgets(
        'pick a real .latch → Enter passphrase → Unlock button wired & enabled',
        (tester) async {
      final tmp = Directory.systemTemp.createTempSync('latch_e2e_decrypt');
      try {
        _pathProvider.configure(tmp.path);
        final src = File('${tmp.path}/note.txt')
          ..writeAsBytesSync(
              Uint8List.fromList(List.generate(2000, (i) => i % 256)));
        // Create a real .latch on the real event loop (tear-down clean).
        await tester.runAsync(() async {
          await AppCrypto.encryptFiles([src.path], 'decrypt passphrase')
              .drain<void>();
        });
        final latch = File('${src.path}.latch');
        expect(latch.existsSync(), isTrue);
        _picker.configure(paths: [latch.path]);

        await _pumpApp(tester);
        await _resetTo(tester, '/home');

        await tester.tap(find.text('Decrypt a file'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose locked files'));
        await tester.pumpAndSettle();

        final enterBtn = find.text('Enter passphrase');
        expect(enterBtn, findsOneWidget);
        await tester.tap(enterBtn);
        await tester.pumpAndSettle();

        final unlockBtn = find.widgetWithText(ElevatedButton, 'Unlock');
        expect(tester.widget<ElevatedButton>(unlockBtn).onPressed, isNull);
        await tester.enterText(
            find.byType(TextField).first, 'decrypt passphrase');
        await tester.pumpAndSettle();
        expect(tester.widget<ElevatedButton>(unlockBtn).onPressed, isNotNull,
            reason: '"Unlock" must be tappable once a passphrase is typed');
      } finally {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('settings', () {
    testWidgets('navigates to passphrase storage screen', (tester) async {
      await _pumpApp(tester);
      await _resetTo(tester, '/home');

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Passphrase storage'));
      await tester.pumpAndSettle();
      expect(find.text('Your passphrase'), findsOneWidget);
    });

    testWidgets('Quick unlock toggle persists to SharedPreferences',
        (tester) async {
      await _pumpApp(tester);
      await _resetTo(tester, '/home');

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      // Quick unlock defaults ON (saving a passphrase should "just work" at
      // decrypt); the switch is the explicit kill switch.
      final switchFinder = find.widgetWithText(SwitchListTile, 'Quick unlock');
      expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('quick_unlock'), isFalse);
    });

    testWidgets('vault screen lists stored passphrases and deletes one',
        (tester) async {
      final svc = AppCrypto.passphraseStorage!;
      await svc.store('/some/dir/photo.jpg', 'pw one');
      await svc.store('3 files', 'pw two');

      await _pumpApp(tester);
      await _resetTo(tester, '/settings/passphrase-storage');

      // Labels are shown (file-path labels as basename), not a placebo list.
      expect(find.text('photo.jpg'), findsOneWidget);
      expect(find.text('3 files'), findsOneWidget);

      // Delete the first entry through the UI, confirming the dialog.
      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      expect(find.text('Delete this passphrase?'), findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(find.text('photo.jpg'), findsNothing);
      expect(find.text('3 files'), findsOneWidget);
      final remaining = await svc.list();
      expect(remaining.length, 1,
          reason: 'delete must actually remove the entry from secure storage');
      expect(remaining.single.label, '3 files');
    });

    testWidgets(
        '"Type it every time" purges the vault after confirmation and '
        'hides the save offer in the encrypt flow', (tester) async {
      final tmp = Directory.systemTemp.createTempSync('latch_vault_mode');
      try {
        final svc = AppCrypto.passphraseStorage!;
        await svc.store('secret.txt', 'a stored pw');

        await _pumpApp(tester);
        // Mirror real navigation: the vault screen is pushed from Settings,
        // so its post-save context.pop() has somewhere to go.
        await _resetTo(tester, '/settings');
        _router.push('/settings/passphrase-storage');
        await tester.pumpAndSettle();

        await tester.tap(find.text('Type it every time'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save choice'));
        await tester.pumpAndSettle();

        // Purge requires explicit consent.
        expect(find.textContaining('stored passphrase'), findsWidgets);
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();

        expect(await svc.list(), isEmpty,
            reason: '"nothing is stored" must actually mean nothing is stored');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('passphrase_storage_mode'), 'none');
        expect(prefs.getBool('quick_unlock'), isFalse);

        // The encrypt flow now respects the choice: no save offer.
        final src = File('${tmp.path}/f.txt')..writeAsStringSync('x');
        _picker.configure(paths: [src.path]);
        _pathProvider.configure(tmp.path);
        await _resetTo(tester, '/home');
        await tester.tap(find.text('Encrypt files'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Choose files to lock'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Set a passphrase'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'typed pw');
        await tester.pumpAndSettle();
        expect(find.text('Save for quick unlock'), findsNothing,
            reason: 'explicit "type it every time" must hide the save offer');
      } finally {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      }
    });

    testWidgets('KDF cost dropdown writes prefs', (tester) async {
      await _pumpApp(tester);
      await _resetTo(tester, '/home');

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();

      // The settings list is long; "KDF cost" is below the fold — scroll to it.
      await tester.scrollUntilVisible(find.text('KDF cost'), 300.0);
      await tester.pumpAndSettle();

      // Open the KDF cost dropdown (its closed value is "Auto") and pick Medium.
      final kdfRow = find.ancestor(
          of: find.text('KDF cost'),
          matching: find.byType(ListTile));
      await tester.tap(find.descendant(of: kdfRow, matching: find.text('Auto')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Medium'));
      await tester.pumpAndSettle();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('kdf_opslimit'), 3);
      expect(prefs.getInt('kdf_memlimit'), 131072);
    });
  });
}