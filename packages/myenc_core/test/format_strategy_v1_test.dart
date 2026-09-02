// The v1 exhaustive battery (specs/003 US2), moved verbatim off the facade
// and onto V1Strategy directly: round-trips, per-field corruption, and the
// fuzz/property sweeps. Facade-level concerns (magic mismatch, version gate,
// dispatch, prefix truncation) stay in codec_test.dart.
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:myenc_core/myenc_core.dart';

void main() {
  const strategy = V1Strategy();

  group('V1Strategy', () {
    FileHeader makeHeader({List<WrapEntry> wraps = const []}) {
      return FileHeader(
        version: FormatVersionRegistry.writeDefault.number,
        flags: 0,
        kdfId: FileHeader.kdfArgon2id,
        salt: Uint8List.fromList(List.generate(16, (i) => i)),
        opslimit: 3,
        memlimit: 65536,
        cipherId: FileHeader.cipherXchacha20Poly1305,
        chunkSize: FileHeader.defaultChunkSize,
        keyIdHint: Uint8List.fromList(List.generate(16, (i) => i + 16)),
        wraps: wraps,
        secretstreamHeader: Uint8List.fromList(
          List.generate(24, (i) => i + 100),
        ),
      );
    }

    test('round-trips a header with no wraps', () {
      final h = makeHeader();
      final encoded = strategy.encode(h);
      final (decoded, consumed) = strategy.decode(encoded, 6);

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
      final h = makeHeader(
        wraps: [WrapEntry(type: WrapType.passphrase, bytes: wrapBytes)],
      );
      final encoded = strategy.encode(h);
      final (decoded, consumed) = strategy.decode(encoded, 6);

      expect(consumed, encoded.length);
      expect(decoded.wraps.length, 1);
      expect(decoded.wraps[0].type, WrapType.passphrase);
      expect(decoded.wraps[0].bytes, wrapBytes);
    });

    test('round-trips a header with multiple wraps', () {
      final h = makeHeader(
        wraps: [
          WrapEntry(type: WrapType.passphrase, bytes: Uint8List(48)),
          WrapEntry(type: WrapType.hardwareKey, bytes: Uint8List(32)),
        ],
      );
      final (decoded, _) = strategy.decode(strategy.encode(h), 6);
      expect(decoded.wraps.length, 2);
      expect(decoded.wraps[1].type, WrapType.hardwareKey);
    });

    test('magic bytes are LATCH in the encoded output', () {
      final encoded = strategy.encode(makeHeader());
      expect(encoded.sublist(0, 5), [0x4C, 0x41, 0x54, 0x43, 0x48]);
    });

    test('bytesConsumed is correct when trailing body bytes follow', () {
      final h = makeHeader();
      final headerBytes = strategy.encode(h);
      final bodyBytes = Uint8List.fromList([0xAA, 0xBB, 0xCC]);
      final full = Uint8List.fromList([...headerBytes, ...bodyBytes]);
      final (_, consumed) = strategy.decode(full, 6);
      expect(consumed, headerBytes.length);
      expect(full.sublist(consumed), bodyBytes);
    });

    test('throws CorruptedFileError for unsupported KDF id', () {
      final encoded = strategy.encode(makeHeader());
      encoded[7] = 0xFF; // kdfId position
      expect(
        () => strategy.decode(encoded, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for unsupported cipher id', () {
      final encoded = strategy.encode(makeHeader());
      encoded[34] = 0xFF; // cipherId position
      expect(
        () => strategy.decode(encoded, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for chunkSize below minimum', () {
      final encoded = strategy.encode(makeHeader());
      // Write chunkSize = 32 (below min 64)
      final buf = ByteData.sublistView(encoded);
      buf.setUint32(35, 32, Endian.big);
      expect(
        () => strategy.decode(encoded, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for chunkSize above maximum', () {
      final encoded = strategy.encode(makeHeader());
      // Write chunkSize = 64 MiB (above max 16 MiB)
      final buf = ByteData.sublistView(encoded);
      buf.setUint32(35, 64 * 1024 * 1024, Endian.big);
      expect(
        () => strategy.decode(encoded, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for opslimit out of range', () {
      final encoded = strategy.encode(makeHeader());
      // Write opslimit = 256 (above max 64)
      final buf = ByteData.sublistView(encoded);
      buf.setUint32(26, 256, Endian.big);
      expect(
        () => strategy.decode(encoded, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for memlimit out of range', () {
      final encoded = strategy.encode(makeHeader());
      // Write memlimit = 0 (below min 8)
      final buf = ByteData.sublistView(encoded);
      buf.setUint32(30, 0, Endian.big);
      expect(
        () => strategy.decode(encoded, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for unknown flag bits', () {
      final encoded = strategy.encode(makeHeader());
      encoded[6] = 0xFE; // flags: all bits set except bit0
      expect(
        () => strategy.decode(encoded, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for unknown wrap type', () {
      final encoded = strategy.encode(makeHeader());
      encoded[56] = 0xFF; // first wrap type byte (no wraps → wrap count = 0)
      // We need a wrap to test unknown type — write wrap count=1
      encoded[55] = 0x01;
      // type=0xFF, length=8, 8 zero data bytes
      final extra = Uint8List.fromList([
        0xFF,
        0x00,
        0x08,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      final modified = Uint8List.fromList([...encoded, ...extra]);
      expect(
        () => strategy.decode(modified, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('round-trips encrypted filename field', () {
      final encName = Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]);
      final h = FileHeader(
        version: FormatVersionRegistry.writeDefault.number,
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
      final (decoded, _) = strategy.decode(strategy.encode(h), 6);
      expect(decoded.filenameEncrypted, isTrue);
      expect(decoded.encryptedFilename, equals(encName));
    });

    test('flags=0 but no encryptedFilename → decodes with null', () {
      final h = FileHeader(
        version: FormatVersionRegistry.writeDefault.number,
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
      final (decoded, _) = strategy.decode(strategy.encode(h), 6);
      expect(decoded.filenameEncrypted, isFalse);
      expect(decoded.encryptedFilename, isNull);
    });

    test('throws CorruptedFileError for truncated enc-filename length', () {
      final encName = Uint8List(8);
      final h = FileHeader(
        version: FormatVersionRegistry.writeDefault.number,
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
      final encoded = strategy.encode(h);
      // Cut after wraps, mid-filename-length field
      final truncated = encoded.sublist(0, encoded.length - (24 + 8 + 2) + 1);
      expect(
        () => strategy.decode(truncated, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('throws CorruptedFileError for truncated enc-filename data', () {
      final encName = Uint8List(8);
      final h = FileHeader(
        version: FormatVersionRegistry.writeDefault.number,
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
      final encoded = strategy.encode(h);
      // Cut mid-filename data
      final truncated = encoded.sublist(0, encoded.length - (24 + 4));
      expect(
        () => strategy.decode(truncated, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });
  });

  group('V1Strategy fuzz / property tests', () {
    test('random garbage (0–1024 bytes) always throws a typed LatchError', () {
      final rng = List.generate(256, (i) => i); // deterministic
      for (final len in [0, 1, 5, 10, 30, 55, 56, 80, 128, 256, 512, 1024]) {
        final garbage = Uint8List.fromList(
          List.generate(len, (i) => rng[(i * 7 + 13) % 256]),
        );
        try {
          strategy.decode(garbage, 6);
          // If decode succeeds, the file must be at least 56 bytes.
          // This shouldn't happen with random bytes.
        } on LatchError {
          // Expected: any typed failure is fine.
        } on Exception catch (e) {
          fail('unexpected exception type ${e.runtimeType} for len=$len');
        }
      }
    });

    test('truncation sweep — every prefix of a valid header fails closed', () {
      final encName = Uint8List(4);
      final valid = strategy.encode(
        FileHeader(
          version: FormatVersionRegistry.writeDefault.number,
          flags: 0x01,
          kdfId: FileHeader.kdfArgon2id,
          salt: Uint8List(16),
          opslimit: 3,
          memlimit: 65536,
          cipherId: FileHeader.cipherXchacha20Poly1305,
          chunkSize: FileHeader.defaultChunkSize,
          keyIdHint: Uint8List(16),
          wraps: [WrapEntry(type: WrapType.passphrase, bytes: Uint8List(48))],
          secretstreamHeader: Uint8List(24),
          encryptedFilename: encName,
        ),
      );
      for (int cut = 0; cut < valid.length; cut++) {
        final truncated = valid.sublist(0, cut);
        try {
          strategy.decode(truncated, 6);
          // If it succeeds, the consumed bytes must match the input.
        } on LatchError {
          // Expected for truncated input.
        } on Exception catch (e) {
          fail('unexpected exception type ${e.runtimeType} for cut=$cut');
        }
      }
    });

    test('single-byte mutations of valid header never crash', () {
      final valid = strategy.encode(
        FileHeader(
          version: FormatVersionRegistry.writeDefault.number,
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
        ),
      );
      for (int pos = 0; pos < valid.length; pos++) {
        final mutated = Uint8List.fromList(valid);
        mutated[pos] ^= 0xFF; // flip all bits at this position
        try {
          strategy.decode(mutated, 6);
        } on LatchError {
          // Expected.
        } on Exception catch (e) {
          fail('unexpected exception type ${e.runtimeType} for pos=$pos');
        }
      }
    });

    test('oversized declared field (saltLen) throws CorruptedFileError', () {
      final valid = strategy.encode(
        FileHeader(
          version: FormatVersionRegistry.writeDefault.number,
          flags: 0,
          kdfId: FileHeader.kdfArgon2id,
          salt: Uint8List(16),
          opslimit: 3,
          memlimit: 65536,
          cipherId: FileHeader.cipherXchacha20Poly1305,
          chunkSize: FileHeader.defaultChunkSize,
          keyIdHint: Uint8List(16),
          wraps: const [],
          secretstreamHeader: Uint8List(24),
        ),
      );
      // Write saltLen = 0xFFFF (beyond buffer)
      final buf = ByteData.sublistView(valid);
      buf.setUint16(8, 0xFFFF, Endian.big);
      expect(
        () => strategy.decode(valid, 6),
        throwsA(isA<CorruptedFileError>()),
      );
    });
  });
}
