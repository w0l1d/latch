import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:myenc_core/myenc_core.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';
import '../../core/app_crypto.dart';

class EncryptProgressScreen extends StatefulWidget {
  final List<String> files;
  final String passphrase;
  final bool deleteOriginals;

  const EncryptProgressScreen({
    super.key,
    required this.files,
    required this.passphrase,
    required this.deleteOriginals,
  });

  @override
  State<EncryptProgressScreen> createState() => _EncryptProgressScreenState();
}

class _EncryptProgressScreenState extends State<EncryptProgressScreen> {
  double _progress = 0;
  int _currentIndex = 0;
  StreamSubscription<double>? _sub;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    final outFiles = widget.files.map((f) => '$f.latch').toList();

    _sub = AppCrypto.encryptFiles(
      widget.files,
      widget.passphrase,
      deleteOriginals: widget.deleteOriginals,
    ).listen(
      (prog) {
        if (!mounted || _cancelled) return;
        setState(() {
          _progress = prog;
          _currentIndex =
              (prog * widget.files.length).clamp(0, widget.files.length - 1).toInt();
        });
        if (prog >= 1.0) {
          context.pushReplacement('/encrypt/success', extra: outFiles);
        }
      },
      onError: (Object e) {
        if (!mounted || _cancelled) return;
        _showError(e);
      },
    );
  }

  void _showError(Object e) {
    final msg = e is StorageFullError
        ? 'Not enough storage space to write the encrypted file.'
        : 'Encryption failed: $e';
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: LatchColors.dangerLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: LatchColors.danger, width: 2),
        ),
        icon: const Icon(Icons.error_outline, color: LatchColors.danger, size: 32),
        title: const Text('Encryption failed',
            style: TextStyle(
                color: LatchColors.danger, fontWeight: FontWeight.w700)),
        content: Text(msg,
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
              child: const Text('Go back'),
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
    final currentName = widget.files.isNotEmpty
        ? p.basename(widget.files[_currentIndex])
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
                  'Locking your files…',
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
                  '${_currentIndex + 1} of ${widget.files.length} · $currentName',
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
