import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';
import '../../core/app_crypto.dart';

class DecryptProgressScreen extends StatefulWidget {
  final List<String> files;
  final String passphrase;

  const DecryptProgressScreen({
    super.key,
    required this.files,
    required this.passphrase,
  });

  @override
  State<DecryptProgressScreen> createState() => _DecryptProgressScreenState();
}

class _DecryptProgressScreenState extends State<DecryptProgressScreen> {
  double _progress = 0;
  StreamSubscription<double>? _sub;
  bool _cancelled = false;
  final _results = <BatchResult>[];
  int _doneCount = 0;
  bool _reported = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _sub = AppCrypto.decryptFiles(
      widget.files,
      widget.passphrase,
      onFileResult: (path, ok, error) {
        _results.add(BatchResult(path: path, ok: ok, errorMessage: error));
        _doneCount++;
      },
    ).listen(
      (prog) {
        if (!mounted || _cancelled) return;
        setState(() => _progress = prog);
        if (prog >= 1.0 && !_reported) {
          _reported = true;
          _onDone();
        }
      },
      onError: (Object e) {
        if (!mounted || _cancelled) return;
        // Fatal error (isolate crash, init failure) — not per-file.
        _showError('Decryption failed', e.toString());
      },
    );
  }

  void _onDone() {
    final ok = _results.where((r) => r.ok).length;
    final bad = _results.where((r) => !r.ok).length;
    if (ok > 0) {
      final outFiles = _results
          .where((r) => r.ok)
          .map((r) => p.withoutExtension(r.path))
          .toList();
      if (bad > 0) {
        _showPartialSuccess(ok, bad);
        return;
      }
      if (mounted) {
        context.pushReplacement('/decrypt/success', extra: outFiles);
      }
    } else {
      // All failed — pick the first error and show the right dialog.
      final first = _results.firstWhere((r) => !r.ok);
      final msg = first.errorMessage ?? '';
      if (msg.contains('WrongPassphraseError')) {
        _showError('Wrong passphrase',
            "That passphrase didn't open these files. Give it another try.");
      } else if (msg.contains('CorruptedFileError')) {
        _showTampered();
      } else if (msg.contains('VersionTooNewError')) {
        _showError('File too new',
            'A file was made with a newer version of Latch. Please update the app.');
      } else {
        _showError('Decryption failed', msg);
      }
    }
  }

  void _showPartialSuccess(int ok, int bad) {
    final listed = _results.where((r) => !r.ok).take(3).map((r) {
      return '${p.basename(r.path)}: ${r.errorMessage ?? "error"}';
    }).join('\n');
    final more = bad > 3 ? '\n… and ${bad - 3} more' : '';
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: LatchColors.cautionLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: LatchColors.caution, width: 2),
        ),
        icon: const Icon(Icons.check_circle_outline,
            color: LatchColors.caution, size: 32),
        title: Text('$ok file${ok > 1 ? "s" : ""} opened, $bad failed',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        content: Text('$listed$more',
            style: const TextStyle(color: Color(0xFF5C3D1A))),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                final outFiles = _results
                    .where((r) => r.ok)
                    .map((r) => p.withoutExtension(r.path))
                    .toList();
                context.pushReplacement('/decrypt/success', extra: outFiles);
              },
              child: const Text('Continue'),
            ),
          ),
        ],
      ),
    );
  }

  void _showError(String title, String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: LatchColors.dangerLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: LatchColors.danger, width: 2),
        ),
        icon: const Icon(Icons.lock_outline, color: LatchColors.danger, size: 32),
        title: Text(title,
            style: const TextStyle(
                color: LatchColors.danger, fontWeight: FontWeight.w700)),
        content: Text(message,
            style: const TextStyle(color: Color(0xFF7A3128))),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                context.pop();
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: LatchColors.danger,
                  foregroundColor: Colors.white),
              child: const Text('Try again'),
            ),
          ),
        ],
      ),
    );
  }

  void _showTampered() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: LatchColors.dangerLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: LatchColors.danger, width: 2),
        ),
        icon: const Icon(Icons.warning_amber_rounded,
            color: LatchColors.danger, size: 32),
        title: const Text("This file can't be trusted.",
            style: TextStyle(
                color: LatchColors.danger, fontWeight: FontWeight.w700)),
        content: const Text(
          'The file has been modified or is incomplete. It may have been tampered with or corrupted in transit. Do not rely on its contents.',
          style: TextStyle(color: Color(0xFF7A3128)),
        ),
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                context.go('/home');
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: LatchColors.danger,
                  foregroundColor: Colors.white),
              child: const Text('Back to home'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fileCount = widget.files.length;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            child: Column(
              children: [
                const Spacer(),
                SizedBox(
                  width: 64,
                  height: 64,
                  child: CircularProgressIndicator(
                    value: _progress < 1.0 ? _progress : null,
                    strokeWidth: 4,
                    backgroundColor: LatchColors.border,
                    color: LatchColors.ink,
                  ),
                ),
                const SizedBox(height: 28),
                Text(
                  fileCount > 1
                      ? 'Opening $fileCount files…'
                      : 'Opening file…',
                  style: Theme.of(context).textTheme.displayMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: _progress,
                    backgroundColor: LatchColors.border,
                    color: LatchColors.ink,
                    minHeight: 10,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  fileCount > 1
                      ? '${_doneCount + 1} of $fileCount'
                      : 'Checking the file is intact, then restoring.',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
                const Spacer(),
                LatchSecondaryButton(
                  label: 'Cancel',
                  onPressed: () {
                    _cancelled = true;
                    _sub?.cancel();
                    context.pop();
                  },
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
