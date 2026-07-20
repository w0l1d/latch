import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';

/// Crypto-erase for .latch files (spec UC-10).
///
/// "Securely delete" by destroying the key material, not by overwriting the
/// body (impossible to guarantee on flash). The entire header — salt, DEK
/// wraps, key-id, encrypted filename, secretstream header — is overwritten
/// in place with random bytes and flushed, making the DEK unrecoverable and
/// the body permanent noise. Then the file is deleted. Physical remnants of
/// the ORIGINAL header blocks are mitigated by the device's own file-based
/// encryption (spec §Threats).
class CryptoErase {
  static const int _peekBytes = 128 * 1024;

  /// Random bytes sized to [path]'s exact header length — for destroying the
  /// header of THIS file wherever it lives (e.g. the real document behind an
  /// Android cache copy, via SafBridge).
  ///
  /// Throws [NotALatchFileError] / [CorruptedFileError] when the file has no
  /// decodable .latch header.
  static Future<Uint8List> headerNoise(String path) async {
    final file = File(path);
    final len = await file.length();

    // Locate the header end via the codec — decodeHeader returns the exact
    // byte count consumed (magic through secretstream header).
    final raf = await file.open();
    Uint8List peek;
    try {
      peek = Uint8List.fromList(
        await raf.read(len < _peekBytes ? len : _peekBytes),
      );
    } finally {
      await raf.close();
    }
    final (_, headerLen) = MyencCodec.decodeHeader(peek);

    final rng = Random.secure();
    final noise = Uint8List(headerLen);
    for (var i = 0; i < headerLen; i++) {
      noise[i] = rng.nextInt(256);
    }
    return noise;
  }

  /// Overwrites the header of [path] with random bytes in place and flushes.
  /// Returns the number of bytes destroyed.
  ///
  /// Throws [NotALatchFileError] / [CorruptedFileError] when the file has no
  /// decodable .latch header (nothing is written in that case).
  static Future<int> eraseHeader(String path) async {
    final noise = await headerNoise(path);
    final headerLen = noise.length;
    final file = File(path);

    // FileMode.append opens read/write WITHOUT truncating; position is
    // movable, so we can overwrite the first headerLen bytes in place.
    final out = await file.open(mode: FileMode.append);
    try {
      await out.setPosition(0);
      await out.writeFrom(noise);
      await out.flush();
    } finally {
      await out.close();
    }
    return headerLen;
  }

  /// Crypto-erases [path]'s header, then deletes the file.
  static Future<void> eraseAndDelete(String path) async {
    await eraseHeader(path);
    await File(path).delete();
  }
}
