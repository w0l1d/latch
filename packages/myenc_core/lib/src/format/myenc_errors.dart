sealed class LatchError implements Exception {}

final class WrongPassphraseError extends LatchError {
  @override
  String toString() => 'WrongPassphraseError: incorrect passphrase';
}

final class CorruptedFileError extends LatchError {
  final String reason;
  CorruptedFileError(this.reason);
  @override
  String toString() => 'CorruptedFileError: $reason';
}

/// The input is not a Latch file at all (wrong magic bytes) — distinct from a
/// genuine Latch file that has been damaged ([CorruptedFileError]). Lets the UI
/// say "this isn't a Latch file" rather than the alarming "tampered" message.
final class NotALatchFileError extends LatchError {
  @override
  String toString() => 'NotALatchFileError: not a Latch (.latch) file';
}

final class VersionTooNewError extends LatchError {
  final int version;
  VersionTooNewError(this.version);
  @override
  String toString() =>
      'VersionTooNewError: format version $version is not supported';
}

final class StorageFullError extends LatchError {
  @override
  String toString() => 'StorageFullError: insufficient storage space';
}

/// The container declares a payload kind this build does not define. The file
/// is authentic and undamaged — it was written by a newer version of the app.
///
/// Deliberately its own type rather than a [CorruptedFileError]: the honest
/// advice is "update the app", and telling the user their file is damaged when
/// it is intact would send them looking for a backup they do not need.
final class UnknownPayloadKindError extends LatchError {
  /// The undefined payload-kind byte, as read from the payload preamble.
  final int kind;
  UnknownPayloadKindError(this.kind);
  @override
  String toString() =>
      'UnknownPayloadKindError: payload kind 0x${kind.toRadixString(16).padLeft(2, '0')} '
      'is not defined by this version';
}

/// An entry in a packed-folder payload would write outside the destination, or
/// is of a kind that is never restored (hard link, device, FIFO).
///
/// Authentication proves the container came from someone holding the key; it
/// does not prove the contents are benign. This is the error for that gap.
final class UnsafeArchiveEntryError extends LatchError {
  /// The entry's path exactly as it appeared in the packed stream — quoted back
  /// so the user can find it in the folder they protected.
  final String entryPath;
  final String reason;
  UnsafeArchiveEntryError(this.entryPath, this.reason);
  @override
  String toString() => 'UnsafeArchiveEntryError: "$entryPath" $reason';
}
