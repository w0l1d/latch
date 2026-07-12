import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/widgets/latch_button.dart';

enum _StorageMode { none, appVault, passwordManager }

class PassphraseStorageScreen extends StatefulWidget {
  const PassphraseStorageScreen({super.key});

  @override
  State<PassphraseStorageScreen> createState() => _PassphraseStorageScreenState();
}

class _PassphraseStorageScreenState extends State<PassphraseStorageScreen> {
  _StorageMode _mode = _StorageMode.none;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('passphrase_storage_mode');
    if (!mounted) return;
    setState(() {
      _mode = _StorageMode.values.firstWhere(
        (m) => m.name == stored,
        orElse: () => _StorageMode.none,
      );
    });
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('passphrase_storage_mode', _mode.name);
    if (!mounted) return;
    context.pop();
  }

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
          child: Column(
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
                onTap: () => setState(() => _mode = _StorageMode.passwordManager),
              ),
              const Spacer(),
              LatchPrimaryButton(
                label: 'Save choice',
                onPressed: _save,
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

  const _ModeCard({required this.title, required this.subtitle, required this.selected, required this.onTap});

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
                  ? const Center(child: CircleAvatar(radius: 5, backgroundColor: LatchColors.ink))
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyLarge),
                  const SizedBox(height: 3),
                  Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
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
