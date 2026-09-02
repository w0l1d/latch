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

  // --- Folder (tree) grants: creating NEW output files beside originals ---
  //
  // The single-file picker only grants access to the picked document, not its
  // folder, so the app can't create a sibling output there. ACTION_OPEN_-
  // DOCUMENT_TREE grants a whole folder (a persistable "tree" URI) into which
  // DocumentsContract.createDocument can write new files.
  //
  // Android persists these grants itself, so [existingTreeGrantFor] is the only
  // record needed to avoid re-prompting — including across restarts. The app
  // keeps no copy: one could outlive the grant it names, and then the app would
  // skip the prompt for a folder it can no longer write to.

  /// Prompt the user to grant a folder. Returns the granted tree URI, or null
  /// if they cancelled.
  ///
  /// The picker is seeded at [initialPath] when a folder was resolved, else at
  /// [initialDocUri] — the picked document's own `content://` URI, whose parent
  /// the *system* resolves (`EXTRA_INITIAL_URI` accepts a document URI and the
  /// document navigator is privileged enough to look up its parent, which this
  /// app is not). That is the only seed available for sources whose folder
  /// can't be resolved, and it is what stops those landing the user at the
  /// storage root. Seeding is best-effort — an ignored seed just means the
  /// picker opens wherever it would have.
  static Future<String?> pickTree({
    String? initialPath,
    String? initialDocUri,
  }) => channel.invokeMethod<String>('openTree', {
    'initialPath': initialPath,
    'initialDocUri': initialDocUri,
  });

  /// Filesystem path a granted tree URI points at, or null when the provider
  /// doesn't front a real folder. Best-effort: never throws.
  static Future<String?> treeUriToPath(String treeUri) async {
    try {
      return await channel.invokeMethod<String>('treeUriToPath', {
        'uri': treeUri,
      });
    } catch (_) {
      return null;
    }
  }

  /// A folder grant the user has already given that covers [folderPath] — the
  /// folder itself, or an ancestor of it, since a tree grant can create
  /// documents in any descendant. [subPath] is the path from the granted tree
  /// down to the folder ('' when the grant is the folder itself). Null when no
  /// existing grant covers it, i.e. the user has to be asked.
  ///
  /// Reads Android's own persisted-permission table, so it finds grants taken
  /// in earlier sessions and grants taken for a parent folder, and it stops
  /// finding a grant the moment Android stops honoring it. Best-effort: never
  /// throws.
  static Future<({String treeUri, String subPath})?> existingTreeGrantFor(
    String folderPath,
  ) async {
    try {
      final m = await channel.invokeMethod<Map>('existingTreeGrant', {
        'folder': folderPath,
      });
      if (m == null) return null;
      return (
        treeUri: m['treeUri'] as String,
        subPath: (m['subPath'] as String?) ?? '',
      );
    } catch (_) {
      return null;
    }
  }

  /// Whether Android still holds a writable grant on this exact [treeUri].
  ///
  /// Lets the app reuse a destination the user chose earlier for sources whose
  /// folder can't be resolved at all, without ever *trusting* the remembered
  /// URI: the platform's persisted-permission table stays the authority, so a
  /// revoked grant reports false and the user is asked again. Best-effort:
  /// never throws — an unanswerable question means "ask the user".
  static Future<bool> isTreeGrantLive(String treeUri) async {
    try {
      final live = await channel.invokeMethod<bool>('isTreeGrantLive', {
        'uri': treeUri,
      });
      return live ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Create [displayName] inside the granted [treeUri] and copy [srcPath] into
  /// it. [subPath] targets a folder nested inside the grant (empty = the tree
  /// root). Returns the created document's URI and a human-readable display
  /// path. Throws (caller falls back to Downloads) when the grant is gone, the
  /// nested folder can't be addressed, or the write fails.
  static Future<({String uri, String displayPath})> createInTree({
    required String treeUri,
    required String displayName,
    required String srcPath,
    String subPath = '',
    String mimeType = 'application/octet-stream',
  }) async {
    final m = await channel.invokeMethod<Map>('createInTree', {
      'treeUri': treeUri,
      'displayName': displayName,
      'mimeType': mimeType,
      'srcPath': srcPath,
      'subPath': subPath,
    });
    if (m == null) throw StateError('createInTree returned no result');
    return (uri: m['uri'] as String, displayPath: m['displayPath'] as String);
  }

  /// Open the system file browser at the folder holding the outputs.
  ///
  /// Prefers a granted [treeUri] (opens exactly that folder); otherwise builds a
  /// primary-storage folder view from [path]. Returns false when nothing can be
  /// opened (no handler app, non-Android, or the path isn't on primary storage).
  /// Best-effort: never throws.
  static Future<bool> openFolder({String? treeUri, String? path}) async {
    if (!Platform.isAndroid) return false;
    try {
      final ok = await channel.invokeMethod<bool>('openFolder', {
        'treeUri': treeUri,
        'path': path,
      });
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
