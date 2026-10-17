import 'dart:async';
import 'dart:io';
import 'package:myenc_core/myenc_core.dart';

typedef DfRunner = Future<ProcessResult> Function(String path);

/// Free space via `df` on macOS/Linux. Everywhere else (and on any failure) the
/// answer is null, which callers read as "proceed". Android and iOS answer
/// through the platform channel in the app, not here.
class FreeSpaceDart implements FreeSpacePort {
  final DfRunner _df;
  final bool _supported;

  FreeSpaceDart({DfRunner? df, bool? supported})
    : _df = df ?? ((p) => Process.run('df', ['-Pk', p])),
      _supported = supported ?? (Platform.isMacOS || Platform.isLinux);

  @override
  Future<int?> freeBytesAt(String path) async {
    if (!_supported) return null;
    try {
      final r = await _df(path).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) return null;
      return parseDfAvailableBytes(r.stdout.toString());
    } catch (_) {
      return null;
    }
  }

  /// Parses POSIX `df -Pk` output: header line, then one data line whose 4th
  /// column is available 1K-blocks. Null for anything else.
  static int? parseDfAvailableBytes(String out) {
    final lines = out
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList(growable: false);
    if (lines.length < 2) return null;
    final cols = lines.last.trim().split(RegExp(r'\s+'));
    if (cols.length < 4) return null;
    final kb = int.tryParse(cols[3]);
    if (kb == null || kb < 0) return null;
    return kb * 1024;
  }
}
