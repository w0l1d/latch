import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:myenc_adapters/myenc_adapters.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'app_crypto.dart';
import 'default_output.dart';
import 'saf_bridge.dart';

/// Where one source file's output should ultimately land (Android only).
class OutputTarget {
  /// Granted folder (tree URI) to create the output in; null means there is no
  /// grant, so the output falls back to Downloads.
  final String? treeUri;

  /// Path from [treeUri]'s folder down to the destination folder, for grants
  /// that cover an ancestor of the source folder rather than the folder itself.
  /// Empty means create directly in the granted folder.
  final String subPath;

  const OutputTarget({this.treeUri, this.subPath = ''});
}

/// A resolved output strategy for a batch.
///
/// On Android the crypto worker can only write to app-private storage under
/// scoped storage, so it stages output in [stagingDir] and the main isolate
/// relocates each file into its [byPath] target afterwards. Off-Android the
/// worker writes the final file directly and [stagingDir] is null.
class OutputPlan {
  /// App-cache dir the worker stages Android output into; null off-Android.
  final String? stagingDir;

  /// Value passed to the worker's `outputDir`. On Android this is [stagingDir];
  /// off-Android it's the real destination (or null = beside each original).
  final String? outputDir;

  /// Per-source-path relocation target (Android only; empty off-Android).
  final Map<String, OutputTarget> byPath;

  const OutputPlan({this.stagingDir, this.outputDir, this.byPath = const {}});

  bool get isStaged => stagingDir != null;
}

/// The final resting place of one output file after relocation.
class RelocatedOutput {
  /// Human-readable destination path the file actually landed at.
  final String path;

  /// True when the file couldn't be placed in the source folder and was saved
  /// to Downloads instead — surfaced to the user as an explicit notice.
  final bool fellBackToDownloads;

  /// The granted SAF tree the file was created in (Android), if any. Lets the
  /// UI open exactly that folder in the system file browser. Null for Downloads
  /// fallback and non-Android outputs, where [path] is used instead.
  final String? treeUri;

  const RelocatedOutput(
    this.path, {
    this.fellBackToDownloads = false,
    this.treeUri,
  });
}

class OutputPlanner {
  /// Builds an [OutputPlan] for [files].
  ///
  /// - [explicitDir]: a real destination folder the user picked (desktop) or
  ///   the iOS default; ignored on Android.
  /// - [explicitTreeUri]: a single folder grant chosen for ALL files (the
  ///   encrypt "choose a folder" button on Android). When set, every file
  ///   targets it and no per-folder prompting happens.
  /// - [requestGrant]: invoked once per distinct source folder that has no
  ///   cached grant, and once for the whole batch with a null folder when the
  ///   source folder can't be resolved at all; returns a tree URI, or null when
  ///   the user declines (→ those files fall back to Downloads).
  static Future<OutputPlan> plan(
    List<String> files, {
    String? explicitDir,
    String? explicitTreeUri,
    Future<String?> Function(String? folder)? requestGrant,
    @visibleForTesting bool? platformIsAndroid,
  }) async {
    final android = platformIsAndroid ?? Platform.isAndroid;
    if (!android) {
      final dir = explicitDir ?? await DefaultOutput.directoryFor(files);
      return OutputPlan(outputDir: dir);
    }

    final staging = p.join((await getTemporaryDirectory()).path, 'latch_stage');
    await _resetDir(staging);

    final byPath = <String, OutputTarget>{};

    if (explicitTreeUri != null) {
      for (final f in files) {
        byPath[f] = OutputTarget(treeUri: explicitTreeUri);
      }
      return OutputPlan(
        stagingDir: staging,
        outputDir: staging,
        byPath: byPath,
      );
    }

    // "Same folder as each original": resolve one grant per distinct folder.
    final grantByFolder = <String, OutputTarget>{};
    // Sources whose provider exposes no filesystem folder (cloud, or a document
    // id we can't map to a path) still get a say in where output lands — ask
    // once for the whole batch rather than silently using Downloads. Nothing is
    // persisted: there is no folder path to key a grant on.
    var askedUnknown = false;
    String? unknownGrant;
    for (final f in files) {
      final folder = await SafBridge.realDirectoryFor(f);
      if (folder == null) {
        if (!askedUnknown) {
          askedUnknown = true;
          if (requestGrant != null) unknownGrant = await requestGrant(null);
        }
        byPath[f] = OutputTarget(treeUri: unknownGrant);
        continue;
      }
      grantByFolder[folder] ??= await _grantFor(folder, requestGrant);
      byPath[f] = grantByFolder[folder]!;
    }
    return OutputPlan(stagingDir: staging, outputDir: staging, byPath: byPath);
  }

