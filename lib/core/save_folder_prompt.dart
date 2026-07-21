import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'saf_bridge.dart';

/// Shows a brief rationale, then the Android folder picker, so the app can
/// create output files in [folder] (the folder the sources came from).
///
/// Returns the granted tree URI, or null when the user declines — in which
/// case the caller falls back to saving in Downloads. Used by both the encrypt
/// and decrypt flows as the `requestGrant` callback for [OutputPlanner.plan].
Future<String?> promptSaveFolder(BuildContext context, String folder) async {
  final choose = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Where to save'),
      content: Text(
        'Allow Latch to save into "${p.basename(folder)}" — the folder these '
        'files came from. If you skip, they go to your Downloads folder.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Use Downloads'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Choose folder'),
        ),
      ],
    ),
  );
  if (choose != true) return null;
  return SafBridge.pickTree(initialPath: folder);
}
