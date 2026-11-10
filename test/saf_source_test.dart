import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/bulk_plan.dart';
import 'package:latch/core/output_plan.dart';
import 'package:latch/core/saf_bridge.dart';
import 'package:latch/core/saf_source.dart';
import 'package:latch/core/verified_delete.dart';
import 'package:myenc_core/myenc_core.dart';

// Read-only use of the frozen golden container as a known-valid header.
final Uint8List _golden = File(
  'packages/myenc_adapters/test/golden/golden_v1.latch',
).readAsBytesSync();

SafTreeEntry _file(String rel, {Uint8List? prefix, int size = 10}) =>
    SafTreeEntry(
      uri: 'content://tree/doc/$rel',
      relativePath: rel,
      isDirectory: false,
      sizeBytes: size,
      modified: DateTime.fromMillisecondsSinceEpoch(1000),
      prefix: prefix ?? Uint8List.fromList([1, 2, 3]),
    );

SafTreeEntry _dir(String rel) => SafTreeEntry(
  uri: 'content://tree/doc/$rel',
  relativePath: rel,
  isDirectory: true,
  sizeBytes: 0,
  modified: DateTime.fromMillisecondsSinceEpoch(0),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BulkPlan.fromTreeListing', () {
    const stage = '/cache/latch_src/Docs';
    BulkInventory inv(
      List<SafTreeEntry> entries, {
      BulkMode mode = BulkMode.encrypt,
      bool recursive = false,
    }) => BulkPlan.fromTreeListing(
      SafTreeListing(rootName: 'Docs', entries: entries),
      treeUri: 'content://tree/root',
      stagingRoot: stage,
      mode: mode,
      recursive: recursive,
    );

    test('a folder the file APIs cannot see still yields its files', () {
      final r = inv([_file('a.pdf'), _file('b.txt')]);
      expect(r.items.map((i) => i.relativePath), ['a.pdf', 'b.txt']);
      expect(r.items.map((i) => i.outRelPath), ['a.pdf.latch', 'b.txt.latch']);
      expect(r.items.first.sourcePath, '$stage/a.pdf');
      expect(r.items.first.docUri, 'content://tree/doc/a.pdf');
      expect(r.root, stage);
      expect(r.sourceTreeUri, 'content://tree/root');
    });

    test('non-recursive leaves subfolder files out and says how many', () {
      final r = inv([_file('a.txt'), _dir('sub'), _file('sub/c.txt')]);
      expect(r.items.map((i) => i.relativePath), ['a.txt']);
      expect(r.subfolders, 1);
      expect(r.excludedInSubfolders, 1);
    });

    test('recursive takes subfolder files and keeps their relative path', () {
      final r = inv([
        _file('a.txt'),
        _dir('sub'),
        _file('sub/c.txt'),
      ], recursive: true);
      expect(r.items.map((i) => i.relativePath), ['a.txt', 'sub/c.txt']);
      expect(r.items.last.sourcePath, '$stage/sub/c.txt');
      expect(r.excludedInSubfolders, 0);
    });

    test('decrypt keeps only real containers, recognised by content', () {
      final r = inv([
        _file('x.bin', prefix: _golden.sublist(0, sniffPrefixLength)),
        _file('y.latch'),
      ], mode: BulkMode.decrypt);
      expect(r.items.map((i) => i.relativePath), ['x.bin']);
      expect(r.items.single.outRelPath, 'x.bin.decrypted');
      expect(r.skipped.map((s) => s.relativePath), ['y.latch']);
    });

    test('a file that could not be opened is skipped, never silently lost', () {
      final bad = SafTreeEntry(
        uri: 'content://tree/doc/z',
        relativePath: 'z.txt',
        isDirectory: false,
        sizeBytes: 5,
        modified: DateTime.fromMillisecondsSinceEpoch(0),
      );
      final r = inv([_file('a.txt'), bad]);
      expect(r.items.map((i) => i.relativePath), ['a.txt']);
      expect(r.skipped.single.relativePath, 'z.txt');
      expect(r.skipped.single.reason, 'unreadable');
    });

    test('a path that escapes the folder is skipped', () {
      final r = inv([_file('../evil.txt'), _file('ok.txt')], recursive: true);
      expect(r.items.map((i) => i.relativePath), ['ok.txt']);
      expect(r.skipped.single.reason, 'unsafe path');
    });

    test('an empty grant is empty, and says so', () {
      final r = inv([]);
      expect(r.items, isEmpty);
      expect(r.skipped, isEmpty);
    });

    test('the document uri survives flat placement', () {
      final r = inv([_file('sub/c.txt')], recursive: true);
      final flat = BulkPlan.applyPlacement(r.items, BulkPlacement.flatFolder);
      expect(flat.single.docUri, 'content://tree/doc/sub/c.txt');
      expect(flat.single.outRelPath, 'c.txt.latch');
    });

    test('safeFolderName never yields a path separator', () {
      expect(BulkPlan.safeFolderName('a/b\\c'), 'a_b_c');
      expect(BulkPlan.safeFolderName(''), 'folder');
    });
  });

  group('SafBridge tree calls', () {
    final calls = <MethodCall>[];
    Object? Function(MethodCall)? handler;

    setUp(() {
      calls.clear();
      handler = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, (c) async {
            calls.add(c);
            final h = handler;
            return h == null ? null : h(c);
          });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SafBridge.channel, null);
    });

    test('listTree sends its arguments and decodes entries', () async {
      handler = (_) => {
        'rootName': 'Docs',
        'entries': [
          {
            'uri': 'content://t/1',
            'rel': 'a.txt',
            'isDir': false,
            'size': 7,
            'modified': 5000,
            'prefix': Uint8List.fromList([9, 9]),
          },
          {
            'uri': 'content://t/2',
            'rel': 'sub',
            'isDir': true,
            'size': 0,
            'modified': 0,
          },
        ],
      };
      final l = await SafBridge.listTree(
        'content://t',
        recursive: true,
        prefixLength: 56,
      );
      expect(calls.single.method, 'listTree');
      expect(calls.single.arguments, {
        'treeUri': 'content://t',
        'recursive': true,
        'prefixLength': 56,
      });
      expect(l.rootName, 'Docs');
      expect(l.entries, hasLength(2));
      expect(l.entries.first.sizeBytes, 7);
      expect(l.entries.first.prefix, [9, 9]);
      expect(l.entries.last.isDirectory, isTrue);
      expect(l.entries.last.prefix, isNull);
    });

    test('listTree throws rather than reporting an empty folder', () async {
      handler = (_) => throw PlatformException(code: 'saf_error');
      expect(
        SafBridge.listTree('content://t', recursive: false),
        throwsA(isA<PlatformException>()),
      );
      handler = (_) => null;
      expect(
        SafBridge.listTree('content://t', recursive: false),
        throwsA(isA<StateError>()),
      );
    });

    test('copyToCache and deleteDocumentUri send uri and path', () async {
      await SafBridge.copyToCache('content://t/1', '/cache/x');
      await SafBridge.deleteDocumentUri('content://t/1');
      expect(calls[0].method, 'copyToCache');
      expect(calls[0].arguments, {
        'uri': 'content://t/1',
        'destPath': '/cache/x',
      });
      expect(calls[1].method, 'delete');
      expect(calls[1].arguments, {'uri': 'content://t/1'});
    });
  });

  group('SafSource', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('saf_source_'));
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('enumerate stages under <tmp>/latch_src/<folder name>', () async {
      Uint8List? seenPrefix;
      final inv = await SafSource.enumerate(
        'content://t',
        BulkMode.encrypt,
        recursive: false,
        tempDir: tmp.path,
        lister: (uri, {required recursive, prefixLength = 0}) async {
          seenPrefix = Uint8List(prefixLength);
          return SafTreeListing(rootName: 'My/Docs', entries: [_file('a.txt')]);
        },
      );
      expect(seenPrefix!.length, sniffPrefixLength);
      expect(inv.root, '${tmp.path}/latch_src/My_Docs');
      expect(inv.items.single.sourcePath, '${inv.root}/a.txt');
    });

    test('stage copies every item and reports progress', () async {
      final r = BulkPlan.fromTreeListing(
        SafTreeListing(
          rootName: 'D',
          entries: [_file('a.txt'), _file('sub/b.txt')],
        ),
        treeUri: 'content://t',
        stagingRoot: '${tmp.path}/stage',
        mode: BulkMode.encrypt,
        recursive: true,
      );
      final copied = <String, String>{};
      final progress = <int>[];
      await SafSource.stage(
        r.items,
        copier: (uri, dest) async => copied[uri] = dest,
        onProgress: (d, t) => progress.add(d * 100 ~/ t),
      );
      expect(copied.length, 2);
      expect(
        copied['content://tree/doc/sub/b.txt'],
        '${tmp.path}/stage/sub/b.txt',
      );
      expect(progress, [50, 100]);
    });

    test('stage names the file it could not read and stops there', () async {
      final r = BulkPlan.fromTreeListing(
        SafTreeListing(
          rootName: 'D',
          entries: [_file('a.txt'), _file('b.txt'), _file('c.txt')],
        ),
        treeUri: 'content://t',
        stagingRoot: '${tmp.path}/stage',
        mode: BulkMode.encrypt,
        recursive: false,
      );
      final seen = <String>[];
      await expectLater(
        SafSource.stage(
          r.items,
          copier: (uri, dest) async {
            seen.add(uri);
            if (uri.endsWith('b.txt')) throw PlatformException(code: 'x');
          },
        ),
        throwsA(
          isA<SourceStagingError>().having(
            (e) => e.relativePath,
            'relativePath',
            'b.txt',
          ),
        ),
      );
      expect(seen.length, 2);
    });

    test('stage stops copying once the run is abandoned', () async {
      final r = BulkPlan.fromTreeListing(
        SafTreeListing(
          rootName: 'D',
          entries: [_file('a.txt'), _file('b.txt'), _file('c.txt')],
        ),
        treeUri: 'content://t',
        stagingRoot: '${tmp.path}/stage',
        mode: BulkMode.encrypt,
        recursive: false,
      );
      var cancelled = false;
      var copies = 0;
      await SafSource.stage(
        r.items,
        copier: (uri, dest) async {
          copies++;
          cancelled = true;
        },
        isCancelled: () => cancelled,
      );
      expect(copies, 1);
    });

    test('sweep removes the staged tree and tolerates a missing one', () {
      final root = Directory('${tmp.path}/stage/sub')
        ..createSync(recursive: true);
      File('${root.path}/p.txt').writeAsStringSync('plaintext');
      SafSource.sweep('${tmp.path}/stage');
      expect(Directory('${tmp.path}/stage').existsSync(), isFalse);
      SafSource.sweep('${tmp.path}/stage');
    });

    BulkItem staged(String rel) {
      final f = File('${tmp.path}/$rel')..createSync(recursive: true);
      return BulkItem(
        sourcePath: f.path,
        relativePath: rel,
        sizeBytes: 0,
        stampAtEnumeration: EntryStamp(
          kind: EntryKind.file,
          sizeBytes: 0,
          modified: DateTime.fromMillisecondsSinceEpoch(0),
        ),
        outRelPath: '$rel.latch',
        docUri: 'content://tree/doc/$rel',
      );
    }

    test('deleteSource removes the document, then the staged copy', () async {
      final item = staged('a.txt');
      final removedUris = <String>[];
      final ok = await SafSource.deleteSource(
        item,
        remover: (u) async => removedUris.add(u),
      );
      expect(ok, isTrue);
      expect(removedUris, ['content://tree/doc/a.txt']);
      expect(File(item.sourcePath).existsSync(), isFalse);
    });

    test('a refused delete leaves both the document and the copy', () async {
      final item = staged('a.txt');
      final ok = await SafSource.deleteSource(
        item,
        remover: (_) async => throw PlatformException(code: 'denied'),
      );
      expect(ok, isFalse);
      expect(File(item.sourcePath).existsSync(), isTrue);
    });

    test(
      'removeVerifiedSources routes through the hook, gated on landing',
      () async {
        final landed = staged('landed.txt');
        final failed = staged('failed.txt');
        final refused = staged('refused.txt');
        final deleted = <String>[];
        final removed = await removeVerifiedSources(
          verifiedPaths: [
            landed.sourcePath,
            failed.sourcePath,
            refused.sourcePath,
          ],
          relocated: [
            RelocatedOutput('o1', sourcePath: landed.sourcePath),
            RelocatedOutput('o2', failed: true, sourcePath: failed.sourcePath),
            RelocatedOutput('o3', sourcePath: refused.sourcePath),
          ],
          deleteOne: (path) async {
            deleted.add(path);
            return path != refused.sourcePath;
          },
        );
        expect(removed, {landed.sourcePath});
        expect(deleted, [landed.sourcePath, refused.sourcePath]);
      },
    );
  });
}
