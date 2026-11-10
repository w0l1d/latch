// On-device pipeline tests.
//
// These run INSIDE the installed app process, on the real phone:
//   flutter test integration_test/pipeline_test.dart -d <device>
//
// Why they exist alongside test/: everything under test/ runs on the host
// with a host build of libsodium against a desktop filesystem. That cannot
// catch a native-asset packaging regression, an arm64-only isolate spawn
// failure, or a `dart:io` behaviour that differs on scoped storage. This
// file exercises the same AppCrypto -> latchWorker -> SodiumCryptoAdapter ->
// FileIoDart path the shipped app uses, on the shipped architecture.
//
// Deliberately plain `test()` and not `testWidgets()`: the crypto worker is a
// spawned isolate driven by the real event loop, which `testWidgets`' fake
// clock cannot drive (see CLAUDE.md "Testing gotchas").
//
// No UI is driven here. DocumentsUI, SAF grants and the save-folder prompt
// are covered by the Maestro suite in e2e/ — they are only observable through
// the real system file picker.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:latch/core/app_crypto.dart';
import 'package:latch/core/bulk_plan.dart';

/// One file's outcome from a batch, collected through `onFileResult`.
class _Outcome {
  final bool ok;
  final String? error;
  final String? outPath;
  const _Outcome(this.ok, this.error, this.outPath);

  @override
  String toString() => 'ok=$ok outPath=$outPath error=$error';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Fixture layout: separate source / container / plaintext directories, so a
  // decrypt never has to rename around the source it came from (collision
  // suffixes would make output paths unpredictable between runs).
  late Directory root;
  late Directory src;
  late Directory enc;
  late Directory dec;

