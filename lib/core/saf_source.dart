import 'dart:io';
import 'package:myenc_core/myenc_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'bulk_plan.dart';
import 'saf_bridge.dart';
import 'staging_sweep.dart';

/// Reading a folder the user granted, on Android.
///
/// A folder picked as a *path* cannot be read there: scoped storage hides
/// non-media files from plain file APIs, so the walk finds nothing and the
/// folder looks empty. The grant itself is the only thing that works, so the
/// folder is listed through the document provider, each source is copied into
/// app-private storage for the crypto worker (which only has `dart:io`), and
/// the results are written back into the same grant.

typedef TreeLister =
    Future<SafTreeListing> Function(
      String treeUri, {
      required bool recursive,
      int prefixLength,
    });
typedef DocumentCopier = Future<void> Function(String uri, String destPath);
typedef DocumentRemover = Future<void> Function(String uri);

/// A source that could not be copied out of the grant for processing.
class SourceStagingError implements Exception {
  final String relativePath;
  final Object cause;
  const SourceStagingError(this.relativePath, this.cause);

  @override
  String toString() =>
      'SourceStagingError: could not read $relativePath ($cause)';
}

class SafSource {
  /// Lists [treeUri] and classifies it like a filesystem folder. Nothing is
  /// copied yet; each item's path is where its copy will be staged.
  static Future<BulkInventory> enumerate(
    String treeUri,
    BulkMode mode, {
    required bool recursive,
    TreeLister? lister,
    String? tempDir,
  }) async {
    final listing = await (lister ?? SafBridge.listTree)(
      treeUri,
      recursive: recursive,
      prefixLength: sniffPrefixLength,
    );
    final tmp = tempDir ?? (await getTemporaryDirectory()).path;
    return BulkPlan.fromTreeListing(
      listing,
      treeUri: treeUri,
      stagingRoot: p.join(
        tmp,
        stagedSourceDirName,
        BulkPlan.safeFolderName(listing.rootName),
      ),
      mode: mode,
      recursive: recursive,
    );
  }

  /// Copies every item's document to its staged path. All or nothing: a source
  /// that cannot be read stops the run before anything is written, so nothing
  /// is half-processed and nothing is deleted.
  static Future<void> stage(
    Iterable<BulkItem> items, {
    DocumentCopier? copier,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final copy = copier ?? SafBridge.copyToCache;
    final list = items.where((i) => i.docUri != null).toList();
    var done = 0;
    for (final i in list) {
      // Stop copying the moment the run is abandoned: the caller sweeps the
      // staged tree once, and a copy landing after that would outlive it.
      if (isCancelled?.call() ?? false) return;
      try {
        await copy(i.docUri!, i.sourcePath);
      } catch (e) {
        throw SourceStagingError(i.relativePath, e);
      }
      onProgress?.call(++done, list.length);
    }
  }

  /// Removes the staged copies under [root]. They hold the user's plaintext
  /// (and, for decrypt runs, are the only copy of nothing — the real documents
  /// stay in the grant), so this runs on every way out of a run.
  static void sweep(String root) {
    try {
      final d = Directory(root);
      if (d.existsSync()) d.deleteSync(recursive: true);
    } on FileSystemException {
      // Best effort: the next run resets the folder anyway.
    }
  }

  /// Removes one verified source: the real document in the grant first, then
  /// its staged copy. Returns false (and leaves the document) when the grant
  /// refuses — the original must survive anything that is not a clean delete.
  static Future<bool> deleteSource(
    BulkItem item, {
    DocumentRemover? remover,
  }) async {
    final uri = item.docUri;
    if (uri == null) return false;
    try {
      await (remover ?? SafBridge.deleteDocumentUri)(uri);
    } catch (_) {
      return false;
    }
    try {
      File(item.sourcePath).deleteSync();
    } on FileSystemException {
      // Staged copy already gone: nothing left to remove.
    }
    return true;
  }
}
