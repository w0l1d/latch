import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../../core/bulk_plan.dart';
import '../../core/saf_bridge.dart';
import '../theme/app_theme.dart';

typedef BulkFolderPick = ({String? dir, String? treeUri, String? label});
typedef BulkFolderPicker = Future<BulkFolderPick?> Function(String sourceRoot);

/// Android hands out a folder grant (the output is written into it afterwards);
/// desktop just gets a path. Null means the user backed out.
Future<BulkFolderPick?> defaultBulkFolderPicker(String sourceRoot) async {
  if (Platform.isAndroid) {
    final treeUri = await SafBridge.pickTree(initialPath: sourceRoot);
    if (treeUri == null) return null;
    final label = await SafBridge.treeUriToPath(treeUri);
    return (dir: null, treeUri: treeUri, label: label);
  }
  final dir = await FilePicker.platform.getDirectoryPath(
    dialogTitle: 'Choose where to save',
  );
  return dir == null ? null : (dir: dir, treeUri: null, label: dir);
}

/// Name of the picked folder, shortened for a list row.
String bulkFolderName(BulkDestination d) {
  final label = d.label;
  if (label == null || label.isEmpty) return 'A folder you picked';
  return p.basename(label).isEmpty ? label : p.basename(label);
}

/// Where this operation's output goes. Changing it here only affects the
/// operation in hand; the saved default lives in Settings (FR-029).
class BulkDestinationSection extends StatelessWidget {
  final BulkDestination value;
  final String sourceRoot;
  final bool decrypt;
  final bool enabled;
  final ValueChanged<BulkDestination> onChanged;
  final BulkFolderPicker? pickFolder;

  const BulkDestinationSection({
    super.key,
    required this.value,
    required this.sourceRoot,
    required this.decrypt,
    required this.onChanged,
    this.enabled = true,
    this.pickFolder,
  });

  Future<void> _pick(BuildContext context) async {
    final BulkFolderPick? pick;
    try {
      pick = await (pickFolder ?? defaultBulkFolderPicker)(sourceRoot);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the folder picker.')),
        );
      }
      return;
    }
    if (pick == null) return;
    onChanged(
      value.withFolder(dir: pick.dir, treeUri: pick.treeUri, label: pick.label),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final what = decrypt ? 'unlocked' : 'locked';
    final source = decrypt ? 'locked file' : 'original';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Where the $what files go', style: t.titleSmall),
        RadioGroup<BulkPlacement>(
          groupValue: value.placement,
          onChanged: (v) {
            if (enabled && v != null) onChanged(value.withPlacement(v));
          },
          child: Column(
            children: [
              RadioListTile<BulkPlacement>(
                contentPadding: EdgeInsets.zero,
                value: BulkPlacement.mirroredFolder,
                title: const Text('One folder, same layout'),
                subtitle: Text(
                  'Subfolders are recreated inside the folder you pick.',
                  style: t.bodySmall,
                ),
              ),
              RadioListTile<BulkPlacement>(
                contentPadding: EdgeInsets.zero,
                value: BulkPlacement.besideOriginals,
                title: Text('Next to each $source'),
                subtitle: Text(
                  'Each file is saved in the folder it came from.',
                  style: t.bodySmall,
                ),
              ),
              RadioListTile<BulkPlacement>(
                contentPadding: EdgeInsets.zero,
                value: BulkPlacement.flatFolder,
                title: const Text('One folder, all together'),
                subtitle: Text(
                  'Subfolders are not recreated. If two files share a name, '
                  'the later one gets a number so neither is replaced.',
                  style: t.bodySmall,
                ),
              ),
            ],
          ),
        ),
        if (value.needsFolder)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              value.hasFolder ? bulkFolderName(value) : 'No folder chosen yet',
              style: value.hasFolder
                  ? null
                  : t.bodyMedium?.copyWith(color: LatchColors.danger),
            ),
            subtitle: value.hasFolder && value.label != null
                ? Text(value.label!, style: t.bodySmall)
                : null,
            trailing: TextButton(
              onPressed: enabled ? () => _pick(context) : null,
              child: Text(value.hasFolder ? 'Change' : 'Choose'),
            ),
          ),
      ],
    );
  }
}

/// The result screen's statement of where output went (FR-032). [firstOut] is
/// the first written file, used only for "beside the originals", where the
/// folder is the source's own.
String bulkSavedWhere({
  required BulkDestination? destination,
  required String firstOut,
  required bool fellBackToDownloads,
  required String sourceNoun,
}) {
  final d =
      destination ??
      const BulkDestination(placement: BulkPlacement.besideOriginals);
  if (d.placement == BulkPlacement.besideOriginals) {
    return fellBackToDownloads
        ? 'Some files could not be saved beside the $sourceNoun and were '
              'saved to Downloads instead.'
        : 'Saved under ${p.dirname(firstOut)}.';
  }
  final name = d.hasFolder ? bulkFolderName(d) : p.dirname(firstOut);
  final fell = fellBackToDownloads
      ? ' Some files could not be written there and were saved to Downloads '
            'instead.'
      : '';
  return d.placement == BulkPlacement.mirroredFolder
      ? 'Saved in $name, with the same folder layout.$fell'
      : 'Saved together in $name. Files that shared a name were given a '
            'number.$fell';
}
