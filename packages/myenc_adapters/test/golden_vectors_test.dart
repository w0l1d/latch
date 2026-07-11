import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:myenc_adapters/src/crypto/sodium_crypto_adapter.dart';

/// Cross-implementation golden vectors.
///
/// The fixtures under test/golden/ are produced by tool/gen_golden_vectors.py,
/// an independent reference that uses argon2-cffi (a separate Argon2 codebase)
/// for KDF derivation and libsodium via ctypes for the secretbox/secretstream
/// primitives — it never touches the Dart implementation. If Latch can decrypt
/// them and re-derive the same KEKs, the two implementations agree on the v1
/// format down to the byte. This is the interop guard that lets the format be
/// frozen (task 5.2).
Uint8List _hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

File _golden(String name) {
  // Tests run with CWD = package root (packages/myenc_adapters).
  return File('test/golden/$name');
}

Future<List<int>> _collect(Stream<Uint8List> s) async {
  final out = <int>[];
  await for (final c in s) {
    out.addAll(c);
  }
  return out;
}

void main() {
  late SodiumSumo sodium;
  late SodiumCryptoAdapter adapter;

  setUpAll(() async {
    sodium = await SodiumSumoInit.init();
  });
  setUp(() => adapter = SodiumCryptoAdapter(sodium));

  group('KDF golden vectors (argon2-cffi ↔ libsodium)', () {
    test('argon2idDerive reproduces every independent KEK', () {
      final cases = (jsonDecode(_golden('golden_kdf.json').readAsStringSync())
          as List)
          .cast<Map<String, dynamic>>();
      expect(cases, isNotEmpty);
      for (final c in cases) {
        final kek = adapter.argon2idDerive(
          passphrase: _hex(c['passphrase_hex'] as String),
          salt: _hex(c['salt_hex'] as String),
          opslimit: c['opslimit'] as int,
          memlimit: c['memlimit_kib'] as int,
          outputLength: 32,
        );
        expect(_bytesHex(kek), c['kek_hex'],
            reason: 'KEK mismatch for salt ${c['salt_hex']}');
      }
    });
  });

  group('End-to-end .latch v1 golden fixture', () {
    late Uint8List latch;
    late Map<String, dynamic> meta;

    setUp(() {
      latch = _golden('golden_v1.latch').readAsBytesSync();
      meta = jsonDecode(_golden('golden_v1.json').readAsStringSync())
          as Map<String, dynamic>;
    });

    test('header decodes to the independently-written field values', () {
      final (hdr, _) = MyencCodec.decodeHeader(latch);
      expect(hdr.version, 1);
      expect(hdr.flags, meta['flags']);
      expect(hdr.kdfId, FileHeader.kdfArgon2id);
      expect(hdr.cipherId, FileHeader.cipherXchacha20Poly1305);
      expect(_bytesHex(hdr.salt), meta['salt_hex']);
      expect(_bytesHex(hdr.keyIdHint), meta['key_id_hint_hex']);
      expect(hdr.opslimit, meta['opslimit']);
      expect(hdr.memlimit, meta['memlimit_kib']);
      expect(hdr.chunkSize, meta['chunk_size']);
      expect(hdr.wraps.single.type, WrapType.passphrase);
      expect(hdr.encryptedFilename, isNotNull);
    });

    test('decrypts to the expected plaintext', () async {
      final plain = await _collect(EnvelopeService(adapter).decrypt(
        ciphertext: Stream.value(latch),
        passphrase: utf8.encode(meta['passphrase'] as String),
      ));
      expect(_bytesHex(Uint8List.fromList(plain)), meta['plaintext_hex']);
    });

    test('recovers the encrypted filename', () {
      final (hdr, _) = MyencCodec.decodeHeader(latch);
      final dek = DekWrap.unwrapPassphrase(
        crypto: adapter,
        entry: hdr.wraps.single,
        passphrase: utf8.encode(meta['passphrase'] as String),
        salt: hdr.salt,
        opslimit: hdr.opslimit,
        memlimit: hdr.memlimit,
      );
      final name = EnvelopeService.decryptFilename(
        crypto: adapter, header: hdr, dek: dek);
      expect(name, isNotNull);
      expect(utf8.decode(name!), meta['filename']);
    });

    test('wrong passphrase is rejected', () {
      expect(
        () => _collect(EnvelopeService(adapter).decrypt(
          ciphertext: Stream.value(latch),
          passphrase: utf8.encode(meta['wrong_passphrase'] as String),
        )),
        throwsA(isA<WrongPassphraseError>()),
      );
    });

    test('a single flipped body byte fails closed', () {
      final tampered = Uint8List.fromList(latch);
      tampered[tampered.length - 1] ^= 0x01; // last byte of the FINAL tag/MAC
      expect(
        () => _collect(EnvelopeService(adapter).decrypt(
          ciphertext: Stream.value(tampered),
          passphrase: utf8.encode(meta['passphrase'] as String),
        )),
        throwsA(isA<CorruptedFileError>()),
      );
    });
  });
}

String _bytesHex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
