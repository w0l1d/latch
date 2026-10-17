# Phase 1 Data Model: Folder Encryption (UC-13)

Entities below are the concrete form of the spec's Key Entities. Each field
names the requirement that constrains it. Everything here except `DeletionMode`
is in-memory for the duration of one operation and is never written down
(FR-040); `DeletionMode` is a single stored enum naming a user preference, not a
folder (FR-041a).

---

## PayloadKind (enum, extensible)

The authenticated indicator that decides how a payload is interpreted
(FR-020b, FR-020c, FR-020g).

| Name | Wire value | Meaning |
|---|---:|---|
| `singleFile` | `0x01` | Payload is one file's bytes, restored byte-for-byte. |
| `packedFolder` | `0x02` | Payload is a packed directory tree, expanded on restore. |

**Rules.**

- Encoded as **one byte** with 253 unused values, so a future kind needs no
  version bump (FR-020g).
- `0x00` is **not** a valid kind — it is reserved so that an all-zero preamble,
  the most likely shape of accidental garbage, is rejected rather than
  interpreted.
- Any value outside the table MUST raise `UnknownPayloadKindError`, surfaced as
  "made by a newer version of Latch" — distinct from wrong-passphrase and from
  corruption (FR-020h).
- Absence of a preamble (a v1 container) means `singleFile`. v1 containers are
  never rewritten (FR-014).

---

## PayloadPreamble

Fixed 8 bytes at the start of a v2 container's **plaintext**. Normative layout in
[`contracts/payload-preamble.md`](./contracts/payload-preamble.md).

| Field | Size | Validation |
|---|---:|---|
| `magic` | 4 | Must equal the defined constant, else `CorruptedFileError`. |
| `kind` | 1 | Must be a defined `PayloadKind`, else `UnknownPayloadKindError`. |
| `packFormat` | 1 | `0x00` none, `0x01` tar-PAX subset. Must be `0x01` iff `kind == packedFolder`. |
| `compression` | 1 | `0x00` none. Any other value → `UnknownPayloadKindError` (a newer writer). |
| `reserved` | 1 | MUST be `0x00`. Non-zero → `UnknownPayloadKindError`. |

**Why fixed-width and not a varint or a length-prefixed blob:** the preamble is
the first structure parsed out of attacker-influenced plaintext. Eight bytes with
no length field and no loop cannot be made to over-read.

---

## FolderEntry

One item discovered in the tree, and one record in the packed stream.

| Field | Type | Constraint |
|---|---|---|
| `relativePath` | `String` | Relative to the selection root, `/`-separated, UTF-8, never empty, never absolute, no `..` segment (FR-020d). |
| `kind` | `file` \| `directory` \| `symlink` | Anything else is *unpreservable* — reported under FR-004, never packed. |
| `sizeBytes` | `int` | Files only. Declared in the tar header **before** content; a mismatch against bytes actually read aborts the operation (R2). |
| `modified` | `DateTime` | In scope (FR-020a), to the granularity the destination filesystem supports. |
| `executable` | `bool` | The **only** permission bit in scope (FR-020a). |
| `linkTarget` | `String?` | Symlinks only. Recorded verbatim, never followed (R4). Must resolve inside the destination root on restore (FR-020d). |

**Out of scope by construction:** creation time, the rest of the POSIX mode,
uid/gid, extended attributes. The tar subset has nowhere to put them, so no test
can accidentally depend on them (FR-020a).

---

## FolderSelection

The result of enumeration, shown to the user **before** anything is encrypted
(FR-003, FR-004).

