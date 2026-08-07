import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';
import '../../core/app_crypto.dart';
import '../../core/crypto_stub.dart';
import '../../core/passphrase_policy.dart';
import '../../core/passphrase_storage_service.dart';

class EncryptPassphraseScreen extends StatefulWidget {
  final List<String> files;
  const EncryptPassphraseScreen({super.key, required this.files});

  @override
  State<EncryptPassphraseScreen> createState() =>
      _EncryptPassphraseScreenState();
}

class _EncryptPassphraseScreenState extends State<EncryptPassphraseScreen> {
  final _controller = TextEditingController();
  final _nameController = TextEditingController();
  bool _obscure = true;
  bool _saveForQuickUnlock = false;
  bool _canSave = false;

  /// Whether the vault holds anything to offer. Gates the "Use a saved
  /// passphrase" action so it is never a control that does nothing.
  bool _hasSaved = false;
  PassphraseResult? _strength;

  /// Label of the vault entry the passphrase was loaded from, or null when the
  /// user typed it. Non-null means the secret is *already stored*, so it must
  /// not be saved a second time under a different label.
  String? _pickedLabel;

  /// The picked entry's existing key-id — reused verbatim so the header still
  /// points at that vault entry without re-storing the secret.
  String? _pickedKeyIdHex;

