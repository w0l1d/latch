import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../../core/app_crypto.dart';
import '../../core/recipient_key_service.dart';
import '../../shared/theme/app_theme.dart';

/// Sharing keys (spec UC-6): shows this install's X25519 public key so it
/// can be given to others, and manages the address book of recipients this
/// install can share files with.
class SharingKeysScreen extends StatefulWidget {
  const SharingKeysScreen({super.key});

  @override
  State<SharingKeysScreen> createState() => _SharingKeysScreenState();
}

class _SharingKeysScreenState extends State<SharingKeysScreen> {
  String? _myPublicKeyHex;
  String? _keyError;
  List<RecipientEntry> _recipients = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final svc = AppCrypto.recipientKeys;
    if (svc == null) {
      setState(() => _keyError = 'Sharing keys are not available.');
      return;
    }
    try {
      final kp = await svc.getOrCreateKeyPair();
      kp.secretKey.fillRange(0, kp.secretKey.length, 0);
      final pkHex = await svc.publicKeyHex();
      final recipients = await svc.listRecipients();
      if (!mounted) return;
      setState(() {
        _myPublicKeyHex = pkHex;
        _recipients = recipients;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _keyError = 'Could not create a sharing key: $e');
    }
  }

  Future<void> _copyKey() async {
    final hex = _myPublicKeyHex;
    if (hex == null) return;
    await Clipboard.setData(ClipboardData(text: hex));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Public key copied')));
  }

  Future<void> _addRecipient() async {
    final labelController = TextEditingController();
    final keyController = TextEditingController();
    String? validationError;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add recipient'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: labelController,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: keyController,
                decoration: InputDecoration(
                  hintText: 'Their public key (64 hex characters)',
                  errorText: validationError,
                ),
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final label = labelController.text.trim();
                final hex = keyController.text.trim().toLowerCase();
                if (label.isEmpty) {
                  setDialogState(() => validationError = 'Enter a name first');
                  return;
                }
                if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
                  setDialogState(
                    () => validationError = 'A public key is 64 hex characters',
                  );
                  return;
                }
                await AppCrypto.recipientKeys?.storeRecipient(label, hex);
                if (ctx.mounted) Navigator.pop(ctx, true);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    labelController.dispose();
    keyController.dispose();
    if (saved == true) _load();
  }

  Future<void> _deleteRecipient(RecipientEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove recipient?'),
        content: Text(
          '"${entry.label}" will be removed from your list. Files already '
          'shared with them stay readable by them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: LatchColors.danger),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppCrypto.recipientKeys?.deleteRecipient(entry.label);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Sharing'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            Text(
              'YOUR PUBLIC KEY',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: LatchColors.border, width: 1.5),
                borderRadius: BorderRadius.circular(12),
                color: LatchColors.cardSurface,
              ),
              child: _keyError != null
                  ? Text(
                      _keyError!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: LatchColors.danger,
                      ),
                    )
                  : _myPublicKeyHex == null
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          color: LatchColors.ink,
                        ),
                      ),
                    )
                  : Row(
                      children: [
                        Expanded(
                          child: SelectableText(
                            _myPublicKeyHex!,
                            style: const TextStyle(
                              fontSize: 13,
                              fontFamily: 'monospace',
                              color: LatchColors.ink,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: _copyKey,
                          tooltip: 'Copy public key',
                          icon: const Icon(
                            Icons.copy_outlined,
                            color: LatchColors.ink,
                          ),
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              'Give this key to anyone who wants to share encrypted files '
              'with you. It is safe to send in the open — it cannot unlock '
              'anything by itself.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 28),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'RECIPIENTS',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      letterSpacing: 0.8,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _addRecipient,
                  icon: const Icon(Icons.add, size: 18, color: LatchColors.ink),
                  label: const Text(
                    'Add',
                    style: TextStyle(color: LatchColors.ink),
                  ),
                ),
              ],
            ),
            if (_recipients.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  'No recipients yet. Add someone’s public key to share '
                  'files with them.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              ..._recipients.map(
                (r) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    r.label,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  subtitle: Text(
                    '${r.publicKeyHex.substring(0, 16)}…',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                  trailing: IconButton(
                    onPressed: () => _deleteRecipient(r),
                    tooltip: 'Remove ${r.label}',
                    icon: const Icon(
                      Icons.delete_outline,
                      color: LatchColors.muted,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
