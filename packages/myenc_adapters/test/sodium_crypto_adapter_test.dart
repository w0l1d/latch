import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:myenc_adapters/src/crypto/sodium_crypto_adapter.dart';

void main() {
  late SodiumSumo sodium;
  late SodiumCryptoAdapter adapter;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });

  setUp(() {
    adapter = SodiumCryptoAdapter(sodium);
  });

  group('SodiumCryptoAdapter.randomBytes', () {
    test('returns the requested length', () {
      expect(adapter.randomBytes(16).length, 16);
      expect(adapter.randomBytes(32).length, 32);
    });

    test('two calls return different bytes', () {
      final a = adapter.randomBytes(16);
      final b = adapter.randomBytes(16);
      expect(a, isNot(equals(b)));
    });
  });

  group('SodiumCryptoAdapter.argon2idDerive', () {
    test('returns the requested output length', () {
      final result = adapter.argon2idDerive(
        passphrase: Uint8List.fromList('pw'.codeUnits),
        salt: Uint8List(16),
        opslimit: 2,
        memlimit: 65536,
        outputLength: 32,
      );
      expect(result.length, 32);
    });

    test('deterministic: same inputs yield same output', () {
      final params = (
        passphrase: Uint8List.fromList('pw'.codeUnits),
        salt: Uint8List(16),
        opslimit: 2,
        memlimit: 65536,
        outputLength: 32,
      );
      final a = adapter.argon2idDerive(
        passphrase: params.passphrase,
        salt: params.salt,
        opslimit: params.opslimit,
        memlimit: params.memlimit,
        outputLength: params.outputLength,
      );
      final b = adapter.argon2idDerive(
        passphrase: params.passphrase,
        salt: params.salt,
        opslimit: params.opslimit,
        memlimit: params.memlimit,
        outputLength: params.outputLength,
      );
      expect(a, equals(b));
    });

    test('different passphrases yield different outputs', () {
      final salt = Uint8List(16);
      final a = adapter.argon2idDerive(
        passphrase: Uint8List.fromList('pw1'.codeUnits),
        salt: salt,
        opslimit: 2,
        memlimit: 65536,
        outputLength: 32,
      );
      final b = adapter.argon2idDerive(
        passphrase: Uint8List.fromList('pw2'.codeUnits),
        salt: salt,
        opslimit: 2,
        memlimit: 65536,
        outputLength: 32,
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('SodiumCryptoAdapter.secretboxSeal / secretboxOpen', () {
    test('round-trips plaintext', () {
      final key = adapter.randomBytes(32);
      final plain = Uint8List.fromList('hello sodium'.codeUnits);
      final sealed = adapter.secretboxSeal(plain, key);
      final opened = adapter.secretboxOpen(sealed, key);
      expect(opened, equals(plain));
    });

    test('throws WrongPassphraseError for wrong key', () {
      final key = adapter.randomBytes(32);
      final wrongKey = adapter.randomBytes(32);
      final sealed = adapter.secretboxSeal(
          Uint8List.fromList('secret'.codeUnits), key);
      expect(() => adapter.secretboxOpen(sealed, wrongKey),
          throwsA(isA<WrongPassphraseError>()));
    });

    test('throws WrongPassphraseError for tampered ciphertext', () {
      final key = adapter.randomBytes(32);
      final sealed = adapter.secretboxSeal(
          Uint8List.fromList('secret'.codeUnits), key);
      final tampered = Uint8List.fromList(sealed);
      tampered[tampered.length - 1] ^= 0xFF;
      expect(() => adapter.secretboxOpen(tampered, key),
          throwsA(isA<WrongPassphraseError>()));
    });
  });

  group('SodiumCryptoAdapter encrypt/decrypt transformers', () {
    Future<Uint8List> collectStream(Stream<Uint8List> s) async {
      final chunks = <int>[];
      await for (final c in s) {
        chunks.addAll(c);
      }
      return Uint8List.fromList(chunks);
    }

    Stream<Uint8List> streamOf(Uint8List data) async* {
      yield data;
    }

    test('round-trips small plaintext', () async {
      final key = adapter.randomBytes(32);
      const chunkSize = 65536;
      final plain = Uint8List.fromList('Hello sodium adapter!'.codeUnits);

      final encrypted = await collectStream(
          streamOf(plain).transform(
              adapter.createEncryptTransformer(key, chunkSize)));
      final decrypted = await collectStream(
          streamOf(encrypted).transform(
              adapter.createDecryptTransformer(key, chunkSize)));
      expect(decrypted, equals(plain));
    });

    test('round-trips empty plaintext', () async {
      final key = adapter.randomBytes(32);
      const chunkSize = 65536;

      final empty = Stream<Uint8List>.empty();
      final encrypted = await collectStream(
          empty.transform(adapter.createEncryptTransformer(key, chunkSize)));
      final decrypted = await collectStream(
          streamOf(encrypted).transform(
              adapter.createDecryptTransformer(key, chunkSize)));
      expect(decrypted, isEmpty);
    });

    test('round-trips multi-chunk plaintext', () async {
      final key = adapter.randomBytes(32);
      const chunkSize = 256;
      final plain =
          Uint8List.fromList(List.generate(1000, (i) => i & 0xFF));

      final encrypted = await collectStream(
          streamOf(plain).transform(
              adapter.createEncryptTransformer(key, chunkSize)));
      final decrypted = await collectStream(
          streamOf(encrypted).transform(
              adapter.createDecryptTransformer(key, chunkSize)));
      expect(decrypted, equals(plain));
    });

    test('secretstreamHeaderBytes is 24', () {
      expect(adapter.secretstreamHeaderBytes, 24);
    });

    test('encrypt transformer output starts with 24-byte secretstream header',
        () async {
      final key = adapter.randomBytes(32);
      const chunkSize = 65536;
      final plain = Uint8List.fromList([1, 2, 3]);

      final encrypted = await collectStream(
          streamOf(plain).transform(
              adapter.createEncryptTransformer(key, chunkSize)));
      expect(encrypted.length,
          greaterThanOrEqualTo(adapter.secretstreamHeaderBytes));
    });

    test('decrypt transformer throws CorruptedFileError on tampered body',
        () async {
      final key = adapter.randomBytes(32);
      const chunkSize = 65536;
      final plain = Uint8List.fromList('tamper test'.codeUnits);

      final encrypted = await collectStream(
          streamOf(plain).transform(
              adapter.createEncryptTransformer(key, chunkSize)));

      // Flip a bit in the body (after the 24-byte header)
      final tampered = Uint8List.fromList(encrypted);
      tampered[adapter.secretstreamHeaderBytes + 5] ^= 0xFF;

      expect(
        () => collectStream(streamOf(tampered)
            .transform(adapter.createDecryptTransformer(key, chunkSize))),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test(
        'decrypt transformer throws CorruptedFileError when truncated (no FINAL)',
        () async {
      final key = adapter.randomBytes(32);
      const chunkSize = 256;
      final plain =
          Uint8List.fromList(List.generate(512, (i) => i & 0xFF));

      final encrypted = await collectStream(
          streamOf(plain).transform(
              adapter.createEncryptTransformer(key, chunkSize)));
      // Truncate to just the header — no encrypted body at all
      final truncated = encrypted.sublist(0, adapter.secretstreamHeaderBytes);

      expect(
        () => collectStream(streamOf(truncated)
            .transform(adapter.createDecryptTransformer(key, chunkSize))),
        throwsA(isA<CorruptedFileError>()),
      );
    });
  });
}
