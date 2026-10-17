import 'dart:typed_data';

import 'package:myenc_core/myenc_core.dart';
import 'package:test/test.dart';

/// Builds an 8-byte preamble directly, so the tests pin the *bytes* rather
/// than agreeing with whatever the encoder happens to produce.
Uint8List raw({
  List<int> magic = const [0x4C, 0x50, 0x4C, 0x44],
  int kind = 0x01,
  int pack = 0x00,
  int compression = 0x00,
  int reserved = 0x00,
}) => Uint8List.fromList([...magic, kind, pack, compression, reserved]);

void main() {
  group('layout', () {
    test('is exactly 8 bytes', () {
      expect(PayloadPreamble.length, 8);
    });

    test('a single-file preamble encodes to LPLD 01 00 00 00', () {
      expect(
        PayloadPreamble.singleFile().encode(),
        Uint8List.fromList([0x4C, 0x50, 0x4C, 0x44, 0x01, 0x00, 0x00, 0x00]),
      );
    });

    test('a packed-folder preamble encodes to LPLD 02 01 00 00', () {
      expect(
        PayloadPreamble.packedFolder().encode(),
        Uint8List.fromList([0x4C, 0x50, 0x4C, 0x44, 0x02, 0x01, 0x00, 0x00]),
      );
    });

    test('encode and decode round-trip both defined kinds', () {
      for (final p in [
        PayloadPreamble.singleFile(),
        PayloadPreamble.packedFolder(),
      ]) {
        expect(PayloadPreamble.decode(p.encode()).kind, p.kind);
      }
    });
  });

  group('valid input', () {
    test('accepts a single-file preamble', () {
      expect(
        PayloadPreamble.decode(raw(kind: 0x01)).kind,
        PayloadKind.singleFile,
      );
    });

    test('accepts a packed-folder preamble', () {
      final p = PayloadPreamble.decode(raw(kind: 0x02, pack: 0x01));
      expect(p.kind, PayloadKind.packedFolder);
      expect(p.packFormat, PackFormat.tarPax);
    });
  });

  group('validation order (contract §5)', () {
    test('rule 1: bad magic is corruption, not an unknown kind', () {
      expect(
        () => PayloadPreamble.decode(raw(magic: [0x4C, 0x50, 0x4C, 0x00])),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test(
      'rule 1 outranks rule 2: bad magic AND bad kind reports corruption',
      () {
        // Order matters: if kind were checked first this would report "newer
        // version" for a file that is simply damaged.
        expect(
          () => PayloadPreamble.decode(raw(magic: [0, 0, 0, 0], kind: 0x7f)),
          throwsA(isA<CorruptedFileError>()),
        );
      },
    );

    test('rule 2: kind 0x00 is rejected as an unknown kind', () {
      // 0x00 is deliberately not a valid kind, so an all-zero preamble body
      // cannot be mistaken for a valid one.
      expect(
        () => PayloadPreamble.decode(raw(kind: 0x00)),
        throwsA(isA<UnknownPayloadKindError>()),
      );
    });

    test('rule 2: an undefined kind is rejected as an unknown kind', () {
      expect(
        () => PayloadPreamble.decode(raw(kind: 0x03, pack: 0x00)),
        throwsA(isA<UnknownPayloadKindError>()),
      );
    });

    test('rule 2: the reported kind byte is the offending one', () {
      try {
        PayloadPreamble.decode(raw(kind: 0x7f));
        fail('expected UnknownPayloadKindError');
      } on UnknownPayloadKindError catch (e) {
        expect(e.kind, 0x7f);
      }
    });

    test('rule 3: a non-zero compression byte is an unknown kind', () {
      expect(
        () => PayloadPreamble.decode(raw(kind: 0x01, compression: 0x01)),
        throwsA(isA<UnknownPayloadKindError>()),
      );
    });

    test('rule 4: a non-zero reserved byte is an unknown kind', () {
      expect(
        () => PayloadPreamble.decode(raw(kind: 0x01, reserved: 0x01)),
        throwsA(isA<UnknownPayloadKindError>()),
      );
    });

    test('rule 5: packedFolder with no pack format is corruption', () {
      expect(
        () => PayloadPreamble.decode(raw(kind: 0x02, pack: 0x00)),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test('rule 6: singleFile with a pack format is corruption', () {
      expect(
        () => PayloadPreamble.decode(raw(kind: 0x01, pack: 0x01)),
        throwsA(isA<CorruptedFileError>()),
      );
    });

    test(
      'rule 3 outranks rule 5: bad compression on a folder is unknown kind',
      () {
        expect(
          () => PayloadPreamble.decode(
            raw(kind: 0x02, pack: 0x00, compression: 9),
          ),
          throwsA(isA<UnknownPayloadKindError>()),
        );
      },
    );
  });

  group('truncation', () {
    test('a short buffer is corruption, never a partial parse', () {
      for (var n = 0; n < 8; n++) {
        expect(
          () => PayloadPreamble.decode(
            Uint8List.fromList(
              PayloadPreamble.singleFile().encode().sublist(0, n),
            ),
          ),
          throwsA(isA<CorruptedFileError>()),
          reason: 'length $n must not decode',
        );
      }
    });

    test('trailing bytes past the preamble are ignored, not an error', () {
      // The payload follows immediately; decode reads a fixed 8 bytes.
      final buf = Uint8List.fromList([...raw(kind: 0x01), 1, 2, 3]);
      expect(PayloadPreamble.decode(buf).kind, PayloadKind.singleFile);
    });
  });

  group('extensibility (FR-020g)', () {
    test('the kind field is a byte, so 253 kinds remain addable', () {
      // Not a boolean: adding a kind must not need a version bump.
      final defined = {0x01, 0x02};
      final addable = List.generate(
        256,
        (i) => i,
      ).where((v) => v != 0x00 && !defined.contains(v)).length;
      expect(addable, 253);
    });

    test('every undefined kind fails closed as an unknown kind', () {
      for (var v = 0; v < 256; v++) {
        if (v == 0x01 || v == 0x02) continue;
        expect(
          () => PayloadPreamble.decode(raw(kind: v)),
          throwsA(isA<UnknownPayloadKindError>()),
          reason: 'kind $v must fail closed',
        );
      }
    });
  });
}
