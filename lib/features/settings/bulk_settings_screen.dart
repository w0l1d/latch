import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/bulk_plan.dart';
import '../../core/bulk_settings.dart';
import '../../shared/theme/app_theme.dart';

/// Advanced choices for locking a whole folder. The key mode is decided here,
/// ahead of time, and is only ever stated (never asked) once a run starts.
class BulkSettingsScreen extends StatefulWidget {
  const BulkSettingsScreen({super.key});

  @override
  State<BulkSettingsScreen> createState() => _BulkSettingsScreenState();
}

class _BulkSettingsScreenState extends State<BulkSettingsScreen> {
  BulkKeyMode _keyMode = BulkKeyMode.perFile;
  BulkPlacement _placement = BulkPlacement.mirroredFolder;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    Future.wait([BulkSettings.keyMode(), BulkSettings.outputPlacement()]).then((
      v,
    ) {
      if (!mounted) return;
      setState(() {
        _keyMode = v[0] as BulkKeyMode;
        _placement = v[1] as BulkPlacement;
        _loaded = true;
      });
    });
  }

  Future<void> _select(BulkKeyMode mode) async {
    if (mode == _keyMode) return;
    if (mode == BulkKeyMode.sharedPerBatch) {
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Use one key for the whole run?'),
          content: const Text(
            'Faster for big folders, but a guess at your passphrase is '
            'checked against every file locked in that run at once, instead '
            'of one file at a time. A strong passphrase matters more here.\n\n'
            'Files locked this way open normally everywhere, and the choice '
            'is not recorded in them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep separate keys'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Use one key'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _keyMode = mode);
    await BulkSettings.setKeyMode(mode);
  }

  Future<void> _selectPlacement(BulkPlacement placement) async {
    if (placement == _placement) return;
    setState(() => _placement = placement);
    await BulkSettings.setOutputPlacement(placement);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        leading: BackButton(onPressed: () => context.pop()),
        title: const Text('Bulk encryption'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            Text(
              'How keys are made when you lock a folder',
              style: t.titleSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Every file always gets its own encryption. This only decides '
              'how often your passphrase is stretched into a key, which is '
              'the slow part.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: 12),
            RadioGroup<BulkKeyMode>(
              groupValue: _keyMode,
              onChanged: (m) {
                if (_loaded && m != null) _select(m);
              },
              child: Column(
                children: [
                  RadioListTile<BulkKeyMode>(
                    contentPadding: EdgeInsets.zero,
                    value: BulkKeyMode.perFile,
                    title: const Text('A separate key for each file'),
                    subtitle: const Text(
                      'Slower on big folders. Each file stands alone: working '
                      'out your passphrase from one file gains nothing on the '
                      'others. Recommended.',
                    ),
                  ),
                  RadioListTile<BulkKeyMode>(
                    contentPadding: EdgeInsets.zero,
                    value: BulkKeyMode.sharedPerBatch,
                    title: const Text('One key for each run'),
                    subtitle: const Text(
                      'Much faster on thousands of files. Every file from the '
                      'same run shares the work of a passphrase guess, so a '
                      'weak passphrase falls to all of them together. Never '
                      'shared between runs.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text('Where the output goes', style: t.titleSmall),
            const SizedBox(height: 8),
            Text(
              'This is the starting choice each time you lock or unlock a '
              'folder. You can change it for a single run without changing '
              'it here.',
              style: t.bodyMedium,
            ),
            const SizedBox(height: 12),
            RadioGroup<BulkPlacement>(
              groupValue: _placement,
              onChanged: (m) {
                if (_loaded && m != null) _selectPlacement(m);
              },
              child: Column(
                children: [
                  RadioListTile<BulkPlacement>(
                    contentPadding: EdgeInsets.zero,
                    value: BulkPlacement.mirroredFolder,
                    title: const Text('One folder, same layout'),
                    subtitle: const Text(
                      'You pick a folder each time; subfolders are recreated '
                      'inside it. Recommended.',
                    ),
                  ),
                  RadioListTile<BulkPlacement>(
                    contentPadding: EdgeInsets.zero,
                    value: BulkPlacement.besideOriginals,
                    title: const Text('Next to each original'),
                    subtitle: const Text(
                      'Every output is saved in the folder its source came '
                      'from. Nothing to pick.',
                    ),
                  ),
                  RadioListTile<BulkPlacement>(
                    contentPadding: EdgeInsets.zero,
                    value: BulkPlacement.flatFolder,
                    title: const Text('One folder, all together'),
                    subtitle: const Text(
                      'You pick a folder each time; everything goes straight '
                      'into it. Files that share a name are numbered, never '
                      'replaced.',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'The folder review states which one applies before anything '
              'is locked. If you delete originals afterwards, checking each '
              'new file still pays the slow step once per file.',
              style: t.bodySmall?.copyWith(color: LatchColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}
