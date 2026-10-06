import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:latch/core/app_crypto.dart';
import 'package:latch/core/verified_delete.dart';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium_sumo.dart';

/// Verified deletion: the original goes only after its container reads back as
/// exactly the source. Plain `test()` — real isolate, real libsodium.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pass = 'a strong enough passphrase';
  late Directory tmp;
  late EnvelopeService svc;
  final io = FileIoDart();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppCrypto.init();
    svc = EnvelopeService(SodiumCryptoAdapter(await SodiumSumoInit.init()));
  });
  setUp(() => tmp = Directory.systemTemp.createTempSync('latch_verify_test'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Uint8List bytes(int n, int seed) =>
      Uint8List.fromList(List.generate(n, (i) => (i * seed + 1) % 251));

  File put(String name, Uint8List data) =>
      File('${tmp.path}/$name')..writeAsBytesSync(data);

  Future<String> encrypt(File src, {bool delete = false}) async {
    String? out;
    await for (final _ in AppCrypto.encryptFiles(
      [src.path],
      pass,
      deleteOriginals: delete,
      verifyDelete: true,
      onFileResult: (_, ok, err, o) {
        expect(ok, isTrue, reason: '$err');
        out = o;
      },
    )) {}
    return out!;
  }

  Future<void> verify(String container, String source) =>
      verifyContainerMatchesSource(
        svc: svc,
        io: io,
        containerPath: container,
        sourcePath: source,
        passphrase: Uint8List.fromList(pass.codeUnits),
      );

  test(
    'a good container verifies, across sizes and chunk boundaries',
    () async {
      for (final n in [0, 1, 4095, 65536, 65537, 200000]) {
        final f = put('f$n', bytes(n, 7));
        final c = await encrypt(f);
        await verify(c, f.path);
      }
    },
  );

  test('the original is deleted and reported verified on success', () async {
    final data = bytes(70000, 3);
    final f = put('a.bin', data);
    final flags = <(bool, bool)>[];
    String? out;
    await for (final _ in AppCrypto.encryptFiles(
      [f.path],
      pass,
      deleteOriginals: true,
      verifyDelete: true,
      onFileResult: (_, ok, _, o) {
        expect(ok, isTrue);
        out = o;
      },
      onFileVerified: (_, v, r) => flags.add((v, r)),
    )) {}
    expect(flags, [(true, true)]);
    expect(f.existsSync(), isFalse);
    expect(File(out!).existsSync(), isTrue);
  });

  test(
    'without deleteOriginals the source stays but is still verified',
    () async {
      final f = put('keep.bin', bytes(500, 5));
      final flags = <(bool, bool)>[];
      await for (final _ in AppCrypto.encryptFiles(
        [f.path],
        pass,
        verifyDelete: true,
        onFileResult: (_, ok, _, _) => expect(ok, isTrue),
        onFileVerified: (_, v, r) => flags.add((v, r)),
      )) {}
      expect(flags, [(true, false)]);
      expect(f.existsSync(), isTrue);
    },
  );

  test('a flipped byte in the body fails verification', () async {
    final f = put('a.bin', bytes(70000, 3));
    final c = File(await encrypt(f));
    final b = c.readAsBytesSync();
    b[b.length - 40] ^= 0x01;
    c.writeAsBytesSync(b);
    await expectLater(
      verify(c.path, f.path),
      throwsA(isA<VerificationFailedError>()),
    );
  });

  test('a truncated container (FINAL tag lost) fails verification', () async {
    final f = put('a.bin', bytes(200000, 3));
    final c = File(await encrypt(f));
    final b = c.readAsBytesSync();
    c.writeAsBytesSync(b.sublist(0, b.length - 1000));
    await expectLater(
      verify(c.path, f.path),
      throwsA(isA<VerificationFailedError>()),
    );
  });

  test('a source that differs by one byte, longer or shorter, fails', () async {
    final data = bytes(70000, 3);
    final f = put('a.bin', data);
    final c = await encrypt(f);

    final flipped = Uint8List.fromList(data)..[69999] ^= 1;
    f.writeAsBytesSync(flipped);
    await expectLater(
      verify(c, f.path),
      throwsA(isA<VerificationFailedError>()),
    );

    f.writeAsBytesSync([...data, 0]);
    await expectLater(
      verify(c, f.path),
      throwsA(isA<VerificationFailedError>()),
    );

    f.writeAsBytesSync(data.sublist(0, data.length - 1));
    await expectLater(
      verify(c, f.path),
      throwsA(isA<VerificationFailedError>()),
    );
  });

  test('the wrong passphrase fails verification, never passes it', () async {
    final f = put('a.bin', bytes(100, 3));
    final c = await encrypt(f);
    await expectLater(
      verifyContainerMatchesSource(
        svc: svc,
        io: io,
        containerPath: c,
        sourcePath: f.path,
        passphrase: Uint8List.fromList('another passphrase'.codeUnits),
      ),
      throwsA(isA<VerificationFailedError>()),
    );
  });

  test(
    'a batch mixing good and bad files: bad ones keep their original',
    () async {
      final good = put('good.bin', bytes(1000, 3));
      final gone = File('${tmp.path}/missing.bin');
      final results = <String, bool>{};
      await for (final _ in AppCrypto.encryptFiles(
        [good.path, gone.path],
        pass,
        deleteOriginals: true,
        verifyDelete: true,
        onFileResult: (p, ok, _, _) => results[p] = ok,
      )) {}
      expect(results[good.path], isTrue);
      expect(results[gone.path], isFalse);
      expect(good.existsSync(), isFalse);
    },
  );

  test(
    'a source edited mid-encryption fails: original kept, container gone',
    () async {
      final f = put('big.bin', bytes(24 * 1024 * 1024, 3));
      String? err;
      bool? ok;
      var touched = false;
      await for (final pct in AppCrypto.encryptFiles(
        [f.path],
        pass,
        deleteOriginals: true,
        verifyDelete: true,
        onFileResult: (_, o, e, _) {
          ok = o;
          err = e;
        },
      )) {
        if (!touched && pct > 0 && pct < 1) {
          touched = true;
          f.writeAsBytesSync([1, 2, 3], mode: FileMode.append);
        }
      }
      expect(touched, isTrue, reason: 'progress never arrived mid-file');
      expect(ok, isFalse);
      expect(err, contains('VerificationFailedError'));
      expect(f.existsSync(), isTrue);
      expect(File('${f.path}.latch').existsSync(), isFalse);
      expect(File('${f.path}.latch.tmp').existsSync(), isFalse);
    },
  );
}
