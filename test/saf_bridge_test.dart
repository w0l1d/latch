import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/saf_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
    test('pickTree forwards the initial path', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (call) async {
            calls.add(call);
            return 'content://tree/primary%3ADocuments';
          });

      final uri = await SafBridge.pickTree(initialPath: '/storage/x/Documents');
      expect(uri, 'content://tree/primary%3ADocuments');
      expect(calls.single.method, 'openTree');
      expect(calls.single.arguments, {'initialPath': '/storage/x/Documents'});
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
      });
    });

    test('rememberTreeGrant caches by folder and treeGrantForFolder reads it', () async {
      SharedPreferences.setMockInitialValues({});
      await SafBridge.rememberTreeGrant(
        '/storage/x/Documents',
        'content://tree/primary%3ADocuments',
      );
      expect(
        SafBridge.treeGrantForFolder('/storage/x/Documents'),
        'content://tree/primary%3ADocuments',
      );
      expect(SafBridge.treeGrantForFolder('/storage/x/Other'), isNull);
    });
  });
}
