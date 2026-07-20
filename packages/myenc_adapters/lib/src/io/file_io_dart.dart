import 'dart:io';
import 'dart:typed_data';
import 'package:myenc_core/myenc_core.dart';
import 'package:path/path.dart' as p;

class FileIoDart implements FileIoPort {
  @override
  Stream<Uint8List> openRead(String path, {int chunkSize = 65536}) async* {
    await for (final chunk in File(path).openRead()) {
      yield Uint8List.fromList(chunk);
    }
  }

  @override
  Future<void> writeChunked(String path, Stream<Uint8List> chunks) async {
    final tmp = '$path.tmp';
    final sink = File(tmp).openWrite();
    try {
      await for (final chunk in chunks) {
        sink.add(chunk);
      }
      await sink.flush();
    } catch (e) {
      await sink.close().catchError((_) {});
      await File(tmp).delete().catchError((_) => File(tmp));
      // errno 28 == ENOSPC (out of disk space) on POSIX platforms.
      if (e is FileSystemException && e.osError?.errorCode == 28) {
        throw StorageFullError();
      }
      rethrow;
    }
    await sink.close();
    await File(tmp).rename(path);
  }

  @override
  Future<void> deleteFile(String path) async {
    try {
      await File(path).delete();
    } catch (_) {
      // Best-effort: never throw on delete.
    }
  }

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<int> fileSize(String path) async => (await File(path).stat()).size;

  @override
  String withSuffix(String path, String suffix) => '$path$suffix';

  @override
  String withoutSuffix(String path, String suffix) => path.endsWith(suffix)
      ? path.substring(0, path.length - suffix.length)
      : path;

  @override
  String resolveOutputPath(String defaultPath, String? outputDir) {
    if (outputDir == null) return defaultPath;
    return p.join(outputDir, p.basename(defaultPath));
  }

  @override
  String resolveNameCollision(String path) {
    if (!File(path).existsSync()) return path;
    final ext = p.extension(path);
    final base = p.withoutExtension(path);
    for (int n = 2; n < 1000; n++) {
      final candidate = '${base}_$n$ext';
      if (!File(candidate).existsSync()) return candidate;
    }
    return '${base}_${DateTime.now().millisecondsSinceEpoch}$ext';
  }
}
