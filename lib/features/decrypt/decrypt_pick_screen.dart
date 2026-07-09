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
  String? _selectedFile;
  bool _picking = false;

  Future<void> _pick() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: false);
      if (result != null && result.files.isNotEmpty && mounted) {
        final path = result.files.first.path;
        if (path != null) setState(() => _selectedFile = path);
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Decrypt a file'),
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
                        : _selectedFile == null
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.lock_open_outlined, size: 44, color: LatchColors.muted),
                                    const SizedBox(height: 14),
                                    Text(
                                      'Choose a locked file',
                                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                                        color: LatchColors.muted,
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Look for files ending in .enc',
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
                                      p.basename(_selectedFile!),
                                      style: Theme.of(context).textTheme.bodyLarge,
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 8),
                                    TextButton(
                                      onPressed: _pick,
                                      child: const Text('Change file'),
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
                onPressed: _selectedFile != null
                    ? () => context.push('/decrypt/passphrase', extra: _selectedFile)
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
