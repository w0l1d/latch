# Data Model: Bulk File Encryption

No persisted domain data; everything below is in-memory per operation except the two
preferences. Names are conceptual; field types are indicative.

## BulkOptions (per operation)
| Field | Type | Notes |
|---|---|---|
| `recursive` | bool | Default `false`, never persisted |
| `keyMode` | `perFile` \| `sharedPerBatch` | Initial value from `BulkSettings`; not re-asked mid-operation (FR-020) |
| `placement` | `mirroredFolder` \| `besideOriginals` \| `flatFolder` | Initial from `BulkSettings`; per-operation override allowed |
| `destinationRoot` | path / tree URI | Required when `placement = mirroredFolder` |
| `deleteSources` | bool | Encrypt: originals; decrypt: containers |

## BulkInventory (result of enumeration, main side)
- `root`: selected folder
- `items`: list of `BulkItem`
- `skipped`: list of `SkippedEntry` (relative path + concrete reason: symlink, unreadable, special file, not a container, newer version, empty)
- `totalBytes`: sum of item sizes (drives pre-flight and byte-weighted progress)
- Invariant: every enumerated entry is in exactly one of `items` / `skipped` — silence is impossible.

## BulkItem
`sourcePath`, `relativePath` (from root, `/`-normalised, no `..`), `sizeBytes`,
`stampAtEnumeration` (kind/size/mtime, for change detection), `outRelPath` (derived:
`<relativePath>.latch` on encrypt; `.latch` stripped on decrypt, with collision rename).

## BatchWrapKey (core, in-memory only)
`salt` (16 random bytes), `kek` (Argon2id output, zeroed on `dispose()`), `opslimit`,
`memlimit`. Lifetime = one operation. Never serialised, never stored (FR-023).

## BulkFileOutcome (extends existing `BatchResult`)
`path`, `ok`, `errorMessage`, `outPath`, plus `verified` (bool, encrypt/decrypt with
deletion) and `sourceRemoved` (bool). Failure of one item never alters another's
outcome (FR-011/012).

## Preferences
`bulk.keyMode`, `bulk.outputPlacement` — see `contracts/settings.md`.

## State transitions (per item)
`enumerated → staged → [verified] → relocated → [source removed]`
Any failure → `failed` (source untouched, staged output deleted). Cancel → all
`staged` swept; items already `relocated` stay (and are reported), sources of
unverified items untouched.
