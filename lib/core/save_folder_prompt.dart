import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'output_plan.dart';
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
/// named permission to ask for, so the destination choices come up directly.
/// The picker can still be seeded in that case: [sourcePath] is one source file
/// from the folder, and its document URI lets the *system* resolve the parent
/// (see [SafBridge.pickTree]), so "Choose folder" opens in the right place
/// instead of at the storage root.
///
/// Returns a [SaveFolderDecision]: a grant, an explicit "use Downloads", or a
/// cancellation. Cancelling stops the batch — Downloads is a destination the
/// user can choose, never one they get by declining to choose. Used by both the
/// encrypt and decrypt flows as the `requestGrant` callback for
/// [OutputPlanner.plan], which only calls it when no existing grant covers
/// the folder.
Future<SaveFolderDecision> promptSaveFolder(
  BuildContext context,
  String? folder, {
  String? sourcePath,
}) async {
  final docUri = sourcePath == null ? null : SafBridge.uriFor(sourcePath);

  // 1. Rationale first — a folder picker appearing out of nowhere reads as the
  // app misbehaving; name the folder and say what happens next. Backing out
  // here is a step back, not a cancel: the destination choices come next, and
  // Cancel is one of them.
  if (folder != null && await _confirmPicker(context, folder)) {
    final granted = await _pickTree(folder, docUri);
    if (granted != null) return SaveFolderDecision.granted(granted);
  }

  // 2. Declined, unresolvable folder, or broken picker — the explicit ways out.
  // Never a silent Downloads fallback.
  //
  // Asked at most twice: an empty picker after "Choose folder" (they backed out
  // of it, or the device has no handler for the intent at all) comes back here
  // rather than guessing, so Downloads stays reachable on a device where the
  // picker cannot open. A second empty picker is taken as an answer — stop
  // asking and cancel.
  if (!context.mounted) return const SaveFolderDecision.cancelled();
  final first = await _askDestination(context, folder, docUri);
  if (first != null) return first;

  if (!context.mounted) return const SaveFolderDecision.cancelled();
  return await _askDestination(context, folder, docUri) ??
      const SaveFolderDecision.cancelled();
}

/// One round of the destination question. Null means "the user asked to choose
/// a folder and the picker produced nothing" — the only outcome that isn't an
/// answer, and the only one worth asking about again.
Future<SaveFolderDecision?> _askDestination(
  BuildContext context,
  String? folder,
  String? docUri,
) async {
  if (!context.mounted) return const SaveFolderDecision.cancelled();
  final destination = await _chooseDestination(context, folder);
  switch (destination) {
    case _Destination.cancel:
      return const SaveFolderDecision.cancelled();
    case _Destination.downloads:
      return const SaveFolderDecision.useDownloads();
    case _Destination.choose:
      // Custom location: start from the folder the files came from, not
      // wherever the picker last was.
      final granted = await _pickTree(folder, docUri);
      return granted == null ? null : SaveFolderDecision.granted(granted);
  }
}

/// Opens the system folder picker seeded at [folder], returning the granted
/// tree URI.
///
/// Null covers every way this can fail to produce a grant, including the
/// picker not opening at all: a device with no handler for
/// `ACTION_OPEN_DOCUMENT_TREE` (or one already showing a picker) must still
/// leave Downloads reachable rather than throwing out of the prompt and
/// failing the whole batch.
Future<String?> _pickTree(String? folder, String? docUri) async {
  try {
    return await SafBridge.pickTree(initialPath: folder, initialDocUri: docUri);
  } catch (_) {
    return null;
  }
}

/// Explains why the folder picker is about to open. False = the user backed
/// out (including by dismissing the dialog), so the picker must not open.
Future<bool> _confirmPicker(BuildContext context, String folder) async {
  final proceed = await showDialog<bool>(
    context: context,
    // Dismissing (back press / tap outside) must not be treated as an
    // explicit choice — see the "Never a silent Downloads fallback" note
    // above, which a default-dismissible dialog would otherwise violate.
    barrierDismissible: false,
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

/// What the user wants done with the output once the source folder is off the
/// table.
enum _Destination { cancel, downloads, choose }

/// The explicit destinations once the source folder is off the table.
///
/// Three outcomes, all of them deliberate. Cancel is a real button and not just
/// a back-gesture, because leaving the batch is a choice a user is entitled to
/// make and an invisible one is no choice at all. Dismissing the dialog means
/// the same thing: the user did not say where the files go, so nothing is
/// written. Downloads is offered plainly, but only ever as something chosen.
///
/// A null [folder] is not a malfunction and must not read like one: when a file
/// is picked through the picker's shortcuts (Downloads, Images, Videos…),
/// Android hands the app that one document and deliberately nothing about the
/// folder holding it — there is no supported way to ask. So the copy explains
/// the situation plainly and leads with the action that fixes it (choosing a
/// folder grants access, and Android remembers that grant for next time).
Future<_Destination> _chooseDestination(
  BuildContext context,
  String? folder,
) async {
  final choice = await showDialog<_Destination>(
    context: context,
    // Same reasoning as _confirmPicker: a dismiss must not silently resolve to
    // "Use Downloads". It resolves to cancel, below.
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Where to save'),
      content: Text(
        folder == null
            ? 'Android doesn\'t tell apps which folder a file came from when '
                  'it\'s picked this way, so Latch can\'t save next to it '
                  'automatically. Choose a folder to save into — Latch will '
                  'remember it — or use your Downloads folder.'
            : 'Without access to "${p.basename(folder)}" — the folder these '
                  'files came from — files go to your Downloads folder. You '
                  'can also choose a different folder.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, _Destination.cancel),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, _Destination.downloads),
          child: const Text('Use Downloads'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, _Destination.choose),
          child: const Text('Choose folder'),
        ),
      ],
    ),
  );
  // Dismissed (back press) — no destination was named, so cancel.
  return choice ?? _Destination.cancel;
}
