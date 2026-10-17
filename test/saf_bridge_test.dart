import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/saf_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SafBridge.channel, null);
  });

  group('SafBridge', () {
    test('rememberUri keeps content:// identifiers only', () {
      SafBridge.rememberUri('/cache/a.latch', 'content://provider/doc/1');
      SafBridge.rememberUri('/cache/b.latch', '/storage/emulated/0/b.latch');
      SafBridge.rememberUri('/cache/c.latch', null);

      expect(SafBridge.uriFor('/cache/a.latch'), 'content://provider/doc/1');
      expect(SafBridge.uriFor('/cache/b.latch'), isNull);
      expect(SafBridge.uriFor('/cache/c.latch'), isNull);
    });

    test('writeBack sends the registered uri and the cache path', () async {
      SafBridge.rememberUri('/cache/d.latch', 'content://provider/doc/2');
      await SafBridge.writeBack('/cache/d.latch');

      expect(calls, hasLength(1));
      expect(calls.single.method, 'writeBack');
      expect(calls.single.arguments, {
        'uri': 'content://provider/doc/2',
        'path': '/cache/d.latch',
      });
    });

    test('overwriteAndDelete sends the noise bytes', () async {
      SafBridge.rememberUri('/cache/e.latch', 'content://provider/doc/3');
      final noise = Uint8List.fromList(List.generate(64, (i) => i));
      await SafBridge.overwriteAndDelete('/cache/e.latch', noise);

      expect(calls.single.method, 'overwriteAndDelete');
      final args = calls.single.arguments as Map;
      expect(args['uri'], 'content://provider/doc/3');
      expect(args['bytes'], noise);
    });

    test('deleteDocument sends the registered uri', () async {
      SafBridge.rememberUri('/cache/f.latch', 'content://provider/doc/4');
      await SafBridge.deleteDocument('/cache/f.latch');

      expect(calls.single.method, 'delete');
      expect(calls.single.arguments, {'uri': 'content://provider/doc/4'});
    });

    test('canWriteBack is false off-Android even with a registered uri', () {
      SafBridge.rememberUri('/cache/g.latch', 'content://provider/doc/5');
      // Tests run on the host platform, so the Android gate must hold.
      expect(SafBridge.canWriteBack('/cache/g.latch'), isFalse);
    });

    test('realDirectoryFor resolves the parent folder and caches it', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) async {
            calls.add(call);
            return '/storage/emulated/0/Documents/report.pdf';
          });
      SafBridge.rememberUri('/cache/h.pdf', 'content://provider/doc/6');

      expect(
        await SafBridge.realDirectoryFor('/cache/h.pdf'),
        '/storage/emulated/0/Documents',
      );
      expect(calls.single.method, 'resolvePath');
      expect(calls.single.arguments, {'uri': 'content://provider/doc/6'});

      // Second lookup answers from the cache — no extra platform call.
      expect(
        await SafBridge.realDirectoryFor('/cache/h.pdf'),
        '/storage/emulated/0/Documents',
      );
      expect(calls, hasLength(1));
    });

    test(
      'realDirectoryFor is null without a uri or when resolution fails',
      () async {
        expect(await SafBridge.realDirectoryFor('/cache/unregistered'), isNull);
        expect(calls, isEmpty);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SafBridge.channel, (call) async {
              throw PlatformException(code: 'saf_error');
            });
        SafBridge.rememberUri('/cache/i.pdf', 'content://provider/doc/7');
        expect(await SafBridge.realDirectoryFor('/cache/i.pdf'), isNull);
      },
    );
  });

  group('SafBridge tree grants', () {
    test('pickTree forwards both picker seeds', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) async {
            calls.add(call);
            return 'content://tree/primary%3ADocuments';
          });

      final uri = await SafBridge.pickTree(
        initialPath: '/storage/x/Documents',
        initialDocUri: 'content://doc/1',
      );
      expect(uri, 'content://tree/primary%3ADocuments');
      expect(calls.single.method, 'openTree');
      expect(calls.single.arguments, {
        'initialPath': '/storage/x/Documents',
        'initialDocUri': 'content://doc/1',
      });
    });

    test('treeUriToPath returns null on platform failure', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) async {
            throw PlatformException(code: 'saf_error');
          });
      expect(await SafBridge.treeUriToPath('content://tree/x'), isNull);
    });

    test('createInTree sends every argument and parses the result', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) async {
            calls.add(call);
            return {
              'uri': 'content://doc/new',
              'displayPath': '/storage/x/Documents/a.txt.latch',
            };
          });

      final created = await SafBridge.createInTree(
        treeUri: 'content://tree/primary%3ADocuments',
        displayName: 'a.txt.latch',
        srcPath: '/cache/latch_stage/0_a.txt.latch',
      );
      expect(created.uri, 'content://doc/new');
      expect(created.displayPath, '/storage/x/Documents/a.txt.latch');
      expect(calls.single.method, 'createInTree');
      expect(calls.single.arguments, {
        'treeUri': 'content://tree/primary%3ADocuments',
        'displayName': 'a.txt.latch',
        'mimeType': 'application/octet-stream',
        'srcPath': '/cache/latch_stage/0_a.txt.latch',
        'subPath': '',
      });
    });

    test('createInTree forwards a nested sub-folder', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) async {
            calls.add(call);
            return {
              'uri': 'content://doc/nested',
              'displayPath': '/storage/x/Documents/Work/a.txt.latch',
            };
          });

      final created = await SafBridge.createInTree(
        treeUri: 'content://tree/primary%3ADocuments',
        displayName: 'a.txt.latch',
        srcPath: '/cache/latch_stage/0_a.txt.latch',
        subPath: 'Work',
      );
      expect(created.displayPath, '/storage/x/Documents/Work/a.txt.latch');
      expect(calls.single.arguments['subPath'], 'Work');
    });

    test('existingTreeGrantFor asks the platform about one folder', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) async {
            calls.add(call);
            return {'treeUri': 'content://tree/docs', 'subPath': 'Work'};
          });

      final grant = await SafBridge.existingTreeGrantFor(
        '/storage/x/Documents/Work',
      );
      expect(grant!.treeUri, 'content://tree/docs');
      expect(grant.subPath, 'Work');
      expect(calls.single.method, 'existingTreeGrant');
      expect(calls.single.arguments, {'folder': '/storage/x/Documents/Work'});
    });

    test(
      'listTreeGrants parses the platform reply, newest row first',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SafBridge.channel, (call) async {
              calls.add(call);
              return {
                'grants': [
                  {
                    'uri': 'content://tree/primary%3ADocuments',
                    'path': '/storage/emulated/0/Documents',
                    'label': '/storage/emulated/0/Documents',
                    'grantedAt': 1700000000000,
                  },
                  {
                    'uri': 'content://tree/cloud%3Aabc',
                    'path': null,
                    'label': 'Team drive',
                    'grantedAt': 0,
                  },
                ],
                'limit': 512,
              };
            });

        final grants = await SafBridge.listTreeGrants();
        expect(calls.single.method, 'listTreeGrants');
        expect(grants.count, 2);
        expect(grants.limit, 512);
        expect(grants.grants.first.path, '/storage/emulated/0/Documents');
        expect(
          grants.grants.first.grantedAt,
          DateTime.fromMillisecondsSinceEpoch(1700000000000),
        );
        // A provider that fronts no folder still gets a usable row.
        expect(grants.grants.last.path, isNull);
        expect(grants.grants.last.label, 'Team drive');
        expect(grants.grants.last.grantedAt, isNull);
        expect(grants.nearLimit, isFalse);
      },
    );

    test('listTreeGrants reads as no access on platform failure', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) async {
            throw PlatformException(code: 'saf_error');
          });
      final grants = await SafBridge.listTreeGrants();
      expect(grants.grants, isEmpty);
      // Never claim a ceiling the platform didn't report.
      expect(grants.limit, 0);
      expect(grants.nearLimit, isFalse);
    });

    test('SafTreeGrants.fromMap survives a malformed reply', () {
      final grants = SafTreeGrants.fromMap({
        'grants': [
          'not a row',
          {'uri': 'content://tree/x'},
        ],
      });
      expect(grants.count, 1);
      // Label falls back to the URI so no row is unidentifiable.
      expect(grants.grants.single.label, 'content://tree/x');
      expect(grants.limit, 0);
    });

    test('nearLimit only fires within 80% of a known ceiling', () {
      SafTreeGrants at(int n, int limit) => SafTreeGrants(
        grants: List.generate(
          n,
          (i) => SafTreeGrant(
            uri: 'content://tree/$i',
            path: null,
            label: '$i',
            grantedAt: null,
          ),
        ),
        limit: limit,
      );
      expect(at(101, 128).nearLimit, isFalse);
      expect(at(102, 128).nearLimit, isTrue);
      // Unknown ceiling must never warn.
      expect(at(600, 0).nearLimit, isFalse);
    });

    test(
      'releaseTreeGrant reports the platform answer, never throws',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SafBridge.channel, (call) async {
              calls.add(call);
              return false;
            });
        expect(await SafBridge.releaseTreeGrant('content://tree/x'), isFalse);
        expect(calls.single.method, 'releaseTreeGrant');
        expect(calls.single.arguments, {'uri': 'content://tree/x'});

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SafBridge.channel, (call) async {
              throw PlatformException(code: 'saf_error');
            });
        expect(await SafBridge.releaseTreeGrant('content://tree/x'), isFalse);
      },
    );

    test(
      'freeBytesAt returns the native answer; null on any failure',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SafBridge.channel, (call) async {
              calls.add(call);
              return 123456789;
            });
        expect(await SafBridge.freeBytesAt('/storage/emulated/0/x'), 123456789);
        expect(calls.single.method, 'freeBytes');
        expect(calls.single.arguments, {'path': '/storage/emulated/0/x'});

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SafBridge.channel, (call) async {
              throw PlatformException(code: 'saf_error');
            });
        expect(await SafBridge.freeBytesAt('/x'), isNull);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SafBridge.channel, (call) async => null);
        expect(await SafBridge.freeBytesAt('/x'), isNull);
      },
    );
  });
}
