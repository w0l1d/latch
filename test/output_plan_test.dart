import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/app_crypto.dart';
import 'package:latch/core/output_plan.dart';
import 'package:latch/core/saf_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

/// Drives the output planner and staged-output relocation. The planner's
/// Android branch is exercised via the [platformIsAndroid] test seam, with a
/// fake path-provider for the staging dir and a mock SAF channel for grants.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final pathProvider = FakePathProvider();
  late Directory tmp;

  setUp(() {
    PathProviderPlatform.instance = pathProvider;
    tmp = Directory.systemTemp.createTempSync('latch_plan');
    pathProvider.configure(tmp.path);
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  void mockSaf(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, handler);
  }

  group('OutputPlanner (non-Android)', () {
    test('honors an explicit destination dir, no staging', () async {
      final plan = await OutputPlanner.plan(
        ['/docs/a.txt'],
        explicitDir: '/chosen',
        platformIsAndroid: false,
      );
      expect(plan.stagingDir, isNull);
      expect(plan.isStaged, isFalse);
      expect(plan.outputDir, '/chosen');
      expect(plan.byPath, isEmpty);
    });
  });

  group('OutputPlanner (Android)', () {
    test('explicitTreeUri routes every file to that one grant', () async {
      mockSaf((_) async => null);
      final plan = await OutputPlanner.plan(
        ['/cache/a.txt', '/cache/b.txt'],
        explicitTreeUri: 'content://tree/chosen',
        platformIsAndroid: true,
      );
      expect(plan.isStaged, isTrue);
      expect(plan.stagingDir, p.join(tmp.path, 'latch_stage'));
      expect(plan.outputDir, plan.stagingDir);
      expect(Directory(plan.stagingDir!).existsSync(), isTrue);
      expect(plan.byPath['/cache/a.txt']!.treeUri, 'content://tree/chosen');
      expect(plan.byPath['/cache/b.txt']!.treeUri, 'content://tree/chosen');
    });

    test('reuses a cached grant for the resolved source folder', () async {
      await SafBridge.rememberTreeGrant(
        '/storage/e/Docs',
        'content://tree/docs',
      );
      SafBridge.rememberUri('/cache/reuse.txt', 'content://provider/reuse');
      mockSaf((call) async {
        if (call.method == 'resolvePath') return '/storage/e/Docs/reuse.txt';
        return null;
      });

      var prompted = false;
      final plan = await OutputPlanner.plan(
        ['/cache/reuse.txt'],
        requestGrant: (_) async {
          prompted = true;
          return null;
        },
        platformIsAndroid: true,
      );
      expect(prompted, isFalse, reason: 'cached grant must not re-prompt');
      expect(plan.byPath['/cache/reuse.txt']!.treeUri, 'content://tree/docs');
    });

    test('prompts once per folder and remembers a granted folder', () async {
      SafBridge.rememberUri('/cache/ask.txt', 'content://provider/ask');
      mockSaf((call) async {
        if (call.method == 'resolvePath') return '/storage/e/Ask/ask.txt';
        return null;
      });

      final plan = await OutputPlanner.plan(
        ['/cache/ask.txt'],
        requestGrant: (folder) async {
          expect(folder, '/storage/e/Ask');
          return 'content://tree/ask';
        },
        platformIsAndroid: true,
      );
      expect(plan.byPath['/cache/ask.txt']!.treeUri, 'content://tree/ask');
      // Persisted for next time.
      expect(
        SafBridge.treeGrantForFolder('/storage/e/Ask'),
        'content://tree/ask',
      );
    });

    test('a declined grant falls back to Downloads (null treeUri)', () async {
      SafBridge.rememberUri('/cache/deny.txt', 'content://provider/deny');
      mockSaf((call) async {
        if (call.method == 'resolvePath') return '/storage/e/Deny/deny.txt';
        return null;
      });

      final plan = await OutputPlanner.plan(
        ['/cache/deny.txt'],
        requestGrant: (_) async => null,
        platformIsAndroid: true,
      );
      expect(plan.byPath['/cache/deny.txt']!.treeUri, isNull);
    });

    test(
      'a source with no filesystem folder falls back to Downloads',
      () async {
        // No registered content URI → realDirectoryFor is null (cloud/media).
        mockSaf((_) async => null);
        final plan = await OutputPlanner.plan(
          ['/cache/cloud-only.txt'],
          requestGrant: (_) async => 'content://tree/should-not-be-used',
          platformIsAndroid: true,
        );
        expect(plan.byPath['/cache/cloud-only.txt']!.treeUri, isNull);
      },
    );
  });

  group('relocateStagedOutputs', () {
    BatchResult ok(String path, String staged) =>
        BatchResult(path: path, ok: true, outPath: staged);

    test('off-Android is a no-op that returns the written paths', () async {
      final results = [ok('/docs/a.txt', '/docs/a.txt.latch')];
      final out = await relocateStagedOutputs(
        results,
        const OutputPlan(), // not staged
        displayNameFor: (s) => '${p.basename(s)}.latch',
      );
      expect(out, hasLength(1));
      expect(out.single.path, '/docs/a.txt.latch');
      expect(out.single.fellBackToDownloads, isFalse);
    });

    test(
      'creates the output in a granted tree and deletes the staged temp',
      () async {
        final staged = File(p.join(tmp.path, '0_a.txt.latch'))
          ..writeAsBytesSync([1, 2, 3]);
        MethodCall? seen;
        mockSaf((call) async {
          seen = call;
          return {
            'uri': 'content://doc/new',
            'displayPath': '/storage/e/Docs/a.txt.latch',
          };
        });

        final out = await relocateStagedOutputs(
          [ok('/cache/a.txt', staged.path)],
          OutputPlan(
            stagingDir: tmp.path,
            outputDir: tmp.path,
            byPath: {
              '/cache/a.txt': const OutputTarget(
                treeUri: 'content://tree/docs',
              ),
            },
          ),
          displayNameFor: (s) => '${p.basename(s)}.latch',
        );

        expect(seen!.method, 'createInTree');
        expect(seen!.arguments['displayName'], 'a.txt.latch');
        expect(seen!.arguments['treeUri'], 'content://tree/docs');
        expect(out.single.path, '/storage/e/Docs/a.txt.latch');
        expect(out.single.fellBackToDownloads, isFalse);
        expect(staged.existsSync(), isFalse, reason: 'staged temp is swept');
      },
    );

    test('falls back to Downloads when there is no grant', () async {
      final staged = File(p.join(tmp.path, '0_note.txt'))
        ..writeAsBytesSync([9, 9, 9]);
      final downloads = Directory(p.join(tmp.path, 'Download'))..createSync();
      mockSaf((_) async => null);

      final out = await relocateStagedOutputs(
        [ok('/cache/note.txt.latch', staged.path)],
        OutputPlan(
          stagingDir: tmp.path,
          outputDir: tmp.path,
          byPath: {'/cache/note.txt.latch': const OutputTarget()},
        ),
        displayNameFor: (s) => p.basenameWithoutExtension(s),
        downloadsDir: () async => downloads.path,
      );

      expect(out.single.fellBackToDownloads, isTrue);
      expect(out.single.path, p.join(downloads.path, 'note.txt'));
      expect(File(out.single.path).existsSync(), isTrue);
      expect(File(out.single.path).readAsBytesSync(), [9, 9, 9]);
      expect(staged.existsSync(), isFalse);
    });

    test('a createInTree failure falls back to Downloads', () async {
      final staged = File(p.join(tmp.path, '0_x.txt.latch'))
        ..writeAsBytesSync([7]);
      final downloads = Directory(p.join(tmp.path, 'DL'))..createSync();
      mockSaf((call) async {
        if (call.method == 'createInTree') {
          throw PlatformException(code: 'saf_error');
        }
        return null;
      });

      final out = await relocateStagedOutputs(
        [ok('/cache/x.txt', staged.path)],
        OutputPlan(
          stagingDir: tmp.path,
          outputDir: tmp.path,
          byPath: {
            '/cache/x.txt': const OutputTarget(treeUri: 'content://tree/gone'),
          },
        ),
        displayNameFor: (s) => '${p.basename(s)}.latch',
        downloadsDir: () async => downloads.path,
      );

      expect(out.single.fellBackToDownloads, isTrue);
      expect(out.single.path, p.join(downloads.path, 'x.txt.latch'));
      expect(File(out.single.path).existsSync(), isTrue);
    });
  });
}
