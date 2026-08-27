// Proves the codec-version-strategies refactor (specs/003) is neutral: every
// `.latch` v1 fixture committed here was produced by the UNTOUCHED
// pre-refactor code (see fixtures/compat_v1/generate_fixtures.dart) and must
// keep decrypting identically afterwards. Never regenerate these fixtures
// with the new code — that would stop proving anything.
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
  late Map<String, dynamic> manifest;
  const dir = 'test/fixtures/compat_v1';

  setUpAll(() async {
    final sodium = await SodiumSumoInit.init();
    envelope = EnvelopeService(SodiumCryptoAdapter(sodium));
    manifest =
        jsonDecode(File('$dir/manifest.json').readAsStringSync())
            as Map<String, dynamic>;
  });

  group('compat v1 corpus (pre-refactor fixtures)', () {
    final passphrase = utf8.encode('compat-v1-fixture-passphrase');

    for (final name in [
      'empty',
      'one_byte',
      'small',
      'multi_chunk',
      'binary',
    ]) {
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
