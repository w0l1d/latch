# Research: Bulk File Encryption

Each decision: Decision / Rationale / Alternatives. All spec-level unknowns were
closed in `/speckit-clarify`; what follows are the planning-level choices.

## R1. Shared-KEK batch mode without touching the format

**Decision.** Add `BatchWrapKey` (pure Dart, `myenc_core`): holds one random 16-byte
salt and the KEK = Argon2id(passphrase, salt, params), derived once per operation.
`EnvelopeService.encrypt` takes an optional `BatchWrapKey`; when present it skips the
per-file `randomBytes(16)` salt and Argon2 call, writes the shared salt into the header,
and wraps that file's *own freshly generated DEK* with `secretboxSeal(dek, kek)`.
Body encryption (secretstream, fresh stream header) is untouched. The KEK is zeroed
when the operation ends, in `finally`.

**Rationale.** v1 already defines a per-header salt and a wrap that is just
`secretbox(dek, kek)`. Decrypt derives from *the header's* salt, so a container that
happens to share a salt with its siblings decrypts through the unchanged path. There
is therefore nothing to mark (FR-022), no version bump (Principle II), and no decrypt
change. Nonce safety: the secretbox nonce is random per wrap, so a shared KEK is safe
across files. Costs are exactly the three the spec records: attacker cost no longer
multiplies per file, containers are linkable by salt, and they share a fate (crack
one salt → all).

**Alternatives.** (a) New wrap type / flag byte — format change, rejected outright.
(b) Derive per file but parallelise across isolates — keeps independence but uses N×64
MiB of RAM on phones; kept as a non-goal. (c) Cache the KEK across operations —
violates FR-023 (scope: one operation).

## R2. Identifying containers on bulk decrypt

**Decision.** `ContainerSniffer.looksLikeLatch(Uint8List firstBytes)` in `myenc_core`:
true when the magic matches **and** `MyencCodec.decodeHeader` accepts the fixed prefix
(version known, lengths sane). Extension is never consulted (spec clarification C).
Unknown *newer* version → reported as "made by a newer Latch", not silently skipped,
mirroring `VersionTooNewError`. The walk reads at most the fixed header prefix per
file (56 bytes + wraps); a file that is too short or has a bad magic is skipped and
listed, never an error for the batch.

**Rationale.** Extension-based filtering both misses renamed containers and wrongly
processes arbitrary `.latch` files; a header check is cheap (one small read per file)
and reuses codec logic so it cannot drift from the real decoder.

**Alternatives.** Extension match (rejected by spec); try-decrypt-and-see (costs a
64 MiB Argon2 per non-container).

## R3. Walk and free-space ports: share 001's shape, land first here

**Decision.** 004 lands `DirectoryIoPort` (subset: `walk`, `stat`, `createDirectory`)
and `FreeSpacePort` with the **same signatures as 001's `contracts/ports.md`**, plus
the sync-`dart:io` adapter note from 001. 001 adopts them on rebase instead of
re-creating them. Bulk walks use `Isolate.run` so a 10,000-entry walk never blocks the
UI. Symlinks are not followed; unreadable/special entries are skipped *and listed*.

**Rationale.** 004 is the earlier-shipping slice; duplicating ports would force an
adapter merge conflict later. The contract was already reviewed in 001. Tradeoff: 001
branch needs a rebase and its T008 (ports) shrinks.

**Alternatives.** Private walk helper in `lib/core` (duplicates 001 and cannot be
tested hexagonally); wait for 001 (defeats the "early solution" goal).

## R4. Verified deletion

**Decision.** In `_encryptOne`, after the container is fully written and closed, when
`deleteOriginals` is set: reopen the *container*, decrypt it through the same
secretstream path (requireFinalized), compare plaintext to the source in lockstep
chunks, and delete the original only on exact equality and matching length. Any
mismatch → keep original, delete nothing, mark that file failed with a typed
reason. The decrypt side of "delete containers after decrypt" (FR-035b) uses the
same compare against the plaintext it just wrote.