  /// Resolves write access to [folder], asking the user only as a last resort:
  ///
  /// 1. the app's own cache of grants it took for exactly this folder;
  /// 2. any grant Android still holds that covers the folder — the folder
  ///    itself, or an ancestor of it (a grant on `.../Documents` can create
  ///    inside `.../Documents/Work`), so a folder already allowed once is never
  ///    asked about again;
  /// 3. only then the folder prompt. After the picker returns, the grant is
  ///    re-resolved through (2) so a user who picks a parent of the requested
  ///    folder still gets the output in the source folder itself.
  ///
  /// A null target tree URI means no access → the caller uses Downloads.
  static Future<OutputTarget> _grantFor(
    String folder,
    Future<String?> Function(String? folder)? requestGrant,
  ) async {
    final cached = SafBridge.treeGrantForFolder(folder);
    if (cached != null) return OutputTarget(treeUri: cached);

    final existing = await SafBridge.existingTreeGrantFor(folder);
    if (existing != null) {
      return OutputTarget(treeUri: existing.treeUri, subPath: existing.subPath);
    }

    if (requestGrant == null) return const OutputTarget();
    final picked = await requestGrant(folder);
    if (picked == null) return const OutputTarget();

    final resolved = await SafBridge.existingTreeGrantFor(folder);
    if (resolved == null) {
      // The user picked a folder unrelated to the source — honor their choice
      // and create the output directly in it.
      return OutputTarget(treeUri: picked);
    }
    if (resolved.subPath.isEmpty) {
      // Granted exactly this folder: worth caching so later batches skip even
      // the platform lookup.
      await SafBridge.rememberTreeGrant(folder, resolved.treeUri);
    }
    return OutputTarget(treeUri: resolved.treeUri, subPath: resolved.subPath);
  }

  static Future<void> _resetDir(String dir) async {
    final d = Directory(dir);
    if (await d.exists()) await d.delete(recursive: true);
    await d.create(recursive: true);
  }
}

/// Relocates each successfully-staged output into its target folder (Android),
/// deleting the staged temp as it goes. Off-Android (`plan.isStaged == false`)
/// this is a no-op that just returns each ok result's own `outPath`.
///
/// [displayNameFor] maps a source path to the destination file name (e.g.
/// `<name>.latch` for encrypt, the de-suffixed name for decrypt).
Future<List<RelocatedOutput>> relocateStagedOutputs(
  List<BatchResult> results,
  OutputPlan plan, {
  required String Function(String sourcePath) displayNameFor,
  @visibleForTesting Future<String?> Function()? downloadsDir,
}) async {
  final ok = results.where((r) => r.ok && r.outPath != null).toList();
  if (!plan.isStaged) {
    return [for (final r in ok) RelocatedOutput(r.outPath!)];
  }

  final io = FileIoDart();
  final out = <RelocatedOutput>[];
  String? downloads;
  var downloadsResolved = false;

  for (final r in ok) {
    final staged = r.outPath!;
    final name = displayNameFor(r.path);
    final target = plan.byPath[r.path];

    // 1. Preferred: create the file in the granted source folder.
    if (target?.treeUri != null) {
      try {
        final created = await SafBridge.createInTree(
          treeUri: target!.treeUri!,
          displayName: name,
          srcPath: staged,
          subPath: target.subPath,
        );
        await _deleteQuietly(staged);
        out.add(
          RelocatedOutput(
            created.displayPath,
            // A grant on an ancestor folder would open the wrong folder, so
            // "Open folder" addresses those by path instead.
            treeUri: target.subPath.isEmpty ? target.treeUri : null,
          ),
        );
        continue;
      } catch (_) {
        // Grant revoked or write failed — fall through to Downloads.
      }
    }

    // 2. Fallback: move the staged file into public Downloads.
    if (!downloadsResolved) {
      downloads = await (downloadsDir?.call() ?? DefaultOutput.directory());
      downloadsResolved = true;
    }
    if (downloads == null) {
      // No Downloads folder (shouldn't happen on Android) — leave in cache.
      out.add(RelocatedOutput(staged));
      continue;
    }
    final dest = io.resolveNameCollision(p.join(downloads, name));
    await _move(staged, dest);
    out.add(RelocatedOutput(dest, fellBackToDownloads: true));
  }
  return out;
}

Future<void> _move(String from, String to) async {
  final src = File(from);
  try {
    await src.rename(to);
  } on FileSystemException {
    // Cache and Downloads can be different mounts (EXDEV) — copy then delete.
    await src.copy(to);
    await _deleteQuietly(from);
  }
}

Future<void> _deleteQuietly(String path) async {
  try {
    await File(path).delete();
  } catch (_) {
    // Best-effort cleanup.
  }
}
