/// What a directory entry is, observed without following links.
enum EntryKind { file, directory, symlink, other }

/// (kind, size, modified) recorded at enumeration and compared again at read
/// time to detect a source changing underneath the operation.
final class EntryStamp {
  final EntryKind kind;
  final int sizeBytes;
  final DateTime modified;
  const EntryStamp({
    required this.kind,
    required this.sizeBytes,
    required this.modified,
  });

  @override
  bool operator ==(Object other) =>
      other is EntryStamp &&
      other.kind == kind &&
      other.sizeBytes == sizeBytes &&
      other.modified == modified;

  @override
  int get hashCode => Object.hash(kind, sizeBytes, modified);

  @override
  String toString() => 'EntryStamp($kind, $sizeBytes, $modified)';
}

/// One entry found by [DirectoryIoPort.walk]. A non-null [skipReason] means
/// the entry is reported but not processable; the walk never drops one silently.
final class FolderEntry {
  /// `/`-separated, relative to the walk root, never empty, never contains `..`.
  final String relativePath;
  final EntryStamp stamp;
  final String? skipReason;
  const FolderEntry({
    required this.relativePath,
    required this.stamp,
    this.skipReason,
  });

  bool get isSkipped => skipReason != null;
}

abstract interface class DirectoryIoPort {
  /// Walks [root] without following symlinks, yielding entries in byte-wise
  /// sorted relative-path order and never the root itself. Descends into
  /// subdirectories only when [recursive]. Classifies rather than rejects:
  /// symlinks, special files and unreadable entries are yielded with a
  /// [FolderEntry.skipReason].
  Stream<FolderEntry> walk(String root, {bool recursive = true});

  /// Non-following stat. Null when nothing exists at [path].
  Future<EntryStamp?> stat(String path);

  Future<void> createDirectory(String path, {bool recursive = false});
}
