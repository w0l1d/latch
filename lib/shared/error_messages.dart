import 'package:myenc_core/myenc_core.dart';

/// Maps both typed [LatchError] subclasses and string-form errors (as received
/// from the worker isolate) to a short, user-friendly message suitable for
/// display in a dialog.
String userMessageForError(Object error) {
  // Typed errors (thrown on the main isolate side).
  if (error is StorageFullError) {
    return 'Not enough storage space to write the file.';
  }
  if (error is WrongPassphraseError) {
    return 'Incorrect passphrase. Double-check and try again.';
  }
  if (error is NotALatchFileError) {
    return 'This file is not a .latch file. Choose a file ending in .latch.';
  }
  if (error is CorruptedFileError) {
    return 'This .latch file appears to be damaged or modified. '
        'It cannot be decrypted safely.';
  }
  if (error is VersionTooNewError) {
    return 'This file was created by a newer version of Latch. '
        'Please update the app.';
  }
  // Authentic, undamaged, and written by a build that knows a payload shape
  // this one does not. Saying "damaged" here would send the user hunting for a
  // backup they do not need — so this gets its own copy (FR-020h).
  if (error is UnknownPayloadKindError) {
    return 'This file holds something a newer version of Latch knows how to '
        'open. The file is fine — please update the app.';
  }
  if (error is UnsafeArchiveEntryError) {
    return 'This folder could not be restored safely: '
        '"${error.entryPath}" ${error.reason}. Nothing was written.';
  }

  // String-form errors (reported by the worker isolate via SendPort).
  final msg = error.toString();
  if (msg.contains('WrongPassphraseError')) {
    return 'Incorrect passphrase. Double-check and try again.';
  }
  if (msg.contains('NotALatchFileError')) {
    return 'This file is not a .latch file. Choose a file ending in .latch.';
  }
  if (msg.contains('CorruptedFileError')) {
    return 'This .latch file appears to be damaged or modified. '
        'It cannot be decrypted safely.';
  }
  if (msg.contains('VersionTooNewError')) {
    return 'This file was created by a newer version of Latch. '
        'Please update the app.';
  }
  if (msg.contains('StorageFullError')) {
    return 'Not enough storage space to write the file.';
  }
  if (msg.contains('UnknownPayloadKindError')) {
    return 'This file holds something a newer version of Latch knows how to '
        'open. The file is fine — please update the app.';
  }
  if (msg.contains('UnsafeArchiveEntryError')) {
    // The worker hands this back as text, so recover the entry path from the
    // quoted portion rather than dropping to the generic message — naming the
    // entry is the whole point of the error.
    final quoted = RegExp(r'"([^"]*)"').firstMatch(msg)?.group(1);
    return quoted == null
        ? 'This folder could not be restored safely. Nothing was written.'
        : 'This folder could not be restored safely: an entry named '
              '"$quoted" is not safe to write. Nothing was written.';
  }

  return 'Something went wrong. The files were not changed.';
}
