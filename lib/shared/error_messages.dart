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

  return 'Something went wrong. The files were not changed.';
}
