import 'dart:io';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';

/// Resolves which stored passphrase a .latch file was encrypted with by
/// reading the opaque key-id hint from its header (spec UC-9). Header parsing
/// is pure Dart (MyencCodec) — no crypto and no isolate needed for a peek.
class KeyIdResolver {
  /// Header prefix that safely covers magic..wraps..enc-filename..ss-header
  /// (fixed 56 B + one 72 B wrap + ≤64 KiB filename field + 24 B).
  static const int _peekBytes = 128 * 1024;

  /// Extracts the key-id hint (hex) from header [bytes], or null when the
  /// bytes are not a decodable .latch header.
  static String? keyIdHexFromHeader(Uint8List bytes) {
    try {
      final (hdr, _) = MyencCodec.decodeHeader(bytes);
      return hdr.keyIdHint
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    } on LatchError {
      return null;
    }
  }

  /// Reads just enough of [path] to decode the header and returns its key-id
  /// hint (hex), or null when the file is unreadable or not a .latch file.
  static Future<String?> keyIdHexFromFile(String path) async {
    try {
      final file = File(path);
      final len = await file.length();
      final raf = await file.open();
      try {
        final bytes = await raf.read(len < _peekBytes ? len : _peekBytes);
        return keyIdHexFromHeader(Uint8List.fromList(bytes));
      } finally {
        await raf.close();
      }
    } on FileSystemException {
      return null;
    }
  }
}
