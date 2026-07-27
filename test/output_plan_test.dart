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

/// Stands in for Android's persisted-URI-permission table, with the same
/// "deepest covering grant wins" matching the native `existingTreeGrant` does:
/// a tree grant can create documents in the granted folder or any descendant.
class FakeGrantTable {
  /// Granted folder path → tree URI.
  final Map<String, String> granted = {};

  void grant(String folderPath, String treeUri) =>
      granted[folderPath] = treeUri;

  /// The channel reply for `existingTreeGrant`: `{treeUri, subPath}` or null.
  Map<String, String>? cover(String folder) {
    final target = folder.replaceAll(RegExp(r'/+$'), '');
    String? bestRoot;
    Map<String, String>? best;
    granted.forEach((root, uri) {
      final r = root.replaceAll(RegExp(r'/+$'), '');
      String? sub;
      if (r == target) {
        sub = '';
      } else if (target.startsWith('$r/')) {
        sub = target.substring(r.length + 1);
      }
      if (sub == null) return;
      if (bestRoot == null || r.length > bestRoot!.length) {
        bestRoot = r;
        best = {'treeUri': uri, 'subPath': sub};
      }
    });
    return best;
  }
}

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

  /// Wires the SAF channel to a fake grant table plus a `resolvePath` map
  /// (source cache path → the real document path it was picked from), recording
  /// every method call so tests can assert what the planner did and didn't ask.
  ///
  /// [registerSources] seeds the content-URI registry the same way the pickers
  /// do, so `realDirectoryFor` resolves each source's folder.
  ({FakeGrantTable grants, List<MethodCall> calls}) wireSaf({
    Map<String, String> registerSources = const {},
    FakeGrantTable? grants,
  }) {
    final table = grants ?? FakeGrantTable();
    final calls = <MethodCall>[];
    final realPathByUri = <String, String>{};
    registerSources.forEach((cachePath, realPath) {
      final uri = 'content://provider/${p.basename(cachePath)}';
      SafBridge.rememberUri(cachePath, uri);
      realPathByUri[uri] = realPath;
    });
    mockSaf((call) async {
      calls.add(call);
      switch (call.method) {
        case 'resolvePath':
          return realPathByUri[call.arguments['uri'] as String];
        case 'existingTreeGrant':
          return table.cover(call.arguments['folder'] as String);
      }
      return null;
    });
    return (grants: table, calls: calls);
  }

  group('SafBridge.existingTreeGrantFor', () {
    test('decodes the tree URI and sub-path', () async {
      mockSaf(
        (_) async => {'treeUri': 'content://tree/docs', 'subPath': 'Work/Q3'},
      );
      final g = await SafBridge.existingTreeGrantFor('/storage/e/Docs/Work/Q3');
      expect(g!.treeUri, 'content://tree/docs');
      expect(g.subPath, 'Work/Q3');
    });

    test('a missing sub-path means the grant is the folder itself', () async {
      mockSaf((_) async => {'treeUri': 'content://tree/docs'});
      final g = await SafBridge.existingTreeGrantFor('/storage/e/Docs');
      expect(g!.subPath, '');
    });

    test('null when no grant covers the folder', () async {
      mockSaf((_) async => null);
      expect(await SafBridge.existingTreeGrantFor('/storage/e/Nope'), isNull);
    });

    test('a platform failure resolves to null instead of throwing', () async {
      mockSaf((_) async => throw PlatformException(code: 'saf_error'));
      expect(await SafBridge.existingTreeGrantFor('/storage/e/Boom'), isNull);
    });
  });

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

  group('OutputPlanner (Android) — staging', () {
    test('explicitTreeUri routes every file to that one grant', () async {
      final saf = wireSaf();
      final plan = await OutputPlanner.plan(
        ['/cache/a.txt', '/cache/b.txt'],
        explicitTreeUri: 'content://tree/chosen',
        requestGrant: (_) async => fail('must not prompt'),
        platformIsAndroid: true,
      );
      expect(plan.isStaged, isTrue);
      expect(plan.stagingDir, p.join(tmp.path, 'latch_stage'));
      expect(plan.outputDir, plan.stagingDir);
      expect(Directory(plan.stagingDir!).existsSync(), isTrue);
      expect(plan.byPath['/cache/a.txt']!.treeUri, 'content://tree/chosen');
      expect(plan.byPath['/cache/a.txt']!.subPath, '');
      expect(plan.byPath['/cache/b.txt']!.treeUri, 'content://tree/chosen');
      expect(
        saf.calls,
        isEmpty,
        reason: 'an explicit grant needs no folder resolution at all',
      );
    });

    test('a stale staging dir is wiped so old temps never leak', () async {
      final stale = Directory(p.join(tmp.path, 'latch_stage'))
        ..createSync(recursive: true);
      final leftover = File(p.join(stale.path, 'old.latch'))
        ..writeAsBytesSync([1]);
      wireSaf();
      await OutputPlanner.plan(
        ['/cache/x.txt'],
        explicitTreeUri: 'content://tree/x',
        platformIsAndroid: true,
      );
      expect(leftover.existsSync(), isFalse);
      expect(stale.existsSync(), isTrue);
    });
  });

  group('OutputPlanner (Android) — grant resolution ladder', () {
    test('1. a cached grant for the folder skips lookup and prompt', () async {
      await SafBridge.rememberTreeGrant(
        '/storage/e/Cached',
        'content://tree/cached',
      );
      final saf = wireSaf(
        registerSources: {'/cache/c1.txt': '/storage/e/Cached/c1.txt'},
      );

      final plan = await OutputPlanner.plan(
        ['/cache/c1.txt'],
        requestGrant: (_) async => fail('cached grant must not re-prompt'),
        platformIsAndroid: true,
      );

      expect(plan.byPath['/cache/c1.txt']!.treeUri, 'content://tree/cached');
      expect(plan.byPath['/cache/c1.txt']!.subPath, '');
      expect(
        saf.calls.map((c) => c.method),
        isNot(contains('existingTreeGrant')),
        reason: 'the app cache answers without touching the platform',
      );
    });

    test('2. an existing platform grant for the exact folder — no '
        'prompt', () async {
      final saf = wireSaf(
        registerSources: {'/cache/e1.txt': '/storage/e/Exact/e1.txt'},
      );
      saf.grants.grant('/storage/e/Exact', 'content://tree/exact');

      final plan = await OutputPlanner.plan(
        ['/cache/e1.txt'],
        requestGrant: (_) async => fail('already granted — must not prompt'),
        platformIsAndroid: true,
      );

      expect(plan.byPath['/cache/e1.txt']!.treeUri, 'content://tree/exact');
      expect(plan.byPath['/cache/e1.txt']!.subPath, '');
    });

    test('3. a grant on an ANCESTOR folder covers the source folder '
        'via subPath', () async {
      final saf = wireSaf(
        registerSources: {'/cache/a1.txt': '/storage/e/Docs/Work/Q3/a1.txt'},
      );
      saf.grants.grant('/storage/e/Docs', 'content://tree/docs');

      final plan = await OutputPlanner.plan(
        ['/cache/a1.txt'],
        requestGrant: (_) async => fail('an ancestor grant already covers it'),
        platformIsAndroid: true,
      );

      final t = plan.byPath['/cache/a1.txt']!;
      expect(t.treeUri, 'content://tree/docs');
      expect(t.subPath, 'Work/Q3');
    });

    test('3b. the deepest covering grant wins', () async {
      final saf = wireSaf(
        registerSources: {'/cache/d1.txt': '/storage/e/Deep/A/B/d1.txt'},
      );
      saf.grants.grant('/storage/e/Deep', 'content://tree/shallow');
      saf.grants.grant('/storage/e/Deep/A', 'content://tree/deeper');

      final plan = await OutputPlanner.plan([
        '/cache/d1.txt',
      ], platformIsAndroid: true);

      final t = plan.byPath['/cache/d1.txt']!;
      expect(t.treeUri, 'content://tree/deeper');
      expect(t.subPath, 'B');
    });

    test('4. no grant → prompts for the exact source folder, then caches '
        'the grant', () async {
      final saf = wireSaf(
        registerSources: {'/cache/p1.txt': '/storage/e/Ask/p1.txt'},
      );

      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/p1.txt'],
        requestGrant: (folder) async {
          asked.add(folder);
          // The user granted exactly the folder they were asked about.
          saf.grants.grant('/storage/e/Ask', 'content://tree/ask');
          return 'content://tree/ask';
        },
        platformIsAndroid: true,
      );

      expect(asked, ['/storage/e/Ask'], reason: 'asked for the exact folder');
      final t = plan.byPath['/cache/p1.txt']!;
      expect(t.treeUri, 'content://tree/ask');
      expect(t.subPath, '');
      expect(
        SafBridge.treeGrantForFolder('/storage/e/Ask'),
        'content://tree/ask',
        reason: 'an exact grant is remembered for later batches',
      );
    });

    test('5. picking a PARENT of the requested folder still targets the '
        'source folder, and is not cached as an exact grant', () async {
      final saf = wireSaf(
        registerSources: {'/cache/p2.txt': '/storage/e/Parent/Sub/p2.txt'},
      );

      final plan = await OutputPlanner.plan(
        ['/cache/p2.txt'],
        requestGrant: (folder) async {
          expect(folder, '/storage/e/Parent/Sub');
          // In the system picker the user navigated up one level.
          saf.grants.grant('/storage/e/Parent', 'content://tree/parent');
          return 'content://tree/parent';
        },
        platformIsAndroid: true,
      );

      final t = plan.byPath['/cache/p2.txt']!;
      expect(t.treeUri, 'content://tree/parent');
      expect(t.subPath, 'Sub');
      expect(
        SafBridge.treeGrantForFolder('/storage/e/Parent/Sub'),
        isNull,
        reason: 'only exact grants are cached; the platform holds the rest',
      );
    });

    test('6. picking an unrelated folder honors that choice at the tree '
        'root', () async {
      wireSaf(registerSources: {'/cache/p3.txt': '/storage/e/Src/p3.txt'});

      final plan = await OutputPlanner.plan(
        ['/cache/p3.txt'],
        // Grant table stays empty: nothing covers /storage/e/Src.
        requestGrant: (_) async => 'content://tree/elsewhere',
        platformIsAndroid: true,
      );

      final t = plan.byPath['/cache/p3.txt']!;
      expect(t.treeUri, 'content://tree/elsewhere');
      expect(t.subPath, '');
    });

    test(
      '7. a declined prompt falls back to Downloads (null treeUri)',
      () async {
        wireSaf(
          registerSources: {'/cache/deny.txt': '/storage/e/Deny/deny.txt'},
        );

        final plan = await OutputPlanner.plan(
          ['/cache/deny.txt'],
          requestGrant: (_) async => null,
          platformIsAndroid: true,
        );
        expect(plan.byPath['/cache/deny.txt']!.treeUri, isNull);
      },
    );

    test('8. with no requestGrant callback an ungranted folder falls back '
        'to Downloads', () async {
      wireSaf(registerSources: {'/cache/n1.txt': '/storage/e/None/n1.txt'});

      final plan = await OutputPlanner.plan([
        '/cache/n1.txt',
      ], platformIsAndroid: true);
      expect(plan.byPath['/cache/n1.txt']!.treeUri, isNull);
    });

    test('9. prompts once per distinct folder, shared across that '
        "folder's files", () async {
      final saf = wireSaf(
        registerSources: {
          '/cache/m1.txt': '/storage/e/M/One/m1.txt',
          '/cache/m2.txt': '/storage/e/M/One/m2.txt',
          '/cache/m3.txt': '/storage/e/M/Two/m3.txt',
        },
      );

      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/m1.txt', '/cache/m2.txt', '/cache/m3.txt'],
        requestGrant: (folder) async {
          asked.add(folder);
          final uri = 'content://tree/${p.basename(folder!)}';
          saf.grants.grant(folder, uri);
          return uri;
        },
        platformIsAndroid: true,
      );

      expect(asked, ['/storage/e/M/One', '/storage/e/M/Two']);
      expect(plan.byPath['/cache/m1.txt']!.treeUri, 'content://tree/One');
      expect(plan.byPath['/cache/m2.txt']!.treeUri, 'content://tree/One');
      expect(plan.byPath['/cache/m3.txt']!.treeUri, 'content://tree/Two');
    });

    test('9b. a second folder needs no prompt when the first grant already '
        'covers it', () async {
      final saf = wireSaf(
        registerSources: {
          '/cache/s1.txt': '/storage/e/Shared/s1.txt',
          '/cache/s2.txt': '/storage/e/Shared/Nested/s2.txt',
        },
      );

      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/s1.txt', '/cache/s2.txt'],
        requestGrant: (folder) async {
          asked.add(folder);
          saf.grants.grant('/storage/e/Shared', 'content://tree/shared');
          return 'content://tree/shared';
        },
        platformIsAndroid: true,
      );

      expect(asked, ['/storage/e/Shared'], reason: 'asked only for the first');
      expect(plan.byPath['/cache/s2.txt']!.treeUri, 'content://tree/shared');
      expect(plan.byPath['/cache/s2.txt']!.subPath, 'Nested');
    });

    test('10. a source with no filesystem folder prompts once with a null '
        'folder', () async {
      // No registered content URI → realDirectoryFor is null (cloud/media).
      // The user must still be asked rather than silently getting Downloads.
      wireSaf();
      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/cloud-a.txt', '/cache/cloud-b.txt'],
        requestGrant: (folder) async {
          asked.add(folder);
          return 'content://tree/picked';
        },
        platformIsAndroid: true,
      );
      expect(asked, [null], reason: 'asked once for the whole batch');
      expect(
        plan.byPath['/cache/cloud-a.txt']!.treeUri,
        'content://tree/picked',
      );
      expect(
        plan.byPath['/cache/cloud-b.txt']!.treeUri,
        'content://tree/picked',
      );
    });

    test('11. declining the unknown-folder prompt falls back to '
        'Downloads', () async {
      wireSaf();
      final plan = await OutputPlanner.plan(
        ['/cache/cloud-only.txt'],
        requestGrant: (_) async => null,
        platformIsAndroid: true,
      );
      expect(plan.byPath['/cache/cloud-only.txt']!.treeUri, isNull);
    });

    test('12. resolvable and unresolvable sources in one batch each get '
        'their own prompt', () async {
      final saf = wireSaf(
        registerSources: {'/cache/mix1.txt': '/storage/e/Mix/mix1.txt'},
      );

      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/mix1.txt', '/cache/mix-cloud.txt'],
        requestGrant: (folder) async {
          asked.add(folder);
          if (folder == null) return 'content://tree/downloads-choice';
          saf.grants.grant(folder, 'content://tree/mix');
          return 'content://tree/mix';
        },
        platformIsAndroid: true,
      );

      expect(asked, ['/storage/e/Mix', null]);
      expect(plan.byPath['/cache/mix1.txt']!.treeUri, 'content://tree/mix');
      expect(
        plan.byPath['/cache/mix-cloud.txt']!.treeUri,
        'content://tree/downloads-choice',
      );
    });
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
        expect(seen!.arguments['subPath'], '');
        expect(out.single.path, '/storage/e/Docs/a.txt.latch');
        expect(out.single.fellBackToDownloads, isFalse);
        expect(
          out.single.treeUri,
          'content://tree/docs',
          reason: 'a grant on the folder itself can be opened directly',
        );
        expect(staged.existsSync(), isFalse, reason: 'staged temp is swept');
      },
    );

    test(
      'an ancestor grant creates the file in the nested sub-folder',
      () async {
        final staged = File(p.join(tmp.path, '0_n.txt.latch'))
          ..writeAsBytesSync([4, 5]);
        MethodCall? seen;
        mockSaf((call) async {
          seen = call;
          return {
            'uri': 'content://doc/nested',
            'displayPath': '/storage/e/Docs/Work/Q3/n.txt.latch',
          };
        });

        final out = await relocateStagedOutputs(
          [ok('/cache/n.txt', staged.path)],
          OutputPlan(
            stagingDir: tmp.path,
            outputDir: tmp.path,
            byPath: {
              '/cache/n.txt': const OutputTarget(
                treeUri: 'content://tree/docs',
                subPath: 'Work/Q3',
              ),
            },
          ),
          displayNameFor: (s) => '${p.basename(s)}.latch',
        );

        expect(seen!.arguments['subPath'], 'Work/Q3');
        expect(out.single.path, '/storage/e/Docs/Work/Q3/n.txt.latch');
        expect(out.single.fellBackToDownloads, isFalse);
        expect(
          out.single.treeUri,
          isNull,
          reason: 'the granted tree is an ancestor, so open by path instead',
        );
        expect(staged.existsSync(), isFalse);
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

    test('an unaddressable nested folder falls back to Downloads', () async {
      final staged = File(p.join(tmp.path, '0_sub.txt.latch'))
        ..writeAsBytesSync([3]);
      final downloads = Directory(p.join(tmp.path, 'DL2'))..createSync();
      mockSaf((call) async {
        // Native throws when the sub-folder can't be addressed in the grant.
        if (call.method == 'createInTree') {
          throw PlatformException(code: 'saf_error', message: 'no such child');
        }
        return null;
      });

      final out = await relocateStagedOutputs(
        [ok('/cache/sub.txt', staged.path)],
        OutputPlan(
          stagingDir: tmp.path,
          outputDir: tmp.path,
          byPath: {
            '/cache/sub.txt': const OutputTarget(
              treeUri: 'content://tree/docs',
              subPath: 'Gone',
            ),
          },
        ),
        displayNameFor: (s) => '${p.basename(s)}.latch',
        downloadsDir: () async => downloads.path,
      );

      expect(out.single.fellBackToDownloads, isTrue);
      expect(out.single.path, p.join(downloads.path, 'sub.txt.latch'));
      expect(staged.existsSync(), isFalse);
    });

    test('failed results are skipped entirely', () async {
      final out = await relocateStagedOutputs(
        [BatchResult(path: '/cache/bad.txt', ok: false, errorMessage: 'nope')],
        OutputPlan(stagingDir: tmp.path, outputDir: tmp.path, byPath: const {}),
        displayNameFor: (s) => '${p.basename(s)}.latch',
      );
      expect(out, isEmpty);
    });
  });
}
