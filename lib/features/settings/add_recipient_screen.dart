import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/app_crypto.dart';
import '../../core/recipient_key_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_alert.dart';
import '../../shared/widgets/latch_button.dart';

/// Share existing .latch files with a saved recipient (spec §3, UC-6) by
/// appending an X25519 sealed-box wrap to each file's header — the body is
/// never re-encrypted, and the passphrase keeps working.
class AddRecipientScreen extends StatefulWidget {
  const AddRecipientScreen({super.key});

  @override
  State<AddRecipientScreen> createState() => _AddRecipientScreenState();
}

class _AddRecipientScreenState extends State<AddRecipientScreen> {
  final _passphraseController = TextEditingController();
  List<String> _files = [];
  List<RecipientEntry> _recipients = [];
  String? _selectedLabel;
  bool _busy = false;
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _loadRecipients();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _passphraseController.dispose();
    super.dispose();
  }

  Future<void> _loadRecipients() async {
    final list = await AppCrypto.recipientKeys?.listRecipients() ?? [];
    if (!mounted) return;
    setState(() {
      _recipients = list;
      if (_selectedLabel != null &&
          !list.any((r) => r.label == _selectedLabel)) {
        _selectedLabel = null;
      }
    });
  }

  bool get _ready =>
      _files.isNotEmpty &&
      _passphraseController.text.isNotEmpty &&
      _selectedLabel != null &&
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
    final recipient =
        _recipients.firstWhere((r) => r.label == _selectedLabel);
    setState(() => _busy = true);
    final results = <BatchResult>[];
    _sub = AppCrypto.addRecipientFiles(
      _files,
      _passphraseController.text,
      recipientPublicKey: decodePublicKeyHex(recipient.publicKeyHex),
      onFileResult: (path, ok, error) {
        results.add(BatchResult(path: path, ok: ok, errorMessage: error));
      },
    ).listen(
      (_) {},
      onDone: () {
        if (!mounted) return;
        setState(() => _busy = false);
        _showResults(results, recipient.label);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _busy = false);
        _showFatal(e.toString());
      },
    );
  }

  void _showResults(List<BatchResult> results, String recipientLabel) {
    final ok = results.where((r) => r.ok).length;
    final bad = results.where((r) => !r.ok).toList();
    if (bad.isEmpty) {
      showLatchAlert(
        context,
        tone: LatchAlertTone.caution,
        icon: Icons.check_circle_outline,
        title: 'Shared with $recipientLabel',
        message:
            '$ok file${ok == 1 ? '' : 's'} can now be opened by $recipientLabel. '
            'Your passphrase still works too.',
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
    final listed = bad.take(3).map((r) => p.basename(r.path)).join(', ');
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: wrongPass ? Icons.lock_outline : Icons.error_outline,
      title: wrongPass ? 'Wrong passphrase' : 'Some files failed',
      message: wrongPass
          ? "The passphrase didn't open: $listed. Those files were left unchanged."
          : 'Failed: $listed. ${ok > 0 ? '$ok other file${ok == 1 ? ' was' : 's were'} shared.' : 'No files were changed.'}',
      buttonLabel: 'OK',
      onPressed: () => Navigator.pop(context),
    );
  }

  void _showFatal(String message) {
    showLatchAlert(
      context,
      tone: LatchAlertTone.danger,
      icon: Icons.error_outline,
      title: 'Sharing failed',
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
        title: const Text('Share with recipient'),
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
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: LatchColors.ink),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _passphraseController,
                obscureText: true,
                enabled: !_busy,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(hintText: 'Passphrase'),
                style: const TextStyle(fontSize: 17, letterSpacing: 1.5),
              ),
              const SizedBox(height: 12),
              if (_recipients.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: LatchColors.border, width: 1.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'No recipients saved yet. Add one under '
                    'Settings → Sharing first.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: LatchColors.border, width: 1.5),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedLabel,
                      isExpanded: true,
                      hint: const Text('Choose a recipient'),
                      style: Theme.of(context)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: LatchColors.ink),
                      items: _recipients
                          .map((r) => DropdownMenuItem(
                                value: r.label,
                                child: Text(r.label),
                              ))
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (v) => setState(() => _selectedLabel = v),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                'This adds a lock for the recipient — the file also still '
                'opens with the passphrase. Contents are not rewritten, so '
                'this is instant even for large files.',
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
                label: 'Share files',
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
