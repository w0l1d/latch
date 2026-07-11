import 'dart:async';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:go_router/go_router.dart';

/// Hooks into the OS share/intent plumbing so the user can tap a .latch file
/// in a file manager (or "Open with Latch" on Android / iOS) and land directly
/// on the decrypt passphrase screen.
class IncomingFileService {
  final ReceiveSharingIntent _plugin;
  StreamSubscription<List<SharedMediaFile>>? _sub;
  final GoRouter _router;

  IncomingFileService({ReceiveSharingIntent? plugin, required this._router})
      : _plugin = plugin ?? ReceiveSharingIntent.instance; // ignore: prefer_initializing_formals

  /// Call once at startup — gates .latch files that arrived BEFORE the Dart
  /// engine was running (cold-start open).
  Future<void> handleInitialMedia() async {
    final files = await _plugin.getInitialMedia();
    if (files.isNotEmpty) {
      final latchFiles = _filterLatch(files);
      if (latchFiles.isNotEmpty) {
        _navigate(latchFiles);
      }
    }
  }

  /// Start listening for warm-start incoming files. Must be called after the
  /// router is configured.
  void startListening() {
    _sub?.cancel();
    _sub = _plugin.getMediaStream().listen((files) {
      final latchFiles = _filterLatch(files);
      if (latchFiles.isNotEmpty) _navigate(latchFiles);
    });
  }

  void dispose() {
    _sub?.cancel();
  }

  List<String> _filterLatch(List<SharedMediaFile> files) {
    return files
        .where((f) =>
            f.path.endsWith('.latch') ||
            (f.mimeType != null &&
                f.mimeType == 'application/octet-stream'))
        .map((f) => f.path)
        .toList();
  }

  void _navigate(List<String> files) {
    _router.push('/decrypt/passphrase', extra: files);
  }
}
