import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/app_crypto.dart';
import '../../core/passphrase_policy.dart';
import '../../core/passphrase_storage_service.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

enum _StorageMode { none, appVault, passwordManager }

class PassphraseStorageScreen extends StatefulWidget {
  const PassphraseStorageScreen({super.key});

  @override
  State<PassphraseStorageScreen> createState() =>
      _PassphraseStorageScreenState();
}

class _PassphraseStorageScreenState extends State<PassphraseStorageScreen> {
  _StorageMode _mode = _StorageMode.appVault;
  List<StoredPassphrase> _entries = [];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(PassphrasePolicy.prefKey);
    final svc = AppCrypto.passphraseStorage;
    final entries = svc == null ? <StoredPassphrase>[] : await svc.list();
    if (!mounted) return;
    setState(() {
      // Unset = default behavior, which allows storing (see PassphrasePolicy).
      _mode = _StorageMode.values.firstWhere(
        (m) => m.name == stored,
        orElse: () => _StorageMode.appVault,
      );
      _entries = entries;
    });
  }

  Future<void> _deleteEntry(StoredPassphrase entry) async {
    final svc = AppCrypto.passphraseStorage;
    if (svc == null) return;
    final confirmed = await _confirm(
      'Delete this passphrase?',
      '"${_entryLabel(entry)}" will be removed from this device. Files locked '
          'with it still need the passphrase itself to open.',
    );
    if (confirmed != true) return;
    try {
      await svc.delete(entry.label);
    } catch (e) {
      _showSnack('Could not delete: $e');
      return;
    }
    _load();
  }

  Future<void> _save() async {
    final svc = AppCrypto.passphraseStorage;
    setState(() => _saving = true);
    try {
      // Choosing a non-vault mode with passphrases still stored would be a
      // lie ("Nothing is stored") — purge them, with consent.
      if (_mode != _StorageMode.appVault && _entries.isNotEmpty) {
        final confirmed = await _confirm(
          'Delete ${_entries.length} stored passphrase${_entries.length == 1 ? '' : 's'}?',
          'This choice means the app stores nothing, so the saved '
              'passphrase${_entries.length == 1 ? '' : 's'} will be removed '
              'from this device. Make sure you know them — files can only be '
              'opened with the passphrase they were locked with.',
        );
        if (confirmed != true) return;
        try {
          await svc?.deleteAll();
        } catch (e) {
          _showSnack('Could not delete stored passphrases: $e');
          return;
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(PassphrasePolicy.prefKey, _mode.name);
      if (_mode != _StorageMode.appVault) {
        await prefs.setBool('quick_unlock', false);
      }
      if (mounted) context.pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool?> _confirm(String title, String message) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: LatchColors.danger),
            ),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  /// Entry labels are file paths when saved from a single-file encrypt —
  /// show just the file name.
  static String _entryLabel(StoredPassphrase e) =>
      e.label.contains('/') ? p.basename(e.label) : e.label;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Your passphrase'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: ListView(
            children: [
              _ModeCard(
                title: 'Type it every time',
                subtitle: 'Nothing is stored. Most private.',
                selected: _mode == _StorageMode.none,
                onTap: () => setState(() => _mode = _StorageMode.none),
              ),
              const SizedBox(height: 12),
              _ModeCard(
                title: 'Save in the app',
                subtitle: 'Kept on this device behind your fingerprint or PIN.',
                selected: _mode == _StorageMode.appVault,
                onTap: () => setState(() => _mode = _StorageMode.appVault),
              ),
              const SizedBox(height: 12),
              _ModeCard(
                title: 'Use my password manager',
                subtitle: 'The app stores nothing; your manager holds it.',
                selected: _mode == _StorageMode.passwordManager,
                onTap: () =>
                    setState(() => _mode = _StorageMode.passwordManager),
              ),
              const SizedBox(height: 24),
              Text(
                'STORED ON THIS DEVICE',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              if (_entries.isEmpty)
                Text(
                  'No passphrases are stored.',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                ..._entries.map(
                  (e) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.vpn_key_outlined,
                      color: LatchColors.muted,
                    ),
                    title: Text(
                      _entryLabel(e),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    trailing: IconButton(
                      icon: const Icon(
                        Icons.delete_outline,
                        color: LatchColors.danger,
                      ),
                      tooltip: 'Delete stored passphrase',
                      onPressed: () => _deleteEntry(e),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              LatchPrimaryButton(
                label: 'Save choice',
                onPressed: _saving ? null : _save,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
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
          width: double.infinity,
          padding: const EdgeInsets.all(16),
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
                margin: const EdgeInsets.only(top: 1),
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
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.bodyLarge),
                    const SizedBox(height: 3),
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
