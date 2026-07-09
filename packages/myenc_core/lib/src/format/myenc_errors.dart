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

final class VersionTooNewError extends LatchError {
  final int version;
  VersionTooNewError(this.version);
  @override
  String toString() => 'VersionTooNewError: format version $version is not supported';
}

final class StorageFullError extends LatchError {
  @override
  String toString() => 'StorageFullError: insufficient storage space';
}
