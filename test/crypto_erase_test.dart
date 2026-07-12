import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:latch/core/crypto_erase.dart';

/// Header bytes that the codec can decode (so eraseHeader can find the
/// header boundary). Key-id must be 16 bytes, wraps list non-empty,
/// secretstream header 24 bytes.
Uint8List _validHeader() {
  return MyencCodec.encodeHeader(FileHeader(
    version: 1,
    flags: 0,
    kdfId: FileHeader.kdfArgon2id,
    salt: Uint8List.fromList(List.generate(16, (i) => i)),
    opslimit: 3,
    memlimit: 65536,
    cipherId: FileHeader.cipherXchacha20Poly1305,
    chunkSize: 65536,
    keyIdHint: Uint8List(16),
    wraps: [
      WrapEntry(type: WrapType.passphrase, bytes: Uint8List(72)),
    ],
    secretstreamHeader: Uint8List(24),
  ));
}

void main() {
  late Directory tmpDir;

  setUp(() async {
    tmpDir = await Directory.systemTemp.createTemp('latch_shred_test');
  });
  tearDown(() async {
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  group('CryptoErase.eraseHeader', () {
    test('overwrites the magic bytes and returns header length', () async {
      final header = _validHeader();
      final body = Uint8List.fromList(List.generate(200, (i) => i + 200));
      final path = '${tmpDir.path}/a.latch';
      await File(path).writeAsBytes([...header, ...body]);

      final destroyedLen = await CryptoErase.eraseHeader(path);
      expect(destroyedLen, header.length);

      final after = await File(path).readAsBytes();
      // First headerLen bytes should NOT match the original header
      final first = after.sublist(0, header.length);
      expect(first, isNot(equals(header)));

      // Magic "LATCH" must be gone
      final magic = utf8.decode(after.sublist(0, 5));
      expect(magic, isNot('LATCH'));

      // Body beyond the header should be intact
      final afterBody = after.sublist(header.length);
      expect(afterBody, equals(body));
    });

    test('body beyond header is untouched', () async {
      final header = _validHeader();
      final body = Uint8List.fromList(List.generate(500, (i) => 0xAA));
      final path = '${tmpDir.path}/b.latch';
      await File(path).writeAsBytes([...header, ...body]);

      await CryptoErase.eraseHeader(path);
      final after = await File(path).readAsBytes();
      final afterBody = after.sublist(header.length);
      expect(afterBody, everyElement(0xAA));
    });

    test('throws and leaves file unmodified for a non-latch file', () async {
      final original = Uint8List.fromList(List.filled(100, 0x42));
      final path = '${tmpDir.path}/not.latch';
      await File(path).writeAsBytes(original);

      await expectLater(
        () => CryptoErase.eraseHeader(path),
        throwsA(isA<NotALatchFileError>()),
      );
      // File must be unmodified
      expect(await File(path).readAsBytes(), equals(original));
    });

    test('throws for a truncated header', () async {
      final full = _validHeader();
      final truncated = full.sublist(0, 30);
      final path = '${tmpDir.path}/trunc.latch';
      await File(path).writeAsBytes(truncated);

      await expectLater(
        () => CryptoErase.eraseHeader(path),
        throwsA(isA<CorruptedFileError>()),
      );
      // File must be unmodified
      expect(await File(path).readAsBytes(), equals(truncated));
    });
  });

  group('CryptoErase.eraseAndDelete', () {
    test('erases header then deletes the file', () async {
      final header = _validHeader();
      final path = '${tmpDir.path}/c.latch';
      await File(path).writeAsBytes([...header, ...List.filled(50, 0xCC)]);

      await CryptoErase.eraseAndDelete(path);
      expect(await File(path).exists(), isFalse);
    });

    test('throws on non-latch file — file still exists, unmodified', () async {
      final original = Uint8List.fromList(List.filled(80, 0x7F));
      final path = '${tmpDir.path}/d.latch';
      await File(path).writeAsBytes(original);

      await expectLater(
        () => CryptoErase.eraseAndDelete(path),
        throwsA(isA<NotALatchFileError>()),
      );
      expect(await File(path).exists(), isTrue);
      expect(await File(path).readAsBytes(), equals(original));
    });
  });
}
