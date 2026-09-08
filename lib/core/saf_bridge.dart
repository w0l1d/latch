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

  /// Every folder grant Android currently holds for this app, newest first.
  ///
  /// The app takes one grant per distinct source folder and, until this
  /// existed, never gave one back — so the set only grew, against a platform
  /// ceiling ([SafTreeGrants.limit]) that silently drops the oldest grant when
  /// reached. This is the read side of making that visible; [releaseTreeGrant]
  /// is the only place the app shrinks it.
  ///
  /// Reads the platform's table live, like every other grant question here.
  /// Best-effort: any failure yields an empty list, which reads as "no folder
  /// access" rather than an error screen. No `Platform.isAndroid` guard —
  /// off Android there is no handler for the channel, which throws and lands
  /// in exactly the same place.
  static Future<SafTreeGrants> listTreeGrants() async {
    try {
      final m = await channel.invokeMethod<Map>('listTreeGrants');
      if (m == null) return SafTreeGrants.empty;
      return SafTreeGrants.fromMap(m);
    } catch (_) {
      return SafTreeGrants.empty;
    }
  }

  /// Give back the folder grant on [treeUri]. Returns whether Android has
  /// actually stopped holding it — the platform table is checked after the
  /// release, so a device that refuses reports false instead of the UI
  /// claiming a revoke that didn't happen.
  ///
  /// Revoking is not destructive: nothing already written is touched, and the
  /// next save into that folder simply asks for the folder again.
  static Future<bool> releaseTreeGrant(String treeUri) async {
    try {
      final ok = await channel.invokeMethod<bool>('releaseTreeGrant', {
        'uri': treeUri,
      });
      return ok ?? false;
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

/// One folder grant the app holds, as Android reports it.
class SafTreeGrant {
  /// The persisted tree URI — the identity used to revoke it.
  final String uri;

  /// Filesystem path the grant fronts, or null for providers that front no
  /// real folder (SD volumes addressed by id, cloud providers).
  final String? path;

  /// What to show the user: the path when there is one, else the granted
  /// folder's own display name, else its document id. Never empty, because a
  /// row the user can't recognize is a row they can't decide about.
  final String label;

  /// When the grant was persisted, per the platform's own record.
  final DateTime? grantedAt;

  const SafTreeGrant({
    required this.uri,
    required this.path,
    required this.label,
    required this.grantedAt,
  });

  factory SafTreeGrant.fromMap(Map m) {
    final at = m['grantedAt'];
    return SafTreeGrant(
      uri: m['uri'] as String,
      path: m['path'] as String?,
      label: (m['label'] as String?) ?? (m['uri'] as String),
      grantedAt: at is int && at > 0
          ? DateTime.fromMillisecondsSinceEpoch(at)
          : null,
    );
  }
}

/// The grants the app holds, with the platform's ceiling on how many it may.
class SafTreeGrants {
  final List<SafTreeGrant> grants;

  /// AOSP's `MAX_PERSISTED_URI_GRANTS` (128, or 512 from API 30). It has no
  /// public accessor, so this is a mirrored constant — shown as headroom, and
  /// never gated on. 0 means "unknown", i.e. don't claim a number.
  final int limit;

  const SafTreeGrants({required this.grants, required this.limit});

  /// No folder access, and no claim about the ceiling.
  static const empty = SafTreeGrants(grants: [], limit: 0);

  /// Parses the platform's reply. Rows that aren't maps, and a missing limit,
  /// are dropped rather than thrown on: a device that answers oddly should
  /// still render whatever it did answer.
  factory SafTreeGrants.fromMap(Map m) => SafTreeGrants(
    grants: ((m['grants'] as List?) ?? const [])
        .whereType<Map>()
        .map(SafTreeGrant.fromMap)
        .toList(),
    limit: (m['limit'] as int?) ?? 0,
  );

  int get count => grants.length;

  /// Whether the app is close enough to the ceiling that the user should be
  /// told before the platform starts dropping their oldest folders for them.
  bool get nearLimit => limit > 0 && count >= (limit * 0.8).floor();
}