| Field | Type | Notes |
|---|---|---|
| `rootPath` | `String` | The selected folder. |
| `rootName` | `String` | Recorded so a restore can rebuild under the original name (FR-010). |
| `entryCount` | `int` | Files + directories + symlinks that will be packed. |
| `totalBytes` | `int` | Needed *before* the stream starts so progress can be a fraction (FR-026, SC-005). |
| `unpreservable` | `List<UnpreservableItem>` | Devices, sockets, FIFOs — **skipped**, named by relative path, shown before encryption starts and again in the outcome. Never silently dropped (FR-002a, FR-004). |
| `snapshot` | `Map<String, EntryStamp>` | Per-entry `(kind, sizeBytes, modified)` recorded at enumeration, compared again at read time to detect a source changing underneath the operation (FR-031a, R11). |
| `refusal` | `SelectionRefusal?` | Non-null means the selection is refused outright (FR-005, FR-005a): a symlink cycle (FR-006), an unresolvable Android `content://` tree (R7), an unreadable entry (FR-031), or a known space shortfall (FR-029a). |

**Invariant.** Encryption may only start from a `FolderSelection` with
`refusal == null`. There is no "partial selection" state: every container that
exists holds **everything in scope under FR-002** (FR-011, FR-032). Entries
skipped under FR-002a are *outside* that scope, not gaps in it — which is why
they are reported to the user before the operation starts, so the scope they are
consenting to is the scope they can see.

**`entryCount` and `totalBytes` are uncapped** (FR-003a). A selection large enough
to be worth mentioning produces a warning in the review screen; a warning is not
a refusal, and there is no threshold at which the app declines on its own
judgement. Only a platform limit refuses (FR-005a).

---

## UnpreservableItem

One entry the format cannot represent, skipped rather than fatal (FR-002a).

| Field | Type | Notes |
|---|---|---|
| `relativePath` | `String` | Relative to the selection root — the user must be able to find it. |
| `reason` | `socket` \| `fifo` \| `unrepresentable` | Named concretely; "unsupported" alone is not a report. |

`socket` and `fifo` come straight from `FileSystemEntityType`. **`unrepresentable`
is the device-node case and cannot be named more precisely**: `dart:io` has no
device value in `FileSystemEntityType`, and a character device stats as
`notFound` exactly like a path that does not exist. The classifier identifies it
as *present in the directory listing but stat-invisible* — a real condition with
no more specific name available (R12). User-facing copy must therefore say what
was observed ("this item could not be read as a file") and not guess at a kind.

**A skip is never silent** and never a failure. macOS bundles are **not** in this
enum: a `.app` or `.photoslibrary` is an ordinary directory and is captured in
full under FR-002 (R12).

---

## EntryStamp / SourceChangeKind

The FR-031a change-detection pair. `EntryStamp` is `(kind, sizeBytes, modified)`,
recorded per entry at enumeration.

| `SourceChangeKind` | Meaning reported to the user |
|---|---|
| `disappeared` | The entry no longer exists. Only ever raised for an entry that classified cleanly at enumeration — a `notFound` stat is ambiguous on its own (R12). |
| `kindChanged` | A file became a directory or a symlink, or vice versa. |
| `grew` | More bytes than declared. |
| `shrank` | Fewer bytes than declared. |
| `modifiedWhileReading` | Same size, different modification time. |

**Ordering rule (load-bearing).** Classification happens **at enumeration**, where
the directory listing is in hand; change detection happens at read time against
the recorded `EntryStamp`. Reversing this inverts two requirements simultaneously
— a device node would abort as "disappeared" (violating FR-002a) and a genuinely
deleted file would be skipped (violating FR-031a). See R12.

**Rule.** Any of these aborts the whole operation and the report MUST carry the
**relative path and the kind**. "The folder changed" is not a conforming report
(FR-031a). Detection is best-effort against an unclosable TOCTOU window (R11);
the byte-count comparison is the load-bearing check, the mtime comparison is
supplementary.

---

## PreflightEstimate

Computed before any work begins (FR-029a), never persisted.

