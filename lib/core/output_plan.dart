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
  const OutputTarget({this.treeUri});
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

  const RelocatedOutput(this.path, {this.fellBackToDownloads = false});
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
  ///   cached grant; returns a tree URI, or null when the user declines (→ that
  ///   folder's files fall back to Downloads).
  static Future<OutputPlan> plan(
    List<String> files, {
    String? explicitDir,
    String? explicitTreeUri,
    Future<String?> Function(String folder)? requestGrant,
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
      return OutputPlan(stagingDir: staging, outputDir: staging, byPath: byPath);
    }

    // "Same folder as each original": resolve one grant per distinct folder.
    final grantByFolder = <String, String?>{};
    for (final f in files) {
      final folder = await SafBridge.realDirectoryFor(f);
      if (folder == null) {
        // Cloud / media provider with no filesystem folder → Downloads.
        byPath[f] = const OutputTarget();
        continue;
      }
      if (!grantByFolder.containsKey(folder)) {
        var grant = SafBridge.treeGrantForFolder(folder);
        if (grant == null && requestGrant != null) {
          grant = await requestGrant(folder);
          if (grant != null) await SafBridge.rememberTreeGrant(folder, grant);
        }
        grantByFolder[folder] = grant;
      }
      byPath[f] = OutputTarget(treeUri: grantByFolder[folder]);
    }
    return OutputPlan(stagingDir: staging, outputDir: staging, byPath: byPath);
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
        );
        await _deleteQuietly(staged);
        out.add(RelocatedOutput(created.displayPath));
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
