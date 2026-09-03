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
    Set<String> liveTreeGrants = const {},
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
        case 'isTreeGrantLive':
          return liveTreeGrants.contains(call.arguments['uri'] as String);
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
        requestGrant: (_, _) async => fail('must not prompt'),
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
    test('1. an existing platform grant for the exact folder — no '
        'prompt', () async {
      final saf = wireSaf(
        registerSources: {'/cache/e1.txt': '/storage/e/Exact/e1.txt'},
      );
      saf.grants.grant('/storage/e/Exact', 'content://tree/exact');

      final plan = await OutputPlanner.plan(
        ['/cache/e1.txt'],
        requestGrant: (_, _) async => fail('already granted — must not prompt'),
        platformIsAndroid: true,
      );

      expect(plan.byPath['/cache/e1.txt']!.treeUri, 'content://tree/exact');
      expect(plan.byPath['/cache/e1.txt']!.subPath, '');
    });

    test('2. a grant on an ANCESTOR folder covers the source folder '
        'via subPath', () async {
      final saf = wireSaf(
        registerSources: {'/cache/a1.txt': '/storage/e/Docs/Work/Q3/a1.txt'},
      );
      saf.grants.grant('/storage/e/Docs', 'content://tree/docs');

      final plan = await OutputPlanner.plan(
        ['/cache/a1.txt'],
        requestGrant: (_, _) async =>
            fail('an ancestor grant already covers it'),
        platformIsAndroid: true,
      );

      final t = plan.byPath['/cache/a1.txt']!;
      expect(t.treeUri, 'content://tree/docs');
      expect(t.subPath, 'Work/Q3');
    });

    test('2b. the deepest covering grant wins', () async {
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

    test('3. no grant → prompts for the exact source folder', () async {
      final saf = wireSaf(
        registerSources: {'/cache/p1.txt': '/storage/e/Ask/p1.txt'},
      );

      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/p1.txt'],
        requestGrant: (folder, _) async {
          asked.add(folder);
          // The user granted exactly the folder they were asked about.
          saf.grants.grant('/storage/e/Ask', 'content://tree/ask');
          return SaveFolderDecision.granted('content://tree/ask');
        },
        platformIsAndroid: true,
      );

      expect(asked, ['/storage/e/Ask'], reason: 'asked for the exact folder');
      final t = plan.byPath['/cache/p1.txt']!;
      expect(t.treeUri, 'content://tree/ask');
      expect(t.subPath, '');
    });

    test('3b. a later batch re-reads the platform rather than trusting a '
        'remembered grant', () async {
      final saf = wireSaf(
        registerSources: {'/cache/g1.txt': '/storage/e/Gone/g1.txt'},
      );
      saf.grants.grant('/storage/e/Gone', 'content://tree/gone');

      // First batch: granted, no prompt.
      await OutputPlanner.plan(
        ['/cache/g1.txt'],
        requestGrant: (_, _) async => fail('already granted'),
        platformIsAndroid: true,
      );

      // The user revoked it (or the volume went away) between batches. Nothing
      // the app remembers may paper over that — a remembered grant would skip
      // the prompt and silently route every later batch to Downloads.
      saf.grants.granted.remove('/storage/e/Gone');
      var asked = 0;
      final plan = await OutputPlanner.plan(
        ['/cache/g1.txt'],
        requestGrant: (_, _) async {
          asked++;
          return const SaveFolderDecision.useDownloads();
        },
        platformIsAndroid: true,
      );

      expect(asked, 1, reason: 'a revoked grant must ask again');
      expect(plan.byPath['/cache/g1.txt']!.treeUri, isNull);
    });

    test('4. picking a PARENT of the requested folder still targets the '
        'source folder', () async {
      final saf = wireSaf(
        registerSources: {'/cache/p2.txt': '/storage/e/Parent/Sub/p2.txt'},
      );

      final plan = await OutputPlanner.plan(
        ['/cache/p2.txt'],
        requestGrant: (folder, _) async {
          expect(folder, '/storage/e/Parent/Sub');
          // In the system picker the user navigated up one level.
          saf.grants.grant('/storage/e/Parent', 'content://tree/parent');
          return SaveFolderDecision.granted('content://tree/parent');
        },
        platformIsAndroid: true,
      );

      final t = plan.byPath['/cache/p2.txt']!;
      expect(t.treeUri, 'content://tree/parent');
      expect(t.subPath, 'Sub');
    });

    test('5. picking an unrelated folder honors that choice at the tree '
        'root', () async {
      wireSaf(registerSources: {'/cache/p3.txt': '/storage/e/Src/p3.txt'});

      final plan = await OutputPlanner.plan(
        ['/cache/p3.txt'],
        // Grant table stays empty: nothing covers /storage/e/Src.
        requestGrant: (_, _) async =>
            SaveFolderDecision.granted('content://tree/elsewhere'),
        platformIsAndroid: true,
      );

      final t = plan.byPath['/cache/p3.txt']!;
      expect(t.treeUri, 'content://tree/elsewhere');
      expect(t.subPath, '');
    });

    test(
      '6. choosing Downloads at the prompt falls back to it (null treeUri)',
      () async {
        wireSaf(
          registerSources: {'/cache/deny.txt': '/storage/e/Deny/deny.txt'},
        );

        final plan = await OutputPlanner.plan(
          ['/cache/deny.txt'],
          requestGrant: (_, _) async => const SaveFolderDecision.useDownloads(),
          platformIsAndroid: true,
        );
        expect(plan.byPath['/cache/deny.txt']!.treeUri, isNull);
      },
    );

    test('6b. cancelling the prompt aborts the whole plan instead of '
        'falling back to Downloads', () async {
      wireSaf(registerSources: {'/cache/stop.txt': '/storage/e/Stop/stop.txt'});

      final plan = await OutputPlanner.plan(
        ['/cache/stop.txt'],
        requestGrant: (_, _) async => const SaveFolderDecision.cancelled(),
        platformIsAndroid: true,
      );

      expect(plan.cancelled, isTrue);
      expect(plan.byPath, isEmpty, reason: 'no file was routed anywhere');
      expect(plan.outputDir, isNull);
    });

    test('6c. cancelling stops at the first prompt — the remaining folders '
        'are not asked about', () async {
      wireSaf(
        registerSources: {
          '/cache/c1.txt': '/storage/e/C/One/c1.txt',
          '/cache/c2.txt': '/storage/e/C/Two/c2.txt',
        },
      );

      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/c1.txt', '/cache/c2.txt'],
        requestGrant: (folder, _) async {
          asked.add(folder);
          return const SaveFolderDecision.cancelled();
        },
        platformIsAndroid: true,
      );

      expect(plan.cancelled, isTrue);
      expect(asked, ['/storage/e/C/One'], reason: 'cancel means the batch');
    });

    test('7. with no requestGrant callback an ungranted folder falls back '
        'to Downloads', () async {
      wireSaf(registerSources: {'/cache/n1.txt': '/storage/e/None/n1.txt'});

      final plan = await OutputPlanner.plan([
        '/cache/n1.txt',
      ], platformIsAndroid: true);
      expect(plan.byPath['/cache/n1.txt']!.treeUri, isNull);
    });

    test('8. prompts once per distinct folder, shared across that '
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
        requestGrant: (folder, _) async {
          asked.add(folder);
          final uri = 'content://tree/${p.basename(folder!)}';
          saf.grants.grant(folder, uri);
          return SaveFolderDecision.granted(uri);
        },
        platformIsAndroid: true,
      );

      expect(asked, ['/storage/e/M/One', '/storage/e/M/Two']);
      expect(plan.byPath['/cache/m1.txt']!.treeUri, 'content://tree/One');
      expect(plan.byPath['/cache/m2.txt']!.treeUri, 'content://tree/One');
      expect(plan.byPath['/cache/m3.txt']!.treeUri, 'content://tree/Two');
    });

    test('8b. a second folder needs no prompt when the first grant already '
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
        requestGrant: (folder, _) async {
          asked.add(folder);
          saf.grants.grant('/storage/e/Shared', 'content://tree/shared');
          return SaveFolderDecision.granted('content://tree/shared');
        },
        platformIsAndroid: true,
      );

      expect(asked, ['/storage/e/Shared'], reason: 'asked only for the first');
      expect(plan.byPath['/cache/s2.txt']!.treeUri, 'content://tree/shared');
      expect(plan.byPath['/cache/s2.txt']!.subPath, 'Nested');
    });

    test('9. a source with no filesystem folder prompts once with a null '
        'folder', () async {
      // No registered content URI → realDirectoryFor is null (cloud/media).
      // The user must still be asked rather than silently getting Downloads.
      wireSaf();
      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/cloud-a.txt', '/cache/cloud-b.txt'],
        requestGrant: (folder, _) async {
          asked.add(folder);
          return SaveFolderDecision.granted('content://tree/picked');
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

    test('10. choosing Downloads at the unknown-folder prompt falls back to '
        'it', () async {
      wireSaf();
      final plan = await OutputPlanner.plan(
        ['/cache/cloud-only.txt'],
        requestGrant: (_, _) async => const SaveFolderDecision.useDownloads(),
        platformIsAndroid: true,
      );
      expect(plan.byPath['/cache/cloud-only.txt']!.treeUri, isNull);
    });

    test('11. resolvable and unresolvable sources in one batch each get '
        'their own prompt', () async {
      final saf = wireSaf(
        registerSources: {'/cache/mix1.txt': '/storage/e/Mix/mix1.txt'},
      );

      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/mix1.txt', '/cache/mix-cloud.txt'],
        requestGrant: (folder, _) async {
          asked.add(folder);
          if (folder == null) {
            return SaveFolderDecision.granted(
              'content://tree/downloads-choice',
            );
          }
          saf.grants.grant(folder, 'content://tree/mix');
          return SaveFolderDecision.granted('content://tree/mix');
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

    test('12. the unknown-folder choice is remembered, so a later batch is '
        'not asked again', () async {
      // There is no folder path to key a grant on, so without remembering the
      // answer the user would face this prompt on every single batch.
      SharedPreferences.setMockInitialValues({
        'unresolved_source_tree_uri': 'content://tree/remembered',
      });
      wireSaf(liveTreeGrants: {'content://tree/remembered'});

      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/cloud-later.txt'],
        requestGrant: (folder, _) async {
          asked.add(folder);
          return SaveFolderDecision.granted(
            'content://tree/should-not-be-asked',
          );
        },
        platformIsAndroid: true,
      );

      expect(asked, isEmpty, reason: 'the remembered destination is reused');
      expect(
        plan.byPath['/cache/cloud-later.txt']!.treeUri,
        'content://tree/remembered',
      );
    });

    test('10b. cancelling the unknown-folder prompt aborts and remembers '
        'nothing', () async {
      // A cancellation is the absence of a preference. Storing it would answer
      // the "where do unresolvable sources go?" question wrongly, forever.
      SharedPreferences.setMockInitialValues({});
      wireSaf();

      final plan = await OutputPlanner.plan(
        ['/cache/cloud-stop.txt'],
        requestGrant: (_, _) async => const SaveFolderDecision.cancelled(),
        platformIsAndroid: true,
      );

      expect(plan.cancelled, isTrue);
      expect(plan.byPath, isEmpty);
      expect(
        SharedPreferences.getInstance().then(
          (p) => p.getString('unresolved_source_tree_uri'),
        ),
        completion(isNull),
      );
    });

    test('12b. a remembered destination whose grant Android no longer holds '
        'is discarded, not trusted', () async {
      // The stored value is a preference, never a substitute for the platform's
      // permission table — a revoked grant must send the user back to the
      // prompt, not silently write nowhere.
      SharedPreferences.setMockInitialValues({
        'unresolved_source_tree_uri': 'content://tree/revoked',
      });
      wireSaf(); // no live grants

      final asked = <String?>[];
      final plan = await OutputPlanner.plan(
        ['/cache/cloud-revoked.txt'],
        requestGrant: (folder, _) async {
          asked.add(folder);
          return SaveFolderDecision.granted('content://tree/fresh');
        },
        platformIsAndroid: true,
      );

      expect(asked, [null], reason: 'asked again once the grant is gone');
      expect(
        plan.byPath['/cache/cloud-revoked.txt']!.treeUri,
        'content://tree/fresh',
      );
      expect(
        SharedPreferences.getInstance().then(
          (p) => p.getString('unresolved_source_tree_uri'),
        ),
        completion('content://tree/fresh'),
        reason: 'the fresh choice replaces the dead one',
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
