import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/build_info.dart';
import 'package:latch/features/settings/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Build provenance: an installed APK must be able to say which build it is.
///
/// The failure this guards is silent by nature — `String.fromEnvironment`
/// returns its default whenever the value was not const-evaluated or the
/// `--dart-define` went missing, with no error anywhere. So the fallback is
/// pinned here (it must read as "local", never as a fabricated tag), and
/// `dev_build.yml` greps the compiled snapshot for the real injected value,
/// which is the half a widget test cannot reach.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BuildInfo', () {
    // `flutter test` passes no --dart-define, so this suite always runs in the
    // un-injected case — exactly the one that must not lie.
    test('an un-injected build reports itself as local, not as a release', () {
      expect(BuildInfo.channel, 'local');
      expect(BuildInfo.tag, isEmpty);
      expect(BuildInfo.sha, isEmpty);
      expect(BuildInfo.isLocal, isTrue);
      expect(BuildInfo.label, 'local build');
    });

    test('the label is never blank — a blank row reads as a missing value', () {
      expect(BuildInfo.label, isNotEmpty);
    });

    test('a release build shows the tag verbatim', () {
      expect(
        BuildInfo.labelFor(tag: 'v1.0.6-2026.09.08.1', channel: 'release'),
        'v1.0.6-2026.09.08.1',
      );
    });

    test('a dev build says so — it can sit beside a release install', () {
      expect(
        BuildInfo.labelFor(tag: '1.0.6-dev.ea97492', channel: 'dev'),
        '1.0.6-dev.ea97492 (dev build)',
      );
    });

    test('a channel without a tag falls back rather than showing nothing', () {
      expect(BuildInfo.labelFor(tag: '', channel: 'release'), 'local build');
    });

    // The Build row sits directly under the Version row. For a release the
    // Version row already *is* the tag, so the row must add something else —
    // the commit — instead of repeating it.
    test('a release Build row shows the commit, not the tag twice', () {
      expect(
        BuildInfo.rowValueFor(
          tag: 'v1.0.18-2026.11.10.19',
          channel: 'release',
          sha: 'abc1234',
          version: 'v1.0.18-2026.11.10.19',
        ),
        'sha abc1234',
      );
    });

    test('a release Build row falls back to the version if no SHA came in', () {
      expect(
        BuildInfo.rowValueFor(
          tag: 'v1.0.18-2026.11.10.19',
          channel: 'release',
          sha: '',
          version: 'v1.0.18-2026.11.10.19',
        ),
        'v1.0.18-2026.11.10.19',
      );
    });

    test('a dev Build row keeps the (dev build) marker', () {
      expect(
        BuildInfo.rowValueFor(
          tag: '1.0.18-dev.abc1234',
          channel: 'dev',
          sha: 'abc1234',
          version: '1.0.18-dev.abc1234',
        ),
        '1.0.18-dev.abc1234 (dev build)',
      );
    });

    test('a local Build row says so, whatever the version reports', () {
      expect(
        BuildInfo.rowValueFor(
          tag: '',
          channel: 'local',
          sha: '',
          version: '0.0.0',
        ),
        'local build',
      );
    });

    test('isLocalFor treats a tag or channel as required, not either', () {
      expect(
        BuildInfo.isLocalFor(tag: '', channel: 'release'),
        isTrue,
        reason: 'a claimed channel with no tag has no provenance to show',
      );
      expect(
        BuildInfo.isLocalFor(tag: 'v1.0.0-2026.01.01.1', channel: 'local'),
        isTrue,
        reason: 'a tag on a local channel must not claim release provenance',
      );
      expect(
        BuildInfo.isLocalFor(tag: 'v1.0.0-2026.01.01.1', channel: 'release'),
        isFalse,
      );
    });
  });

  group('Settings → About', () {
    late List<MethodCall> platformCalls;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      platformCalls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            platformCalls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('shows a Build row and copies it on tap', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
      await tester.pumpAndSettle();

      // About sits at the bottom of the settings list.
      await tester.scrollUntilVisible(find.text('Build'), 200);
      await tester.pumpAndSettle();

      expect(find.text('Build'), findsOneWidget);
      expect(find.text(BuildInfo.label), findsOneWidget);

      await tester.tap(find.text('Build'));
      await tester.pumpAndSettle();

      // Tapping must reach the clipboard: the row exists to be pasted into a
      // bug report, and nobody retypes a commit SHA correctly.
      final copy = platformCalls.where((c) => c.method == 'Clipboard.setData');
      expect(copy, hasLength(1));
      final copied = (copy.first.arguments as Map)['text'] as String;
      expect(copied, contains(BuildInfo.label));

      expect(find.text('Build details copied'), findsOneWidget);
    });
  });
}
