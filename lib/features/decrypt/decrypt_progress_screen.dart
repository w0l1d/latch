import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';
import '../../shared/widgets/latch_alert.dart';
import '../../shared/error_messages.dart';
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
    // An empty batch would complete instantly with no events, leaving the
    // spinner running forever — fail fast and visibly instead.
    if (widget.files.isEmpty) {
      _reported = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showError('Nothing to unlock', 'No files were selected.');
        }
      });
      return;
    }
    _loadAndRun();
  }

  Future<void> _loadAndRun() async {
    Uint8List? deviceKey;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('device_bound_recovery') ?? false) {
      deviceKey = await AppCrypto.deviceKeyService?.getOrCreateKey();
    }
    // Files shared TO this install: if a sharing keypair exists, pass it so
    // recipient wraps are tried when the passphrase wrap fails.
    Uint8List? recipientPk;
    Uint8List? recipientSk;
    final recipientSvc = AppCrypto.recipientKeys;
    if (recipientSvc != null && await recipientSvc.hasKeyPair()) {
      final kp = await recipientSvc.getOrCreateKeyPair();
      recipientPk = kp.publicKey;
      recipientSk = kp.secretKey;
    }
    if (!mounted) return;
    _sub = AppCrypto.decryptFiles(
      widget.files,
      widget.passphrase,
      deviceKey: deviceKey,
      recipientPublicKey: recipientPk,
      recipientSecretKey: recipientSk,
      onFileResult: (path, ok, error, outPath) {
        _results.add(BatchResult(path: path, ok: ok, errorMessage: error, outPath: outPath));
        _doneCount++;
      },
    ).listen(
      (prog) {
        if (!mounted || _cancelled) return;
        setState(() => _progress = prog);
        if (_doneCount >= widget.files.length && !_reported) {
          _reported = true;
          _onDone();
        }
      },
      onError: (Object e) {
        if (!mounted || _cancelled) return;
        // Fatal error (isolate crash, init failure) — not per-file.
        _showError('Decryption failed', userMessageForError(e));
      },
      onDone: () {
        if (!mounted || _cancelled || _reported) return;
        _reported = true;
        if (_doneCount >= widget.files.length) {
          // Normal completion where the terminal progress event was missed
          // (defensive — the worker normally reports 1.0 after the last file).
          _onDone();
        } else {
          // The worker stream ended without reporting every file. Without
          // this the spinner runs forever with Cancel as the only way out.
          _showError('Decryption stopped unexpectedly',
              'Only $_doneCount of ${widget.files.length} files were processed.');
        }
      },
    );
  }

  void _onDone() {
    final ok = _results.where((r) => r.ok).length;
    final bad = _results.where((r) => !r.ok).length;
    if (ok > 0) {
      if (bad > 0) {
        _showPartialSuccess(ok, bad);
        return;
      }
      if (mounted) {
        context.pushReplacement('/decrypt/success', extra: _outFiles());
      }
    } else {
      // All failed — pick the first error and show the right dialog.
      final first = _results.firstWhere((r) => !r.ok);
      final msg = first.errorMessage ?? '';
      if (msg.contains('WrongPassphraseError')) {
        _showError('Wrong passphrase',
            "That passphrase didn't open these files. Give it another try.");
      } else if (msg.contains('NotALatchFileError')) {
        _showError('Not a Latch file',
            "This doesn't look like a file Latch created. Choose a file ending in .latch.");
      } else if (msg.contains('CorruptedFileError')) {
        _showTampered();
      } else if (msg.contains('VersionTooNewError')) {
        _showError('File too new',
            'A file was made with a newer version of Latch. Please update the app.');
      } else if (msg.contains('StorageFullError')) {
        _showError('Not enough space',
            'There is not enough free storage to write the decrypted file.');
      } else {
        _showError('Decryption failed', userMessageForError(msg));
      }
    }
  }

  /// Paths the worker actually wrote (accounts for the output folder and
  /// collision renaming); falls back to the derived name only if a worker
  /// predates the outPath protocol field.
  List<String> _outFiles() => _results
      .where((r) => r.ok)
      .map((r) => r.outPath ?? p.withoutExtension(r.path))
      .toList();

  void _showPartialSuccess(int ok, int bad) {
    final listed = _results.where((r) => !r.ok).take(3).map((r) {
      final msg = userMessageForError(r.errorMessage ?? '');
      return '${p.basename(r.path)}: $msg';
    }).join('\n');
    final more = bad > 3 ? '\n… and ${bad - 3} more' : '';
    showLatchAlert(
      context,
      tone: LatchAlertTone.caution,
      icon: Icons.check_circle_outline,
      title: '$ok file${ok > 1 ? "s" : ""} opened, $bad failed',
      message: '$listed$more',
      buttonLabel: 'Continue',
      onPressed: () {
        Navigator.pop(context);
        context.pushReplacement('/decrypt/success', extra: _outFiles());
      },
    );
  }

  void _showError(String title, String message) {
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: Icons.lock_outline,
      title: title,
      message: message,
      buttonLabel: 'Try again',
      onPressed: () {
        Navigator.pop(context);
        context.pop();
      },
    );
  }

  void _showTampered() {
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: Icons.warning_amber_rounded,
      title: "This file can't be trusted.",
      message:
          'The file has been modified or is incomplete. It may have been tampered with or corrupted in transit. Do not rely on its contents.',
      buttonLabel: 'Back to home',
      onPressed: () {
        Navigator.pop(context);
        context.go('/home');
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
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          _cancelled = true;
          _sub?.cancel();
          context.pop();
        }
      },
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
