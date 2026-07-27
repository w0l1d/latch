import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'saf_bridge.dart';

/// Asks for write access to [folder] — the folder the sources came from — so
/// output files can land beside their originals.
///
/// The permission prompt comes FIRST: the system folder picker opens seeded at
/// [folder], so granting is one tap on "Use this folder". Only when the user
/// backs out of the picker — or the picker can't open at all (no handler for
/// the intent on stripped-down/restricted Android) — do the explicit
/// alternatives come up: save to Downloads, or choose a custom folder (the
/// picker reopens, still seeded at the source folder). A null [folder] means
/// the source folder couldn't be resolved, so both pickers go unseeded.
///
/// Returns the granted tree URI, or null when the user declines everything —
/// in which case the caller falls back to saving in Downloads. Used by both
/// the encrypt and decrypt flows as the `requestGrant` callback for
/// [OutputPlanner.plan], which only calls it when no existing grant covers
/// the folder.
Future<String?> promptSaveFolder(BuildContext context, String? folder) async {
  // The permission prompt itself: seeded at the source folder, so the common
  // case ("save beside the original") is a single tap.
  String? granted;
  try {
    granted = await SafBridge.pickTree(initialPath: folder);
  } catch (_) {
    // No handler for the tree picker — fall through to the explicit choices
    // so Downloads stays reachable instead of failing the whole batch.
  }
  if (granted != null) return granted;

  // Declined — offer the explicit ways out.
  if (!context.mounted) return null;
  final choose = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Where to save'),
      content: Text(
        folder == null
            ? 'Latch can\'t tell which folder these files came from. Save to '
                  'your Downloads folder, or choose a folder yourself.'
            : 'Without access to "${p.basename(folder)}" — the folder these '
                  'files came from — files go to your Downloads folder. You '
                  'can also choose a different folder.',
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
  // Custom location: start from the folder the files came from, not wherever
  // the picker last was.
  return SafBridge.pickTree(initialPath: folder);
}
