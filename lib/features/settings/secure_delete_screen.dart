import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/app_crypto.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_alert.dart';
import '../../shared/widgets/latch_button.dart';
import '../../shared/error_messages.dart';

/// Crypto-erase .latch files (spec UC-10). Overwrites the header in place
/// with random bytes — destroying the salt, DEK wraps, key-id, encrypted
/// filename, and secretstream header — then deletes the file. The body
/// becomes permanent noise even if recovered from flash.
class SecureDeleteScreen extends StatefulWidget {
  const SecureDeleteScreen({super.key});

  @override
  State<SecureDeleteScreen> createState() => _SecureDeleteScreenState();
}

class _SecureDeleteScreenState extends State<SecureDeleteScreen> {
  List<String> _files = [];
  bool _busy = false;
  StreamSubscription<double>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool get _ready => _files.isNotEmpty && !_busy;

  Future<void> _pickFiles() async {
    List<String> paths;
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null) return;
      paths = result.paths.whereType<String>().toList();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the file picker: $e')),
        );
      }
      return;
    }
    if (!mounted) return;
    final latch = paths.where((path) => path.endsWith('.latch')).toList();
    final skipped = paths.length - latch.length;
    setState(() => _files = latch);
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                '$skipped file${skipped == 1 ? '' : 's'} skipped — only .latch files can be shredded.')),
      );
    }
  }

  Future<void> _showConfirm() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: LatchColors.dangerLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: LatchColors.danger, width: 2),
        ),
        icon: const Icon(Icons.warning_amber_rounded,
            color: LatchColors.danger, size: 32),
        title: const Text(
          'Shred files?',
          style: TextStyle(
            color: LatchColors.danger,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          _files.length == 1
              ? 'This will permanently destroy '
                  '${p.basename(_files.first)}. The encrypted body cannot be '
                  'recovered even if the file is restored from flash.'
              : 'This will permanently destroy ${_files.length} files. The '
                  'encrypted bodies cannot be recovered even if the files are '
                  'restored from flash.',
          style: const TextStyle(color: Color(0xFF7A3128)),
        ),
        actions: [
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: LatchColors.ink,
                    side: const BorderSide(color: LatchColors.ink, width: 2),
                    minimumSize: const Size(0, 48),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: LatchColors.danger,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 48),
                  ),
                  child: const Text('Shred files'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    if (ok == true && mounted) _run();
  }

  void _run() {
    setState(() => _busy = true);
    final results = <BatchResult>[];
    _sub = AppCrypto.secureDeleteFiles(
      _files,
      onFileResult: (path, ok, error, outPath) {
        results.add(BatchResult(path: path, ok: ok, errorMessage: error, outPath: outPath));
      },
    ).listen(
      (_) {},
      onDone: () {
        if (!mounted) return;
        setState(() => _busy = false);
        _showResults(results);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _busy = false);
        _showFatal(e.toString());
      },
    );
  }

  void _showResults(List<BatchResult> results) {
    final ok = results.where((r) => r.ok).length;
    final bad = results.where((r) => !r.ok).toList();
    if (bad.isEmpty) {
      showLatchAlert(
        context,
        tone: LatchAlertTone.danger,
        icon: Icons.check_circle_outline,
        title: 'Files shredded',
        message:
            '$ok file${ok == 1 ? '' : 's'} crypto-erased and deleted.',
        buttonLabel: 'Done',
        onPressed: () {
          if (Navigator.of(context).canPop()) {
            Navigator.pop(context);
          }
          context.pop();
        },
      );
      return;
    }
    final listed = bad
        .take(3)
        .map((r) => p.basename(r.path))
        .join(', ');
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: Icons.error_outline,
      title: 'Some files failed',
      message: 'Failed: $listed. '
          '${ok > 0 ? '$ok other file${ok == 1 ? ' was' : 's were'} shredded.' : 'No files were shredded.'}',
      buttonLabel: 'OK',
      onPressed: () => Navigator.pop(context),
    );
  }

  void _showFatal(String message) {
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: Icons.error_outline,
      title: 'Shred failed',
      message: userMessageForError(message),
      buttonLabel: 'OK',
      onPressed: () => Navigator.pop(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Leaving mid-shred would hide which files were already destroyed —
      // block back navigation until the batch reports.
      canPop: !_busy,
      child: Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () {
          if (!_busy) context.pop();
        }),
        title: const Text('Secure delete'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                button: true,
                label: 'Choose .latch files to shred',
                child: GestureDetector(
                  onTap: _busy ? null : _pickFiles,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: LatchColors.border, width: 1.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                    children: [
                      const Icon(Icons.insert_drive_file_outlined,
                          color: LatchColors.ink),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _files.isEmpty
                              ? 'Choose .latch files to shred'
                              : _files.length == 1
                                  ? p.basename(_files.first)
                                  : '${_files.length} files selected',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: LatchColors.ink,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Crypto-erase destroys the encryption key stored in each '
                'file’s header, then deletes the file. The encrypted body '
                'becomes permanent noise — even if a deleted file is recovered '
                'from flash, its contents can never be decrypted.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 10),
              Text(
                'This is the safest way to delete .latch files. '
                'There is no undo.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: LatchColors.danger,
                    ),
              ),
              const Spacer(),
              if (_busy)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: LatchColors.ink,
                    ),
                  ),
                ),
              LatchPrimaryButton(
                label: 'Shred files',
                onPressed: _ready ? _showConfirm : null,
                backgroundColor: LatchColors.danger,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
    );
  }
}
