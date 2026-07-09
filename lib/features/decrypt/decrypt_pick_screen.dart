import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class DecryptPickScreen extends StatefulWidget {
  const DecryptPickScreen({super.key});

  @override
  State<DecryptPickScreen> createState() => _DecryptPickScreenState();
}

class _DecryptPickScreenState extends State<DecryptPickScreen> {
  List<String>? _selectedFiles;
  bool _picking = false;

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result != null && result.files.isNotEmpty && mounted) {
        final paths = result.files.map((f) => f.path!).where((p) => p.isNotEmpty).toList();
        if (paths.isNotEmpty) setState(() => _selectedFiles = paths);
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = _selectedFiles?.length ?? 0;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Decrypt files'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _picking ? null : _pick,
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: LatchColors.border, width: 2),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: _picking
                        ? const Center(child: CircularProgressIndicator(color: LatchColors.ink))
                        : count == 0
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.lock_open_outlined, size: 44, color: LatchColors.muted),
                                    const SizedBox(height: 14),
                                    Text(
                                      'Choose locked files',
                                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                        color: LatchColors.muted,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Look for files ending in .latch',
                                      style: Theme.of(context).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.all(16),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    const Icon(Icons.insert_drive_file_outlined, size: 44, color: LatchColors.ink),
                                    const SizedBox(height: 12),
                                    Text(
                                      count == 1 ? p.basename(_selectedFiles!.first) : '$count files selected',
                                      style: Theme.of(context).textTheme.bodyLarge,
                                      textAlign: TextAlign.center,
                                    ),
                                    if (count > 1) ...[
                                      const SizedBox(height: 6),
                                      ..._selectedFiles!.take(3).map((f) => Text(
                                        p.basename(f),
                                        style: Theme.of(context).textTheme.bodySmall,
                                        textAlign: TextAlign.center,
                                      )),
                                      if (count > 3) Text('…and ${count - 3} more', style: Theme.of(context).textTheme.bodySmall),
                                    ],
                                    const SizedBox(height: 8),
                                    TextButton(
                                      onPressed: _pick,
                                      child: const Text('Change files'),
                                    ),
                                  ],
                                ),
                              ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              LatchPrimaryButton(
                label: 'Enter passphrase',
                onPressed: count > 0
                    ? () => context.push('/decrypt/passphrase', extra: _selectedFiles)
                    : null,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
