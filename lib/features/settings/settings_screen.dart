import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../shared/theme/app_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _deleteOriginals = false;
  bool _encryptFilename = true;
  bool _quickUnlock = false;
  String _cipher = 'Auto';
  String _kdfCost = 'Auto';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Settings'),
      ),
      body: ListView(
        children: [
          _SectionHeader('Passphrase'),
          _NavTile(
            title: 'Passphrase storage',
            subtitle: 'None — type every time',
            onTap: () => context.push('/settings/passphrase-storage'),
          ),
          _SwitchTile(
            title: 'Quick unlock',
            subtitle: 'Biometric / device PIN gate',
            value: _quickUnlock,
            onChanged: (v) => setState(() => _quickUnlock = v),
          ),
          _SectionHeader('Encryption'),
          _SelectTile(
            title: 'Cipher',
            value: _cipher,
            options: const ['Auto', 'ChaCha20-Poly1305', 'AES-256-GCM'],
            onChanged: (v) => setState(() => _cipher = v),
          ),
          _SelectTile(
            title: 'KDF cost',
            value: _kdfCost,
            options: const ['Auto', 'Low', 'Medium', 'High'],
            onChanged: (v) => setState(() => _kdfCost = v),
          ),
          _SwitchTile(
            title: 'Encrypt filename',
            subtitle: 'Stores real name inside the locked file',
            value: _encryptFilename,
            onChanged: (v) => setState(() => _encryptFilename = v),
          ),
          _SectionHeader('Files'),
          _SwitchTile(
            title: 'Delete originals after encrypt',
            subtitle: 'Off by default — applies globally',
            value: _deleteOriginals,
            onChanged: (v) => setState(() => _deleteOriginals = v),
          ),
          _InfoTile(
            title: 'Output location',
            value: 'Beside each original',
          ),
          _SectionHeader('About'),
          _InfoTile(title: 'Version', value: '1.0.0'),
          _InfoTile(
            title: 'File format',
            value: '.latch (v1)',
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 8),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          letterSpacing: 0.8,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({required this.title, required this.subtitle, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: Text(title, style: Theme.of(context).textTheme.bodyLarge),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      value: value,
      onChanged: onChanged,
      activeThumbColor: LatchColors.ink,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
    );
  }
}

class _NavTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _NavTile({required this.title, required this.subtitle, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: Theme.of(context).textTheme.bodyLarge),
      subtitle: Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
      trailing: const Icon(Icons.chevron_right, color: LatchColors.muted),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
    );
  }
}

class _InfoTile extends StatelessWidget {
  final String title;
  final String value;

  const _InfoTile({required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: Theme.of(context).textTheme.bodyLarge),
      trailing: Text(value, style: Theme.of(context).textTheme.bodyMedium),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
    );
  }
}

class _SelectTile extends StatelessWidget {
  final String title;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;

  const _SelectTile({required this.title, required this.value, required this.options, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(title, style: Theme.of(context).textTheme.bodyLarge),
      trailing: DropdownButton<String>(
        value: value,
        underline: const SizedBox(),
        style: Theme.of(context).textTheme.bodyMedium,
        items: options.map((o) => DropdownMenuItem(value: o, child: Text(o))).toList(),
        onChanged: (v) { if (v != null) onChanged(v); },
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
    );
  }
}
