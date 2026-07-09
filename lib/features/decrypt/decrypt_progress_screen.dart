import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:myenc_core/myenc_core.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';
import '../../core/app_crypto.dart';

class DecryptProgressScreen extends StatefulWidget {
  final String file;
  final String passphrase;

  const DecryptProgressScreen({
    super.key,
    required this.file,
    required this.passphrase,
  });

  @override
  State<DecryptProgressScreen> createState() => _DecryptProgressScreenState();
}

class _DecryptProgressScreenState extends State<DecryptProgressScreen> {
  double _progress = 0;
  StreamSubscription<double>? _sub;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final outFile = p.withoutExtension(widget.file);

    _sub = AppCrypto.decryptFile(widget.file, widget.passphrase).listen(
      (prog) {
        if (!mounted || _cancelled) return;
        setState(() => _progress = prog);
        if (prog >= 1.0) {
          context.pushReplacement('/decrypt/success', extra: outFile);
        }
      },
      onError: (Object e) {
        if (!mounted || _cancelled) return;
        if (e is WrongPassphraseError) {
          _showError(
            'Wrong passphrase',
            "That passphrase didn't open this file. Give it another try.",
          );
        } else if (e is CorruptedFileError) {
          _showTampered();
        } else if (e is VersionTooNewError) {
          _showError(
            'File too new',
            'This file was made with a newer version of Latch. Please update the app.',
          );
        } else {
          _showError('Decryption failed', e.toString());
        }
      },
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
                  'Opening file…',
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
                  'Checking the file is intact, then restoring.',
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
