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

    test('filenameEncrypted flag reflects flags bit0', () {
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
      );
      final (decoded, _) = MyencCodec.decodeHeader(MyencCodec.encodeHeader(h));
      expect(decoded.filenameEncrypted, isTrue);
    });
  });
}
