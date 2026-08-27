// Facade-level concerns only: magic mismatch, the version gate, dispatch
// correctness, and truncation ahead of the version byte. The v1 layout
// battery lives in format_strategy_v1_test.dart, targeting V1Strategy
// directly (specs/003 US2).
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:myenc_core/myenc_core.dart';

void main() {
  group('MyencCodec', () {
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

    test('dispatches to the write-default strategy and round-trips', () {
      final h = makeHeader(
        wraps: [WrapEntry(type: WrapType.passphrase, bytes: Uint8List(48))],
      );
      final encoded = MyencCodec.encodeHeader(h);
      final (decoded, consumed) = MyencCodec.decodeHeader(encoded);

      expect(consumed, encoded.length);
      expect(decoded.version, FormatVersionRegistry.writeDefault.number);
      expect(decoded.wraps.length, 1);
      expect(decoded.wraps[0].type, WrapType.passphrase);
    });

    test('throws NotALatchFileError for wrong magic', () {
      final encoded = MyencCodec.encodeHeader(makeHeader());
      encoded[0] = 0xFF; // corrupt first magic byte
      expect(
        () => MyencCodec.decodeHeader(encoded),
        throwsA(isA<NotALatchFileError>()),
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
  });
}
