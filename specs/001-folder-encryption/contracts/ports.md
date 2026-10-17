# Contract: DirectoryIoPort, FreeSpacePort and the worker protocol

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

  /// Non-following classification of a single entry, used both at enumeration
  /// (to decide packed vs skipped, FR-002a) and again immediately before and
  /// after reading it (to detect a source changing underneath, FR-031a).
  /// Returns null when the entry does not exist.
  Future<EntryStamp?> stat(String path);
}

/// (kind, sizeBytes, modified) — see data-model.md.
final class EntryStamp { ... }
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
- `walk` MUST classify, not reject: an entry that is neither a file, a directory
  nor a symlink is yielded as **skipped** with its relative path and a concrete
  reason, never dropped and never fatal (FR-002a, R12). It is the caller's job to
  report the skip; it is the port's job to make silence impossible.
- `stat` MUST NOT follow links, for the same reason `walk` does not.
- **`stat` returning `notFound` is ambiguous by itself.** `dart:io` has no device
  kind, so a character device is stat-invisible exactly like a nonexistent path
  (R12). The port therefore returns the raw observation and the *caller* resolves
  it by context: at enumeration, "listed but stat-invisible" ⇒ skip; at read time,
  for an entry that already classified cleanly, ⇒ `disappeared`. The port MUST NOT
  try to collapse the two — it does not have the listing.
- The adapter SHOULD use the **sync** `dart:io` variants (`statSync`,
  `typeSync`, `listSync`) internally. Dart's own `avoid_slow_async_io` lint exists
  because the async forms are substantially slower, and this walk runs over
  10,000 entries (SC-005) inside the spawned isolate, where blocking costs
  nothing. The port's methods stay `Future`-returning so the interface does not
  leak the choice.

## 1b. `FreeSpacePort` (new, `myenc_core/lib/src/ports/`)

```dart
abstract interface class FreeSpacePort {
  /// Bytes available to this app at [path]'s volume, or null when the
  /// platform will not say. Null is a valid answer, NOT an error.
  Future<int?> freeBytesAt(String path);

  /// Whether [path]'s volume will accept a *single file* of [bytes].
  /// Null when the platform will not say. Null is NOT a refusal.
  Future<bool?> canHoldSingleFile(String path, int bytes);
}
```

**Contract notes.**

- `dart:io` has no free-space API, so the adapter is per-platform: Android
  `StatFs(path)`, Apple `volumeAvailableCapacityForImportantUsageKey` (**not** the
  older `NSFileSystemFreeSize` — on iOS the two differ, and only the former
  answers "can I write this now"), `df` on Linux/macOS, `GetDiskFreeSpaceEx` on
  Windows. See R10 for why the `storage_space` package was read as a reference
  and rejected as a dependency.
- **The path argument is the whole point**, and it is where most of the pub.dev
  options fail: `storage_space` and `storage_info` expose device-wide readings
  with no path parameter, so on an SD-card destination they report internal
  storage and let a doomed operation start. `disk_space_plus` *does* take a path
  (`StatFs(path)` / `volumeAvailableCapacityForImportantUsageKey`, the same two
  calls chosen here) but returns rounded megabytes and **throws** when the path
  is not statable, which is the SAF case. An adapter that cannot resolve a real
  path for a location MUST return `null`, never a different volume's number and
  never an exception.
- On Android the destination path comes from the existing
  `SafBridge.realDirectoryFor`; when it cannot resolve the SAF tree (cloud
  providers, `msf:` ids — the documented limit in CLAUDE.md), the probe returns
  `null` and the operation proceeds.
- `canHoldSingleFile` answers a different question and MUST NOT be folded into
  the free-space one: it is "no single file may be this large" (`EFBIG`), not
  "not enough room" (`ENOSPC`), and the two produce different messages. No
  platform exposes a filesystem type or a maximum file size, so the adapter
  **provokes** the limit instead of querying it: allocate `bytes` at `path` and
  read the errno. Required behaviour — call it only when `bytes` exceeds 4 GiB;
  bound it with a timeout; return `false` **only** on `EFBIG`; return `null` for
  every other failure, for an unsupported operation (a cloud provider's pipe
  gives `ESPIPE`/`EINVAL`), and on timeout; and leave nothing behind whatever the
  outcome. A refusal arrives in microseconds and a success is free on any
  filesystem with sparse files, so the check is cheap in both directions — see
  R15 for the measurements.
- On Android `canHoldSingleFile` MUST run natively against the SAF destination
  (`createDocument` → `openFileDescriptor("w")` → `Os.ftruncate`), never in Dart:
  the worker stages into the app cache, which is a different volume with a
  different limit. Prefer `StorageManager.allocateBytes` where
  `isAllocationSupported(fd)` is true, but keep the probe — `getAllocatableBytes`
  does not cover removable volumes, which are the ones this check exists for.
- Returning `null` MUST mean **proceed**, never **refuse**. FR-029a's guarantee
  is "refuse early where the platform will answer"; FR-029's mid-run abort is the
  backstop for everywhere else.
- MUST NOT throw. A probe that fails is a probe that returned `null`.
- Callers MUST query **both** the destination and, on Android, the staging cache
  — they are frequently different volumes, and the refusal has to name which one
  is short (FR-029a).

## 2. Errors added to `myenc_errors.dart`

```dart
/// The container declares a payload kind, pack format, compression, or
/// reserved value this version does not define — it was made by a newer
/// version of Latch. Distinct from wrong-passphrase and from corruption.
final class UnknownPayloadKindError extends LatchError { ... }

/// A packed entry tried to escape the destination root, or used a type this
/// version does not accept. Names the offending relative path.
final class UnsafeArchiveEntryError extends LatchError { ... }

/// The operation cannot fit. Carries the shortfall in bytes AND which
/// location is short — destination or staging — because on Android they are
/// routinely different volumes (FR-029a). Raised pre-flight where the
/// platform answers, and mapped onto the mid-run write failure where it does
/// not, so exhaustion is never reported as a generic write error.
final class InsufficientSpaceError extends LatchError { ... }

/// An entry changed between enumeration and reading. Carries the relative
/// path AND a SourceChangeKind (disappeared / kindChanged / grew / shrank /
/// modifiedWhileReading). A message that says only "the folder changed" does
/// not satisfy FR-031a.
final class SourceChangedError extends LatchError { ... }
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

`pack_encrypt`'s task map carries the `EntryStamp` snapshot taken at
enumeration, and its `file_done` carries the **captured manifest** — the entries
the container actually holds. The manifest is what `OriginalDeletion` iterates;
nothing downstream may re-walk the source tree (FR-002b, R12).

The pre-flight space check runs on the **main isolate, before the worker is
spawned** (FR-029a). It needs platform channels on Android, which the worker does
not have — the same constraint that already puts SAF relocation after the batch.
Nothing is staged or written when it refuses, so there is nothing to sweep.

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
