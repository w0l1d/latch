import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';
import '../../core/app_crypto.dart';
import '../../core/key_id_resolver.dart';

class DecryptPassphraseScreen extends StatefulWidget {
  final List<String> files;
  const DecryptPassphraseScreen({super.key, required this.files});

  @override
  State<DecryptPassphraseScreen> createState() => _DecryptPassphraseScreenState();
}

class _DecryptPassphraseScreenState extends State<DecryptPassphraseScreen> {
  final _controller = TextEditingController();
  bool _obscure = true;
  bool _hasStored = false;
  bool _quickUnlocking = false;

  @override
  void initState() {
    super.initState();
    _checkStored();
  }

  Future<void> _checkStored() async {
    final prefs = await SharedPreferences.getInstance();
    final quickUnlockOn = prefs.getBool('quick_unlock') ?? false;
    if (!quickUnlockOn) return;
    final svc = AppCrypto.passphraseStorage;
    if (svc == null) return;
    final has = await svc.hasStored();
    if (mounted) setState(() => _hasStored = has);
  }

  Future<void> _quickUnlock() async {
    final svc = AppCrypto.passphraseStorage;
    if (svc == null || !_hasStored) return;
    setState(() => _quickUnlocking = true);
    try {
      final stored = await svc.list();
      if (stored.isEmpty) return;

      // Resolve which stored passphrase this file points at via the opaque
      // key-id hint in its header (spec UC-9) — no Argon2 trial needed.
      // Falls back to the first entry for files without a matching id.
      String label = stored.first.label;
      final keyIdHex = await KeyIdResolver.keyIdHexFromFile(widget.files.first);
      if (keyIdHex != null) {
        final match = await svc.findLabelByKeyId(keyIdHex);
        if (match != null) label = match;
      }

      final passphrase = await svc.loadWithAuth(label);
      if (passphrase != null && mounted) {
        _controller.text = passphrase;
        _submit();
      }
    } finally {
      if (mounted) setState(() => _quickUnlocking = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    context.push(
      '/decrypt/progress',
      extra: {
        'files': widget.files,
        'passphrase': _controller.text,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: Text(widget.files.length > 1 ? 'Open ${widget.files.length} files' : 'Open this file'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: LatchColors.border, width: 1.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.insert_drive_file_outlined, color: LatchColors.ink),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.files.length == 1
                            ? widget.files.first
                            : '${widget.files.length} files selected',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: LatchColors.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Enter the passphrase used to lock it.',
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _controller,
                obscureText: _obscure,
                autofocus: !_hasStored,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Passphrase',
                  suffixIcon: TextButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    child: Text(_obscure ? 'show' : 'hide',
                        style: const TextStyle(color: LatchColors.subtle)),
                  ),
                ),
                style: const TextStyle(fontSize: 17, letterSpacing: 1.5),
              ),
              const SizedBox(height: 14),
              if (_hasStored)
                GestureDetector(
                  onTap: _quickUnlocking ? null : _quickUnlock,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      border: Border.all(color: LatchColors.border, width: 1.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            border: Border.all(color: LatchColors.muted, width: 1.5),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            _quickUnlocking ? Icons.lock_outline : Icons.fingerprint,
                            size: 14,
                            color: LatchColors.muted,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _quickUnlocking ? 'Unlocking…' : 'Use quick unlock instead',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Unlock',
                onPressed: _controller.text.isNotEmpty ? _submit : null,
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}
