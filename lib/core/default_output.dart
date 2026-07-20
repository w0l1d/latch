import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'saf_bridge.dart';

/// Where encrypt/decrypt outputs land when the user hasn't picked a folder.
///
/// "Beside the original" only works where the picked path IS the original.
/// The Android and iOS file pickers hand the app a private cache COPY of the
/// selected file, so writing next to it would bury outputs in app-private
/// storage where no file manager can see them.
class DefaultOutput {
  /// Directory for batch outputs, or null meaning "beside each original".
  ///
  /// Preference order:
  /// 1. The folder the source files actually live in — resolved from their
  ///    content:// URIs (Android) — when every file shares one folder and
  ///    scoped storage lets the app write there.
  /// 2. The platform fallback from [directory].
  static Future<String?> directoryFor(List<String> sourceFiles) async {
    if (Platform.isAndroid) {
      final dirs = <String>{};
      for (final f in sourceFiles) {
        final dir = await SafBridge.realDirectoryFor(f);
        if (dir == null) return directory();
        dirs.add(dir);
      }
      if (dirs.length == 1 && await _canWriteTo(dirs.single)) {
        return dirs.single;
      }
      return directory();
    }
    return directory();
  }

  /// Platform fallback, or null meaning "beside each original".
  ///
  /// - Android: the public Downloads folder — visible in every file manager
  ///   and writable without permissions since API 29 (MediaStore-backed
  ///   direct paths).
  /// - iOS: the app documents folder, exposed in the Files app via
  ///   UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace.
  /// - Desktop: null — picked paths are the real files, so beside the
  ///   original is both correct and visible.
  static Future<String?> directory() async {
    if (Platform.isAndroid) {
      for (final candidate in const [
        '/storage/emulated/0/Download',
        '/sdcard/Download',
      ]) {
        if (await Directory(candidate).exists()) return candidate;
      }
      return null;
    }
    if (Platform.isIOS) {
      return (await getApplicationDocumentsDirectory()).path;
    }
    return null;
  }

  /// Scoped storage decides writability per folder (Downloads yes, most
  /// others no) — the only reliable check is to try.
  static Future<bool> _canWriteTo(String dir) async {
    final probe = File(p.join(dir, '.latch-write-probe'));
    try {
      await probe.writeAsBytes(const [0]);
      await probe.delete();
      return true;
    } catch (_) {
      try {
        if (await probe.exists()) await probe.delete();
      } catch (_) {}
      return false;
    }
  }
}
