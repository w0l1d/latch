# Phase 0 Research: Folder Encryption (UC-13)

**Feature**: `specs/001-folder-encryption/` | **Date**: 2026-08-26

Every decision below is checked against `.specify/memory/constitution.md` v1.0.0
and the requirement it serves. Nothing here is a preference; each entry names the
requirement that forces it.

---

## R1. Where the payload-kind indicator lives

**Decision.** The payload-kind lives **inside the encrypted payload**, as a fixed
8-byte preamble at the very start of the plaintext stream. The `.latch` header
gains **no new field**; only the version byte changes, from `0x01` to `0x02`, to
mark "this container's plaintext begins with a payload preamble".

**Rationale.**

- **FR-020c demands authentication.** The v1 header is *not* authenticated —
  there is no header MAC (`docs/FORMAT.md` §2; only the secretstream body carries
  tags). A new header field would therefore be *unauthenticated* unless
  secretstream additional-data were introduced, which is a second format change.
  Bytes inside the secretstream are authenticated by construction, at zero design
  cost.
- **FR-013 / Principle II demand no v1 byte changes.** This touches no v1 field
  at all. `MyencCodec.encodeHeader`/`decodeHeader` keep their exact layout; the
  only edit is widening the accepted version set. `codec_freeze_test.dart` and the
  golden vectors keep passing **unmodified** — which is the point of a freeze
  guard.
- **Free confidentiality win.** Whether a container holds a file or a folder is
  not observable from the ciphertext. FR-009 only requires entry names and tree
  shape to be confidential; this gives more than asked without extra work.
- **FR-020h falls out naturally.** An unknown payload-kind is discovered only
  *after* the DEK unwrapped and the first chunk authenticated — so it is
  structurally impossible to confuse with a wrong passphrase (fails at the wrap)
  or corruption (fails at a chunk tag). The three messages are distinguishable
  because the three failures happen at three different, ordered stages, which is
  exactly Principle IV's ordering guarantee.

**Alternatives rejected.**

| Alternative | Rejected because |
|---|---|
| New header field (e.g. reuse reserved flag bits 1–7) | Unauthenticated — flipping the bit would silently change payload interpretation, violating FR-020c. Reusing reserved v1 bits also breaks Principle II directly: a v1 reader accepts the byte and misreads the container. |
| New header field + secretstream additional-data on chunk 0 | Authenticated, but a strictly larger change: touches the header codec, the crypto port (`createEncryptTransformer` has no AAD parameter), and the golden-vector producer. Leaks folder-vs-file to an observer. No compensating benefit. |
| Sniff the plaintext for tar/zip magic | Explicitly forbidden by FR-020b, and would expand a user's `.zip` into a tree — the exact bug the clarification session was about. |

**Version-emission policy.** Writers emit the **lowest version that can express
the payload**: a single file still produces **v1**, byte-identical to today
(FR-014); only a packed folder produces v2. A v2 container declaring kind
"single opaque file" is legal and readable, but is never produced by default.
This keeps containers readable by installs that predate the feature whenever it
is possible at all.

---

## R2. Packing format for the folder tree

**Decision.** **tar**, restricted to a defined subset: USTAR base records with
**PAX extended headers** for long paths, long link targets, and non-ASCII names.
Read and written with **`package:tar` ^2.0.2**. No compression.

**Rationale.**

- **Pure Dart, no `dart:io`.** Verified against the published archive: the only
  occurrence of `dart:io` in `package:tar` 2.0.2 `lib/` is inside a doc comment.
  Its transitive deps are `async`, `meta`, `typed_data` — all pure Dart. It can
  therefore live in `myenc_core` without violating **Principle III**.
- **Streaming both directions.** `TarWriter` consumes and `TarReader` produces
  entries as streams, so a 10 GB file is never materialised. This is what
  **FR-027** (peak memory independent of entry count *and* of largest file) and
  **SC-006** require, and it is what rules the alternatives out.
- **Carries exactly the in-scope metadata of FR-020a and no more.** A tar header
  has `mode` (executable bit), `modified` (mtime), and `TypeFlag.symlink` with
  `linkName`. Creation times, ACLs, and xattrs have no place in the subset — so
  FR-020a's out-of-scope list is enforced by the format, not by discipline.
- **An independent oracle exists for free — Principle V.** Python's stdlib
  `tarfile` with `format=tarfile.PAX_FORMAT` reads and writes the same subset.
  `tool/gen_golden_vectors.py` can therefore produce a folder container whose
  packed stream was never touched by Dart, which is precisely what Principle V
  requires and what a hand-rolled format cannot offer.

**Alternatives rejected.**

| Alternative | Rejected because |
|---|---|
| Custom "latchpack" format | No independent oracle: the Python producer would be a transliteration of the Dart code, so Principle V's "external oracle" degrades to self-consistency. Also writes the hostile-input parser — the riskiest code in the feature — from scratch. |
| `package:archive` | Its tar/zip encoders build in memory rather than streaming, so peak memory scales with archive size. Fails FR-027 and SC-006. |
| zip | The central directory is at the *end* and requires seeking, so a forward-only stream cannot be read without buffering the whole archive. Symlink support is a non-portable extension field. |
| tar with GNU long-name extensions instead of PAX | Python `tarfile` handles both, but PAX is the POSIX.1-2001 standard and encodes names as UTF-8 by specification — needed for FR-018 (byte-identical names). |

**Determinism (FR-020).** The tar subset must be written deterministically or
"restoring twice yields identical trees" is not testable. Rules:

