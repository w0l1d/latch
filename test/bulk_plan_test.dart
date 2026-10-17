import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/bulk_plan.dart';
import 'package:myenc_core/myenc_core.dart';

// Read-only use of the frozen golden container as a known-valid header.
final Uint8List _golden = File(
  'packages/myenc_adapters/test/golden/golden_v1.latch',
).readAsBytesSync();

void _write(Directory d, String rel, List<int> bytes) {
  final f = File('${d.path}/$rel')..createSync(recursive: true);
  f.writeAsBytesSync(bytes);
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('bulk_plan_'));
  tearDown(() => root.deleteSync(recursive: true));

  group('encrypt enumeration', () {
    test('non-recursive lists depth 1 and counts what it left out', () {
      _write(root, 'a.txt', [1, 2, 3]);
      _write(root, 'b.txt', [4]);
      _write(root, 'sub/c.txt', [5]);
      _write(root, 'sub/deep/d.txt', [6]);

      final inv = BulkPlan.enumerateSync(root.path, BulkMode.encrypt);

      expect(inv.items.map((i) => i.relativePath), ['a.txt', 'b.txt']);
      expect(inv.items.map((i) => i.outRelPath), [
        'a.txt.latch',
        'b.txt.latch',
      ]);
      expect(inv.subfolders, 1);
      expect(inv.excludedInSubfolders, 2);
      expect(inv.totalBytes, 4);
    });

    test('recursive includes subfolders and excludes nothing', () {
      _write(root, 'a.txt', [1]);
      _write(root, 'sub/c.txt', [2, 2]);
      _write(root, 'sub/deep/d.txt', [3, 3, 3]);

      final inv = BulkPlan.enumerateSync(
        root.path,
        BulkMode.encrypt,
        recursive: true,
      );

      expect(inv.items.map((i) => i.relativePath), [
        'a.txt',
        'sub/c.txt',
        'sub/deep/d.txt',
      ]);
      expect(inv.excludedInSubfolders, 0);
      expect(inv.subfolders, 2);
      expect(inv.totalBytes, 6);
    });

    test('every file is in exactly one of items or skipped', () {
      _write(root, 'ok.txt', [1]);
      _write(root, 'target.txt', [1]);
      Link('${root.path}/link').createSync('${root.path}/target.txt');

      final inv = BulkPlan.enumerateSync(root.path, BulkMode.encrypt);

      final all = [
        ...inv.items.map((i) => i.relativePath),
        ...inv.skipped.map((s) => s.relativePath),
      ]..sort();
      expect(all, ['link', 'ok.txt', 'target.txt']);
      expect(inv.skipped.single.relativePath, 'link');
      expect(inv.skipped.single.reason, 'symbolic link');
    });

    test('a symlink to an ancestor is skipped and never looped on', () {
      _write(root, 'sub/f.txt', [1]);
      Link('${root.path}/sub/up').createSync(root.path);

      final inv = BulkPlan.enumerateSync(
        root.path,
        BulkMode.encrypt,
        recursive: true,
      );

      expect(inv.items.map((i) => i.relativePath), ['sub/f.txt']);
      expect(inv.skipped.map((s) => s.relativePath), ['sub/up']);
    });

    test('counts files that already look like containers by header', () {
      _write(root, 'renamed.bin', _golden);
      _write(root, 'plain.txt', [1, 2, 3]);

      final inv = BulkPlan.enumerateSync(root.path, BulkMode.encrypt);

      expect(inv.alreadyContainers, 1);
      expect(inv.items, hasLength(2));
    });

    test('an empty file is an item, not a silent drop', () {
      _write(root, 'empty.txt', []);
      final inv = BulkPlan.enumerateSync(root.path, BulkMode.encrypt);
      expect(inv.items.single.sizeBytes, 0);
    });

    test('item paths are relative, slash-separated and never contain ..', () {
      _write(root, 'a b/ü.txt', [1]);
      final inv = BulkPlan.enumerateSync(
        root.path,
        BulkMode.encrypt,
        recursive: true,
      );
      for (final i in inv.items) {
        expect(i.relativePath.startsWith('/'), isFalse);
        expect(i.relativePath.split('/'), isNot(contains('..')));
        expect(i.outRelPath, '${i.relativePath}.latch');
      }
    });

    test('an empty folder yields an empty inventory', () {
      final inv = BulkPlan.enumerateSync(root.path, BulkMode.encrypt);
      expect(inv.items, isEmpty);
      expect(inv.skipped, isEmpty);
    });
  });

  group('decrypt enumeration', () {
    test('finds containers by header, whatever they are called', () {
      _write(root, 'a.txt.latch', _golden);
      _write(root, 'renamed.dat', _golden);

      final inv = BulkPlan.enumerateSync(root.path, BulkMode.decrypt);

      expect(inv.items.map((i) => i.relativePath), [
        'a.txt.latch',
        'renamed.dat',
      ]);
      expect(inv.items.map((i) => i.outRelPath), [
        'a.txt',
        'renamed.dat.decrypted',
      ]);
    });

    test('a fake .latch is named individually in the skip report', () {
      _write(root, 'fake.latch', [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      _write(root, 'notes.txt', List.filled(100, 65));

      final inv = BulkPlan.enumerateSync(root.path, BulkMode.decrypt);

      expect(inv.items, isEmpty);
      final byName = {for (final s in inv.skipped) s.relativePath: s.reason};
      expect(byName['fake.latch'], 'named .latch but not a Latch container');
      expect(byName['notes.txt'], 'not a Latch container');
    });

    test('a container from a newer version is skipped with its own reason', () {
      final newer = Uint8List.fromList(_golden)..[5] = 0xEE;
      _write(root, 'future.latch', newer);

      final inv = BulkPlan.enumerateSync(root.path, BulkMode.decrypt);

      expect(inv.items, isEmpty);
      expect(inv.skipped.single.reason, 'made by a newer version of Latch');
    });

    test('a truncated container is skipped, not failed', () {
      _write(root, 'cut.latch', _golden.sublist(0, 20));
      final inv = BulkPlan.enumerateSync(root.path, BulkMode.decrypt);
      expect(inv.items, isEmpty);
      expect(inv.skipped.single.relativePath, 'cut.latch');
    });

    test('recursive decrypt mirrors subfolder layout in outRelPath', () {
      _write(root, 'sub/x.pdf.latch', _golden);
      final inv = BulkPlan.enumerateSync(
        root.path,
        BulkMode.decrypt,
        recursive: true,
      );
      expect(inv.items.single.outRelPath, 'sub/x.pdf');
    });
  });

  group('recursion (US3)', () {
    test('a deep nested tree is mirrored exactly, in both modes', () {
      const rels = [
        'a.txt',
        'd1/b.txt',
        'd1/d2/c.txt',
        'd1/d2/d3/d.txt',
        'e/f.txt',
      ];
      for (final r in rels) {
        _write(root, r, [1, 2, 3]);
      }
      final enc = BulkPlan.enumerateSync(
        root.path,
        BulkMode.encrypt,
        recursive: true,
      );
      expect(enc.items.map((i) => i.relativePath).toSet(), rels.toSet());
      expect(enc.items.map((i) => i.outRelPath).toSet(), {
        for (final r in rels) '$r.latch',
      });
      expect(enc.excludedInSubfolders, 0);

      for (final r in rels) {
        File('${root.path}/$r').deleteSync();
        _write(root, '$r.latch', _golden);
      }
      final dec = BulkPlan.enumerateSync(
        root.path,
        BulkMode.decrypt,
        recursive: true,
      );
      expect(dec.items.map((i) => i.outRelPath).toSet(), rels.toSet());
    });

    test('off by default: BulkOptions and enumeration ignore subfolders', () {
      expect(const BulkOptions().recursive, isFalse);
      _write(root, 'a.txt', [1]);
      _write(root, 'sub/deep/b.txt', [2]);
      final inv = BulkPlan.enumerateSync(root.path, BulkMode.encrypt);
      expect(inv.items.map((i) => i.relativePath), ['a.txt']);
      expect(inv.recursive, isFalse);
      expect(inv.excludedInSubfolders, 1);
    });

    test(
      'a 10,000-entry walk does not block the calling isolate',
      () async {
        for (var i = 0; i < 100; i++) {
          for (var j = 0; j < 100; j++) {
            File('${root.path}/d$i/f$j.txt')
              ..createSync(recursive: true)
              ..writeAsBytesSync([1]);
          }
        }
        var maxGap = Duration.zero;
        var last = Stopwatch()..start();
        final ticker = Timer.periodic(const Duration(milliseconds: 10), (_) {
          if (last.elapsed > maxGap) maxGap = last.elapsed;
          last = Stopwatch()..start();
        });
        final inv = await BulkPlan.enumerate(
          root.path,
          BulkMode.encrypt,
          recursive: true,
        );
        ticker.cancel();
        expect(inv.items.length, 10000);
        expect(maxGap, lessThan(const Duration(milliseconds: 250)));
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  test('enumerate() runs the same walk in a spawned isolate', () async {
    _write(root, 'a.txt', [1]);
    _write(root, 'sub/b.txt', [2]);
    final inv = await BulkPlan.enumerate(
      root.path,
      BulkMode.encrypt,
      recursive: true,
    );
    expect(inv.items.map((i) => i.relativePath), ['a.txt', 'sub/b.txt']);
  });

  group('pre-flight space check', () {
    BulkInventory inv(List<int> sizes) => BulkInventory(
      root: '/r',
      mode: BulkMode.encrypt,
      recursive: false,
      items: [
        for (var i = 0; i < sizes.length; i++)
          BulkItem(
            sourcePath: '/r/f$i',
            relativePath: 'f$i',
            sizeBytes: sizes[i],
            stampAtEnumeration: EntryStamp(
              kind: EntryKind.file,
              sizeBytes: sizes[i],
              modified: DateTime(2026),
            ),
            outRelPath: 'f$i.latch',
          ),
      ],
      skipped: const [],
      subfolders: 0,
      excludedInSubfolders: 0,
      alreadyContainers: 0,
    );

    test('proceeds when there is room', () async {
      final r = await BulkPlan.preflight(
        inventory: inv([1000, 2000]),
        freeSpace: _FakeFree({'/dest': 1 << 20}),
        destinationPath: '/dest',
      );
      expect(r, isNull);
    });

    test('refuses a short destination and names the shortfall', () async {
      final need = BulkPlan.peakBytes([1000, 2000], mode: BulkMode.encrypt);
      final r = await BulkPlan.preflight(
        inventory: inv([1000, 2000]),
        freeSpace: _FakeFree({'/dest': need - 7}),
        destinationPath: '/dest',
      );
      expect(r!.location, SpaceLocation.destination);
      expect(r.shortfallBytes, 7);
    });

    test('names staging when only the staging volume is short', () async {
      final r = await BulkPlan.preflight(
        inventory: inv([5000]),
        freeSpace: _FakeFree({'/dest': 1 << 30, '/cache': 100}),
        destinationPath: '/dest',
        stagingPath: '/cache',
      );
      expect(r!.location, SpaceLocation.staging);
      expect(r.shortfallBytes, greaterThan(0));
    });

    test(
      'names the destination when staging is fine but it is short',
      () async {
        final r = await BulkPlan.preflight(
          inventory: inv([5000]),
          freeSpace: _FakeFree({'/dest': 100, '/cache': 1 << 30}),
          destinationPath: '/dest',
          stagingPath: '/cache',
        );
        expect(r!.location, SpaceLocation.destination);
      },
    );

    test('an unanswered question proceeds, never refuses', () async {
      final r = await BulkPlan.preflight(
        inventory: inv([1 << 40]),
        freeSpace: _FakeFree({}),
        destinationPath: '/dest',
        stagingPath: '/cache',
      );
      expect(r, isNull);
    });

    test(
      'reclaimed originals lower the peak only when they free the volume',
      () {
        final sizes = [1000, 1000, 1000, 1000];
        final total = BulkPlan.peakBytes(sizes, mode: BulkMode.encrypt);
        final reclaimed = BulkPlan.peakBytes(
          sizes,
          mode: BulkMode.encrypt,
          reclaimsSources: true,
        );
        expect(reclaimed, lessThan(total));
        // Each file nets only its overhead once its original is gone; the last
        // file's full container is on top of that.
        final overhead = BulkPlan.containerBytes(1000) - 1000;
        expect(reclaimed, 3 * overhead + BulkPlan.containerBytes(1000));
      },
    );

    test('deleting is not credited when the volumes differ', () async {
      final sizes = [1000, 1000, 1000, 1000];
      final peakWithCredit = BulkPlan.peakBytes(
        sizes,
        mode: BulkMode.encrypt,
        reclaimsSources: true,
      );
      final r = await BulkPlan.preflight(
        inventory: inv(sizes),
        freeSpace: _FakeFree({'/dest': peakWithCredit}),
        destinationPath: '/dest',
        deleteSources: true,
      );
      expect(r, isNotNull);
      final ok = await BulkPlan.preflight(
        inventory: inv(sizes),
        freeSpace: _FakeFree({'/dest': peakWithCredit}),
        destinationPath: '/dest',
        deleteSources: true,
        destinationSharesSourceVolume: true,
      );
      expect(ok, isNull);
    });

    test('the container estimate is never below the real container size', () {
      for (final n in [0, 1, 65535, 65536, 65537, 1 << 20]) {
        expect(BulkPlan.containerBytes(n), greaterThanOrEqualTo(n + 56));
      }
    });
  });

  group('estimateDuration', () {
    test('zero files take no time', () {
      expect(
        BulkPlan.estimateDuration(
          fileCount: 0,
          totalBytes: 0,
          keyMode: BulkKeyMode.perFile,
        ),
        Duration.zero,
      );
    });

    test('per-file keys cost more derivations than a shared batch key', () {
      final per = BulkPlan.estimateDuration(
        fileCount: 100,
        totalBytes: 1000,
        keyMode: BulkKeyMode.perFile,
      );
      final shared = BulkPlan.estimateDuration(
        fileCount: 100,
        totalBytes: 1000,
        keyMode: BulkKeyMode.sharedPerBatch,
      );
      expect(per, greaterThan(shared * 50));
    });

    test('verification makes the estimate larger', () {
      Duration d(bool v) => BulkPlan.estimateDuration(
        fileCount: 10,
        totalBytes: 100 << 20,
        keyMode: BulkKeyMode.perFile,
        verified: v,
      );
      expect(d(true), greaterThan(d(false)));
    });
  });
}

class _FakeFree implements FreeSpacePort {
  final Map<String, int> free;
  _FakeFree(this.free);
  @override
  Future<int?> freeBytesAt(String path) async => free[path];
}
