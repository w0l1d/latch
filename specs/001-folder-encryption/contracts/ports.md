# Contract: DirectoryIoPort and the worker protocol

## 1. `DirectoryIoPort` (new, `myenc_core/lib/src/ports/`)

`myenc_core` cannot import `dart:io` (Principle III), and `FileIoPort` is
file-shaped — it has no notion of a tree, a symlink, an mtime, or a mode.
Directory work therefore gets its own port rather than bloating `FileIoPort` and
forcing every existing fake to implement methods it does not care about.

```dart
abstract interface class DirectoryIoPort {
  /// Walks [root] WITHOUT following symlinks, yielding entries in
  /// byte-wise sorted relative-path order. Never yields the root itself.
  Stream<FolderEntry> walk(String root);

  Future<bool> directoryExists(String path);
  Future<void> createDirectory(String path, {bool recursive = false});

  /// Removes [path] and everything under it. Used to sweep staged output on
  /// cancellation or failure — a security property, not tidiness.
  Future<void> deleteDirectory(String path, {bool recursive = true});

  /// Creates a symbolic link at [path] pointing at [target], verbatim.
  /// Returns false when the platform refuses (Android/iOS sandbox) so the
  /// caller can record it in the metadata report instead of failing.
  Future<bool> createSymlink(String path, String target);

  /// Returns false when the platform refuses, for the same reason.
  Future<bool> setModified(String path, DateTime modified);
  Future<bool> setExecutable(String path, bool executable);

  /// Atomically moves a fully-unpacked staging tree onto its final name.
  Future<void> renameDirectory(String from, String to);
}
```

**Contract notes.**

- `walk` MUST use non-following stats. Following symlinks both escapes the
  selection root and permits an unbounded capture (FR-006, R4).
- `walk` MUST detect and refuse cycles (FR-006).
- `createSymlink`, `setModified`, and `setExecutable` return `bool` rather than
  throwing, because a platform refusal is the **normal path** inside the Android
  and iOS sandboxes. FR-020e requires the restore to succeed and report, not to
  fail the entry.
- `deleteDirectory` and `renameDirectory` exist for the staging discipline in §3.

## 2. Errors added to `myenc_errors.dart`

```dart
/// The container declares a payload kind, pack format, compression, or
/// reserved value this version does not define — it was made by a newer
/// version of Latch. Distinct from wrong-passphrase and from corruption.
final class UnknownPayloadKindError extends LatchError { ... }

/// A packed entry tried to escape the destination root, or used a type this
/// version does not accept. Names the offending relative path.
final class UnsafeArchiveEntryError extends LatchError { ... }
```

Both MUST get human copy in `lib/shared/error_messages.dart`. Raw exception text
is never interpolated into user-facing messages (Principle IV).

## 3. Worker protocol (unchanged shape, new commands)

The worker→main message protocol stays **exactly** as it is —
`file_start` / `progress` / `file_done` / `error` / `done` — because the
"last per-file result arrives before the final `1.0`" invariant is a property of
the protocol, and keeping it unchanged is what keeps that invariant and
`test/app_crypto_batch_test.dart` valid (Principle V).

Two new `cmd` values in `latchWorker`:

| `cmd` | Task map | Emits |
|---|---|---|
| `pack_encrypt` | root path, entry inventory, total bytes, passphrase, output path, wrap options | one `file_start`, byte-weighted `progress`, one `file_done`, `done` |
| `decrypt_unpack` | container path, passphrase, staging root, destination root | one `file_start`, byte-weighted `progress`, one `file_done` carrying the metadata report, `done` |

**One folder is one batch item** (FR-012), so exactly one `file_done` per
operation.

**Progress is byte-weighted, not entry-counted** — FR-026 requires progress to be
meaningful for both a folder of 3 large files and one of 10,000 small ones, and
SC-005 requires it to advance at least once per second for 10,000 files. Total
bytes are known before the stream starts because enumeration already ran, which
FR-003 and FR-004 require anyway.

## 4. Required change to `AppCrypto._runBatch` — security, not cleanup

Teardown currently kills the isolate and sweeps the in-flight `<outPath>.tmp`
**file**. A folder restore stages a **directory**. `_runBatch` MUST sweep a staged
directory recursively on teardown before `done`.

Without this, cancelling a folder restore leaves partial plaintext on disk. That
is a Principle IV violation and a security regression — which is why this lands
in phase P1, before any UI can trigger a restore, not as a follow-up.