**Rationale.** Today's flow trusts the write. For bulk, one bad flash block across
5,000 files is the failure mode the spec wants closed. Cost ≈ one extra decrypt per
file, disclosed in the UI (FR-033a). Argon2 is not re-run: the verifier re-unwraps the DEK from the written
container's wrap with the already-held KEK (so a broken wrap cannot pass), then
decrypts the body. On verification failure the container is deleted, the original
kept, and the file reported by name (FR-033c). For decrypt (FR-035b) the verifier
re-reads the container a second time, independently decrypts it, and compares to
the restored file; container deleted only on exact match, kept and named otherwise
(FR-035c).

**Alternatives.** Trust write success (status quo; rejected in clarify); hash-only
check (can't catch encryption bugs the way a real decrypt does).

## R5. Settings

**Decision.** `BulkSettings` in `lib/core` over `shared_preferences`:
`bulk.keyMode` (`perFile` default | `sharedPerBatch`), `bulk.outputPlacement`
(`mirroredFolder` default | `besideOriginals` | `flatFolder`, FR-028). Recursion is **not** persisted —
off every operation (spec). Per-operation override lives in route `extra`, not in
prefs. Batch mode is in advanced settings and never asked mid-operation (FR-018/020).

**Rationale.** Matches existing patterns (`passphrase_storage_service`, prefs-backed
policy). Preferences, not secrets; no keychain needed.

**Alternatives.** Secure storage (unneeded); persisting last-used recursion
(violates default-off intent).

## R6. Android output: mirrored tree through one grant

**Decision.** Reuse stage-then-relocate: the worker writes the mirrored tree under
an app-cache staging dir; `relocateStagedOutputs` moves each file via
`SafBridge.createInTree` with `subPath` = the file's relative directory. **Open
item:** confirm `createInTree` creates *missing intermediate* folders under the
`subPath`; if it only addresses an existing folder, extend the native method to
`createDirectory` per missing segment (JVM-testable via a framework-free path-split
helper, same pattern as `ExternalStorageDocIds`). One tree grant, taken at the chosen
folder (FR-036/038); `existingTreeGrantFor` first so a covering grant is never
re-requested (FR-038).

**Rationale.** The worker has no platform channels; this is the established pattern.
Decrypt output never transits Downloads; a folder bulk-decrypt that cannot reach
the chosen grant **cancels rather than falling back** (FR-040 amended 2026-10-04) (mirrors 001's restore rule —
bulk plaintext must not land in a shared location silently).

**Alternatives.** `MANAGE_EXTERNAL_STORAGE` (rejected in CLAUDE.md); writing
directly into SAF from the worker (impossible).

**Carried risk.** Whether the plain-`dart:io` worker can *read/walk* the picked
folder's real path on API 30+ is the same untested assumption as 001 R7. Plan the
device test first and design for it to fail (see tasks phase).

## R7. Worker protocol: extend task maps, keep messages

**Decision.** `encrypt` / `decrypt` tasks gain `outRelPath` per file and a batch-level
`keyMode`. Messages stay `file_start` / `progress` / `file_done` / `error` / `done`;
the per-file result still precedes final `1.0`. The **pre-flight space check and
walk run before spawn on the main side**, so a refusal stages nothing (nothing to
sweep). Staged-directory sweep on teardown (001 §4) is required here too, because
bulk decrypt stages a tree of plaintext.

**Rationale.** Keeps `app_crypto_batch_test.dart` valid; no new command means no new
protocol surface to pin.

## R8. Unmapped risks accepted

- **Shared-salt linkability** is by design in opt-in mode; surfaced in the UI
  comparison (spec "Key derivation modes, in plain language").
- **Name collisions on mirror** use the existing `resolveNameCollision` per output.
- **Source changes mid-run**: per-file stat before/after; a changed file fails *that
  file* only (not the batch).