- entries emitted in a **stable sorted order** by relative path, byte-wise on the
  UTF-8 encoding;
- `uid`/`gid` written as `0`, `userName`/`groupName` empty — these are out of
  scope per FR-020a and would otherwise leak the encrypting user's identity into
  the container;
- `mode` normalised to `0o755` for directories and executables, `0o644`
  otherwise — the executable bit is in scope, the rest of the permission set is
  not;
- no tar padding beyond the format's own 512-byte blocking;
- names written **verbatim**, with **no Unicode normalisation** — see below.

**Unicode normalisation: do not normalise (FR-018).** Cryptomator normalises every
cleartext name to NFC before encrypting it, to obtain one unique binary
representation per name. Latch must do the **opposite**, and the reason is a
different requirement rather than a different opinion: FR-018 demands restored
names be byte-for-byte identical to the originals, so normalising at pack time
would rewrite an NFD name created on macOS into NFC and break the round trip. The
bytes are the payload.

The exposure therefore moves to **restore**, and that is where it must be handled:
two entries whose names are byte-distinct but normalisation-equivalent (or
case-equivalent) round-trip correctly onto a byte-preserving filesystem, and
collide on one that folds them — APFS compares normalisation-insensitively, HFS+
normalised to NFD, and Windows and many SAF providers fold case. The unpacker MUST
detect that collision and abort, naming **both** relative paths. This is the same
rejection class as the duplicate-relative-path case already required of the safe
unpacker (FR-020d, quickstart S5), not a new mechanism — the equality test is
widened from byte equality to "equal after NFC folding, or after case folding on a
case-insensitive destination", and the second form can only be decided against the
actual destination. Silently overwriting the first entry with the second is the
one outcome that is not acceptable, because it loses data while reporting success.

**Concurrent modification (Assumptions).** A tar header states a file's size
*before* its content. If the file grows or shrinks between `stat` and read, the
archive is silently corrupt. The writer MUST compare bytes actually read against
the declared size and **abort the whole operation** on mismatch, naming the
entry — the same abort path as FR-031.

---

## R3. Compression

**Decision.** **No compression** in this feature. Pack format id `0x00` (none) is
the only value written; the preamble reserves a byte so compression can be added
later without a version bump.

**Rationale.** FR-020f makes compression optional and warns that it makes
container size correlate with content compressibility — a disclosure the product
does not currently make. Declining it costs nothing the spec asks for, keeps the
streaming path simple, and avoids widening the threat model for a size win the
success criteria never mention.

---

## R4. Folder enumeration and metadata access

**Decision.** A new port, `DirectoryIoPort`, in `myenc_core/lib/src/ports/`,
implemented as `DirectoryIoDart` in `myenc_adapters`. It is the *only* way the
core learns anything about a real directory.

**Rationale.** Principle III: `myenc_core` cannot import `dart:io`, and
`FileIoPort` is file-shaped (`openRead`, `writeChunked`, `fileSize`) with no
notion of a tree, a symlink, an mtime, or a mode. Extending `FileIoPort` with
directory operations would make every existing adapter and test fake implement
methods irrelevant to single-file work; a separate port keeps both interfaces
small and the fakes honest.

**Symlink handling.** Enumeration MUST use a non-following stat
(`Link.target()` / `FileSystemEntity.type(followLinks: false)`), never a
following one. Following would both escape the selection root and allow an
unbounded-size capture — see FR-006 (cycles) and the Assumptions section.

---

## R5. Hostile packed streams — the unpack guard

**Decision.** A single chokepoint, `SafeUnpacker`, in `myenc_core`. Every entry
coming out of `TarReader` passes through it before any filesystem call. It
rejects, fail-closed, before writing a byte:

- absolute paths, and paths containing a root or drive prefix;
- any path segment equal to `..`, and any path that after normalisation does not
  start with the destination root;
- symlink targets that are absolute, or that resolve outside the destination
  root once joined to the link's own directory;
- hard links, device nodes, FIFOs, sockets, and any tar typeflag outside the
  defined subset;
- entries whose declared size disagrees with the bytes read;
- duplicate relative paths within one archive.

**Rationale.** FR-020d states it plainly: a container is attacker-supplied data
by the time it is restored, and its authentication proves only that it was
produced with the passphrase — not that its contents are benign. Successful
authentication is therefore **not** an argument for trusting the packed stream.
Concentrating the checks in one class is what makes them reviewable (Principle
III) and directly testable (SC-013).

**A note on ordering.** The guard runs on entries, and entries are only produced
after the secretstream authenticates each chunk. So a corrupt container fails at
a chunk tag (Principle IV) *before* the guard ever sees a malicious path — the
two defences are sequential, not alternatives.

---

## R6. Restore output staging — no reachable partial plaintext

**Decision.** Restore unpacks into a **temporary sibling directory** and only
then renames it into place as one step. Nothing is written under the final tree
name until the entire unpack has succeeded. On cancellation, failure, or worker
death, the temporary directory is removed recursively.

