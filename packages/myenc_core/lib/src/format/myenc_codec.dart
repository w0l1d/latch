import 'dart:typed_data';
import 'file_header.dart';
import 'format_strategy.dart';
import 'format_version.dart';
import 'myenc_errors.dart';

/// Version-independent façade over the `.latch` header formats.
///
/// Owns only what every version shares — length sanity, the magic prefix,
/// the version byte, and the [FormatVersionRegistry] gate — then dispatches
/// to that version's [FormatVersionStrategy] (specs/003). All layout
/// knowledge (byte offsets, field bounds, wrap tables) lives in the
/// strategy, never here.
class MyencCodec {
  // Encodes the full file header (magic through secretstream header).
  //
  // Dispatches on h.version when it names a known strategy; otherwise falls
  // back to the write-default strategy so byte-level tests can stamp an
  // arbitrary (including deliberately unknown) version number and still get
  // a well-formed header to feed to decodeHeader's gate. Real callers always
  // set h.version from FormatVersionRegistry.writeDefault, so this fallback
  // never fires in production.
  static Uint8List encodeHeader(FileHeader h) {
    final strategy =
        formatVersionStrategies[h.version] ??
        formatVersionStrategies[FormatVersionRegistry.writeDefault.number]!;
    return strategy.encode(h);
  }

  // Decodes a header from the start of [bytes].
  // Returns (header, bytesConsumed) so the caller knows where the body starts.
  static (FileHeader, int) decodeHeader(Uint8List bytes) {
    if (bytes.length < 6) {
      throw CorruptedFileError('file too short for header');
    }
    for (int i = 0; i < 5; i++) {
      if (bytes[i] != MyencCodecMagic.bytes[i]) throw NotALatchFileError();
    }

    final version = bytes[5];
    // Fail closed: an unknown version byte — including 0 — is refused, never
    // guessed at. The registry is the only place that answers "is N known?";
    // the gate holds no comparison against any version value.
    FormatVersionRegistry.require(version);

    final strategy = formatVersionStrategies[version];
    if (strategy == null) throw VersionTooNewError(version);
    return strategy.decode(bytes, 6);
  }
}
