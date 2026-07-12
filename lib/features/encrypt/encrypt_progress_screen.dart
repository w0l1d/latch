import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:myenc_core/myenc_core.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';
import '../../shared/widgets/latch_alert.dart';
import '../../core/app_crypto.dart';

class EncryptProgressScreen extends StatefulWidget {
  final List<String> files;
  final String passphrase;
  final bool deleteOriginals;
  final String? outputDir;
  final String? keyIdHex;

  const EncryptProgressScreen({
    super.key,
    required this.files,
    required this.passphrase,
    required this.deleteOriginals,
    this.outputDir,
    this.keyIdHex,
  });

  @override
  State<EncryptProgressScreen> createState() => _EncryptProgressScreenState();
}

class _EncryptProgressScreenState extends State<EncryptProgressScreen> {
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
    _sub = AppCrypto.encryptFiles(
      widget.files,
      widget.passphrase,
      deleteOriginals: widget.deleteOriginals,
      outputDir: widget.outputDir,
      keyIdHex: widget.keyIdHex,
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
        _showFatalError(e);
      },
    );
  }

  void _onDone() {
    final ok = _results.where((r) => r.ok).length;
    final bad = _results.where((r) => !r.ok).length;
    if (ok > 0) {
      final outFiles =
          _results.where((r) => r.ok).map((r) => '${r.path}.latch').toList();
      if (bad > 0) {
        _showPartialSuccess(ok, bad);
        return;
      }
      if (mounted) context.pushReplacement('/encrypt/success', extra: outFiles);
    } else {
      // All failed — show the first error.
      final first = _results.firstWhere((r) => !r.ok);
      _showError('Encryption failed', first.errorMessage ?? 'Unknown error');
    }
  }

  void _showPartialSuccess(int ok, int bad) {
    final listed = _results.where((r) => !r.ok).take(3).map((r) {
      return '${p.basename(r.path)}: ${r.errorMessage ?? "error"}';
    }).join('\n');
    final more = bad > 3 ? '\n… and ${bad - 3} more' : '';
    showLatchAlert(
      context,
      tone: LatchAlertTone.caution,
      icon: Icons.check_circle_outline,
      title: '$ok file${ok > 1 ? "s" : ""} locked, $bad failed',
      message: '$listed$more',
      buttonLabel: 'Continue',
      onPressed: () {
        Navigator.pop(context);
        final outFiles =
            _results.where((r) => r.ok).map((r) => '${r.path}.latch').toList();
        context.pushReplacement('/encrypt/success', extra: outFiles);
      },
    );
  }

  void _showFatalError(Object e) {
    final msg = e is StorageFullError
        ? 'Not enough storage space to write the encrypted file.'
        : 'Encryption failed: $e';
    _showError('Encryption failed', msg);
  }

  void _showError(String title, String message) {
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: Icons.error_outline,
      title: title,
      message: message,
      buttonLabel: 'Go back',
      onPressed: () {
        Navigator.pop(context);
        context.pop();
      },
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
    final currentIndex = _doneCount.clamp(0, fileCount);
    final currentName = widget.files.isNotEmpty
        ? p.basename(widget.files[currentIndex.clamp(0, fileCount - 1)])
        : '';
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
                  fileCount > 1 ? 'Locking $fileCount files…' : 'Locking your file…',
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
                      ? '${_doneCount + 1} of $fileCount · $currentName'
                      : currentName,
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
