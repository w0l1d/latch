import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Bridge to Android's Storage Access Framework.
///
/// The system file picker gives the app a private cache COPY of every
/// selection — the user's real document is only reachable through the
/// content:// URI the picker used. Pickers register that URI per cache path
/// here, and in-place operations (change passphrase, add recipient, shred,
/// delete-originals) use it to act on the actual file instead of the copy.
///
/// On platforms without content URIs (desktop; iOS file paths) nothing is
/// registered and [canWriteBack] stays false, so callers keep the plain
/// filesystem behavior.
class SafBridge {
  static const channel = MethodChannel('latch/saf');

  static final Map<String, String> _uriByPath = {};

  /// Remember which real document the picked cache copy at [path] came from.
  /// Ignores identifiers that are not content:// URIs.
  static void rememberUri(String path, String? identifier) {
    if (identifier != null && identifier.startsWith('content://')) {
      _uriByPath[path] = identifier;
    }
  }

  /// Whether the real document behind [path] is reachable for write-back.
  static bool canWriteBack(String path) =>
      Platform.isAndroid && _uriByPath.containsKey(path);

  /// The registered URI for [path], if any (exposed for tests).
  static String? uriFor(String path) => _uriByPath[path];

  /// Copies the (already-modified) cache file at [path] over the real
  /// document it was picked from. Truncates, writes, and syncs.
  static Future<void> writeBack(String path) {
    return channel.invokeMethod('writeBack', {
      'uri': _uriByPath[path]!,
      'path': path,
    });
  }

  /// Overwrites the real document's first [noise.length] bytes in place
  /// (crypto-erase of the header), then deletes the document.
  static Future<void> overwriteAndDelete(String path, Uint8List noise) {
    return channel.invokeMethod('overwriteAndDelete', {
      'uri': _uriByPath[path]!,
      'bytes': noise,
    });
  }

  /// Deletes the real document behind [path].
  static Future<void> deleteDocument(String path) {
    return channel.invokeMethod('delete', {'uri': _uriByPath[path]!});
  }

  static final Map<String, String?> _realDirByPath = {};

  /// The real folder the document behind [path] lives in, or null when the
  /// provider doesn't expose a filesystem path (media store, cloud). Used to
  /// default outputs to the source file's own folder. Best-effort: any
  /// platform failure resolves to null, never throws.
  static Future<String?> realDirectoryFor(String path) async {
    final uri = _uriByPath[path];
    if (uri == null) return null;
    if (_realDirByPath.containsKey(path)) return _realDirByPath[path];
    String? dir;
    try {
      final resolved = await channel.invokeMethod<String>('resolvePath', {
        'uri': uri,
      });
      if (resolved != null) dir = p.dirname(resolved);
    } catch (_) {
      dir = null;
    }
    _realDirByPath[path] = dir;
    return dir;
  }
}
