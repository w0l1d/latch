import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/default_output.dart';
import '../../core/saf_bridge.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

class EncryptOptionsScreen extends StatefulWidget {
  final List<String> files;
  final String passphrase;
  final String? keyIdHex;

  const EncryptOptionsScreen({
    super.key,
    required this.files,
    required this.passphrase,
    this.keyIdHex,
  });

  @override
  State<EncryptOptionsScreen> createState() => _EncryptOptionsScreenState();
}

class _EncryptOptionsScreenState extends State<EncryptOptionsScreen> {
  bool _deleteOriginals = false;
  String? _outputDir; // desktop/iOS picked folder; null = beside each original
  String? _defaultDir; // platform default (null on Android = same as original)

  // Android only: a folder grant the user chose for ALL files, and its display
  // path. When set, output goes into this granted folder instead of each
  // original's own folder.
  String? _explicitTreeUri;
  String? _explicitTreeLabel;

  @override
  void initState() {
    super.initState();
    _loadDefaults();
  }

  Future<void> _loadDefaults() async {
    final prefs = await SharedPreferences.getInstance();
    // On Android the default is each original's own folder (resolved and
    // granted at lock time). Off-Android we fall back to the platform default
    // (null on desktop = beside each original; app documents on iOS).
    final def = Platform.isAndroid
        ? null
        : await DefaultOutput.directoryFor(widget.files);
    if (!mounted) return;
    setState(() {
      _deleteOriginals = prefs.getBool('delete_originals') ?? false;
      _defaultDir = def;
      _outputDir ??= def;
    });
  }

  Future<void> _pickFolder() async {
    if (Platform.isAndroid) {
      // Grant a folder the app can create output files in (ACTION_OPEN_-
      // DOCUMENT_TREE). The single-file picker can't grant this.
      String? treeUri;
      try {
        treeUri = await SafBridge.pickTree();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open the folder picker: $e')),
          );
        }
        return;
      }
      if (treeUri == null) return; // cancelled
      final label = await SafBridge.treeUriToPath(treeUri);
      if (!mounted) return;
      setState(() {
        _explicitTreeUri = treeUri;
        _explicitTreeLabel = label;
      });
      return;
    }
    final String? dir;
    try {
      dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Choose where to save locked files',
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open the folder picker: $e')),
        );
      }
      return;
    }
    if (dir != null && mounted) setState(() => _outputDir = dir);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('After locking…'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            children: [
              _OptionCard(
                title: 'Keep the originals',
                subtitle: 'You\'ll have both the file and its locked copy.',
                selected: !_deleteOriginals,
                onTap: () => setState(() => _deleteOriginals = false),
              ),
              const SizedBox(height: 12),
              _OptionCard(
                title: 'Delete originals after',
                subtitle: 'Remove the unlocked copies once locking succeeds.',
                selected: _deleteOriginals,
                onTap: () => setState(() => _deleteOriginals = true),
              ),
              const SizedBox(height: 20),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Where to save',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 8),
              _OutputFolderRow(
                title: _explicitTreeUri != null
                    ? (_explicitTreeLabel == null
                          ? 'Chosen folder'
                          : p.basename(_explicitTreeLabel!))
                    : (_outputDir == null
                          ? 'Same folder as each original'
                          : p.basename(_outputDir!)),
                subtitle: _explicitTreeUri != null
                    ? (_explicitTreeLabel ?? 'A folder you picked')
                    : (_outputDir ?? 'Tap to choose a different folder'),
                isCustom: _explicitTreeUri != null || _outputDir != _defaultDir,
                onChoose: _pickFolder,
                onClear: () => setState(() {
                  _outputDir = _defaultDir;
                  _explicitTreeUri = null;
                  _explicitTreeLabel = null;
                }),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: LatchColors.cautionLight,
                  border: Border.all(color: LatchColors.caution, width: 1.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.info_outline,
                      color: LatchColors.caution,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Deleting is best-effort. What truly protects deleted remnants is your phone\'s built-in device encryption.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF8A5E1E),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Continue',
                onPressed: () => context.push(
                  '/encrypt/review',
                  extra: {
                    'files': widget.files,
                    'passphrase': widget.passphrase,
                    'deleteOriginals': _deleteOriginals,
                    'outputDir': _outputDir,
                    'explicitTreeUri': _explicitTreeUri,
                    'keyIdHex': widget.keyIdHex,
                  },
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

class _OutputFolderRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool isCustom;
  final VoidCallback onChoose;
  final VoidCallback onClear;

  const _OutputFolderRow({
    required this.title,
    required this.subtitle,
    required this.isCustom,
    required this.onChoose,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Choose output folder',
      child: GestureDetector(
        onTap: onChoose,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(color: LatchColors.border, width: 1.5),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(
                isCustom
                    ? Icons.folder_special_outlined
                    : Icons.folder_outlined,
                color: LatchColors.ink,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (isCustom)
                IconButton(
                  icon: const Icon(
                    Icons.close,
                    size: 18,
                    color: LatchColors.muted,
                  ),
                  tooltip: 'Reset to default folder',
                  onPressed: onClear,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _OptionCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: title,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            border: Border.all(
              color: selected ? LatchColors.ink : LatchColors.border,
              width: selected ? 2.5 : 1.5,
            ),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? LatchColors.ink : LatchColors.border,
                    width: 2,
                  ),
                ),
                child: selected
                    ? const Center(
                        child: CircleAvatar(
                          radius: 5,
                          backgroundColor: LatchColors.ink,
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
