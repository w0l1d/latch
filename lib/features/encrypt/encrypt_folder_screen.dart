import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import '../../core/bulk_plan.dart';
import '../../core/bulk_settings.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/bulk_destination_section.dart';
import '../../shared/widgets/latch_button.dart';

/// Above this many files the user must deliberately confirm (FR-026h).
const int bulkConfirmThreshold = 10000;

/// Shown on every bulk summary (FR-044/045). Plain statement of what a folder
/// of containers reveals that a single archive would not.
const String bulkPrivacyDisclosure =
    'Each file is locked on its own, so anyone who can see the folder can still '
    'see how many files there are, their approximate sizes, and the folder '
    'structure. File names are hidden only if you choose that. This is not '
    'the same protection as locking the whole folder into a single file.';

typedef FolderPicker = Future<String?> Function();
typedef FolderEnumerator =
    Future<BulkInventory> Function(String root, bool recursive);

String describeDuration(Duration d) {
  if (d.inSeconds < 60) return 'under a minute';
  final m = d.inMinutes;
  if (m < 60) return 'about $m minute${m == 1 ? '' : 's'}';
  final h = (d.inMinutes / 60).toStringAsFixed(1);
  return 'about $h hours';
}

String describeBytes(int b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return '${i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1)} ${u[i]}';
}

class EncryptFolderScreen extends StatefulWidget {
  final FolderPicker? pickFolder;
  final FolderEnumerator? enumerate;
  final BulkFolderPicker? pickDestination;

  const EncryptFolderScreen({
    super.key,
    this.pickFolder,
    this.enumerate,
    this.pickDestination,
  });

  @override
  State<EncryptFolderScreen> createState() => _EncryptFolderScreenState();
}

class _EncryptFolderScreenState extends State<EncryptFolderScreen> {
  BulkInventory? _inv;
  bool _recursive = false;
  bool _deleteSources = false;
  bool _confirmedLarge = false;
  BulkKeyMode _keyMode = BulkKeyMode.perFile;
  BulkDestination? _dest;
  bool _busy = false;
  String? _error;

