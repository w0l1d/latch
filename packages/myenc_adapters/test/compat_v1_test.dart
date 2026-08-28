// Proves the codec-version-strategies refactor (specs/003) is neutral: every
// `.latch` v1 fixture committed here was produced by the UNTOUCHED
// pre-refactor code (see fixtures/compat_v1/generate_fixtures.dart) and must
// keep decrypting identically afterwards. Never regenerate these fixtures
// with the new code — that would stop proving anything. The manifest's
// "generated_at_commit" field records the exact pre-refactor commit the
// fixtures were produced from, and is pinned by a provenance test below.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:myenc_adapters/src/crypto/sodium_crypto_adapter.dart';

Future<Uint8List> _collect(Stream<Uint8List> s) async {
  final out = <int>[];
  await for (final c in s) {
    out.addAll(c);
  }
  return Uint8List.fromList(out);
}

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late EnvelopeService envelope;
  late SodiumSumo sodium;
  const dir = 'test/fixtures/compat_v1';

  // Read synchronously at declaration time: the per-fixture loops below
  // iterate the manifest's file list to register tests, which happens
  // before setUpAll runs.
  final manifest =
      jsonDecode(File('$dir/manifest.json').readAsStringSync())
          as Map<String, dynamic>;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
    envelope = EnvelopeService(SodiumCryptoAdapter(sodium));
  });

  group('compat v1 corpus (pre-refactor fixtures)', () {
    final passphrase = utf8.encode('compat-v1-fixture-passphrase');
    final names = (manifest['files'] as Map<String, dynamic>).keys.toList()
      ..sort();

    test('fixtures carry old-code provenance at the recorded commit', () {
      expect(manifest['generated_at_commit'], '9fded2f');
      expect(
        manifest['generated_with'],
        contains('before the FormatVersionStrategy extraction'),
      );
    });

    test('corpus covers every planned size/content/chunk kind', () {
      expect(names, [
        'all_bytes',
        'ascii_text',
        'binary',
        'boundary_64k',
        'boundary_plus_1',
        'empty',
        'json',
        'large_1mb',
        'multi_chunk',
        'one_byte',
        'small',
        'unicode_text',
        'zero_bytes',
      ]);
    });

    for (final name in names) {
      test(
        'decrypts $name.latch to the manifest-pinned plaintext hash',
        () async {
          final entry =
              (manifest['files'] as Map<String, dynamic>)[name]
                  as Map<String, dynamic>;
          final latchBytes = File(
            '$dir/${entry['latch_file']}',
          ).readAsBytesSync();

          final plaintext = await _collect(
            envelope.decrypt(
              ciphertext: Stream.value(latchBytes),
              passphrase: Uint8List.fromList(passphrase),
            ),
          );

          expect(plaintext.length, entry['raw_length']);
          expect(_sha256Hex(plaintext), entry['raw_sha256']);
        },
      );
    }

    for (final name in names) {
      test('encrypts $name with the new code and decrypts back to the '
          'manifest-pinned hash', () async {
        final entry =
            (manifest['files'] as Map<String, dynamic>)[name]
                as Map<String, dynamic>;
        final raw = File('$dir/${entry['raw_file']}').readAsBytesSync();
        final kdf = manifest['kdf_params'] as Map<String, dynamic>;

        final ciphertext = await _collect(
          envelope.encrypt(
            plaintext: Stream.value(raw),
            passphrase: Uint8List.fromList(passphrase),
            params: KdfParams(
              opslimit: kdf['opslimit'] as int,
              memlimit: kdf['memlimit'] as int,
            ),
          ),
        );
        final back = await _collect(
          envelope.decrypt(
            ciphertext: Stream.value(ciphertext),
            passphrase: Uint8List.fromList(passphrase),
          ),
        );

        expect(back.length, entry['raw_length']);
        expect(_sha256Hex(back), entry['raw_sha256']);
      });
    }

    // The "same salt" comparison, at the only layer where it is possible:
    // the header encode/decode is a pure function of its fields — including
    // the old code's real random salt, keyIdHint, and secretstream header
    // bytes as frozen in the fixture. Re-encoding the old fixture's parsed
    // header must reproduce the original header bytes exactly.
    for (final name in names) {
      test(
        're-encodes $name\'s header byte-identically (same salt, same bytes)',
        () {
          final entry =
              (manifest['files'] as Map<String, dynamic>)[name]
                  as Map<String, dynamic>;
          final latchBytes = File(
            '$dir/${entry['latch_file']}',
          ).readAsBytesSync();

          final (header, consumed) = MyencCodec.decodeHeader(latchBytes);
          final reencoded = MyencCodec.encodeHeader(header);

          expect(consumed, reencoded.length);
          expect(reencoded, latchBytes.sublist(0, consumed));
        },
      );
    }

    // The deep "same salt" comparison: feed the old fixture's salt, DEK, and
    // wrap nonce back through the new code via a CryptoPort double, so every
    // byte the format CAN hold constant is held constant, then compare
    // everything comparable — scalar fields, wrap bytes on the wire, and the
    // encoded header prefix byte-for-byte. The one region that cannot be
    // reproduced is the secretstream header: libsodium's
    // crypto_secretstream_xchacha20poly1305_init_push generates its 24-byte
    // nonce internally (the C API's header parameter is an OUTPUT, and
    // sodium 4.0.4 exposes no way to inject one), so that region — and the
    // body bytes derived from it — are excluded from the byte comparison.
    // The deterministically-produced file is then decrypted for real and
    // hash-checked against the manifest.
    for (final name in names) {
      test('re-encrypts $name with fixed salt/DEK/wrap-nonce: every '
          'deterministic detail matches the old fixture', () async {
        final entry =
            (manifest['files'] as Map<String, dynamic>)[name]
                as Map<String, dynamic>;
        final raw = File('$dir/${entry['raw_file']}').readAsBytesSync();
        final latchBytes = File(
          '$dir/${entry['latch_file']}',
        ).readAsBytesSync();
        final kdf = manifest['kdf_params'] as Map<String, dynamic>;
        final params = KdfParams(
          opslimit: kdf['opslimit'] as int,
          memlimit: kdf['memlimit'] as int,
        );

        final (oldHeader, oldConsumed) = MyencCodec.decodeHeader(latchBytes);

        // The exact DEK the old code sealed — recoverable because the
        // passphrase is known. Reusing it is what makes the wrap
        // deterministic.
        final realCrypto = SodiumCryptoAdapter(sodium);
        final oldDek = DekWrap.unwrapPassphrase(
          crypto: realCrypto,
          entry: oldHeader.wraps.single,
          passphrase: Uint8List.fromList(passphrase),
          salt: oldHeader.salt,
          opslimit: oldHeader.opslimit,
          memlimit: oldHeader.memlimit,
        );

        // EnvelopeService.encrypt draws randomness in this order:
        // salt(16) via randomBytes, then — with keyIdHint supplied —
        // DEK(32) via randomBytes, then the wrap nonce(24) via
        // secretboxSeal (which the double fixes separately, because the
        // real adapter draws it from libsodium directly).
        final fixedCrypto = _FixedCrypto(
          delegate: realCrypto,
          sodium: sodium,
          randomSequence: [oldHeader.salt, oldDek],
          secretboxNonce: Uint8List.sublistView(
            oldHeader.wraps.single.bytes,
            0,
            24,
          ),
        );
        final fixedEnvelope = EnvelopeService(fixedCrypto);

        final newCiphertext = await _collect(
          fixedEnvelope.encrypt(
            plaintext: Stream.value(raw),
            passphrase: Uint8List.fromList(passphrase),
            params: params,
            keyIdHint: oldHeader.keyIdHint,
            filename: '$name.bin',
          ),
        );

        final (newHeader, newConsumed) = MyencCodec.decodeHeader(newCiphertext);

        // Same shape: same header size, same chunking, same total size.
        expect(newConsumed, oldConsumed);
        expect(newCiphertext.length, latchBytes.length);

        // Every scalar header field.
        expect(newHeader.version, oldHeader.version);
        expect(newHeader.flags, oldHeader.flags);
        expect(newHeader.kdfId, oldHeader.kdfId);
        expect(newHeader.opslimit, oldHeader.opslimit);
        expect(newHeader.memlimit, oldHeader.memlimit);
        expect(newHeader.cipherId, oldHeader.cipherId);
        expect(newHeader.chunkSize, oldHeader.chunkSize);

        // The pinned randomness: salt and key-id hint are byte-identical.
        expect(newHeader.salt, oldHeader.salt);
        expect(newHeader.keyIdHint, oldHeader.keyIdHint);

        // The passphrase wrap is byte-identical — nonce, MAC, ciphertext.
        expect(newHeader.wraps, hasLength(1));
        expect(newHeader.wraps.single.type, oldHeader.wraps.single.type);
        expect(newHeader.wraps.single.bytes, oldHeader.wraps.single.bytes);

        // Sanity: the identical wrap still opens to the old DEK.
        final newDek = DekWrap.unwrapPassphrase(
          crypto: realCrypto,
          entry: newHeader.wraps.single,
          passphrase: Uint8List.fromList(passphrase),
          salt: newHeader.salt,
          opslimit: newHeader.opslimit,
          memlimit: newHeader.memlimit,
        );
        expect(newDek, oldDek);

        // Wire-level: the encoded header is byte-identical everywhere
        // except the uncontrollable secretstream header (see the comment
        // above this loop).
        final comparablePrefix =
            oldConsumed - FileHeader.secretstreamHeaderLength;
        expect(
          newCiphertext.sublist(0, comparablePrefix),
          latchBytes.sublist(0, comparablePrefix),
        );

        // And the deterministic re-encryption still round-trips for real.
        final back = await _collect(
          envelope.decrypt(
            ciphertext: Stream.value(newCiphertext),
            passphrase: Uint8List.fromList(passphrase),
          ),
        );
        expect(back.length, entry['raw_length']);
        expect(_sha256Hex(back), entry['raw_sha256']);
      });
    }

    test(
      'wrong passphrase fails fast, before any body byte is touched',
      () async {
        final latchBytes = File(
          '$dir/${manifest['wrong_passphrase_fixture']}',
        ).readAsBytesSync();
        final wrongPassphrase = utf8.encode(
          manifest['wrong_passphrase'] as String,
        );

        expect(
          () => _collect(
            envelope.decrypt(
              ciphertext: Stream.value(latchBytes),
              passphrase: Uint8List.fromList(wrongPassphrase),
            ),
          ),
          throwsA(isA<WrongPassphraseError>()),
        );
      },
    );

    test(
      'tampered body fails at a chunk tag, never emitting partial plaintext',
      () async {
        final tamperedBytes = File(
          '$dir/${manifest['tampered_body_fixture']}',
        ).readAsBytesSync();

        final emitted = <int>[];
        await expectLater(() async {
          await for (final chunk in envelope.decrypt(
            ciphertext: Stream.value(tamperedBytes),
            passphrase: Uint8List.fromList(passphrase),
          )) {
            emitted.addAll(chunk);
          }
        }(), throwsA(isA<CorruptedFileError>()));
        expect(
          emitted,
          isEmpty,
          reason: 'a tampered body must never leak partial plaintext',
        );
      },
    );
  });
}

