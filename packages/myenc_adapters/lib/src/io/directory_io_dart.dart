import 'dart:convert';
import 'dart:io';
import 'package:myenc_core/myenc_core.dart';
import 'package:path/path.dart' as p;

/// `dart:io` directory access that never follows symlinks.
///
/// Uses the sync APIs deliberately: they are markedly faster than the async
/// forms, and the walk runs inside a spawned isolate where blocking is free.
class DirectoryIoDart implements DirectoryIoPort {
  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(
    0,
    isUtc: true,
  );

  @override
  Stream<FolderEntry> walk(String root, {bool recursive = true}) async* {
    for (final e in walkSync(root, recursive: recursive)) {
      yield e;
    }
  }

  /// The whole walk as a sorted list, for callers already off the UI isolate.
  List<FolderEntry> walkSync(String root, {bool recursive = true}) {
    final out = <FolderEntry>[];
    _walkInto(root, '', recursive, out);
    out.sort(
      (a, b) => _compareBytes(
        utf8.encode(a.relativePath),
        utf8.encode(b.relativePath),
      ),
    );
    return out;
  }

  void _walkInto(
    String dir,
    String prefix,
    bool recursive,
    List<FolderEntry> out,
  ) {
    final List<FileSystemEntity> children;
    try {
      children = Directory(dir).listSync(followLinks: false);
    } on FileSystemException {
      if (prefix.isNotEmpty) {
        // The directory was already yielded by its parent; replace it with a
        // skipped record so the failure is reported rather than lost.
        final i = out.indexWhere((e) => e.relativePath == prefix);
        if (i >= 0) {
          out[i] = FolderEntry(
            relativePath: prefix,
            stamp: out[i].stamp,
            skipReason: 'unreadable folder',
          );
        }
        return;
      }
      rethrow;
    }

    for (final child in children) {
      final decoded = p.basename(child.path);
      if (decoded.isEmpty) continue;
      final rel = prefix.isEmpty ? decoded : '$prefix/$decoded';
      final path = child.path;
      final type = FileSystemEntity.typeSync(path, followLinks: false);

      switch (type) {
        case FileSystemEntityType.file:
          final stamp = _fileStamp(path, EntryKind.file);
          out.add(
            stamp == null
                ? FolderEntry(
                    relativePath: rel,
                    stamp: EntryStamp(
                      kind: EntryKind.file,
                      sizeBytes: 0,
                      modified: _epoch,
                    ),
                    skipReason: 'unreadable',
                  )
                : FolderEntry(relativePath: rel, stamp: stamp),
          );
        case FileSystemEntityType.directory:
          out.add(
            FolderEntry(
              relativePath: rel,
              stamp:
                  _fileStamp(path, EntryKind.directory) ??
                  EntryStamp(
                    kind: EntryKind.directory,
                    sizeBytes: 0,
                    modified: _epoch,
                  ),
            ),
          );
          if (recursive) _walkInto(path, rel, recursive, out);
        case FileSystemEntityType.link:
          out.add(
            FolderEntry(
              relativePath: rel,
              stamp: EntryStamp(
                kind: EntryKind.symlink,
                sizeBytes: 0,
                modified: _epoch,
              ),
              skipReason: 'symbolic link',
            ),
          );
        default:
          // pipe, socket, or listed-but-stat-invisible (device node).
          out.add(
            FolderEntry(
              relativePath: rel,
              stamp: EntryStamp(
                kind: EntryKind.other,
                sizeBytes: 0,
                modified: _epoch,
              ),
              skipReason: 'special file',
            ),
          );
      }
    }
  }

  EntryStamp? _fileStamp(String path, EntryKind kind) {
    try {
      final s = FileStat.statSync(path);
      if (s.type == FileSystemEntityType.notFound) return null;
      return EntryStamp(kind: kind, sizeBytes: s.size, modified: s.modified);
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<EntryStamp?> stat(String path) async {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.notFound:
        return null;
      case FileSystemEntityType.link:
        return EntryStamp(
          kind: EntryKind.symlink,
          sizeBytes: 0,
          modified: _epoch,
        );
      case FileSystemEntityType.file:
        return _fileStamp(path, EntryKind.file);
      case FileSystemEntityType.directory:
        return _fileStamp(path, EntryKind.directory);
      default:
        return EntryStamp(
          kind: EntryKind.other,
          sizeBytes: 0,
          modified: _epoch,
        );
    }
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    Directory(path).createSync(recursive: recursive);
  }

  static int _compareBytes(List<int> a, List<int> b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return a[i] - b[i];
    }
    return a.length - b.length;
  }
}
