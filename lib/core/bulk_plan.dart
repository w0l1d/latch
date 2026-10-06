import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:myenc_core/myenc_core.dart';
import 'package:path/path.dart' as p;

enum BulkMode { encrypt, decrypt }

enum BulkKeyMode { perFile, sharedPerBatch }

enum BulkPlacement { mirroredFolder, besideOriginals, flatFolder }

/// Per-operation choices. [recursive] is never persisted: every new operation
/// starts with it off (FR-004).
class BulkOptions {
  final bool recursive;
  final BulkKeyMode keyMode;
  final BulkPlacement placement;
  final String? destinationRoot;
  final bool deleteSources;

  const BulkOptions({
    this.recursive = false,
    this.keyMode = BulkKeyMode.perFile,
    this.placement = BulkPlacement.mirroredFolder,
    this.destinationRoot,
    this.deleteSources = false,
  });

  BulkOptions copyWith({
    bool? recursive,
    BulkKeyMode? keyMode,
    BulkPlacement? placement,
    String? destinationRoot,
    bool? deleteSources,
  }) => BulkOptions(
    recursive: recursive ?? this.recursive,
    keyMode: keyMode ?? this.keyMode,
    placement: placement ?? this.placement,
    destinationRoot: destinationRoot ?? this.destinationRoot,
    deleteSources: deleteSources ?? this.deleteSources,
  );
}

/// Where one operation's outputs go. Built per operation from the saved
/// default and never written back (FR-029).
class BulkDestination {
  final BulkPlacement placement;

  /// Picked folder on desktop, or null.
  final String? dir;

  /// Picked tree grant on Android, or null.
  final String? treeUri;

  /// Human-readable name of the picked folder, for display only.
  final String? label;

  const BulkDestination({
    this.placement = BulkPlacement.mirroredFolder,
    this.dir,
    this.treeUri,
    this.label,
  });

  bool get needsFolder => placement != BulkPlacement.besideOriginals;
  bool get hasFolder => dir != null || treeUri != null;

  /// Outputs beside the originals need no pick; the other two need a folder.
  bool get isReady => !needsFolder || hasFolder;

  BulkDestination withPlacement(BulkPlacement p) =>
      BulkDestination(placement: p, dir: dir, treeUri: treeUri, label: label);

  BulkDestination withFolder({String? dir, String? treeUri, String? label}) =>
      BulkDestination(
        placement: placement,
        dir: dir,
        treeUri: treeUri,
        label: label,
      );

  /// Where the planner should write: a picked folder only counts when the
  /// placement uses one.
  String? get plannerDir => needsFolder ? dir : null;
  String? get plannerTreeUri => needsFolder ? treeUri : null;
}

class SkippedEntry {
  final String relativePath;
  final String reason;
  const SkippedEntry(this.relativePath, this.reason);

  @override
  String toString() => '$relativePath ($reason)';
}

class BulkItem {
  final String sourcePath;
  final String relativePath;
  final int sizeBytes;
  final EntryStamp stampAtEnumeration;

  /// Path of the output relative to the chosen destination: `<rel>.latch` on
  /// encrypt, `.latch` stripped on decrypt.
  final String outRelPath;

  const BulkItem({
    required this.sourcePath,
    required this.relativePath,
    required this.sizeBytes,
    required this.stampAtEnumeration,
    required this.outRelPath,
  });
}

/// Result of listing a folder. Every enumerated entry lands in exactly one of
/// [items], [skipped], or is a directory counted in [subfolders].
class BulkInventory {
  final String root;
  final BulkMode mode;
  final bool recursive;
  final List<BulkItem> items;
  final List<SkippedEntry> skipped;

  /// Directories seen (descended into only when [recursive]).
  final int subfolders;

  /// Files inside subfolders that were left out because recursion is off
  /// (FR-005). Always 0 when [recursive].
  final int excludedInSubfolders;

  /// Encrypt only (FR-009): items whose header already looks like a container.
  final int alreadyContainers;

  const BulkInventory({
    required this.root,
    required this.mode,
    required this.recursive,
    required this.items,
    required this.skipped,
    required this.subfolders,
    required this.excludedInSubfolders,
    required this.alreadyContainers,
  });

  int get totalBytes => items.fold(0, (s, i) => s + i.sizeBytes);
}

