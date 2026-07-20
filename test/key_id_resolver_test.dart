import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:latch/core/key_id_resolver.dart';

Uint8List _headerWithKeyId(Uint8List keyId) {
  return MyencCodec.encodeHeader(
    FileHeader(
      version: 1,
      flags: 0,
      kdfId: FileHeader.kdfArgon2id,
      salt: Uint8List.fromList(List.generate(16, (i) => i)),
      opslimit: 3,
      memlimit: 65536,
      cipherId: FileHeader.cipherXchacha20Poly1305,
      chunkSize: 65536,
      keyIdHint: keyId,
      wraps: [WrapEntry(type: WrapType.passphrase, bytes: Uint8List(72))],
      secretstreamHeader: Uint8List(24),
    ),
  );
}

void main() {
  final keyId = Uint8List.fromList(List.generate(16, (i) => 0xB0 + i));
  const keyIdHex = 'b0b1b2b3b4b5b6b7b8b9babbbcbdbebf';

  group('KeyIdResolver.keyIdHexFromHeader', () {
    test('extracts the key-id from a valid header', () {
      expect(
        KeyIdResolver.keyIdHexFromHeader(_headerWithKeyId(keyId)),
        keyIdHex,
      );
    });

    test('returns null for a non-latch file', () {
      expect(
        KeyIdResolver.keyIdHexFromHeader(
          Uint8List.fromList(List.filled(200, 0x41)),
        ),
        isNull,
      );
    });

    test('returns null for a truncated header', () {
      final full = _headerWithKeyId(keyId);
      expect(KeyIdResolver.keyIdHexFromHeader(full.sublist(0, 30)), isNull);
    });
  });

  group('KeyIdResolver.keyIdHexFromFile', () {
    late Directory tmpDir;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('latch_keyid_test');
    });
    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    test('reads the key-id from a .latch file on disk', () async {
      final path = '${tmpDir.path}/x.latch';
      // Header + a fake body — the resolver only needs the header prefix.
      await File(
        path,
      ).writeAsBytes([..._headerWithKeyId(keyId), ...List.filled(100, 0)]);
      expect(await KeyIdResolver.keyIdHexFromFile(path), keyIdHex);
    });

    test('returns null for a missing file', () async {
      expect(
        await KeyIdResolver.keyIdHexFromFile('${tmpDir.path}/nope.latch'),
        isNull,
      );
    });
  });
}