**Rationale.** Principle IV requires decrypt output to be written to a temporary
path and revealed only on success, and its cleanup is called out as a *security
property*, not tidiness. The existing single-file path already does this with
`<outPath>.tmp` swept by `AppCrypto._runBatch` on teardown. A folder is the same
problem one directory up: FR-021 ("MUST NOT reveal any part of the restored tree
at the destination before the restore is known to have succeeded") and FR-029
(no reachable partial plaintext) leave no other shape.

**Consequence to flag.** `AppCrypto._runBatch`'s teardown currently sweeps a
single `<outPath>.tmp` *file*. It must learn to sweep a staged *directory*
recursively, or a cancelled folder restore leaves partial plaintext on disk —
a security regression, not a cosmetic one.

---

## R7. Android — folder selection and restore destination

*Revisited 2026-09-29, after PRs #66, #74 and #78 changed the grant machinery
this decision rests on. The core decision stands; three things around it changed.*

**Decision.** Folder selection uses the existing SAF tree grant
(`SafBridge.pickTree` → `treeUriToPath`). The feature requires a **resolvable
real filesystem path** for both the source folder and the restore destination.
Where the path cannot be resolved — a cloud DocumentsProvider, a non-external
volume — the feature **refuses the selection with a clear explanation** under
FR-005 rather than degrading.

**Rationale.** The crypto worker is plain `dart:io` and has no platform channels
(`CLAUDE.md`, "Output path resolution"); it cannot walk a `content://` tree.
Enumerating and writing a whole tree through SAF from the main isolate would be a
second, much larger feature. FR-005 already requires refusing a selection the
system cannot safely process, and FR-034 requires *selection* to go through the
platform's folder-grant mechanism — which it does. Refusing loudly is compliant;
silently capturing a partial tree is not (FR-011, FR-032).

**The refusal case is narrower than it reads.** The unresolvable-source problem
documented for single files does **not** transfer wholesale to folders. It exists
because `ACTION_OPEN_DOCUMENT` hands back a document URI with no parent pointer,
so the *folder* cannot be named. Folder selection uses
`ACTION_OPEN_DOCUMENT_TREE`, which hands back the chosen folder's own document
id — path-shaped (`primary:Docs/Work`) for the external-storage provider that
backs ordinary on-device folders. `ExternalStorageDocIds` maps that to a real
path directly. So the common case resolves, and the refusal is reserved for cloud
and virtual providers, where refusing is the honest answer anyway (US5 scenario 4
already requires it, because such a folder cannot be fully read).

**The source grant is read *and* write, which removes a prompt.**
`pickTree` takes `FLAG_GRANT_READ_URI_PERMISSION or
FLAG_GRANT_WRITE_URI_PERMISSION` (`MainActivity.kt`). Selecting a folder to
encrypt therefore already carries write access to that folder, and
`existingTreeGrantFor` — which matches a grant covering the folder *or an
ancestor* — will find it when output placement runs. The ordinary case, "encrypt
this folder, put the `.latch` next to it", asks for access **once**, at selection
(FR-034a, SC-019). Anything that prompts a second time for the folder the user
just picked is a defect, not a platform constraint.

**Consequence #78 created: the grant shows up in "Save folders".** Persisted
grants are one undifferentiated pool. `SafTreeGrant` records uri, path, label and
grant time — nothing about why the grant was taken — and the settings screen is
titled **Save folders** with revoke copy reading *"Latch will lose write access
to …"*. A folder the user only ever encrypted would appear there described as a
save destination, which is inaccurate. FR-035a requires this be fixed; **how** is
a plan decision, and the cheap correct option is to change what the screen claims
rather than to start recording per-grant provenance, which would be exactly the
app-side grant bookkeeping FR-035 forbids. Note the platform cannot answer "why"
either: it records the grant, not the intent.

**Grant-cap pressure is real and one-directional.** The persisted table only
grows until the user gives something back, and at the platform ceiling Android
drops the *oldest* grant silently. Folder encryption is a new consumer of that
pool, so FR-035b forbids taking a grant the app already covers — `existingTreeGrantFor`
is the check, and it already matches ancestors, so a user who granted a parent
folder once is not re-prompted per child.

**Cancellation is now a real outcome (#74).** The destination prompt answers
granted / explicitly-chose-fallback / cancelled, and cancelling produces a
cancelled plan: nothing written, nothing staged, nothing remembered, and a
dismissed dialog reads as cancel rather than as consent. Folder operations
inherit this unchanged (FR-037a). This matters more for folders than for files:
planning runs before the worker, so a cancelled folder operation has not yet
packed anything, and the cheapest correct behaviour is also the safest one.

**Restore destination — a deliberate divergence from single-file decrypt.**
Single-file decrypt may fall back to Downloads with a banner. A folder restore
**MUST NOT**: FR-036 forbids restored plaintext passing through any shared or
world-readable location. So the destination is either a resolvable granted path
or **app-private storage** — never Downloads. This difference must be stated in
the UI copy, or a user will reasonably expect the Downloads fallback they have
seen before. Note this also means the "use the shared fallback" answer of the
three-outcome prompt is **not offered** for a restore; the prompt a restore shows
has two answers, a granted folder or cancel.

### The fallback nobody has costed: walking the tree through SAF

*Added 2026-09-30.* The decision above rests on one assumption — that a tree URI
resolving to a real path means the plain-`dart:io` worker can then **walk and read**
that path on API 30+. That assumption is untested, and the prior art argues
against it: Cryptomator's Android app has exactly one local-storage backend and it
is pure SAF (`data/.../cloud/local/`), with no `java.io.File` path anywhere in the
package and no non-SAF fallback for local folders. That is not proof — Cryptomator
models every backend as a "cloud provider", so SAF fits their abstraction
independently of the permission question — but a team that would obviously prefer
plain file access not having it is evidence. **Plan M1 assuming the SAF walk is
needed and run the device test to disprove it, not to confirm it.**

So the walk needs a cost model before it is needed, not after.

**The `DocumentIdCache` is not evidence that SAF enumeration is slow.** It is the
obvious thing to point at, and it is the wrong thing. Cryptomator's `list()`
(`LocalStorageAccessFrameworkImpl.kt`) is already the efficient shape: **one**
`contentResolver.query` per directory against
`buildChildDocumentsUriUsingTree(treeUri, parentDocId)`, with display name, MIME
type, size, last-modified and document id all in a single projection. The cache
exists for a different problem — their domain model addresses nodes by *path*,
SAF addresses them by *document id*, and SAF offers no path→id function. So
`listFilesWithNameFilter` resolves a path by listing the parent and filtering on
name, and resolving the parent recurses the same way: a directory listing per path
*segment*, per lookup. `DocumentIdCache` (an `LruCache<String, NodeInfo>` of 1000)
makes that O(1) instead of O(depth). It is a **random-access-by-path** cache.

A walk never does random access by path. It starts from the tree root's own
document id — which `ACTION_OPEN_DOCUMENT_TREE` hands back directly — and every
child row in the cursor already carries its own `COLUMN_DOCUMENT_ID`, which is
exactly what descending into that child requires. The pathological case that
forced Cryptomator's cache cannot structurally arise. Do **not** add a
path→document-id cache to this feature on their precedent.

**The cost model that does apply:** one binder round trip per **directory**, not
per entry, and the returned cursor already carries every column `EntryStamp` needs
— so there is no second per-file stat either. 10,000 files spread over a few
hundred directories is a few hundred queries. The count that matters is the
directory count, so the adversarial shape is a deep, wide tree of near-empty
directories, not a large file count. `MainActivity.childDisplayNames` already uses
this exact pattern for collision detection, so the primitive is in the repo.

**The real gap this exposes is not performance, it is that enumeration is
unbudgeted.** No success criterion bounds it. SC-005 governs progress *during*
work and, per R8, enumeration finishes before that stream starts; SC-010 requires
a folder be "fully enumerated" but says nothing about how long that may take. Yet
FR-003 and FR-004 put enumeration on the critical path *before* anything is
encrypted, which means a slow SAF walk surfaces as a dead screen with no progress
UI specified for it — the one failure mode the current criteria cannot catch. That
is a spec gap to close whichever way the device test goes, since the `dart:io`
walk of 10,000 entries is not instant either.

*(Noted in passing: SC-005 in `spec.md` reads "at least once per 1% of total
work", while `quickstart.md` S10 checks "at least once per second". The quickstart
is the stricter reading; they should be reconciled rather than left to diverge.)*

---

## R8. Progress reporting and the worker protocol

**Decision.** Reuse the existing worker→main protocol verbatim
(`file_start` / `progress` / `file_done` / `error` / `done`) with a **new `cmd`
value** — `pack_encrypt` and `decrypt_unpack` — and treat the whole folder as
**one** batch item. Progress is a two-stage weighted fraction: bytes packed and
encrypted, then, on restore, bytes unpacked.

**Rationale.** FR-012 makes the folder one container, so it is one unit of
success or failure — one `file_done`. FR-026 requires progress meaningful for
both "3 large files" and "10,000 small ones", which byte-weighted progress gives
and per-entry counting does not. Crucially, the **"last per-file result arrives
before the final 1.0" ordering invariant** (`test/app_crypto_batch_test.dart`,
Principle V) is a property of the protocol, not of the payload — keeping the
protocol unchanged is what keeps that invariant, and its test, valid.

**Total size must be known before the stream starts** for progress to be a
fraction (SC-005: progress advances at least once per second for 10,000 files).
Enumeration therefore happens **before** encryption begins — which FR-003 and
FR-004 already require, since the user is shown what was found and what will not
be preserved before anything is encrypted.

---

## R9. Testing strategy

| What | Where | Why there |
|---|---|---|
| Preamble encode/decode, unknown-kind rejection, reserved-byte rejection | `packages/myenc_core/test/` | Pure Dart, no platform. |
| `SafeUnpacker` against hostile streams (absolute path, `..`, escaping symlink, bad typeflag, size mismatch, duplicate path) | `packages/myenc_core/test/` | SC-013. Hand-built hostile tar streams — no filesystem needed to prove zero bytes escape. |
| Determinism: same tree packs to identical bytes twice | `packages/myenc_core/test/` | FR-020. |
| v1 freeze guards | `packages/myenc_core/test/codec_freeze_test.dart` (**unmodified**) | Principle II. If it fails, the change is wrong. |
| Golden folder container produced by Python (`tarfile` PAX + argon2-cffi + libsodium) | `packages/myenc_adapters/test/golden/` | Principle V — an oracle Dart did not produce. Committed alongside the existing v1 vectors, which keep passing. |
| Fidelity fixture round trip: known mtimes, an executable file, an internal symlink | `packages/myenc_adapters/test/` | SC-002, SC-014. Needs a real filesystem. |
| Archive-as-file: a `.zip` protected as a file restores byte-identical and is never expanded | `packages/myenc_adapters/test/` | SC-012, FR-020b — the bug this design exists to prevent. |
| Folder batch completion and the last-result-before-1.0 ordering | root `test/app_crypto_batch_test.dart` (plain `test()`) | Principle V and the FakeAsync gotcha: `testWidgets` cannot drive a real isolate. |
| Folder pick / review / progress / success screens | root `test/` `testWidgets`, real work inside `tester.runAsync` | Matches `test/e2e_flow_test.dart`; progress screens stay excluded. |

**Fixture creation caveat.** A fidelity fixture cannot be committed as a
directory with mtimes and symlinks intact — git does not preserve mtimes. The
fixture MUST be **built at test setup** from a declarative description, so the
mtimes and the executable bit are set by the test, not by the checkout.

---

## R10. Free space — there is no Dart API, so this needs a port

*Added 2026-09-29 for FR-029a, FR-005a.*

**Decision.** A new port, `FreeSpacePort`, with a single method
`Future<int?> freeBytesAt(String path)`. `null` means **unknowable**, and that is
a first-class answer, not an error. `PreflightCheck` refuses only on a *known*
shortfall; when the probe returns `null` it proceeds and the operation relies on
the existing FR-029 mid-run abort.

**Rationale — verified, not assumed.** `dart:io` exposes no free-space API. An
exhaustive grep of the SDK's `lib/io/` sources for `freeSpace`, `statvfs`,
`statfs`, `availableSpace`, `diskSpace` and `totalSpace` returns **zero matches**,
and `FileStat` carries exactly `type`, `mode`, `size`, `changed`, `modified`,
`accessed` — per-entry data only, nothing about the volume. Every option therefore
costs some platform surface, so the question is only which:

| Option | Verdict |
|---|---|
| Per-OS implementation behind a port (Android `StatFs(path)`, Apple `volumeAvailableCapacityForImportantUsageKey`, Linux/macOS `df -k`, Windows `GetDiskFreeSpaceEx`) | **Chosen.** A few dozen lines per platform, all of it readable, none of it in `myenc_core`. |
| `storage_space` (pub.dev) — evaluated in detail below | Rejected as a dependency, **kept as a reference implementation**. |
| `disk_space_plus` (pub.dev) — the only candidate that *does* take a path | Rejected as a dependency, **kept as a second reference implementation**. Wrong units, throws on an unstattable path, Android/iOS only. |
| `storage_info`, `universal_disk_space` | Rejected. `storage_info` splits storage into a fixed internal/external pair with no path argument. `universal_disk_space` is capped at `sdk <3.0.0` (last release 2021) and cannot be resolved by this project at all. |
| Any other third-party disk-space plugin | Rejected. Principle III's audit-surface argument bites harder on a plugin than on app code, and this is the smallest possible native call. |

### Why `storage_space` does not fit, and what it is still worth

Evaluated at v1.2.0 by reading the published package source, not the README.

**Its whole implementation is four lines**, and they are the right four:

```kotlin
// android/src/main/kotlin/flowmobile/storage_space/StorageSpacePlugin.kt
"getFreeSpace" -> { val stat = StatFs(Environment.getDataDirectory().path) ... }
```
```swift
// ios/Classes/SwiftStorageSpacePlugin.swift
documentDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
```

**The disqualifier is the API shape, not the quality.** `getStorageSpace({required int lowOnSpaceThreshold, required int fractionDigits})` takes **no path, directory or volume argument** — it returns one device-wide reading, from a hardcoded location on each platform. FR-029a's entire content is *which of two locations is short*, and this API cannot express the question. Against the four readings this feature needs:

| Reading | `storage_space` |
|---|---|
| Android staging (app cache, on `/data`) | ✅ `Environment.getDataDirectory()` is a fair proxy — the cache dir lives on that partition |
| Android destination on another volume (SD card, USB) | ❌ hardcoded to `/data`; returns the wrong volume's number, which is worse than `null` |
| iOS destination | ✅ iOS output *is* the app documents directory (`DefaultOutput.directoryFor`), which is exactly what it reads |
| macOS / Linux / Windows | ❌ not supported — the plugin declares Android and iOS only |

A dependency that confidently answers a **different** question than the one asked is worse than no dependency: on an SD-card destination it would report internal free space and let a doomed operation start, which is precisely the failure FR-029a exists to prevent. `null` at least routes correctly to "proceed, and rely on FR-029".

Secondary concerns, none decisive on their own: 2 of 6 platforms (150/160 pub points, the 10 lost are platform coverage); three releases in five years, the last 14 months ago; pub flags legacy Kotlin plugin configuration and no Swift Package Manager support; the `fractionDigits` / human-readable-string / `lowOnSpace` surface is presentation logic Latch already owns and would have to ignore.

**What it is worth keeping.** Its iOS line is the *correct* answer to a question we would otherwise have had to research: `volumeAvailableCapacityForImportantUsageKey`, not the older `NSFileSystemFreeSize`. On iOS those differ — the former accounts for space the system can reclaim, and is what Apple documents for "can I write this now". Use that key. Its Android line confirms `StatFs`, which needs only a path parameter added. The package is BSD-3-Clause, so vendoring either snippet with attribution is permitted; at four lines, reimplementing against a path argument is simpler than vendoring.

### `disk_space_plus` — right shape, wrong contract

Evaluated at v0.2.6 by reading the published source. It is the one package that
asks the question this feature asks: `getFreeDiskSpaceForPath(String path)`,
implemented as `StatFs(path)` on Android and
`URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])`
on iOS — **the same two calls chosen above, independently arrived at**. That is
useful corroboration and it corrects the over-broad claim that no package takes a
path.

It is still not adoptable, for four reasons that are about contract rather than
approach:

- **It returns megabytes as a `double`, not bytes.** Android computes
  `bytesAvailable / (1024f * 1024f)` — a *single-precision* division, widened to
  `Double` afterwards. FR-029a requires naming the shortfall in bytes; a rounded
  MB figure cannot.
- **It throws when the path is not statable**: the Dart wrapper begins
  `if (!Directory(path).existsSync()) throw Exception(...)`. `FreeSpacePort` MUST
  NOT throw and MUST return `null` where the platform will not answer — and a
  SAF-resolved destination on API 30+ is exactly the case that trips this.
- **Android and iOS only.** No desktop, where Latch's output normally lands.
- **No maximum-file-size probe** (R15), which needs the same native call site
  (`openFileDescriptor` → `ftruncate`). Owning the channel to get that anyway
  removes most of the saving a dependency would offer.

| Skip the check; rely on FR-029's mid-run abort alone | Rejected — it is exactly what FR-029a was written to stop. |

**Two locations, not one** (Android). The worker stages into app cache and the
main isolate relocates through SAF afterwards, so a container needs its size free
in the cache volume *and* at the destination; they are frequently different
volumes. The estimate must name **which** location is short (FR-029a) — "not
enough space" without a location is unactionable when one of the two is an SD
card.

**Estimating the container size.** `totalBytes` from `FolderSelection`, plus tar
overhead: 512 bytes of header per entry, per-entry padding to a 512-byte
boundary, two 512-byte trailer blocks, plus a PAX extended-header record for any
entry needing one. Add the secretstream's per-chunk MAC overhead
(`totalBytes / 65536 × 17`, using the existing `defaultChunkSize`) and the fixed
header. Round **up** and add a margin: an estimate that is optimistic produces the
mid-run failure this check exists to avoid, while a pessimistic one at worst
refuses a job that would just barely have fit — and says exactly how short it
thinks it is, so the user can disagree.

**What this does not cover.** A destination filesystem's **maximum file size**
(4 GiB on FAT32, the common case for a removable card) is *not* probeable: SAF
reports no filesystem type, and neither does `dart:io`. FR-005a asks for that
refusal before work begins; the design can only detect it at write time. Carried
as an open risk below — it is mapped to its own error and message rather than a
generic write failure, which is the part of FR-005a that *is* achievable.

---

## R11. Detecting an entry that changes mid-operation

*Added 2026-09-29 for FR-031a.*

**Decision.** `FolderScan` records `(kind, sizeBytes, modified)` per entry at
enumeration. `FolderPack` then, for each entry: re-stats immediately before
opening, streams the content while counting bytes, and re-stats after the last
byte. Any of five disagreements aborts the operation with a `SourceChangedError`
carrying the relative path **and** a `SourceChangeKind`:

| `SourceChangeKind` | Detected by |
|---|---|
| `disappeared` | pre-open stat returns `notFound` — **valid only for an entry that classified cleanly at enumeration**, see R12 |
| `kindChanged` | pre-open stat's type ≠ the recorded kind (a file replaced by a directory or a symlink) |
| `grew` | bytes read > declared size, or post-read size > declared size |
| `shrank` | stream ends before the declared size is reached |
| `modifiedWhileReading` | post-read mtime ≠ recorded mtime, with size unchanged |

**Rationale.** This is not gold-plating: tar declares each entry's length in its
header *before* the content, so a file that changes size mid-read produces a
stream whose own headers are wrong — a container that decrypts and authenticates
cleanly and then fails to unpack, or worse, unpacks to silently wrong bytes. The
size check was already required by R2 for correctness; FR-031a's contribution is
the **taxonomy**, so the report can say which of the five happened rather than
"the folder changed".

**This is detection, not prevention.** There is no portable way to lock a tree
against other processes, and Latch will not try: the honest guarantee is that a
container is never written from a tree that moved under it, not that trees cannot
move. The time-of-check/time-of-use gap between the post-read stat and the stream
close is real and unclosable; mtime granularity (1 s on some filesystems) means a
change within the same second as the read can escape the mtime check — which is
why the byte-count check, which cannot, carries the load.

---

## R12. Skipping what cannot be represented, instead of refusing

*Added 2026-09-29 for FR-002a, FR-002b. Refines R4.*

**Decision.** `FileSystemEntity.type(followLinks: false)` classifies every entry.
`file`, `directory` and `link` are packed. `unixDomainSock` and `pipe` are
**skipped**, recorded in `FolderSelection.unpreservable` by relative path, and
shown before encryption starts.

**`dart:io` cannot name a device node, and this changes the design.** Verified
against the SDK source and on-device: `FileSystemEntityType` has exactly six
values — `file`, `directory`, `link`, `unixDomainSock`, `pipe`, `notFound`. There
is **no** device/character/block value. A character device stats as `notFound`
with `size == -1`, identically to a path that does not exist:

```
/dev/zero  -> type=notFound  statType=notFound  size=-1  mode=---------
/dev/null  -> type=notFound  statType=notFound  size=-1
/dev/__nope__ -> type=notFound          (a path that genuinely does not exist)
```

But `Directory.listSync(followLinks: false)` **does** yield them — as plain
`File` objects (`/dev` lists 609 entries, `/dev/null` among them). So the
discriminator is not the stat, it is the pair:

| Condition | Classification |
|---|---|
| appears in the directory listing **and** stats `notFound` | **unrepresentable — skip** and report (FR-002a) |
| does not appear in the listing, stats `notFound` | does not exist |
| recorded at enumeration as a file, stats `notFound` at read time | `SourceChangeKind.disappeared` — **abort** (FR-031a) |

**Classification therefore MUST happen at enumeration**, where the listing is in
hand. The read-time `notFound` check may only be applied to entries that already
classified cleanly, because by then the listing is gone and `notFound` alone is
ambiguous. Getting this backwards inverts two requirements at once: a device node
in the tree would abort the whole operation as "disappeared" (violating FR-002a's
skip rule), and a genuinely deleted file would be silently skipped (violating
FR-031a's abort rule).

`FileStat.size == -1` is a useful corroborating signal but MUST NOT be the primary
test — it is not a documented sentinel.

**Platform variance.** `unixDomainSock` and `pipe` are POSIX concepts; on Windows
the enumeration simply never produces them, and the skip path is dead code there.
That is fine — it must still exist, because a `.latch` container is portable and
the *unpacking* side has no such luxury.

**Rationale.** A socket or FIFO in a source tree is nearly always incidental — a
running daemon's control socket inside a project directory. Refusing the whole
folder over one of them makes the feature unusable on exactly the trees developers
most want to protect, and the data those entries hold is zero bytes: there is
nothing to lose by skipping and everything to lose by aborting. Device nodes are
the same argument with a sharper edge — "capturing" `/dev/zero` is not a capture.

**No skip is silent.** The report is part of the pre-encryption review (FR-003)
and of the outcome, not a log line.

**macOS bundles are ordinary directories.** A `.app`, `.rtfd` or `.photoslibrary`
is a directory with a naming convention; it is captured in full, entry by entry,
under FR-002. The design deliberately does **no** bundle detection — no
`NSWorkspace`, no extension list. Treating a bundle as an opaque unit would need
a second packing path and would break the "same tree in, same tree out"
guarantee for every non-Apple platform the container might be opened on.

**The deletion coupling (FR-002b).** `OriginalDeletion` consumes the **captured
manifest** — the list of entries the container actually holds — and never a fresh
walk of the source tree. A fresh walk would re-find the skipped socket, the entry
that appeared after enumeration, and anything else outside the capture, and
delete an original the container does not protect. Consuming the manifest makes
that failure structurally impossible rather than guarded against.

---

## R13. Deleting the originals — mode, default, and where the setting lives

*Added 2026-09-29 for FR-041, FR-041a.*

**Decision.** Default mode: **shred each captured file** through the existing
secure-delete path (`AppCrypto.secureDeleteFiles`), then remove the now-empty
directories bottom-up, so entry *names* and directory *names* are destroyed too,
not just contents. A directory that is not empty after its captured children are
gone — because something was skipped under R12 — is **left in place**. The mode
is one `shared_preferences` enum, changed in an advanced setting
(`deletion_mode_screen.dart`), never asked per operation.

**Rationale.** Shredding contents while leaving `Tax Returns 2019/passport
scan.pdf` on the directory listing protects the wrong half. Removing the emptied
directories costs nothing and closes that gap. Reusing `secureDeleteFiles` keeps
one implementation of the overwrite logic and one place where its limits are
documented.

**The copy must state the limits.** Overwriting cannot be guaranteed on flash
storage: wear levelling means a write may land on a fresh block while the
original persists, and the app cannot see the mapping. Whatever the mode says, it
says it without overclaiming — FR-041a makes this copy a requirement, not a
nicety, and it is the same honesty rule the metadata report (FR-020e) follows.

**Why a setting and not a prompt.** A question on every operation trains the user
to dismiss it, which is how the destructive default gets chosen by reflex. One
decision, made once, in a place the user went looking for, with the reasoning in
front of them.

---

## R14. What Context7 could and could not answer

*Added 2026-09-29.* Recorded so the next person does not repeat the search.

| Question | Context7 | Resolved by |
|---|---|---|
| Free-space API in `dart:io` | **No coverage.** Its Dart corpus is the dart.dev *guides*, not `api.dart.dev`; a direct query returned no match. | Exhaustive grep of the SDK's `lib/io/` sources (R10) |
| `FileSystemEntityType` values | Not in the guide corpus | SDK source + an on-device probe (R12) |
| `package:tar` | **Not indexed at all.** Every `tar` hit is a JavaScript library (`tar-stream`, `modern-tar`, `napi-rs/tar`). | Already pinned at `tar: ^2.0.2` in `packages/myenc_core/pubspec.yaml` |
| A Flutter free-space plugin | **Not indexed.** `disk_space_plus` returns unrelated libraries. | Not needed — the port design (R10) does not use one |

**Rule for this feature: Context7 is the wrong tool for Dart/Flutter
*API-surface* questions.** It indexes guide prose and third-party library docs
well, and the SDK's own API reference not at all. For "does this API exist",
the Dart SDK sources are on disk at
`$(dirname $(which flutter))/cache/dart-sdk/lib/` and a five-line `dart run`
probe settles it in seconds. This matches the existing note about Android
platform research: for platform and SDK limits, go to the source, not to
documentation aggregators.

---

## R15. The maximum-file-size refusal — provoke it, do not query it

*Added 2026-09-29, resolving open risk 4 and the FR-005a deviation.*

**Decision.** Pre-flight the destination's maximum file size by **attempting the
allocation**, not by identifying the filesystem. Open the output file and
`truncate` it to the estimated container size; a refusal with `EFBIG` (errno 27)
is the answer. Run the probe only when the estimate exceeds 4 GiB, and treat any
other errno, or an unsupported operation, as **unknowable → proceed** — the same
rule R10 already applies to free space.

This **closes** the FR-005a deviation. The requirement can stand as written: a
container too large for the destination filesystem *is* refused before any work
begins.

### Why querying fails — checked against the real API surface

Read from `android.jar` at API 37 with `javap`, not from documentation:

| Class | What it exposes | Filesystem type? | Max file size? |
|---|---|---|---|
| `android.system.StructStatVfs` | 11 fields; `f_namemax` is the maximum **filename** length | No | No |
| `android.os.StatFs` | block counts and byte totals only | No | No |
| `android.os.storage.StorageVolume` | `isRemovable()`, `isEmulated()`, `isPrimary()`, `getState()`, `getUuid()`, `getDescription()` | No | No |

`isRemovable() && !isEmulated()` is the closest thing to a signal, and it says
"probably a card", not "FAT32" — an exFAT card would be refused wrongly and an
internal FAT partition missed. Heuristics of that shape are exactly what the
existing Android research note warns against. `/proc/mounts` is no better: under
scoped storage every app-visible path is fronted by FUSE, so it reports `fuse`
for the emulated volume and the real `vfat`/`exfat` mount under `/mnt/media_rw`
is SELinux-unreachable. **There is no supported query.**

### Why provoking works — measured, not reasoned

`FileSystemException.osError.errorCode` carries the raw errno (verified: a
missing path yields `2`/`ENOENT`). A FAT32 volume built with
`hdiutil create -fs MS-DOS` and probed from Dart gives:

| Target size | Result |
|---|---|
| 3 GiB | OK — but **3,728 ms** |
| 4 GiB − 1 | OK — but **6,329 ms** |
| 4 GiB | **REFUSED, errno 27 "File too large", 321 µs** |
| 5 GiB | REFUSED, errno 27 |
| 1 PiB | REFUSED, errno 27, **21 µs** |

The same probe on APFS returns OK in **0 ms** at 8 GiB and at 1 PiB, and `du`
reports **0 B** used — the file is sparse, so nothing is written.

Two properties make this cheap, and both are load-bearing:

1. **Refusal is instant** (microseconds) and leaves a **zero-length** file. The
   case the check exists for costs nothing.
2. **Success is free on any filesystem with sparse files** (ext4, APFS, NTFS,
   exFAT). It is slow only where success requires a real zero-fill — and FAT32,
   the one common filesystem without sparse files, refuses above 4 GiB rather
   than filling. Gating the probe at >4 GiB therefore keeps the slow path
   effectively unreachable. Cap it with a timeout anyway; a timeout reads as
   unknowable, not as a refusal.

**A failed probe must not be mistaken for a free-space failure.** `EFBIG` is "no
single file may be this large"; `ENOSPC` (28) is "not enough room" and belongs to
the R10 check with its own message. Distinguishing them is the whole reason to
read the errno rather than the exception text.

### Where it runs on Android

Not in Dart. The worker stages into the app cache (ext4), so a Dart-side probe
would measure the wrong volume. The probe belongs beside the existing SAF calls
in `MainActivity.kt`: `createDocument` → `openFileDescriptor("w")` →
`Os.ftruncate(fd, size)`, catching `ErrnoException`. Two notes:

- A cloud provider hands back a **pipe**, where `ftruncate` fails with `ESPIPE`
  or `EINVAL`. That is unknowable → proceed, and it is also already the
  `fellBackToDownloads` path.
- `StorageManager.allocateBytes(FileDescriptor, long)` is Android's own answer to
  the same question and is worth preferring where it applies; it reserves space
  and throws when it cannot, and `isAllocationSupported(fd)` says up front
  whether the fd's filesystem can do it. It does **not** replace the probe:
  `getAllocatableBytes` is scoped to internal and adopted volumes, which is to
  say not to the removable card this check exists for.

**Implication for `FreeSpacePort`.** The port grows a second method rather than a
second port — the two questions share one destination path and one native call
site:

```dart
/// Whether [path]'s volume will accept a single file of [bytes].
/// Null when the platform will not say. Null is NOT a refusal.
Future<bool?> canHoldSingleFile(String path, int bytes);
```

**Alternatives considered.** Identify the filesystem and consult a table of
limits — rejected above, unqueryable. Catch `EFBIG` at write time only — the
original fallback; still needed as a backstop, but it spends the whole encryption
before failing, which is what FR-005a exists to prevent. Refuse any container over
4 GiB on removable storage — rejected as a heuristic that punishes exFAT cards,
which are common and have no such limit.

---

## Open technical risks carried into Phase 1

1. **`_runBatch` teardown sweeps a file, not a tree** (R6). Security-relevant.
2. **Android metadata loss is expected, not exceptional** (FR-020e): the app
   sandbox will refuse the executable bit and symlinks routinely, so the
   "could not apply" report is a normal-path UI surface, not an error dialog.
3. **`package:tar` becomes a `myenc_core` dependency** — the first one beyond
   `test`. It is pure Dart and small, but it does enlarge the audit surface that
   Principle III's rationale is about. Recorded in Complexity Tracking.
4. **Maximum-file-size refusal is a probe, not a query** (R15). **Resolved** —
   no filesystem-type API exists on Android, but attempting the allocation and
   reading `EFBIG` answers the question in microseconds, so FR-005a stands as
   written. The residual risks are narrow: the probe must be gated at >4 GiB and
   timed out (a non-sparse filesystem that *accepts* large files would zero-fill),
   its errno must be told apart from `ENOSPC`, and on Android it must run natively
   against the SAF destination, never in Dart against the staging cache.
5. **Free-space probes can return `null`** (R10). Cloud-backed and unusual
   providers will. The design treats unknowable as "proceed" rather than
   "refuse", so FR-029a's guarantee is *best-effort on the destinations where the
   platform will answer* — the mid-run abort (FR-029) remains the backstop and
   must stay correct.
6. **Mid-operation change detection has an irreducible TOCTOU window** (R11), and
   1-second mtime granularity can hide a same-second modification. The byte-count
   check is the load-bearing one; the mtime check is supplementary.
