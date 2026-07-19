import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/app_crypto.dart';
import '../../shared/theme/app_theme.dart';

/// Presets for the KDF cost selector.
/// These map to the opslimit/memlimit values read by AppCrypto._loadKdfParams
/// and applied to every encryption.
class _KdfPreset {
  final String label;
  final int opslimit;
  final int memlimit; // KiB

  const _KdfPreset(this.label, this.opslimit, this.memlimit);

  bool matches(int ops, int mem) => opslimit == ops && memlimit == mem;
}

const _kdfPresets = [
  _KdfPreset('Auto', 3, 65536),
  _KdfPreset('Low', 2, 65536),
  _KdfPreset('Medium', 3, 131072),
  _KdfPreset('High', 4, 262144),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _deleteOriginals = false;
  bool _quickUnlock = false;
  bool _deviceBoundRecovery = false;
  String _kdfCost = 'Auto';
  int _storedCount = 0;
  String _version = '';

  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final ops = prefs.getInt('kdf_opslimit') ?? 3;
    final mem = prefs.getInt('kdf_memlimit') ?? 65536;
    final label = _kdfPresets
        .firstWhere((p) => p.matches(ops, mem), orElse: () => _kdfPresets[0])
        .label;

    // Platform-channel failures must not blank the whole settings screen —
    // fall back to neutral values and render everything else.
    final svc = AppCrypto.passphraseStorage;
    int count = 0;
    if (svc != null) {
      try {
        count = (await svc.list()).length;
      } catch (_) {}
    }

    if (!mounted) return;

    String version = '';
    try {
      final info = await PackageInfo.fromPlatform();
      version = '${info.version}+${info.buildNumber}';
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _deleteOriginals = prefs.getBool('delete_originals') ?? false;
      // Default true — saving a passphrase in the encrypt flow enables quick
      // unlock; this switch is the explicit kill switch.
      _quickUnlock = prefs.getBool('quick_unlock') ?? true;
      _deviceBoundRecovery = prefs.getBool('device_bound_recovery') ?? false;
      _kdfCost = label;
      _storedCount = count;
      _version = version;
      _loaded = true;
    });
  }

  /// Applies a KDF preset. "Auto" restores the values calibrated during
  /// onboarding rather than a fixed pair.
  Future<void> _setKdf(_KdfPreset preset) async {
    final prefs = await SharedPreferences.getInstance();
    var ops = preset.opslimit;
    var mem = preset.memlimit;
    if (preset.label == 'Auto') {
      ops = prefs.getInt('kdf_calibrated_opslimit') ?? ops;
      mem = prefs.getInt('kdf_calibrated_memlimit') ?? mem;
    }
    await prefs.setInt('kdf_opslimit', ops);
    await prefs.setInt('kdf_memlimit', mem);
  }

  Future<void> _set(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is int) {
      await prefs.setInt(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
  }

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
            subtitle: _storedCount == 0
                ? 'None — type every time'
                : '$_storedCount stored',
            onTap: () async {
              await context.push('/settings/passphrase-storage');
              // Refresh the count when returning.
              _load();
            },
          ),
          _NavTile(
            title: 'Change passphrase',
            subtitle: 'Re-lock .latch files under a new passphrase',
            onTap: () => context.push('/settings/change-passphrase'),
          ),
          _NavTile(
            title: 'Secure delete',
            subtitle: 'Crypto-erase .latch file headers — permanent',
            onTap: () => context.push('/settings/secure-delete'),
          ),
          _NavTile(
            title: 'Sharing',
            subtitle: 'Your public key and saved recipients',
            onTap: () => context.push('/settings/sharing-keys'),
          ),
          _NavTile(
            title: 'Share with recipient',
            subtitle: 'Add a recipient lock to .latch files',
            onTap: () => context.push('/settings/add-recipient'),
          ),
          _SwitchTile(
            title: 'Quick unlock',
            subtitle: 'Biometric / device PIN gate',
            value: _quickUnlock,
            onChanged: _loaded
                ? (v) {
                    setState(() => _quickUnlock = v);
                    _set('quick_unlock', v);
                  }
                : null,
          ),
          _SwitchTile(
            title: 'Device-bound recovery',
            subtitle:
                'Add a device-key wrap so files can be opened on this device '
                'even if you forget the passphrase',
            value: _deviceBoundRecovery,
            onChanged: _loaded
                ? (v) {
                    setState(() => _deviceBoundRecovery = v);
                    _set('device_bound_recovery', v);
                  }
                : null,
          ),
          _SectionHeader('Encryption'),
          // The .latch v1 format has exactly one cipher — state it instead of
          // offering a selector that couldn't change anything.
          _InfoTile(
            title: 'Cipher',
            value: 'XChaCha20-Poly1305',
          ),
          _SelectTile(
            title: 'KDF cost',
            value: _kdfCost,
            options: _kdfPresets.map((p) => p.label).toList(),
            onChanged: _loaded
                ? (v) {
                    final preset = _kdfPresets.firstWhere((p) => p.label == v);
                    setState(() => _kdfCost = v);
                    _setKdf(preset);
                  }
                : null,
          ),
          _SectionHeader('Files'),
          _SwitchTile(
            title: 'Delete originals after encrypt',
            subtitle: 'Off by default — applies globally',
            value: _deleteOriginals,
            onChanged: _loaded
                ? (v) {
                    setState(() => _deleteOriginals = v);
                    _set('delete_originals', v);
                  }
                : null,
          ),
          _InfoTile(
            title: 'Output location',
            value: Platform.isAndroid
                ? 'Downloads folder — changeable per encrypt'
                : Platform.isIOS
                    ? 'Latch folder in Files — changeable per encrypt'
                    : 'Next to each original — changeable per encrypt',
          ),
          _SectionHeader('About'),
          _InfoTile(title: 'Version', value: _version),
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
  final ValueChanged<bool>? onChanged;

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
  final ValueChanged<String>? onChanged;

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
        onChanged: onChanged != null ? (v) { if (v != null) onChanged!(v); } : null,
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
    );
  }
}
