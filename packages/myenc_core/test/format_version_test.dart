import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:myenc_core/myenc_core.dart';

/// Invariants of the central format-version registry (specs/002).
///
/// I1 contiguity and I2 key/number agreement are what keep the derived
/// first-unknown boundary honest: a row added for a version the codec cannot
/// actually read would silently move what the freeze guard covers.
void main() {
  group('FormatVersionRegistry — the table', () {
    test('the build knows exactly one version: the frozen v1', () {
      expect(FormatVersionRegistry.all.length, 1);
      expect(FormatVersionRegistry.all[1]!.number, 1);
    });

    test('I1: the table is contiguous and begins at 1', () {
      final keys = FormatVersionRegistry.all.keys.toList()..sort();
      expect(keys, [for (var i = 1; i <= keys.length; i++) i]);
    });

    test('I2: every key maps to an entry whose number equals that key', () {
      FormatVersionRegistry.all.forEach((key, entry) {
        expect(entry.number, key, reason: 'entry registered under $key');
      });
    });

    test('I4: writeDefault is v1, independent of the table maximum', () {
      expect(FormatVersionRegistry.writeDefault.number, 1);
      expect(
        identical(FormatVersionRegistry.writeDefault, FormatVersionRegistry.v1),
        isTrue,
        reason: 'the write default is stated in its own right, not derived',
      );
    });

    test(
      'firstUnknown is the smallest positive integer absent from the table',
      () {
        expect(FormatVersionRegistry.firstUnknown, 2);
      },
    );
  });

  group('FormatVersionRegistry.require', () {
    test('resolves every known version to its entry', () {
      FormatVersionRegistry.all.forEach((key, entry) {
        expect(FormatVersionRegistry.require(key), same(entry));
      });
    });

    test('refuses 0 — absence means refusal, never a default', () {
      expect(
        () => FormatVersionRegistry.require(0),
        throwsA(isA<VersionTooNewError>()),
      );
    });

    test(
      'I3: refuses every byte value with no entry, firstUnknown through 255',
      () {
        for (var n = FormatVersionRegistry.firstUnknown; n <= 255; n++) {
          expect(
            () => FormatVersionRegistry.require(n),
            throwsA(isA<VersionTooNewError>()),
            reason: 'version $n must be refused',
          );
        }
      },
    );

    test('the refusal carries the offending version number', () {
      expect(
        () => FormatVersionRegistry.require(200),
        throwsA(
          isA<VersionTooNewError>().having((e) => e.version, 'version', 200),
        ),
      );
    });
  });

  group('MyencCodec decode gate consults the registry', () {
    Uint8List headerBytes({int version = 1}) {
      return MyencCodec.encodeHeader(
        FileHeader(
          version: version,
          flags: 0,
          kdfId: FileHeader.kdfArgon2id,
          salt: Uint8List.fromList(List.generate(16, (i) => i)),
          opslimit: 3,
          memlimit: 65536,
          cipherId: FileHeader.cipherXchacha20Poly1305,
          chunkSize: FileHeader.defaultChunkSize,
          keyIdHint: Uint8List.fromList(List.generate(16, (i) => i + 16)),
          wraps: const [],
          secretstreamHeader: Uint8List.fromList(
            List.generate(24, (i) => i + 100),
          ),
        ),
      );
    }

    test('refuses a container stamped with version 0', () {
      final bytes = headerBytes(version: 0);
      expect(
        () => MyencCodec.decodeHeader(bytes),
        throwsA(isA<VersionTooNewError>()),
      );
    });

    test('refuses versions firstUnknown through 255, carrying the number', () {
      for (var v = FormatVersionRegistry.firstUnknown; v <= 255; v++) {
        final bytes = headerBytes(version: v);
        expect(
          () => MyencCodec.decodeHeader(bytes),
          throwsA(
            isA<VersionTooNewError>().having((e) => e.version, 'version', v),
          ),
          reason: 'version $v must be refused',
        );
      }
    });

    test('decodes a container stamped version 1', () {
      final bytes = headerBytes();
      final (header, consumed) = MyencCodec.decodeHeader(bytes);
      expect(header.version, 1);
      expect(consumed, bytes.length);
    });
  });
}
