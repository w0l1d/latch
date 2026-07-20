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