  setUpAll(() async {
    // Reads the persisted KDF parameters (falls back to the defaults). Needed
    // once before the first batch, exactly as main() does on cold start.
    await AppCrypto.init();
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('latch_it_');
    src = Directory('${root.path}/src')..createSync();
    enc = Directory('${root.path}/enc')..createSync();
    dec = Directory('${root.path}/dec')..createSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------

  File writeFile(String name, List<int> bytes) {
    final f = File('${src.path}/$name')..writeAsBytesSync(bytes);
    return f;
  }

  Future<Map<String, _Outcome>> encryptBatch(
    List<String> files,
    String passphrase, {
    String? outputDir,
    bool deleteOriginals = false,
    bool verifyDelete = false,
    BulkKeyMode keyMode = BulkKeyMode.perFile,
  }) async {
    final out = <String, _Outcome>{};
    await AppCrypto.encryptFiles(
      files,
      passphrase,
      outputDir: outputDir,
      deleteOriginals: deleteOriginals,
      verifyDelete: verifyDelete,
      keyMode: keyMode,
      onFileResult: (p, ok, err, o) => out[p] = _Outcome(ok, err, o),
    ).drain<void>();
    return out;
  }

  Future<Map<String, _Outcome>> decryptBatch(
    List<String> files,
    String passphrase, {
    String? outputDir,
  }) async {
    final out = <String, _Outcome>{};
    await AppCrypto.decryptFiles(
      files,
      passphrase,
      outputDir: outputDir,
      onFileResult: (p, ok, err, o) => out[p] = _Outcome(ok, err, o),
    ).drain<void>();
    return out;
  }

  /// Asserts the frozen v1 envelope prefix: magic + version byte, read
  /// straight off the device filesystem. Pinning the offset here (rather than
  /// only decoding through MyencCodec) is the point — it fails if the shipped
  /// bytes ever stop starting with `LATCH\x01`.
  void expectV1Prefix(File container) {
    final raf = container.openSync();
    late Uint8List head;
    try {
      head = raf.readSync(6);
    } finally {
      raf.closeSync();
    }
    expect(head.length, 6, reason: 'container shorter than its magic prefix');
    expect(
      String.fromCharCodes(head.sublist(0, 5)),
      'LATCH',
      reason: 'first five bytes must be the v1 magic',
    );
    expect(head[5], 1, reason: 'version byte must be 1 (v1 is frozen)');
  }

  _Outcome single(Map<String, _Outcome> results) {
    expect(results, hasLength(1));
    return results.values.single;
  }

  // ---------------------------------------------------------------------
  // round trips
  // ---------------------------------------------------------------------

  test('text file: encrypt then decrypt returns the identical bytes', () async {
    const body = 'hello from the device\nsecond line\n';
    final srcFile = writeFile('notes.txt', utf8.encode(body));

    final e = single(
      await encryptBatch([srcFile.path], 'pw-one', outputDir: enc.path),
    );
    expect(e.ok, isTrue, reason: '$e');
    final container = File(e.outPath!);
    expect(container.existsSync(), isTrue);
    expectV1Prefix(container);
    // The plaintext must not be readable in the container.
    expect(
      utf8.decode(container.readAsBytesSync(), allowMalformed: true),
      isNot(contains('hello from the device')),
    );
    // Originals kept by default.
    expect(srcFile.existsSync(), isTrue);

    final d = single(
      await decryptBatch([container.path], 'pw-one', outputDir: dec.path),
    );
    expect(d.ok, isTrue, reason: '$d');
    expect(File(d.outPath!).readAsStringSync(), body);
  });

  test('empty file round trips and produces a header-only container', () async {
    final srcFile = writeFile('empty.bin', const <int>[]);

    final e = single(
      await encryptBatch([srcFile.path], 'pw-one', outputDir: enc.path),
    );
    expect(e.ok, isTrue, reason: '$e');
    final container = File(e.outPath!);
    expectV1Prefix(container);
    expect(
      container.lengthSync(),
      greaterThan(56),
      reason: 'header must exist',
    );

    final d = single(
      await decryptBatch([container.path], 'pw-one', outputDir: dec.path),
    );
    expect(d.ok, isTrue, reason: '$d');
    expect(File(d.outPath!).lengthSync(), 0);
  });

  test('unicode filename round trips', () async {
    const name = 'café notes ☐ 日本語.txt';
    final srcFile = writeFile(name, utf8.encode('unicode name'));

    final e = single(
      await encryptBatch([srcFile.path], 'pw-one', outputDir: enc.path),
    );
    expect(e.ok, isTrue, reason: '$e');

    final d = single(
      await decryptBatch([e.outPath!], 'pw-one', outputDir: dec.path),
    );
    expect(d.ok, isTrue, reason: '$d');
    // The length is what matters; a mangled name still carries the bytes.
    expect(File(d.outPath!).readAsStringSync(), 'unicode name');
    expect(dec.listSync(), hasLength(1));
  });

  // 65536 is FileHeader.defaultChunkSize: these sizes pin the sizes either
  // side of every chunk boundary, where an off-by-one in framing shows up as
  // a FINAL-tag failure rather than a wrong length.
  for (final size in <int>[1, 65535, 65536, 65537, 131072, 2 * 1024 * 1024]) {
    test('round trips at chunk-boundary size $size', () async {
      final bytes = Uint8List.fromList(
        List<int>.generate(size, (i) => (i * 31 + 7) & 0xFF),
      );
      final srcFile = writeFile('size-$size.bin', bytes);

      final e = single(
        await encryptBatch([srcFile.path], 'pw-one', outputDir: enc.path),
      );
      expect(e.ok, isTrue, reason: '$e');

      final d = single(
        await decryptBatch([e.outPath!], 'pw-one', outputDir: dec.path),
      );
      expect(d.ok, isTrue, reason: '$d');
      expect(File(d.outPath!).lengthSync(), size);
      expect(File(d.outPath!).readAsBytesSync(), bytes);
    });
  }

  // ---------------------------------------------------------------------
  // failure paths — the security-relevant ones
  // ---------------------------------------------------------------------

  test('wrong passphrase produces no plaintext and reports an error', () async {
    final srcFile = writeFile('secret.txt', utf8.encode('must not leak'));
    final e = single(
      await encryptBatch([srcFile.path], 'right-pw', outputDir: enc.path),
    );
    expect(e.ok, isTrue);

    final d = single(
      await decryptBatch([e.outPath!], 'wrong-pw', outputDir: dec.path),
    );
    expect(d.ok, isFalse, reason: 'a wrong passphrase must never succeed');
    expect(d.error, isNotNull);
    expect(d.outPath, isNull);
    // The whole point: nothing at all was written.
    expect(
      dec.listSync(recursive: true),
      isEmpty,
      reason: 'a failed decrypt must leave no plaintext, not even a temp',
    );

    // The container itself is untouched, so the right passphrase still works.
    final ok = single(
      await decryptBatch([e.outPath!], 'right-pw', outputDir: dec.path),
    );
    expect(ok.ok, isTrue, reason: '$ok');
    expect(File(ok.outPath!).readAsStringSync(), 'must not leak');
  });

  test(
    'tampered container is rejected and leaves no partial plaintext',
    () async {
      final body = Uint8List.fromList(
        List<int>.generate(4096, (i) => i & 0xFF),
      );
      final srcFile = writeFile('payload.bin', body);
      final e = single(
        await encryptBatch([srcFile.path], 'pw-one', outputDir: enc.path),
      );
      expect(e.ok, isTrue);

      // Flip one byte deep in the body, past the header, where the chunk MAC
      // lives. A container that decrypts after this would mean the tag over the
      // ciphertext is not being verified.
      final container = File(e.outPath!);
      final bytes = container.readAsBytesSync();
      final target = bytes.length - 8;
      bytes[target] = bytes[target] ^ 0xFF;
      container.writeAsBytesSync(bytes);

      final d = single(
        await decryptBatch([container.path], 'pw-one', outputDir: dec.path),
      );
      expect(d.ok, isFalse, reason: 'a tampered body must not decrypt');
      expect(d.outPath, isNull);
      expect(
        dec.listSync(recursive: true),
        isEmpty,
        reason: 'no partial plaintext may survive a failed chunk tag',
      );
    },
  );

  test('a non-.latch file is refused, not silently treated as one', () async {
    final notAContainer = writeFile(
      'plain.txt',
      utf8.encode('i am not encrypted'),
    );

    final d = single(
      await decryptBatch([notAContainer.path], 'pw-one', outputDir: dec.path),
    );
    expect(d.ok, isFalse);
    expect(dec.listSync(recursive: true), isEmpty);
  });

  // ---------------------------------------------------------------------
  // verified deletion — the one path allowed to remove user data
  // ---------------------------------------------------------------------

  test(
    'verified delete removes the source only after the container decrypts',
    () async {
      final srcFile = writeFile('to-remove.txt', utf8.encode('keep me safe'));
      final e = single(
        await encryptBatch(
          [srcFile.path],
          'pw-one',
          outputDir: enc.path,
          deleteOriginals: true,
          verifyDelete: true,
        ),
      );
      expect(e.ok, isTrue, reason: '$e');
      expect(
        srcFile.existsSync(),
        isFalse,
        reason: 'verified delete should have removed the source',
      );

      // And the container really carries the content — deletion was earned.
      final d = single(
        await decryptBatch([e.outPath!], 'pw-one', outputDir: dec.path),
      );
      expect(d.ok, isTrue, reason: '$d');
      expect(File(d.outPath!).readAsStringSync(), 'keep me safe');
    },
  );

  // ---------------------------------------------------------------------
  // batch modes
  // ---------------------------------------------------------------------

  test(
    'shared-per-batch KEK still yields independently decryptable files',
    () async {
      final files = <String>[
        writeFile('a.txt', utf8.encode('alpha')).path,
        writeFile('b.txt', utf8.encode('beta')).path,
        writeFile('c.txt', utf8.encode('gamma')).path,
      ];

      final e = await encryptBatch(
        files,
        'shared-pw',
        outputDir: enc.path,
        keyMode: BulkKeyMode.sharedPerBatch,
      );
      expect(e.values.every((o) => o.ok), isTrue, reason: '$e');

      // Every container decrypts on its own — the batch shares a KEK, never a DEK.
      for (final o in e.values) {
        final d = single(
          await decryptBatch([o.outPath!], 'shared-pw', outputDir: dec.path),
        );
        expect(d.ok, isTrue, reason: '$d');
      }
      expect(dec.listSync(), hasLength(3));
    },
  );

  test('same-name outputs in one batch never overwrite each other', () async {
    final first = writeFile('dup.txt', utf8.encode('one'));
    final second = File('${root.path}/src2/dup.txt')
      ..createSync(recursive: true)
      ..writeAsBytesSync(utf8.encode('two'));

    final e = await encryptBatch(
      [first.path, second.path],
      'pw-one',
      outputDir: enc.path,
    );
    expect(e.values.every((o) => o.ok), isTrue, reason: '$e');
    expect(
      e.values.map((o) => o.outPath).toSet(),
      hasLength(2),
      reason: 'two same-named sources must produce two distinct containers',
    );
    expect(enc.listSync(), hasLength(2));
  });

  // ---------------------------------------------------------------------
  // rewrap
  // ---------------------------------------------------------------------

  test('change passphrase rewraps in place: old fails, new works', () async {
    final srcFile = writeFile('rewrap.txt', utf8.encode('reusable payload'));
    final e = single(
      await encryptBatch([srcFile.path], 'old-pw', outputDir: enc.path),
    );
    expect(e.ok, isTrue);
    final container = File(e.outPath!);
    final bodyBefore = container.readAsBytesSync();

    await AppCrypto.changePassphraseFiles(
      [container.path],
      'old-pw',
      'new-pw',
    ).drain<void>();

    // Rewrapping must not re-encrypt the body: only the wrap and salt change.
    final bodyAfter = container.readAsBytesSync();
    expect(bodyAfter.length, bodyBefore.length);

    final old = single(
      await decryptBatch([container.path], 'old-pw', outputDir: dec.path),
    );
    expect(old.ok, isFalse, reason: 'the old passphrase must stop working');

    final fresh = single(
      await decryptBatch([container.path], 'new-pw', outputDir: dec.path),
    );
    expect(fresh.ok, isTrue, reason: '$fresh');
    expect(File(fresh.outPath!).readAsStringSync(), 'reusable payload');
  });
}
