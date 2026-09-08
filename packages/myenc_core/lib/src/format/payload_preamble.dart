import 'dart:typed_data';

import 'myenc_errors.dart';

/// What the decrypted plaintext of a `.latch` v2 container holds.
///
/// Deliberately an enumerated byte rather than a boolean (FR-020g): a future
/// payload shape must be addable without a further format-version bump, and
/// older readers must only have to *reject* it safely, never understand it.
/// `0x00` is intentionally not assigned, so an all-zero preamble body cannot be
/// mistaken for a valid one.
enum PayloadKind {
  /// One file's bytes, byte-for-byte. Identical in meaning to v1's payload.
  singleFile(0x01),

  /// A lossless packed stream of a directory tree, expanded on restore.
  packedFolder(0x02);

  const PayloadKind(this.value);
  final int value;

  /// `null` for every undefined value — the caller turns that into a
  /// fail-closed [UnknownPayloadKindError] rather than guessing.
  static PayloadKind? fromByte(int b) {
    for (final k in values) {
      if (k.value == b) return k;
    }
    return null;
  }
}

/// How a [PayloadKind.packedFolder] payload is framed.
enum PackFormat {
  /// No packing — the payload is the bytes themselves.
  none(0x00),

  /// tar, USTAR with the PAX extension subset described in `pack-format.md`.
  tarPax(0x01);

  const PackFormat(this.value);
  final int value;

  static PackFormat? fromByte(int b) {
    for (final f in values) {
      if (f.value == b) return f;
    }
    return null;
  }
}

/// The fixed 8-byte header at the start of a `.latch` **v2** plaintext.
///
/// This is the only difference between v1 and v2, and it lives *inside* the
/// secretstream rather than in the file header. That placement is the whole
/// design: the v1 file header carries no MAC, so a header field could not be
/// authenticated (FR-020c), whereas plaintext bytes are covered by the first
/// chunk's Poly1305 tag for free — and the payload kind stays confidential as
/// a side effect. It also means not one byte of the frozen v1 layout moves.
///
/// Fixed-width by design: every field is a single byte, with no length prefix,
/// no loop, and no variable-width integer. The preamble is the first thing read
/// out of attacker-influenceable plaintext, so there is nothing here for a
/// malformed length to drive.
class PayloadPreamble {
  /// ASCII `LPLD`. Not a file-type sniff: this is inside authenticated
  /// ciphertext and is only ever read at a known offset.
  static const List<int> magic = [0x4C, 0x50, 0x4C, 0x44];

  /// Total encoded size. Never varies.
  static const int length = 8;

  final PayloadKind kind;
  final PackFormat packFormat;

  const PayloadPreamble._(this.kind, this.packFormat);

  /// Legal to read, but never produced by default — a single file is written as
  /// v1 with no preamble at all, so it stays openable by older installs
  /// (`payload-preamble.md` §2).
  factory PayloadPreamble.singleFile() =>
      const PayloadPreamble._(PayloadKind.singleFile, PackFormat.none);

  factory PayloadPreamble.packedFolder() =>
      const PayloadPreamble._(PayloadKind.packedFolder, PackFormat.tarPax);

  Uint8List encode() => Uint8List.fromList([
    ...magic,
    kind.value,
    packFormat.value,
    0x00, // compression: none
    0x00, // reserved
  ]);

  /// Reads the preamble from the first [length] bytes of [bytes].
  ///
  /// Applies `payload-preamble.md` §5 in exactly that order and stops at the
  /// first failure. The order is load-bearing, not stylistic: magic is checked
  /// before the kind so a damaged file is reported as damaged rather than as
  /// "made by a newer version", which would send the user looking for a backup
  /// they do not need.
  static PayloadPreamble decode(Uint8List bytes) {
    if (bytes.length < length) {
      throw CorruptedFileError('payload preamble is truncated');
    }

    // Rule 1 — magic.
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) {
        throw CorruptedFileError('payload preamble magic is wrong');
      }
    }

    final kindByte = bytes[4];
    final packByte = bytes[5];
    final compression = bytes[6];
    final reserved = bytes[7];

    // Rule 2 — payload kind. Includes 0x00, which is never assigned.
    final kind = PayloadKind.fromByte(kindByte);
    if (kind == null) throw UnknownPayloadKindError(kindByte);

    // Rules 3 and 4 — anything set in a field this version defines as zero was
    // given meaning by a newer writer, so this reader cannot be trusted with
    // the payload. Fail closed rather than ignoring the bits.
    if (compression != 0x00) throw UnknownPayloadKindError(kindByte);
    if (reserved != 0x00) throw UnknownPayloadKindError(kindByte);

    // Rules 5 and 6 — kind and pack format must agree. A disagreement is a
    // self-inconsistent container, i.e. damage, not a newer format.
    final pack = PackFormat.fromByte(packByte);
    switch (kind) {
      case PayloadKind.packedFolder:
        if (pack != PackFormat.tarPax) {
          throw CorruptedFileError(
            'packed folder payload declares no pack format',
          );
        }
      case PayloadKind.singleFile:
        if (pack != PackFormat.none) {
          throw CorruptedFileError(
            'single file payload declares a pack format',
          );
        }
    }

    return PayloadPreamble._(kind, pack!);
  }
}
