import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../../core/saf_bridge.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class EncryptPickScreen extends StatefulWidget {
  const EncryptPickScreen({super.key});

  @override
  State<EncryptPickScreen> createState() => _EncryptPickScreenState();
}

class _EncryptPickScreenState extends State<EncryptPickScreen> {
  final List<String> _files = [];
  bool _picking = false;

  Future<void> _pickFiles() async {
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result != null && mounted) {
        setState(() {
          for (final f in result.files) {
            final path = f.path;
            if (path == null) continue;
            // Keep the real document's content:// URI so "delete originals"
            // can remove the actual file, not just the picker's cache copy.
            SafBridge.rememberUri(path, f.identifier);
            if (!_files.contains(path)) _files.add(path);
          }
        });
      }
    } catch (_) {
      // The raw platform exception is noise to the user — name what failed and
      // the one route into the app that doesn't need the picker.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Couldn\'t open the file picker on this device. '
              'You can share files into Latch from your Files app instead.',
            ),
          ),
        );
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
        title: Text(
          _files.isEmpty
              ? 'Encrypt files'
              : '${_files.length} file${_files.length == 1 ? '' : 's'} selected',
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            children: [
              if (_files.isEmpty)
                Expanded(
                  child: Semantics(
                    button: true,
                    label: 'Choose files to lock',
                    child: GestureDetector(
                      onTap: _picking ? null : _pickFiles,
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: LatchColors.border,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Center(
                          child: _picking
                              ? const CircularProgressIndicator(
                                  color: LatchColors.ink,
                                )
                              : Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Container(
                                      width: 52,
                                      height: 52,
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: LatchColors.border,
                                          width: 2,
                                        ),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Icon(
                                        Icons.add,
                                        color: LatchColors.muted,
                                        size: 28,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    Text(
                                      'Choose files to lock',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineMedium
                                          ?.copyWith(color: LatchColors.muted),
                                    ),
                                    const SizedBox(height: 6),
                                    Text(
                                      'Opens your phone\'s file picker.',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                        ),
                      ),
                    ),
                  ),
                )
              else ...[
                Expanded(
                  child: ListView.separated(
                    itemCount: _files.length,
                    separatorBuilder: (ctx, idx) => const SizedBox(height: 10),
                    itemBuilder: (ctx, i) => _FileRow(
                      name: p.basename(_files[i]),
                      onRemove: () => setState(() => _files.removeAt(i)),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: _picking ? null : _pickFiles,
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      border: Border.all(color: LatchColors.border, width: 1.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Center(
                      child: _picking
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: LatchColors.ink,
                              ),
                            )
                          : Text(
                              '+ Add more',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              if (_files.isEmpty)
                LatchSecondaryButton(
                  label: 'Lock a whole folder',
                  onPressed: () => context.push('/encrypt/folder'),
                ),
              const SizedBox(height: 8),
              LatchPrimaryButton(
                label: 'Set a passphrase',
                onPressed: _files.isEmpty
                    ? null
                    : () => context.push(
                        '/encrypt/passphrase',
                        extra: List<String>.from(_files),
                      ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  final String name;
  final VoidCallback onRemove;

  const _FileRow({required this.name, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: LatchColors.border, width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.insert_drive_file_outlined, color: LatchColors.ink),
          const SizedBox(width: 12),
          Expanded(
            child: Text(name, style: Theme.of(context).textTheme.bodyLarge),
          ),
          IconButton(
            icon: const Icon(Icons.close, color: LatchColors.subtle),
            tooltip: 'Remove file',
            onPressed: onRemove,
          ),
        ],
      ),
    );
  }
}