/// Per-item outcome, extending the plain batch result with verification state.
class BulkFileOutcome {
  final String path;
  final bool ok;
  final String? errorMessage;
  final String? outPath;
  final bool verified;
  final bool sourceRemoved;

  const BulkFileOutcome({
    required this.path,
    required this.ok,
    this.errorMessage,
    this.outPath,
    this.verified = false,
    this.sourceRemoved = false,
  });
}

/// Folder enumeration. [enumerate] runs the walk in a spawned isolate so a
/// 10,000-entry folder never blocks the UI; [enumerateSync] is the same work
/// for tests and for callers already off the main isolate.
class BulkPlan {
  static const String _suffix = '.latch';

  /// Rewrites each output's relative path for [placement]. Only the flat
  /// placement changes anything: folders are dropped, so two sources with the
  /// same name aim at the same output name, and the write step's collision
  /// rename keeps both (FR-031).
  static List<BulkItem> applyPlacement(
    List<BulkItem> items,
    BulkPlacement placement,
  ) {
    if (placement != BulkPlacement.flatFolder) return items;
    return [
      for (final i in items)
        BulkItem(
          sourcePath: i.sourcePath,
          relativePath: i.relativePath,
          sizeBytes: i.sizeBytes,
          stampAtEnumeration: i.stampAtEnumeration,
          outRelPath: p.posix.basename(i.outRelPath.replaceAll(r'\', '/')),
        ),
    ];
  }

  static Future<BulkInventory> enumerate(
    String root,
    BulkMode mode, {
    bool recursive = false,
  }) => Isolate.run(() => enumerateSync(root, mode, recursive: recursive));

  static BulkInventory enumerateSync(
    String root,
    BulkMode mode, {
    bool recursive = false,
  }) {
    final io = DirectoryIoDart();
    final entries = io.walkSync(root, recursive: recursive);

    final items = <BulkItem>[];
    final skipped = <SkippedEntry>[];
    var subfolders = 0;
    var excluded = 0;
    var already = 0;

    for (final e in entries) {
      final rel = e.relativePath;
      final kind = e.stamp.kind;
      if (kind == EntryKind.directory && !e.isSkipped) {
        subfolders++;
        if (!recursive) excluded += _countFiles(p.join(root, rel));
        continue;
      }
      if (e.isSkipped) {
        skipped.add(SkippedEntry(rel, e.skipReason!));
        continue;
      }
      if (!_isSafe(rel)) {
        skipped.add(SkippedEntry(rel, 'unsafe path'));
        continue;
      }
      final path = p.join(root, rel);
      final head = _readPrefix(path);
      if (head == null) {
        skipped.add(SkippedEntry(rel, 'unreadable'));
        continue;
      }
      final sniffed = sniff(head);

      if (mode == BulkMode.decrypt) {
        switch (sniffed) {
          case SniffResult.container:
            items.add(
              BulkItem(
                sourcePath: path,
                relativePath: rel,
                sizeBytes: e.stamp.sizeBytes,
                stampAtEnumeration: e.stamp,
                outRelPath: _strip(rel),
              ),
            );
          case SniffResult.newerVersion:
            skipped.add(SkippedEntry(rel, 'made by a newer version of Latch'));
          case SniffResult.truncated:
          case SniffResult.notContainer:
            skipped.add(
              SkippedEntry(
                rel,
                rel.toLowerCase().endsWith(_suffix)
                    ? 'named .latch but not a Latch container'
                    : 'not a Latch container',
              ),
            );
        }
      } else {
        if (sniffed == SniffResult.container ||
            sniffed == SniffResult.newerVersion) {
          already++;
        }
        items.add(
          BulkItem(
            sourcePath: path,
            relativePath: rel,
            sizeBytes: e.stamp.sizeBytes,
            stampAtEnumeration: e.stamp,
            outRelPath: '$rel$_suffix',
          ),
        );
      }
    }

    return BulkInventory(
      root: root,
      mode: mode,
      recursive: recursive,
      items: items,
      skipped: skipped,
      subfolders: subfolders,
      excludedInSubfolders: excluded,
      alreadyContainers: already,
    );
  }

  /// `x.pdf.latch` → `x.pdf`. A container with some other name gets a neutral
  /// suffix, so the output can never be the container's own path.
  static String _strip(String rel) =>
      rel.toLowerCase().endsWith(_suffix) && rel.length > _suffix.length
      ? rel.substring(0, rel.length - _suffix.length)
      : '$rel.decrypted';

  static bool _isSafe(String rel) {
    if (rel.isEmpty || rel.startsWith('/') || rel.contains('\\')) return false;
    return !rel.split('/').any((s) => s == '..' || s == '.' || s.isEmpty);
  }

  static Uint8List? _readPrefix(String path) {
    RandomAccessFile? f;
    try {
      f = File(path).openSync();
      return f.readSync(sniffPrefixLength);
    } on FileSystemException {
      return null;
    } finally {
      f?.closeSync();
    }
  }

  static int _countFiles(String dir) {
    var n = 0;
    try {
      for (final e in Directory(
        dir,
      ).listSync(recursive: true, followLinks: false)) {
        if (e is File) n++;
      }
    } on FileSystemException {
      // Unreadable subtree: its contents are unknown, the folder itself is
      // already counted in `subfolders`.
    }
    return n;
  }

  /// Container size for a [plainBytes] file: header, wrap and one tag per
  /// 64 KiB chunk. Deliberately a slight over-estimate — a pre-flight that
  /// under-counts would pass an operation that then runs out of space.
  static int containerBytes(int plainBytes) =>
      plainBytes + 512 + ((plainBytes ~/ 65536) + 1) * 17;

  /// The most space the operation will ever occupy at once on the volume that
  /// receives output. With [reclaimsSources] each original is removed right
  /// after its container is verified, so space is handed back as the batch
  /// goes (FR-026d) and the peak is the running maximum, not the total.
  static int peakBytes(
    List<int> plainSizes, {
    required BulkMode mode,
    bool reclaimsSources = false,
  }) {
    var running = 0;
    var peak = 0;
    for (final size in plainSizes) {
      running += mode == BulkMode.encrypt ? containerBytes(size) : size;
      if (running > peak) peak = running;
      if (reclaimsSources) running -= size;
    }
    return peak;
  }

  /// Checks the volumes the operation will write to before anything is written
  /// (FR-026a/c/e). Returns null to proceed — including whenever the platform
  /// will not report free space (FR-026b) — or the shortfall naming the volume.
  ///
  /// [stagingPath] is the Android app-cache staging area, where every output
  /// of the batch sits until it is relocated, so it needs the full total.
  /// [destinationSharesSourceVolume] says whether deleting originals frees
  /// room on the destination; if it is not known to, nothing is credited.
  static Future<InsufficientSpaceError?> preflight({
    required BulkInventory inventory,
    required FreeSpacePort freeSpace,
    required String destinationPath,
    String? stagingPath,
    bool deleteSources = false,
    bool destinationSharesSourceVolume = false,
  }) async {
    final sizes = [for (final i in inventory.items) i.sizeBytes];
    if (stagingPath != null) {
      final need = peakBytes(sizes, mode: inventory.mode);
      final have = await freeSpace.freeBytesAt(stagingPath);
      if (have != null && have < need) {
        return InsufficientSpaceError(
          shortfallBytes: need - have,
          location: SpaceLocation.staging,
        );
      }
    }
    final need = peakBytes(
      sizes,
      mode: inventory.mode,
      reclaimsSources: deleteSources && destinationSharesSourceVolume,
    );
    final have = await freeSpace.freeBytesAt(destinationPath);
    if (have != null && have < need) {
      return InsufficientSpaceError(
        shortfallBytes: need - have,
        location: SpaceLocation.destination,
      );
    }
    return null;
  }

  /// Rough wall-clock estimate shown before the run (FR-026). Per-file keys pay
  /// one key derivation per file; a shared batch key pays one. [verified]
  /// (delete-originals) adds a second derivation and a second read per file,
  /// which is the cost the summary screen discloses.
  static Duration estimateDuration({
    required int fileCount,
    required int totalBytes,
    required BulkKeyMode keyMode,
    bool verified = false,
    Duration derivation = const Duration(milliseconds: 700),
    int bytesPerSecond = 80 * 1024 * 1024,
  }) {
    if (fileCount <= 0) return Duration.zero;
    final derivations =
        (keyMode == BulkKeyMode.perFile ? fileCount : 1) +
        (verified ? fileCount : 0);
    final passes = verified ? 2 : 1;
    final micros =
        derivations * derivation.inMicroseconds +
        (passes * totalBytes * 1000000) ~/ bytesPerSecond;
    return Duration(microseconds: micros);
  }
}
