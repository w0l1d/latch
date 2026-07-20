import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:latch/core/app_crypto.dart';

/// End-to-end regression coverage for the batch crypto protocol that runs in
/// the worker isolate (lib/core/isolate_worker.dart) and is consumed by the
/// encrypt/decrypt progress screens.
///
/// The original hang bug: `_encryptOne` emitted a premature `progress 1.0`
/// *before* the batch sent `file_done`, so the UI's completion check fired
/// with an empty result list and threw. These tests pin the invariant the
/// UI now relies on — **every per-file result is delivered before the stream
/// emits its final 1.0** — and prove the stream always terminates.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppCrypto.init();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('latch_batch_test');
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  test(
    'single-file encrypt: last result arrives before the final 1.0',
    () async {
      final src = File('${tmp.path}/note.txt')
        ..writeAsBytesSync(
          Uint8List.fromList(List.generate(5000, (i) => i % 256)),
        );

      final results = <bool>[];
      var doneCountAtFinalProgress = -1;

      await for (final prog in AppCrypto.encryptFiles(
        [src.path],
        'correct horse battery staple',
        onFileResult: (_, ok, _, _) => results.add(ok),
      )) {
        if (prog >= 1.0) doneCountAtFinalProgress = results.length;
      }

      // The invariant the progress screens depend on.
      expect(
        doneCountAtFinalProgress,
        1,
        reason: 'file_done must precede the terminal progress 1.0',
      );
      expect(results, [true]);
      expect(File('${src.path}.latch').existsSync(), isTrue);
    },
  );

  test('multi-file encrypt: all results arrive before the final 1.0', () async {
    final paths = <String>[];
    for (var i = 0; i < 3; i++) {
      final f = File('${tmp.path}/f$i.bin')
        ..writeAsBytesSync(Uint8List.fromList(List.filled(1000 + i, i)));
      paths.add(f.path);
    }

    final results = <bool>[];
    var doneCountAtFinalProgress = -1;

    await for (final prog in AppCrypto.encryptFiles(
      paths,
      'a strong enough passphrase',
      onFileResult: (_, ok, _, _) => results.add(ok),
    )) {
      if (prog >= 1.0) doneCountAtFinalProgress = results.length;
    }

    expect(doneCountAtFinalProgress, 3);
    expect(results, [true, true, true]);
  });

  test('encrypt then decrypt round-trips the original bytes', () async {
    final original = Uint8List.fromList(
      List.generate(70000, (i) => (i * 7) % 256),
    );
    final src = File('${tmp.path}/big.dat')..writeAsBytesSync(original);
    const pass = 'round trip passphrase';

    await AppCrypto.encryptFiles([src.path], pass).drain<void>();
    final enc = '${src.path}.latch';
    expect(File(enc).existsSync(), isTrue);

    final decResults = <bool>[];
    await AppCrypto.decryptFiles(
      [enc],
      pass,
      outputDir: tmp.path,
      onFileResult: (_, ok, _, _) => decResults.add(ok),
    ).drain<void>();

    expect(decResults, [true]);
    // decrypt writes <name without .latch>; a name collision appends _2.
    final restored = File('${tmp.path}/big.dat').existsSync()
        ? File('${tmp.path}/big.dat')
        : File('${tmp.path}/big_2.dat');
    expect(restored.existsSync(), isTrue);
    expect(restored.readAsBytesSync(), original);
  });

  test('wrong passphrase reports a failed result, does not hang', () async {
    final src = File('${tmp.path}/secret.txt')
      ..writeAsBytesSync(Uint8List.fromList([1, 2, 3, 4]));
    await AppCrypto.encryptFiles([
      src.path,
    ], 'the real passphrase').drain<void>();

    final errors = <String?>[];
    await AppCrypto.decryptFiles(
      ['${src.path}.latch'],
      'the WRONG passphrase',
      onFileResult: (_, _, error, _) => errors.add(error),
    ).drain<void>();

    expect(errors.length, 1);
    expect(errors.first, contains('WrongPassphraseError'));
  });

  test('encrypt with outputDir: reported outPath is the real file', () async {
    final outDir = Directory('${tmp.path}/out')..createSync();
    final src = File('${tmp.path}/doc.txt')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(2048, 42)));

    final outPaths = <String?>[];
    await AppCrypto.encryptFiles(
      [src.path],
      'output dir passphrase',
      outputDir: outDir.path,
      onFileResult: (_, _, _, outPath) => outPaths.add(outPath),
    ).drain<void>();

    expect(outPaths.length, 1);
    final reported = outPaths.single;
    expect(reported, isNotNull);
    expect(
      File(reported!).existsSync(),
      isTrue,
      reason: 'the UI shows this path — it must exist on disk',
    );
    expect(
      reported,
      startsWith(outDir.path),
      reason: 'output must land in the chosen folder',
    );
    expect(
      reported,
      isNot('${src.path}.latch'),
      reason: 'with an outputDir the naive input-derived path is wrong',
    );
    // The naive path the old UI fabricated must NOT exist.
    expect(File('${src.path}.latch').existsSync(), isFalse);
  });

  test('collision renaming: outPath reports the renamed file', () async {
    final src = File('${tmp.path}/dup.txt')
      ..writeAsBytesSync(Uint8List.fromList([9, 9, 9]));
    // Occupy the natural output name.
    final squatter = File('${src.path}.latch')
      ..writeAsBytesSync(Uint8List.fromList([0]));

    final outPaths = <String?>[];
    await AppCrypto.encryptFiles(
      [src.path],
      'collision passphrase',
      onFileResult: (_, _, _, outPath) => outPaths.add(outPath),
    ).drain<void>();

    final reported = outPaths.single!;
    expect(
      reported,
      isNot(squatter.path),
      reason: 'must not claim the pre-existing file as its output',
    );
    expect(File(reported).existsSync(), isTrue);
    // The squatter is untouched.
    expect(squatter.readAsBytesSync(), [0]);
  });

  test('decrypt outPath: reported file holds the original bytes', () async {
    final original = Uint8List.fromList(List.generate(3000, (i) => i % 251));
    final src = File('${tmp.path}/orig.bin')..writeAsBytesSync(original);
    const pass = 'decrypt outPath pass';
    await AppCrypto.encryptFiles([src.path], pass).drain<void>();

    final outPaths = <String?>[];
    await AppCrypto.decryptFiles(
      ['${src.path}.latch'],
      pass,
      onFileResult: (_, _, _, outPath) => outPaths.add(outPath),
    ).drain<void>();

    final reported = outPaths.single!;
    // src still exists, so collision renaming must have picked a new name —
    // and the reported path must be that real file with the right contents.
    expect(File(reported).existsSync(), isTrue);
    expect(File(reported).readAsBytesSync(), original);
  });

  test('failed file reports a null outPath', () async {
    final notLatch = File('${tmp.path}/garbage.latch')
      ..writeAsBytesSync(Uint8List.fromList(List.filled(64, 7)));

    final outPaths = <String?>['sentinel'];
    outPaths.clear();
    await AppCrypto.decryptFiles(
      [notLatch.path],
      'whatever',
      onFileResult: (_, ok, _, outPath) {
        expect(ok, isFalse);
        outPaths.add(outPath);
      },
    ).drain<void>();

    expect(outPaths, [null]);
  });
}
