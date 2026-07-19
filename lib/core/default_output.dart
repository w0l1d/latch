import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Where encrypt/decrypt outputs land when the user hasn't picked a folder.
///
/// "Beside the original" only works where the picked path IS the original.
/// The Android and iOS file pickers hand the app a private cache COPY of the
/// selected file, so writing next to it would bury outputs in app-private
/// storage where no file manager can see them.
class DefaultOutput {
  /// Directory for batch outputs, or null meaning "beside each original".
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
}
