import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:myenc_core/myenc_core.dart';

void main() {
  group('MyencCodec', () {
    FileHeader makeHeader({List<WrapEntry> wraps = const []}) {
      return FileHeader(
        version: FileHeader.supportedVersion,
        flags: 0,
        kdfId: FileHeader.kdfArgon2id,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        opslimit: 3,
        memlimit: 65536,
        cipherId: FileHeader.cipherXchacha20Poly1305,
        chunkSize: FileHeader.defaultChunkSize,
        keyIdHint: Uint8List.fromList(List.generate(16, (i) => i + 16)),
        wraps: wraps,
        secretstreamHeader: Uint8List.fromList(List.generate(24, (i) => i + 100)),
      );
    }

    test('round-trips a header with no wraps', () {
      final h = makeHeader();
      final encoded = MyencCodec.encodeHeader(h);
      final (decoded, consumed) = MyencCodec.decodeHeader(encoded);

      expect(consumed, encoded.length);
      expect(decoded.version, h.version);
      expect(decoded.flags, h.flags);
      expect(decoded.kdfId, h.kdfId);
      expect(decoded.salt, h.salt);
      expect(decoded.opslimit, h.opslimit);
      expect(decoded.memlimit, h.memlimit);
      expect(decoded.cipherId, h.cipherId);
      expect(decoded.chunkSize, h.chunkSize);
      expect(decoded.keyIdHint, h.keyIdHint);
      expect(decoded.wraps, isEmpty);
      expect(decoded.secretstreamHeader, h.secretstreamHeader);
    });

    test('round-trips a header with one passphrase wrap', () {
      final wrapBytes = Uint8List.fromList(List.generate(48, (i) => i));
      final h = makeHeader(wraps: [
        WrapEntry(type: WrapType.passphrase, bytes: wrapBytes),
      ]);
      final encoded = MyencCodec.encodeHeader(h);
      final (decoded, consumed) = MyencCodec.decodeHeader(encoded);

      expect(consumed, encoded.length);
      expect(decoded.wraps.length, 1);
      expect(decoded.wraps[0].type, WrapType.passphrase);
      expect(decoded.wraps[0].bytes, wrapBytes);
    });

    test('round-trips a header with multiple wraps', () {
      final h = makeHeader(wraps: [
        WrapEntry(type: WrapType.passphrase, bytes: Uint8List(48)),
        WrapEntry(type: WrapType.hardwareKey, bytes: Uint8List(32)),
      ]);
      final (decoded, _) = MyencCodec.decodeHeader(MyencCodec.encodeHeader(h));
      expect(decoded.wraps.length, 2);
      expect(decoded.wraps[1].type, WrapType.hardwareKey);
    });

    test('magic bytes are LATCH in the encoded output', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      expect(encoded.sublist(0, 5), [0x4C, 0x41, 0x54, 0x43, 0x48]);
    });

    test('throws CorruptedFileError for wrong magic', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      encoded[0] = 0xFF; // corrupt first magic byte
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws VersionTooNewError for unsupported version', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      encoded[5] = 0xFF; // version = 255
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<VersionTooNewError>()),
      );
    });

    test('throws CorruptedFileError for truncated input', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      expect(
        () => MyencCodec.decodeHeader(encoded.sublist(0, 10)),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('bytesConsumed is correct when trailing body bytes follow', () {
      final h = makeHeader();
      final headerBytes = MyencCodec.encodeHeader(h);
      final bodyBytes = Uint8List.fromList([0xAA, 0xBB, 0xCC]);
      final full = Uint8List.fromList([...headerBytes, ...bodyBytes]);
      final (_, consumed) = MyencCodec.decodeHeader(full);
      expect(consumed, headerBytes.length);
      expect(full.sublist(consumed), bodyBytes);
    });

    test('throws CorruptedFileError for unsupported KDF id', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      encoded[7] = 0xFF; // kdfId position
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for unsupported cipher id', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      encoded[34] = 0xFF; // cipherId position
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for chunkSize below minimum', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      // Write chunkSize = 32 (below min 64)
      final buf = ByteData.sublistView(encoded);
      buf.setUint32(35, 32, Endian.big);
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for chunkSize above maximum', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      // Write chunkSize = 64 MiB (above max 16 MiB)
      final buf = ByteData.sublistView(encoded);
      buf.setUint32(35, 64 * 1024 * 1024, Endian.big);
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for opslimit out of range', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      // Write opslimit = 256 (above max 64)
      final buf = ByteData.sublistView(encoded);
      buf.setUint32(26, 256, Endian.big);
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for memlimit out of range', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      // Write memlimit = 0 (below min 8)
      final buf = ByteData.sublistView(encoded);
      buf.setUint32(30, 0, Endian.big);
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for unknown flag bits', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      encoded[6] = 0xFE; // flags: all bits set except bit0
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for unknown wrap type', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      encoded[56] = 0xFF; // first wrap type byte (no wraps → wrap count = 0)
      // We need a wrap to test unknown type — write wrap count=1
      encoded[55] = 0x01;
      // type=0xFF, length=8, 8 zero data bytes
      final extra = Uint8List.fromList([0xFF, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
      final modified = Uint8List.fromList([...encoded, ...extra]);
      expect(
        () => MyencCodec.decodeHeader(modified),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('round-trips encrypted filename field', () {
      final encName = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);
      final h = FileHeader(
        version: FileHeader.supportedVersion,
        flags: 0x01,
        kdfId: FileHeader.kdfArgon2id,
        salt: Uint8List(16),
        opslimit: 3,
        memlimit: 65536,
        cipherId: FileHeader.cipherXchacha20Poly1305,
        chunkSize: FileHeader.defaultChunkSize,
        keyIdHint: Uint8List(16),
        wraps: const [],
        secretstreamHeader: Uint8List(24),
        encryptedFilename: encName,
      );
      final (decoded, _) = MyencCodec.decodeHeader(MyencCodec.encodeHeader(h));
      expect(decoded.filenameEncrypted, isTrue);
      expect(decoded.encryptedFilename, equals(encName));
    });

    test('flags=0 but no encryptedFilename → decodes with null', () {
      final h = FileHeader(
        version: FileHeader.supportedVersion,
        flags: 0x00,
        kdfId: FileHeader.kdfArgon2id,
        salt: Uint8List(16),
        opslimit: 3,
        memlimit: 65536,
        cipherId: FileHeader.cipherXchacha20Poly1305,
        chunkSize: FileHeader.defaultChunkSize,
        keyIdHint: Uint8List(16),
        wraps: const [],
        secretstreamHeader: Uint8List(24),
      );
      final (decoded, _) = MyencCodec.decodeHeader(MyencCodec.encodeHeader(h));
      expect(decoded.filenameEncrypted, isFalse);
      expect(decoded.encryptedFilename, isNull);
    });

    test('throws CorruptedFileError for truncated enc-filename length', () {
      final encName = Uint8List(8);
      final h = FileHeader(
        version: FileHeader.supportedVersion,
        flags: 0x01,
        kdfId: FileHeader.kdfArgon2id,
        salt: Uint8List(16),
        opslimit: 3,
        memlimit: 65536,
        cipherId: FileHeader.cipherXchacha20Poly1305,
        chunkSize: FileHeader.defaultChunkSize,
        keyIdHint: Uint8List(16),
        wraps: const [],
        secretstreamHeader: Uint8List(24),
        encryptedFilename: encName,
      );
      final encoded = MyencCodec.encodeHeader(h);
      // Cut after wraps, mid-filename-length field
      final truncated = encoded.sublist(0, encoded.length - (24 + 8 + 2) + 1);
      expect(
        () => MyencCodec.decodeHeader(truncated),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for truncated enc-filename data', () {
      final encName = Uint8List(8);
      final h = FileHeader(
        version: FileHeader.supportedVersion,
        flags: 0x01,
        kdfId: FileHeader.kdfArgon2id,
        salt: Uint8List(16),
        opslimit: 3,
        memlimit: 65536,
        cipherId: FileHeader.cipherXchacha20Poly1305,
        chunkSize: FileHeader.defaultChunkSize,
        keyIdHint: Uint8List(16),
        wraps: const [],
        secretstreamHeader: Uint8List(24),
        encryptedFilename: encName,
      );
      final encoded = MyencCodec.encodeHeader(h);
      // Cut mid-filename data
      final truncated = encoded.sublist(0, encoded.length - (24 + 4));
      expect(
        () => MyencCodec.decodeHeader(truncated),
        throwsA(isA<CorruptedFileError>()),
      );
    });
  });
}
