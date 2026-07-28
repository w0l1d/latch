import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'saf_bridge.dart';

/// Asks for write access to [folder] — the folder the sources came from — so
/// output files can land beside their originals.
///
/// Never drops the system folder picker on the user unexplained: a rationale
/// dialog first names the folder and says the picker opens next. On Continue
/// the permission picker appears, seeded at [folder], so granting is one tap
/// on "Use this folder". When the user backs out of the picker — cancels the
/// rationale, declines the picker, or the picker can't open at all (no handler
/// for the intent on stripped-down/restricted Android) — the explicit
/// alternatives come up: save to Downloads, or choose a custom folder (the
/// picker reopens, still seeded at [folder]).
///
/// A null [folder] means the source folder couldn't be resolved — there is no
/// permission to ask for, so the destination choices come up directly and both
/// pickers go unseeded.
///
/// Returns the granted tree URI, or null when the user declines everything —
/// in which case the caller falls back to saving in Downloads. Used by both
/// the encrypt and decrypt flows as the `requestGrant` callback for
/// [OutputPlanner.plan], which only calls it when no existing grant covers
/// the folder.
Future<String?> promptSaveFolder(BuildContext context, String? folder) async {
  // 1. Rationale first — a folder picker appearing out of nowhere reads as the
  // app misbehaving; name the folder and say what happens next.
  if (folder != null && await _confirmPicker(context, folder)) {
    final granted = await _pickTree(folder);
    if (granted != null) return granted;
  }

  // 2. Declined, unresolvable folder, or broken picker — the explicit ways
  // out. Never a silent Downloads fallback.
  if (!context.mounted) return null;
  if (!await _chooseCustomFolder(context, folder)) return null;

  // Custom location: start from the folder the files came from, not wherever
  // the picker last was.
  return _pickTree(folder);
}

/// Opens the system folder picker seeded at [folder], returning the granted
/// tree URI.
///
/// Null covers every way this can fail to produce a grant, including the
/// picker not opening at all: a device with no handler for
/// `ACTION_OPEN_DOCUMENT_TREE` (or one already showing a picker) must still
/// leave Downloads reachable rather than throwing out of the prompt and
/// failing the whole batch.
Future<String?> _pickTree(String? folder) async {
  try {
    return await SafBridge.pickTree(initialPath: folder);
  } catch (_) {
    return null;
  }
}

/// Explains why the folder picker is about to open. False = the user backed
/// out (including by dismissing the dialog), so the picker must not open.
Future<bool> _confirmPicker(BuildContext context, String folder) async {
  final proceed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Save beside the originals?'),
      content: Text(
        'To save into "${p.basename(folder)}" — the folder these files came '
        'from — Android needs you to allow Latch access to it. The folder '
        'picker opens next.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Continue'),
        ),
      ],
    ),
  );
  return proceed == true;
}

/// The explicit destinations once the source folder is off the table. True =
/// the user wants to pick a folder themselves; false = use Downloads.
Future<bool> _chooseCustomFolder(BuildContext context, String? folder) async {
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
  return choose == true;
}
