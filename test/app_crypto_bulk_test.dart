import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:latch/core/app_crypto.dart';
import 'package:latch/core/bulk_plan.dart' show BulkKeyMode;
import 'package:latch/core/output_plan.dart';
import 'package:latch/core/verified_delete.dart';
import 'package:latch/shared/error_messages.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Real-isolate coverage for the bulk additions to the worker: mirrored output
/// paths and the staging-tree sweep on cancel. Plain `test()` on purpose —
/// `testWidgets` runs a fake clock and cannot drive a spawned isolate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pass = 'a strong enough passphrase';
  late Directory tmp;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppCrypto.init();
  });
  setUp(() => tmp = Directory.systemTemp.createTempSync('latch_bulk_test'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Uint8List bytes(int n, int seed) =>
      Uint8List.fromList(List.generate(n, (i) => (i * seed) % 251));

  File put(String rel, Uint8List data) => File('${tmp.path}/$rel')
    ..createSync(recursive: true)
    ..writeAsBytesSync(data);

  test(
    'mirrored encrypt then decrypt restores the tree byte-for-byte',
    () async {
      final a = bytes(3000, 3);
      final b = bytes(70000, 5);
      final srcA = put('src/a.txt', a);
      final srcB = put('src/sub/deep/b.bin', b);

      final encDir = '${tmp.path}/enc';
      final outs = <String?>[];
      await for (final _ in AppCrypto.encryptFiles(
        [srcA.path, srcB.path],
        pass,
        outputDir: encDir,
        outRelPaths: ['a.txt.latch', 'sub/deep/b.bin.latch'],
        onFileResult: (_, ok, _, out) {
          expect(ok, isTrue);
          outs.add(out);
        },
      )) {}
      expect(File('$encDir/a.txt.latch').existsSync(), isTrue);
      expect(File('$encDir/sub/deep/b.bin.latch').existsSync(), isTrue);
      expect(outs, ['$encDir/a.txt.latch', '$encDir/sub/deep/b.bin.latch']);

      final decDir = '${tmp.path}/dec';
      await for (final _ in AppCrypto.decryptFiles(
        ['$encDir/a.txt.latch', '$encDir/sub/deep/b.bin.latch'],
        pass,
        outputDir: decDir,
        outRelPaths: ['a.txt', 'sub/deep/b.bin'],
        onFileResult: (_, ok, _, _) => expect(ok, isTrue),
      )) {}
      expect(File('$decDir/a.txt').readAsBytesSync(), a);
      expect(File('$decDir/sub/deep/b.bin').readAsBytesSync(), b);
    },
  );

  test(
    'a collision at the mirrored path is renamed, never overwritten',
    () async {
      final src = put('src/a.txt', bytes(100, 7));
      final dest = '${tmp.path}/enc';
      File('$dest/a.txt.latch')
        ..createSync(recursive: true)
        ..writeAsStringSync('existing');

      String? out;
      await for (final _ in AppCrypto.encryptFiles(
        [src.path],
        pass,
        outputDir: dest,
        outRelPaths: ['a.txt.latch'],
        onFileResult: (_, _, _, o) => out = o,
      )) {}

      expect(File('$dest/a.txt.latch').readAsStringSync(), 'existing');
      expect(out, isNot('$dest/a.txt.latch'));
      expect(File(out!).existsSync(), isTrue);
    },
  );

  test('without outRelPaths behaviour is the historical flat layout', () async {
    final src = put('src/sub/a.txt', bytes(100, 7));
    final dest = '${tmp.path}/flat';
    Directory(dest).createSync();
    await for (final _ in AppCrypto.encryptFiles(
      [src.path],
      pass,
      outputDir: dest,
    )) {}
    expect(File('$dest/a.txt.latch').existsSync(), isTrue);
  });

  test(
    'flat placement: same-named files in different folders both survive',
    () async {
      final a1 = bytes(500, 3);
      final a2 = bytes(900, 5);
      final s1 = put('src/one/a.txt', a1);
      final s2 = put('src/two/a.txt', a2);
      final dest = '${tmp.path}/flat';

      final outs = <String>[];
      await for (final _ in AppCrypto.encryptFiles(
        [s1.path, s2.path],
        pass,
        outputDir: dest,
        outRelPaths: ['a.txt.latch', 'a.txt.latch'],
        onFileResult: (_, ok, _, out) {
          expect(ok, isTrue);
          outs.add(out!);
        },
      )) {}
      expect(outs.toSet().length, 2, reason: 'no output replaced another');
      expect(Directory(dest).listSync().length, 2);

      final plain = '${tmp.path}/plain';
      Directory(plain).createSync();
      final got = <List<int>>[];
      await for (final _ in AppCrypto.decryptFiles(
        outs,
        pass,
        outputDir: plain,
        onFileResult: (_, ok, _, out) {
          expect(ok, isTrue);
          got.add(File(out!).readAsBytesSync());
        },
      )) {}
      expect(got, containsAll([a1, a2]));
    },
  );

  test('cancelling a mirrored decrypt sweeps the staging tree', () async {
    final files = <String>[];
    final rels = <String?>[];
    final encDir = '${tmp.path}/enc';
    final srcs = <String>[];
    for (var i = 0; i < 4; i++) {
      srcs.add(put('src/d$i/f$i.bin', bytes(200000, i + 2)).path);
      rels.add('d$i/f$i.bin.latch');
    }
    await for (final _ in AppCrypto.encryptFiles(
      srcs,
      pass,
      outputDir: encDir,
      outRelPaths: rels,
    )) {}
    for (var i = 0; i < 4; i++) {
      files.add('$encDir/d$i/f$i.bin.latch');
    }

    final staging = '${tmp.path}/staging';
    Directory(staging).createSync();
    var finished = 0;
    final sub = AppCrypto.decryptFiles(
      files,
      pass,
      outputDir: staging,
      stagingDir: staging,
      outRelPaths: [for (var i = 0; i < 4; i++) 'd$i/f$i.bin'],
      onFileResult: (_, ok, _, _) => finished++,
    ).listen((_) {});

    // Wait for the first file to land in staging, then cancel mid-batch.
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (finished < 1 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(finished, greaterThanOrEqualTo(1));
    expect(finished, lessThan(4), reason: 'must cancel before the batch ends');
    await sub.cancel();

    final sweepBy = DateTime.now().add(const Duration(seconds: 5));
    while (Directory(staging).existsSync() &&
        DateTime.now().isBefore(sweepBy)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      Directory(staging).existsSync(),
      isFalse,
      reason: 'staged plaintext must not survive a cancel',
    );
  });

  test('a completed batch leaves its staging tree for relocation', () async {
    final src = put('src/a.txt', bytes(100, 7));
    final staging = '${tmp.path}/staging';
    Directory(staging).createSync();
    await for (final _ in AppCrypto.encryptFiles(
      [src.path],
      pass,
      outputDir: staging,
      stagingDir: staging,
      outRelPaths: ['a.txt.latch'],
    )) {}
    expect(File('$staging/a.txt.latch').existsSync(), isTrue);
  });

  test(
    'a volume that fills mid-batch fails the rest for lack of space, not as a write error',
    () async {
      // A real 2 MB FAT volume, so the worker hits a genuine ENOSPC.
      final img = '${tmp.path}/small.dmg';
      final mnt = '${tmp.path}/mnt';
      Directory(mnt).createSync();
      expect(
        Process.runSync('hdiutil', [
          'create',
          '-size',
          '2m',
          '-fs',
          'MS-DOS',
          '-volname',
          'LATCHFULL',
          img,
        ]).exitCode,
        0,
      );
      expect(
        Process.runSync('hdiutil', [
          'attach',
          img,
          '-mountpoint',
          mnt,
        ]).exitCode,
        0,
      );
      addTearDown(() => Process.runSync('hdiutil', ['detach', mnt, '-force']));

      final srcs = [
        for (var i = 0; i < 4; i++)
          put('src/f$i.bin', bytes(700 * 1024, i + 3)),
      ];
      final results = <String, (bool, String?)>{};
      await for (final _ in AppCrypto.encryptFiles(
        [for (final f in srcs) f.path],
        pass,
        outputDir: mnt,
        outRelPaths: [for (var i = 0; i < 4; i++) 'f$i.bin.latch'],
        onFileResult: (path, ok, err, _) => results[path] = (ok, err),
      )) {}

      expect(results.length, 4, reason: 'every file gets a result');
      final outcomes = [for (final f in srcs) results[f.path]!];
      final firstFail = outcomes.indexWhere((r) => !r.$1);
      expect(
        firstFail,
        greaterThan(-1),
        reason: 'the volume should have filled',
      );
      for (var i = firstFail; i < 4; i++) {
        expect(outcomes[i].$1, isFalse);
        expect(outcomes[i].$2, contains('InsufficientSpaceError'));
      }
      for (var i = 0; i < firstFail; i++) {
        expect(outcomes[i].$1, isTrue);
      }
      expect(userMessageForError(outcomes[firstFail].$2!), contains('space'));
    },
    skip: Platform.isMacOS ? false : 'needs hdiutil to build a tiny volume',
  );

  test(
    'memory does not scale with file size: 96 MB costs about what 1 MB does',
    () async {
      // The key derivation alone holds ~64 MB (Argon2id memlimit), so absolute
      // RSS says nothing; what must not happen is growth with the file.
      Future<double> peakGrowthMb(int mb) async {
        final f = File('${tmp.path}/f$mb.bin')..createSync();
        final raf = f.openSync(mode: FileMode.write);
        final block = bytes(1024 * 1024, 7);
        for (var i = 0; i < mb; i++) {
          raf.writeFromSync(block);
        }
        raf.closeSync();
        final base = ProcessInfo.currentRss;
        var peak = base;
        final timer = Timer.periodic(const Duration(milliseconds: 2), (_) {
          if (ProcessInfo.currentRss > peak) peak = ProcessInfo.currentRss;
        });
        bool? ok;
        await for (final _ in AppCrypto.encryptFiles(
          [f.path],
          pass,
          verifyDelete: true,
          onFileResult: (_, o, _, _) => ok = o,
        )) {}
        timer.cancel();
        expect(ok, isTrue);
        return (peak - base) / (1024 * 1024);
      }

      await peakGrowthMb(1); // warm-up: first spawn pays one-off allocations
      // A short run can finish between two samples and miss the Argon2 peak;
      // the best of a few is the baseline the big run is compared against.
      var small = 0.0;
      for (var i = 0; i < 3; i++) {
        final g = await peakGrowthMb(1);
        if (g > small) small = g;
      }
      final big = await peakGrowthMb(96);
      expect(
        big - small,
        lessThan(40),
        reason:
            '1 MB peaked +${small.toStringAsFixed(1)} MB, '
            '96 MB peaked +${big.toStringAsFixed(1)} MB',
      );
    },
  );

  group('decrypt with container removal', () {
    Future<String> lock(String rel, Uint8List data, {String pw = pass}) async {
      final src = put(rel, data);
      String? out;
      await for (final _ in AppCrypto.encryptFiles(
        [src.path],
        pw,
        onFileResult: (_, ok, _, o) {
          expect(ok, isTrue);
          out = o;
        },
      )) {}
      src.deleteSync();
      return out!;
    }

    test('verified container is removed once the plaintext matches', () async {
      final data = bytes(50000, 11);
      final c = await lock('in/a.bin', data);
      final events = <String>[];
      await for (final _ in AppCrypto.decryptFiles(
        [c],
        pass,
        deleteOriginals: true,
        verifyDelete: true,
        onFileResult: (_, ok, _, _) => events.add('result:$ok'),
        onFileVerified: (_, v, r) => events.add('verified:$v:$r'),
      )) {}
      expect(events, ['result:true', 'verified:true:true']);
      expect(File(c).existsSync(), isFalse);
      expect(File('${tmp.path}/in/a.bin').readAsBytesSync(), data);
    });

    test('staged bulk run verifies but leaves the container for the '
        'main isolate to remove after relocation', () async {
      final c = await lock('in/a.bin', bytes(1000, 3));
      final staging = '${tmp.path}/stage';
      Directory(staging).createSync();
      bool? removed;
      bool? verified;
      await for (final _ in AppCrypto.decryptFiles(
        [c],
        pass,
        outputDir: staging,
        stagingDir: staging,
        outRelPaths: ['a.bin'],
        deleteOriginals: true,
        verifyDelete: true,
        onFileVerified: (_, v, r) {
          verified = v;
          removed = r;
        },
      )) {}
      expect(verified, isTrue);
      expect(removed, isFalse);
      expect(File(c).existsSync(), isTrue);
    });

    test(
      'wrong passphrase fails that file only and keeps its container',
      () async {
        final good = await lock('in/good.bin', bytes(500, 3));
        final other = await lock(
          'in/other.bin',
          bytes(500, 5),
          pw: 'someone else',
        );
        final results = <String, bool>{};
        await for (final _ in AppCrypto.decryptFiles(
          [good, other],
          pass,
          deleteOriginals: true,
          verifyDelete: true,
          onFileResult: (p, ok, _, _) => results[p] = ok,
        )) {}
        expect(results, {good: true, other: false});
        expect(File(good).existsSync(), isFalse);
        expect(File(other).existsSync(), isTrue);
        expect(File('${tmp.path}/in/other.bin').existsSync(), isFalse);
      },
    );

    test('a tampered container never emits plaintext and is kept', () async {
      final c = await lock('in/t.bin', bytes(200000, 3));
      final raw = File(c).readAsBytesSync();
      raw[raw.length - 40] ^= 0xFF;
      File(c).writeAsBytesSync(raw);
      bool? ok;
      await for (final _ in AppCrypto.decryptFiles(
        [c],
        pass,
        deleteOriginals: true,
        verifyDelete: true,
        onFileResult: (_, o, _, _) => ok = o,
      )) {}
      expect(ok, isFalse);
      expect(File(c).existsSync(), isTrue);
      expect(File('${tmp.path}/in/t.bin').existsSync(), isFalse);
      expect(
        Directory(
          '${tmp.path}/in',
        ).listSync().where((e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
    });
  });

  group('removeVerifiedSources', () {
    test('removes only inputs whose output reached a destination', () async {
      final landed = put('s/landed', bytes(10, 1));
      final failed = put('s/failed', bytes(10, 2));
      final cached = put('s/cached', bytes(10, 3));
      final unlisted = put('s/unlisted', bytes(10, 4));
      final removed = await removeVerifiedSources(
        verifiedPaths: [landed.path, failed.path, cached.path, unlisted.path],
        relocated: [
          RelocatedOutput('x', sourcePath: landed.path),
          RelocatedOutput('y', failed: true, sourcePath: failed.path),
          RelocatedOutput('z', keptInCache: true, sourcePath: cached.path),
        ],
      );
      expect(removed, {landed.path});
      expect(landed.existsSync(), isFalse);
      expect(failed.existsSync(), isTrue);
      expect(cached.existsSync(), isTrue);
      expect(unlisted.existsSync(), isTrue);
    });
  });

  group('key mode', () {
    Future<List<FileHeader>> encryptThree(BulkKeyMode mode) async {
      final srcs = [
        for (var i = 0; i < 3; i++)
          put('k${mode.name}/f$i.bin', bytes(500 + i, 3 + i)),
      ];
      final dir = '${tmp.path}/enc_${mode.name}';
      await for (final _ in AppCrypto.encryptFiles(
        [for (final f in srcs) f.path],
        pass,
        outputDir: dir,
        outRelPaths: [for (var i = 0; i < 3; i++) 'f$i.bin.latch'],
        keyMode: mode,
        onFileResult: (_, ok, _, _) => expect(ok, isTrue),
      )) {}
      return [
        for (var i = 0; i < 3; i++)
          MyencCodec.decodeHeader(
            File('$dir/f$i.bin.latch').readAsBytesSync(),
          ).$1,
      ];
    }

    test(
      'shared mode: one salt, distinct stream headers, normal decrypt',
      () async {
        final headers = await encryptThree(BulkKeyMode.sharedPerBatch);
        expect({for (final h in headers) h.salt.join(',')}.length, 1);
        expect(
          {for (final h in headers) h.secretstreamHeader.join(',')}.length,
          3,
        );

        final decDir = '${tmp.path}/dec_shared';
        await for (final _ in AppCrypto.decryptFiles(
          [
            for (var i = 0; i < 3; i++)
              '${tmp.path}/enc_sharedPerBatch/f$i.bin.latch',
          ],
          pass,
          outputDir: decDir,
          outRelPaths: [for (var i = 0; i < 3; i++) 'f$i.bin'],
          onFileResult: (_, ok, _, _) => expect(ok, isTrue),
        )) {}
        for (var i = 0; i < 3; i++) {
          expect(
            File('$decDir/f$i.bin').readAsBytesSync(),
            bytes(500 + i, 3 + i),
          );
        }
      },
    );

    test('shared mode still rejects a wrong passphrase', () async {
      await encryptThree(BulkKeyMode.sharedPerBatch);
      var anyOk = false;
      await for (final _ in AppCrypto.decryptFiles(
        ['${tmp.path}/enc_sharedPerBatch/f0.bin.latch'],
        'not the passphrase',
        outputDir: '${tmp.path}/dec_wrong',
        outRelPaths: ['f0.bin'],
        onFileResult: (_, ok, _, _) => anyOk = anyOk || ok,
      )) {}
      expect(anyOk, isFalse);
      expect(File('${tmp.path}/dec_wrong/f0.bin').existsSync(), isFalse);
    });

    test('per-file mode (default): every container has its own salt', () async {
      final headers = await encryptThree(BulkKeyMode.perFile);
      expect({for (final h in headers) h.salt.join(',')}.length, 3);
    });

    test('two shared runs do not reuse a salt across operations', () async {
      final first = await encryptThree(BulkKeyMode.sharedPerBatch);
      File('${tmp.path}/enc_sharedPerBatch').deleteSync(recursive: true);
      final second = await encryptThree(BulkKeyMode.sharedPerBatch);
      expect(first.first.salt, isNot(second.first.salt));
    });
  });
}