  Future<void> _choose() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final root = await (widget.pickFolder ?? _defaultPick)();
      if (root == null) return;
      await _scan(root, _recursive);
    } catch (_) {
      _error = 'Couldn\'t read that folder. Pick another one.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _defaultPick() => FilePicker.platform.getDirectoryPath();

  Future<void> _scan(String root, bool recursive) async {
    final enumerate =
        widget.enumerate ??
        (r, rec) => BulkPlan.enumerate(r, BulkMode.encrypt, recursive: rec);
    final inv = await enumerate(root, recursive);
    final keyMode = await BulkSettings.keyMode();
    final placement = _dest == null
        ? await BulkSettings.outputPlacement()
        : null;
    if (!mounted) return;
    setState(() {
      _keyMode = keyMode;
      if (placement != null) _dest = BulkDestination(placement: placement);
      _inv = inv;
      _recursive = recursive;
      _confirmedLarge = false;
    });
  }

  Future<void> _toggleRecursive(bool v) async {
    final inv = _inv;
    if (inv == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _scan(inv.root, v);
    } catch (_) {
      _error = 'Couldn\'t read that folder.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _needsConfirm => (_inv?.items.length ?? 0) > bulkConfirmThreshold;

  bool get _canContinue =>
      !_busy &&
      _inv != null &&
      (_dest?.isReady ?? false) &&
      _inv!.items.isNotEmpty &&
      (!_needsConfirm || _confirmedLarge);

  void _continue() {
    final inv = _inv!;
    context.push(
      '/encrypt/passphrase',
      extra: {
        'files': [for (final i in inv.items) i.sourcePath],
        'bulk': {
          'inventory': inv,
          'deleteSources': _deleteSources,
          'keyMode': _keyMode,
          'destination': _dest,
        },
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final inv = _inv;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Lock a folder'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: inv == null
                    ? Center(
                        child: _busy
                            ? const CircularProgressIndicator(
                                semanticsLabel: 'Reading the folder',
                                color: LatchColors.ink,
                              )
                            : Text(
                                _error ??
                                    'Choose a folder. Every file in it is '
                                        'locked into its own .latch file.',
                                style: t.bodyMedium,
                                textAlign: TextAlign.center,
                              ),
                      )
                    : _Summary(
                        inv: inv,
                        recursive: _recursive,
                        deleteSources: _deleteSources,
                        keyMode: _keyMode,
                        destination: _dest!,
                        pickDestination: widget.pickDestination,
                        onDestination: (d) => setState(() => _dest = d),
                        confirmedLarge: _confirmedLarge,
                        needsConfirm: _needsConfirm,
                        busy: _busy,
                        error: _error,
                        onRecursive: _toggleRecursive,
                        onDelete: (v) => setState(() => _deleteSources = v),
                        onConfirm: (v) => setState(() => _confirmedLarge = v),
                      ),
              ),
              const SizedBox(height: 12),
              if (inv == null)
                LatchPrimaryButton(
                  label: 'Choose a folder',
                  onPressed: _busy ? null : _choose,
                )
              else ...[
                LatchSecondaryButton(
                  label: 'Choose a different folder',
                  onPressed: _busy ? null : _choose,
                ),
                const SizedBox(height: 8),
                LatchPrimaryButton(
                  label: 'Set a passphrase',
                  onPressed: _canContinue ? _continue : null,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  final BulkInventory inv;
  final bool recursive;
  final bool deleteSources;
  final BulkKeyMode keyMode;
  final BulkDestination destination;
  final BulkFolderPicker? pickDestination;
  final ValueChanged<BulkDestination> onDestination;
  final bool confirmedLarge;
  final bool needsConfirm;
  final bool busy;
  final String? error;
  final ValueChanged<bool> onRecursive;
  final ValueChanged<bool> onDelete;
  final ValueChanged<bool> onConfirm;

  const _Summary({
    required this.inv,
    required this.recursive,
    required this.deleteSources,
    required this.keyMode,
    required this.destination,
    required this.pickDestination,
    required this.onDestination,
    required this.confirmedLarge,
    required this.needsConfirm,
    required this.busy,
    required this.error,
    required this.onRecursive,
    required this.onDelete,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final n = inv.items.length;
    final est = BulkPlan.estimateDuration(
      fileCount: n,
      totalBytes: inv.totalBytes,
      keyMode: keyMode,
      verified: deleteSources,
    );
    return ListView(
      children: [
        Text(p.basename(inv.root), style: t.headlineMedium),
        const SizedBox(height: 4),
        Text(
          '$n file${n == 1 ? '' : 's'} · ${describeBytes(inv.totalBytes)} · '
          '${describeDuration(est)}',
          style: t.bodyMedium,
        ),
        if (error != null) ...[
          const SizedBox(height: 8),
          Text(error!, style: t.bodySmall?.copyWith(color: LatchColors.danger)),
        ],
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include subfolders'),
          subtitle: Text(
            recursive
                ? '${inv.subfolders} subfolder${inv.subfolders == 1 ? '' : 's'} included.'
                : inv.excludedInSubfolders > 0
                ? '${inv.excludedInSubfolders} file${inv.excludedInSubfolders == 1 ? '' : 's'} '
                      'in subfolders will be left out.'
                : 'Only files directly in this folder.',
          ),
          value: recursive,
          onChanged: busy ? null : onRecursive,
        ),
        Text(
          keyMode == BulkKeyMode.sharedPerBatch
              ? 'One key is made for this whole run, so it finishes sooner. '
                    'Each file still has its own encryption. You can change '
                    'this in Settings.'
              : 'Each file gets its own key.',
        ),
        const SizedBox(height: 12),
        BulkDestinationSection(
          value: destination,
          sourceRoot: inv.root,
          decrypt: false,
          enabled: !busy,
          pickFolder: pickDestination,
          onChanged: onDestination,
        ),
        if (inv.alreadyContainers > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${inv.alreadyContainers} already look like Latch containers and '
            'will be locked again.',
            style: t.bodySmall,
          ),
        ],
        if (inv.skipped.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text('${inv.skipped.length} skipped', style: t.titleSmall),
          for (final s in inv.skipped.take(20))
            Text('${s.relativePath} — ${s.reason}', style: t.bodySmall),
          if (inv.skipped.length > 20)
            Text('… and ${inv.skipped.length - 20} more', style: t.bodySmall),
        ],
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Delete originals afterwards'),
          subtitle: const Text(
            'Each original is removed only after its locked copy has been '
            'unlocked again and matched byte for byte. This reads every file '
            'twice, so it takes longer. Empty folders are left in place.',
          ),
          value: deleteSources,
          onChanged: onDelete,
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            border: Border.all(color: LatchColors.border, width: 1.5),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(bulkPrivacyDisclosure, style: t.bodySmall),
        ),
        if (needsConfirm)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: confirmedLarge,
            onChanged: (v) => onConfirm(v ?? false),
            title: Text('I understand this will lock $n files.'),
          ),
        if (n == 0)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('There is nothing to lock here.', style: t.bodyMedium),
          ),
      ],
    );
  }
}
