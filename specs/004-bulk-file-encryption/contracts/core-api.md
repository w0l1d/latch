# Contract: myenc_core additions

All additions are pure Dart. No `dart:io`, no Flutter.

## BatchWrapKey
```dart
final class BatchWrapKey {
  static Future<BatchWrapKey> derive(CryptoPort crypto, Uint8List passphrase,
      {required int opslimit, required int memlimit});
  Uint8List get salt;      // 16 bytes
  void dispose();          // zeroes the KEK; idempotent
}
```
`EnvelopeService.encrypt(..., {BatchWrapKey? batchKey})`: when non-null, header salt =
`batchKey.salt`, wrap = `secretboxSeal(freshDek, batchKey.kek)` (via
`DekWrap.wrapPassphraseWithKek`). Header `opslimit/memlimit` MUST equal the key's.
Using a disposed key throws `StateError`.

**Required tests.** (1) Shared-salt containers decrypt through unchanged
`EnvelopeService.decrypt`. (2) Two files in one batch have *different* DEKs, secretstream
headers and wrap nonces, *identical* salt. (3) An independent reference (Python, like
`tool/gen_golden_vectors.py`) decrypts a batch container by deriving from the header
salt. (4) `codec_freeze_test` and goldens pass unmodified.

## ContainerSniffer
```dart
enum SniffResult { container, notContainer, newerVersion, truncated }
SniffResult sniff(Uint8List firstBytes);   // needs only the fixed prefix
```
Never throws. Never reads the extension.

## DirectoryIoPort (subset; signatures as in specs/001-folder-encryption/contracts/ports.md)
`walk(root)` (non-following, byte-sorted, classifies not rejects), `stat(path)`,
`createDirectory(path, {recursive})`.

## FreeSpacePort (as in 001)
`freeBytesAt(path)` → `int?`; `null` means *proceed*, never *refuse*. Callers check
destination **and** (Android) staging cache and name which is short.

## Errors
Reuse existing typed errors. `InsufficientSpaceError` is shared with 001: whichever
feature lands first defines it; it carries shortfall bytes and which location is short.