/// Delegating CryptoPort double that pins the two randomness entry points
/// EnvelopeService.encrypt reaches through the port: [randomBytes] (salt,
/// DEK) and [secretboxSeal] (the wrap nonce — the real adapter draws it from
/// libsodium directly, bypassing [randomBytes]). Everything else is the real
/// adapter, so argon2id, secretstream, and secretbox cryptography stay real.
class _FixedCrypto implements CryptoPort {
  _FixedCrypto({
    required this.delegate,
    required this.sodium,
    required List<Uint8List> randomSequence,
    required this.secretboxNonce,
  }) : _random = List.of(randomSequence);

  final SodiumCryptoAdapter delegate;
  final SodiumSumo sodium;
  final Uint8List secretboxNonce;
  final List<Uint8List> _random;

  @override
  Uint8List randomBytes(int length) {
    if (_random.isEmpty) {
      throw StateError('fixed random sequence exhausted');
    }
    final next = _random.removeAt(0);
    if (next.length != length) {
      throw StateError(
        'fixed random size mismatch: wanted $length bytes, '
        'sequence serves ${next.length}',
      );
    }
    return Uint8List.fromList(next);
  }

  @override
  Uint8List secretboxSeal(Uint8List plaintext, Uint8List key) {
    // Same wire layout as SodiumCryptoAdapter.secretboxSeal
    // (nonce ‖ MAC ‖ ciphertext), but with the fixed nonce.
    final secureKey = SecureKey.fromList(sodium, key);
    try {
      final encrypted = sodium.crypto.secretBox.easy(
        message: plaintext,
        nonce: secretboxNonce,
        key: secureKey,
      );
      return Uint8List.fromList([...secretboxNonce, ...encrypted]);
    } finally {
      secureKey.dispose();
    }
  }

