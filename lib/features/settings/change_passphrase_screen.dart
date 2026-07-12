import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/app_crypto.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_alert.dart';
import '../../shared/widgets/latch_button.dart';

/// Change the passphrase of existing .latch files by re-wrapping the DEK —
/// the file body is never re-encrypted, so this is fast even for huge files.
class ChangePassphraseScreen extends StatefulWidget {
  const ChangePassphraseScreen({super.key});

  @override
  State<ChangePassphraseScreen> createState() => _ChangePassphraseScreenState();
}

class _ChangePassphraseScreenState extends State<ChangePassphraseScreen> {
  final _oldController = TextEditingController();
  final _newController = TextEditingController();
  List<String> _files = [];
  bool _busy = false;
  StreamSubscription<double>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    _oldController.dispose();
    _newController.dispose();
    super.dispose();
  }

  bool get _ready =>
      _files.isNotEmpty &&
      _oldController.text.isNotEmpty &&
      _newController.text.isNotEmpty &&
      !_busy;

  Future<void> _pickFiles() async {
    final result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    setState(() {
      _files = result.paths
          .whereType<String>()
          .where((path) => path.endsWith('.latch'))
          .toList();
    });
  }

  void _run() {
    setState(() => _busy = true);
    final results = <BatchResult>[];
    _sub = AppCrypto.changePassphraseFiles(
      _files,
      _oldController.text,
      _newController.text,
      onFileResult: (path, ok, error) {
        results.add(BatchResult(path: path, ok: ok, errorMessage: error));
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
        tone: LatchAlertTone.caution,
        icon: Icons.check_circle_outline,
        title: 'Passphrase changed',
        message:
            '$ok file${ok == 1 ? '' : 's'} now open${ok == 1 ? 's' : ''} with the new passphrase.',
        buttonLabel: 'Done',
        onPressed: () {
          Navigator.pop(context);
          context.pop();
        },
      );
      return;
    }
    final first = bad.first.errorMessage ?? '';
    final wrongPass = first.contains('WrongPassphraseError');
    final listed = bad
        .take(3)
        .map((r) => p.basename(r.path))
        .join(', ');
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: wrongPass ? Icons.lock_outline : Icons.error_outline,
      title: wrongPass ? 'Wrong current passphrase' : 'Some files failed',
      message: wrongPass
          ? "The current passphrase didn't open: $listed. Those files were left unchanged."
          : 'Failed: $listed. ${ok > 0 ? '$ok other file${ok == 1 ? ' was' : 's were'} changed.' : 'No files were changed.'}',
      buttonLabel: 'OK',
      onPressed: () => Navigator.pop(context),
    );
  }

  void _showFatal(String message) {
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: Icons.error_outline,
      title: 'Change failed',
      message: message,
      buttonLabel: 'OK',
      onPressed: () => Navigator.pop(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Change passphrase'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
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
                              ? 'Choose .latch files'
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
              const SizedBox(height: 20),
              TextField(
                controller: _oldController,
                obscureText: true,
                enabled: !_busy,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'Current passphrase'),
                style: const TextStyle(fontSize: 17, letterSpacing: 1.5),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _newController,
                obscureText: true,
                enabled: !_busy,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'New passphrase'),
                style: const TextStyle(fontSize: 17, letterSpacing: 1.5),
              ),
              const SizedBox(height: 12),
              Text(
                'Only the lock changes — file contents are not rewritten, so this is instant even for large files. Files stay where they are.',
                style: Theme.of(context).textTheme.bodySmall,
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
                label: 'Change passphrase',
                onPressed: _ready ? _run : null,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