  /// Set only while [_pickFromApp] writes into the controller, so the listener
  /// can tell a programmatic fill from the user editing the field by hand.
  bool _fillingFromVault = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      setState(() {
        _strength = _controller.text.isEmpty
            ? null
            : CryptoStub.evaluate(_controller.text);
        // Hand-editing a vault-loaded passphrase makes it a different secret,
        // so it goes back to normal save/overwrite behavior.
        if (!_fillingFromVault && _pickedLabel != null) {
          _pickedLabel = null;
          _pickedKeyIdHex = null;
        }
      });
    });
    _checkAuth();
  }

  Future<void> _checkAuth() async {
    final svc = AppCrypto.passphraseStorage;
    if (svc == null) return;
    // Respect an explicit "the app stores nothing" choice from Settings —
    // it disables both storing new passphrases and offering stored ones.
    if (!await PassphrasePolicy.storageAllowed()) return;
    final ok = await svc.canAuthenticate;
    final hasStored = await svc.hasStored();
    if (mounted) {
      setState(() {
        _canSave = ok;
        _hasSaved = hasStored;
      });
    }
  }

  Future<void> _pickFromApp() async {
    final svc = AppCrypto.passphraseStorage;
    if (svc == null || !mounted) return;
    final entries = await svc.list();
    if (entries.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'No saved passphrases yet. Save one on this screen first.',
            ),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    final label = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Pick a saved passphrase',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
              ),
            ),
            // Flexible + ListView: a long vault list scrolls inside the
            // sheet instead of overflowing it.
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: entries
                    .map(
                      (e) => ListTile(
                        leading: const Icon(Icons.vpn_key_outlined),
                        title: Text(
                          _displayLabel(e.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text('Saved ${_friendlyDate(e.createdAt)}'),
                        onTap: () => Navigator.pop(ctx, e.label),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
    if (label == null || !mounted) return;
    String? passphrase;
    try {
      passphrase = await svc.loadWithAuth(label);
    } catch (_) {
      // A platform-level auth failure must be visible, not a silent no-op —
      // but the raw platform exception is not something to show a user.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not show the unlock prompt on this device.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    if (passphrase != null) {
      // This secret is already in the vault. Remember which entry it came
      // from so it is never stored a second time under a different label,
      // and reuse that entry's key-id so the header still points at it.
      final picked = entries.firstWhere(
        (e) => e.label == label,
        orElse: () => StoredPassphrase(
          label: label,
          passphrase: '',
          createdAt: DateTime.now(),
          keyIdHex: '',
        ),
      );
      _fillingFromVault = true;
      _controller.text = passphrase;
      _fillingFromVault = false;
      setState(() {
        _pickedLabel = label;
        _pickedKeyIdHex = picked.keyIdHex.isEmpty ? null : picked.keyIdHex;
        // The save block is replaced by an "already saved" row, so a stale
        // toggle can't imply a second copy is about to be written.
        _saveForQuickUnlock = false;
        _nameController.clear();
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not unlock the saved passphrase — authentication was cancelled or failed.',
          ),
        ),
      );
    }
  }

  /// Entries saved by older builds used the file path as the label — show
  /// just the basename for those.
  static String _displayLabel(String label) =>
      label.contains('/') ? p.basename(label) : label;

  static String _friendlyDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) return 'today';
    if (diff.inDays == 1) return 'yesterday';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  /// Neutral autogenerated vault name. Deliberately unrelated to the files
  /// being encrypted — a label like "taxes-2026.pdf" in the vault list would
  /// leak what the user encrypts.
  static String _autoName() {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return 'Passphrase · ${now.day} ${months[now.month - 1]} $hh:$mm';
  }

  void _toggleSave() {
    setState(() {
      _saveForQuickUnlock = !_saveForQuickUnlock;
      if (_saveForQuickUnlock && _nameController.text.isEmpty) {
        _nameController.text = _autoName();
      }
    });
  }

  Future<void> _storeAndContinue() async {
    if (_busy) return; // a second tap must not push /encrypt/options twice
    setState(() => _busy = true);
    final svc = AppCrypto.passphraseStorage;
    String? keyIdHex;
    // Loaded from the vault: reuse that entry's key-id and store nothing —
    // re-storing would duplicate the secret under a second label.
    if (_pickedLabel != null) {
      keyIdHex = _pickedKeyIdHex;
    } else if (_saveForQuickUnlock && svc != null && _canSave) {
      final name = _nameController.text.trim();
      final label = name.isEmpty ? _autoName() : name;
      try {
        keyIdHex = await svc.store(label, _controller.text);
        // Saving implies the user wants quick unlock — turn it on so the
        // saved passphrase is actually offered at decrypt time.
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('quick_unlock', true);
      } catch (e) {
        // Continue without quick unlock rather than silently doing nothing —
        // encryption itself must not be blocked by a vault failure.
        keyIdHex = null;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not save the passphrase — continuing without quick unlock.',
              ),
            ),
          );
        }
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    context.push(
      '/encrypt/options',
      extra: {
        'files': widget.files,
        'passphrase': _controller.text,
        'keyIdHex': keyIdHex,
      },
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _nameController.dispose();
    super.dispose();
  }

  Color get _strengthColor {
    switch (_strength?.strength) {
      case PassphraseStrength.weak:
        return LatchColors.danger;
      case PassphraseStrength.fair:
        return LatchColors.caution;
      case PassphraseStrength.strong:
        return LatchColors.safe;
      case PassphraseStrength.veryStrong:
        return LatchColors.safe;
      default:
        return LatchColors.border;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Create a passphrase'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _controller,
                obscureText: _obscure,
                autofocus: true,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (_controller.text.isNotEmpty) _storeAndContinue();
                },
                decoration: InputDecoration(
                  hintText: 'Enter passphrase',
                  suffixIcon: TextButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    child: Text(
                      _obscure ? 'show' : 'hide',
                      style: const TextStyle(color: LatchColors.subtle),
                    ),
                  ),
                ),
                // Theme-derived so the system text-scaling setting applies.
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(letterSpacing: 1.5),
              ),
              // A saved passphrase is a one-shot action, not a persistent
              // mode — and it is only offered when the vault has something
              // to offer, so it is never a control that does nothing.
              if (_hasSaved) ...[
                const SizedBox(height: 4),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _pickFromApp,
                    icon: const Icon(Icons.vpn_key_outlined, size: 18),
                    label: const Text('Use a saved passphrase'),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              if (_strength != null) ...[
                _StrengthBar(score: _strength!.score, color: _strengthColor),
                const SizedBox(height: 8),
                Text(
                  _strength!.label,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: _strengthColor),
                ),
              ],
              const SizedBox(height: 10),
              // Already in the vault — a static statement, not a save control,
              // so nothing implies a second copy is about to be written.
              if (_pickedLabel != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: LatchColors.safeLight,
                    border: Border.all(color: LatchColors.safeBorder),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle_outline,
                        color: LatchColors.safe,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Already saved as "${_displayLabel(_pickedLabel!)}"',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: LatchColors.safe),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_canSave && _pickedLabel == null)
                Semantics(
                  button: true,
                  label: 'Save for quick unlock',
                  child: GestureDetector(
                    onTap: _toggleSave,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: _saveForQuickUnlock
                              ? LatchColors.ink
                              : LatchColors.border,
                          width: _saveForQuickUnlock ? 2.5 : 1.5,
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _saveForQuickUnlock
                                ? Icons.fingerprint
                                : Icons.fingerprint_outlined,
                            color: _saveForQuickUnlock
                                ? LatchColors.ink
                                : LatchColors.muted,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Save for quick unlock',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: _saveForQuickUnlock
                                        ? LatchColors.ink
                                        : LatchColors.muted,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_canSave && _saveForQuickUnlock && _pickedLabel == null) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: _nameController,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'Name for this passphrase',
                    helperText: 'Just a label for your vault — pick anything.',
                  ),
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ],
              if (_canSave) const SizedBox(height: 10),
              Text(
                'A few random words beats hard-to-type symbols. Longer is stronger.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Continue',
                onPressed: _controller.text.isNotEmpty && !_busy
                    ? _storeAndContinue
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

class _StrengthBar extends StatelessWidget {
  final double score;
  final Color color;

  const _StrengthBar({required this.score, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: List.generate(4, (i) {
        final filled = score > i * 0.25;
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(right: i < 3 ? 4 : 0),
            height: 7,
            decoration: BoxDecoration(
              color: filled ? color : LatchColors.border,
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        );
      }),
    );
  }
}
