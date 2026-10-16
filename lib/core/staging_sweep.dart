import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Cache folders Android runs stage into. A lock run's staged sources and an
/// unlock run's staged outputs are plaintext.
const stagedSourceDirName = 'latch_src';
const stagedOutputDirName = 'latch_stage';

/// Removes staging left behind by a run that never reached its own teardown
/// (process killed under memory pressure, crash, force-stop).
///
/// Call it once, before any screen can start a run: it deletes the staging
/// folders wholesale, so it must not race a live batch. Never throws — a
/// folder that cannot be removed is retried at the next start.
class StagingSweep {
  static Future<int> sweepOrphans({String? tempDir}) async {
    var removed = 0;
    try {
      final tmp = tempDir ?? (await getTemporaryDirectory()).path;
      for (final name in [stagedSourceDirName, stagedOutputDirName]) {
        final d = Directory(p.join(tmp, name));
        try {
          if (await d.exists()) {
            await d.delete(recursive: true);
            removed++;
          }
        } on FileSystemException {
          // Best effort.
        }
      }
    } catch (_) {
      // No cache directory to look in: nothing to sweep.
    }
    return removed;
  }
}