  @override
  Uint8List argon2idDerive({
    required Uint8List passphrase,
    required Uint8List salt,
    required int opslimit,
    required int memlimit,
    required int outputLength,
  }) => delegate.argon2idDerive(
    passphrase: passphrase,
    salt: salt,
    opslimit: opslimit,
    memlimit: memlimit,
    outputLength: outputLength,
  );

  @override
  Uint8List secretboxOpen(Uint8List ciphertext, Uint8List key) =>
      delegate.secretboxOpen(ciphertext, key);

  @override
  int get secretstreamHeaderBytes => delegate.secretstreamHeaderBytes;

  @override
  StreamTransformer<Uint8List, Uint8List> createEncryptTransformer(
    Uint8List key,
    int chunkSize,
  ) => delegate.createEncryptTransformer(key, chunkSize);

  @override
  StreamTransformer<Uint8List, Uint8List> createDecryptTransformer(
    Uint8List key,
    int chunkSize,
  ) => delegate.createDecryptTransformer(key, chunkSize);

  @override
  Uint8List boxSeal(Uint8List plaintext, Uint8List recipientPublicKey) =>
      delegate.boxSeal(plaintext, recipientPublicKey);

  @override
  Uint8List boxSealOpen(
    Uint8List ciphertext,
    Uint8List publicKey,
    Uint8List secretKey,
  ) => delegate.boxSealOpen(ciphertext, publicKey, secretKey);
}
