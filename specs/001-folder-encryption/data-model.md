# Phase 1 Data Model: Folder Encryption (UC-13)

Entities below are the concrete form of the spec's Key Entities. Each field
names the requirement that constrains it. Nothing here is persisted — every
structure is in-memory for the duration of one operation (FR-040).

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
| `unpreservable` | `List<UnpreservableItem>` | Devices, sockets, FIFOs — named and shown, never silently dropped (FR-004). |
| `refusal` | `SelectionRefusal?` | Non-null means the selection is refused outright (FR-005): a symlink cycle (FR-006), an unresolvable Android `content://` tree (R7), or an unreadable entry (FR-031). |

**Invariant.** Encryption may only start from a `FolderSelection` with
`refusal == null`. There is no "partial selection" state — FR-011 and FR-032 make
every container that exists a complete capture, so incompleteness can only ever
be a refusal, never an output.

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