| Field | Type | Notes |
|---|---|---|
| `estimatedContainerBytes` | `int` | `totalBytes` + tar header/padding/trailer + secretstream MAC overhead, rounded **up** with a margin. Optimism here produces the mid-run failure this check exists to prevent. |
| `destinationFreeBytes` | `int?` | `null` = the platform would not say (R10). |
| `stagingFreeBytes` | `int?` | Android only; `null` elsewhere, where there is no staging step. |
| `shortfall` | `Shortfall?` | Non-null ⇒ refuse. Carries the **number of bytes short and which location** — destination or staging — because on Android they are routinely different volumes (FR-029a). |
| `largeSelectionWarning` | `bool` | Advisory only; never gates (FR-003a). |

**A `null` free-space reading is "proceed", not "refuse".** The guarantee FR-029a
buys is *refuse early where the platform will answer*; FR-029's mid-run abort
stays the backstop and must remain correct.

---

## CapturedManifest

The list of entries the finished container demonstrably holds. Produced by the
pack, consumed by `OriginalDeletion`.

**Invariant (FR-002b).** Deletion of originals iterates **this**, never a fresh
walk of the source tree. A fresh walk would re-find the skipped socket and
anything that appeared after enumeration, and delete a source the container does
not protect. Consuming the manifest makes that structurally impossible rather
than merely guarded against.

---

## DeletionMode

The one persisted value this feature adds (FR-041a). A `shared_preferences` enum;
it names no folder and reveals nothing about what was protected, so it does not
conflict with FR-040.

| Value | Behaviour |
|---|---|
| `shredThenRemoveDirs` | **Default.** Each captured file is shredded through the existing secure-delete path; the emptied directories are then removed bottom-up, so entry and directory *names* die with the contents (FR-041). A directory still holding a skipped entry is left in place. |
| `plainDelete` | Ordinary deletion. Faster, recoverable by forensic tools. |
| `keepOriginals` | Nothing is deleted. |

**Rules.** The setting lives in advanced settings and MUST NOT be posed as a
question on every operation — a per-run prompt trains dismissal, which is how the
destructive option gets chosen by reflex. The copy MUST state what each mode does
**and its limits**: overwriting cannot be guaranteed on flash storage, because
wear levelling may leave the original block intact and the app cannot see the
mapping (FR-041a). Deletion runs only after the container is written and
verified, and only over the `CapturedManifest`.

---

## FolderRestorePlan

| Field | Type | Notes |
|---|---|---|
| `destinationRoot` | `String` | The final tree path. Never a shared or world-readable location (FR-036) — resolvable granted path or app-private storage only, **never Downloads** (R7). |
| `stagingRoot` | `String` | Temporary directory the unpack writes into. Renamed onto `destinationRoot` as one step on success; removed recursively on any failure, cancellation, or worker death (FR-021, FR-029, Principle IV). |
| `collisionPolicy` | `renameNew` | A restore never overwrites, merges into, or deletes anything already at the destination (FR-019); a name clash produces a fresh name, mirroring `resolveNameCollision`. |

---

## MetadataApplicationReport

Produced by a restore, surfaced to the user (FR-020e).

| Field | Type | Notes |
|---|---|---|
| `executableBitSkipped` | `int` | Count of entries whose executable bit could not be applied. |
| `symlinksMaterialised` | `int` | Links the platform could not create as links. |
| `mtimesSkipped` | `int` | Entries whose modification time could not be set. |

**This is a normal-path surface, not an error.** Inside the Android and iOS app
sandboxes these counts are routinely non-zero. A restore with a non-empty report
still **succeeded** — it MUST NOT fail the entry, and it MUST NOT report
unqualified success either (FR-020e).

---

## OperationOutcome (existing, unchanged shape)

A folder is **one** batch item, so it produces exactly one `BatchResult`
(`path`, `ok`, `errorMessage`, `outPath`) — FR-012 makes the folder a single unit
of success or failure. Keeping the existing shape is what preserves the
"last per-file result arrives before the final 1.0" invariant and the test that
pins it (R8, Principle V).
