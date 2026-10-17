# Tasks: Folder Encryption (UC-13)

**Input**: Design documents from `specs/001-folder-encryption/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md), `.specify/memory/constitution.md` v1.0.0

**Tests**: Test tasks ARE included. This is not a preference — the spec's
"User Scenarios & Testing" section is mandatory, and Principle V requires
cryptographic behaviour to be pinned by an oracle the Dart code did not produce.
Two tasks in the final phase are **constitutional gates, not optional polish**.

**Organization**: Grouped by user story. The engine that every story needs sits
in Foundational; each story phase then adds one independently demonstrable
increment.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on incomplete work)
- **[Story]**: `[US1]`–`[US5]`, mapping to the user stories in spec.md
- Every task names its exact file path

## Path Conventions

Three packages, each analyzed and tested separately (there is no single command
for all three):

- `packages/myenc_core/` — pure Dart. **No Flutter, no `dart:io`.**
- `packages/myenc_adapters/` — port implementations, Flutter + `dart:io`
- `/` — the Flutter app (`lib/`, `test/`, `android/`)

---

## Phase 1: Setup

**Purpose**: Get the one new dependency and the new error vocabulary in place.

- [X] T001 Add `tar: ^2.0.2` to `dependencies` in `packages/myenc_core/pubspec.yaml`, then run `flutter pub get` at the repo root to resolve the path-deps; confirm `packages/myenc_core/lib/` still has zero `dart:io` and zero Flutter imports
- [X] T002 Add `UnknownPayloadKindError` (carries the offending byte value) and `UnsafeArchiveEntryError` (carries the offending relative path) to the `sealed class LatchError` hierarchy in `packages/myenc_core/lib/src/format/myenc_errors.dart`
- [X] T003 Export the new errors and the forthcoming preamble/pack symbols from `packages/myenc_core/lib/myenc_core.dart`
- [X] T004 Add human copy for both new errors to `userMessageForError` in `lib/shared/error_messages.dart` — "made by a newer version of Latch" for the unknown-kind case, distinct from the existing corruption and wrong-passphrase copy; never interpolate raw exception text

**Checkpoint**: `flutter analyze --no-pub` clean in all three packages.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The `.latch` v2 format, the directory port, and the hostile-input
guard. Everything here is needed by every user story and none of it is
user-visible yet.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. T014
in particular is a security fix that must land before any UI can trigger a
restore.

- [X] T005 Create `packages/myenc_core/lib/src/format/payload_preamble.dart` with the extensible `PayloadKind` enum (`singleFile` `0x01`, `packedFolder` `0x02`; `0x00` reserved and invalid) plus fixed-width 8-byte encode/decode, per `contracts/payload-preamble.md` §3
- [X] T006 Implement the ordered validation of `contracts/payload-preamble.md` §5 in `payload_preamble.dart`: bad magic → `CorruptedFileError`; undefined kind, non-zero compression, non-zero reserved → `UnknownPayloadKindError`; kind/pack-format disagreement → `CorruptedFileError`. Stop at the first failure and never return a partially-parsed preamble
- [X] T007 [P] Add `packages/myenc_core/test/payload_preamble_test.dart` covering every branch of T006, including `0x00` kind, an undefined kind, a non-zero reserved byte, a truncated preamble, and the exact error type raised for each — SC-015, FR-020g, FR-020h
- [ ] T008 Register version 2 as one row in `FormatVersionRegistry.all`
  (`packages/myenc_core/lib/src/format/format_version.dart`) and add its layout as
  one `FormatVersionStrategy` in
  `packages/myenc_core/lib/src/format/format_strategy_v2.dart`, keyed into
  `formatVersionStrategies`. v2's header layout is **identical to v1's** — the
  preamble lives in the ciphertext, not the header — so the strategy may delegate
  to `V1Strategy` rather than restate offsets. Add no version comparison anywhere:
  the fail-closed refusal of unknown versions already lives in
  `FormatVersionRegistry.require` and `MyencCodec.decodeHeader`, and must not be
  duplicated (FR-013a, FR-013d)
- [ ] T008a Leave `FormatVersionRegistry.writeDefault` at v1. Registering v2
  widens what can be *read* and must not change what single-file containers are
  *written* as (FR-013b). Add a test pinning `writeDefault.number == 1` with the
  reason in its name, so a later "tidy-up" that derives it from `all`'s maximum
  fails loudly instead of silently orphaning every older install
- [ ] T008b Add `packages/myenc_core/test/format_version_totality_test.dart`
  coverage for v2 — or extend the existing totality test from specs/003 if it
  already iterates the registry — asserting the registry's version set and
  `formatVersionStrategies`' key set agree in **both** directions. A registered
  version with no strategy must be a red test, never a runtime failure on a user's
  file (FR-013a)
- [ ] T009 Run `packages/myenc_core/test/codec_freeze_test.dart`,
  `packages/myenc_adapters/test/golden_vectors_test.dart`, and the compatibility
  corpora committed by specs/002 and specs/003, and confirm all pass **with the
  test files and their expected values unmodified**. If any fails, the v1 layout
  moved — revert, do not edit the test (Principle II, FR-013, FR-013e, SC-009,
  SC-018)

> **✅ The former T009 blocker is resolved.** It is kept here as the record of
> why the version machinery exists. The guard used to hardcode `2` as its example
> of an unknown version, which went stale the moment v2 was defined, because
> `myenc_core` had no central place to ask what a version means. Both refactors
> that fixed it have since shipped into `develop`:
> **[specs/002-format-version-registry](../002-format-version-registry/spec.md)**
> (the registry, PRs #59 and #61) and
> **[specs/003-codec-version-strategies](../003-codec-version-strategies/spec.md)**
> (the per-version strategy seam and the totality invariant, PR #63).
>
> The interim edits this branch once carried — `maxReadableVersion` /
> `versionWithPayloadPreamble` on `FileHeader`, the hand-rolled gate in
> `myenc_codec.dart`, and `test/version_gate_test.dart` — were dropped in commit
> `fefc408` as superseded. Do not reintroduce them in any form; T008 is now
> additive only.
- [ ] T010 Teach `EnvelopeService.encrypt` in `packages/myenc_core/lib/src/domain/envelope_service.dart` to prepend the preamble to the plaintext stream and write version `0x02` when a preamble is requested; when none is requested it must emit v1 byte-identically to today (FR-014)
- [ ] T011 Teach `EnvelopeService.decrypt` in the same file to consume and validate the preamble when the header version is `2`, and to treat a v1 container as `singleFile` with no preamble. Preamble validation must run after the first chunk authenticates and must emit zero payload bytes on failure (`contracts/payload-preamble.md` §6)
- [ ] T012 [P] **Extend** `packages/myenc_core/lib/src/ports/directory_io_port.dart` to the full interface in `contracts/ports.md` §1. **Partly landed by 004**: the file and `FolderEntry`/`EntryStamp` exist with `walk(root, {recursive})`, `stat` and `createDirectory`; what is left here is `directoryExists`, `deleteDirectory`, `createSymlink`, `setModified`, `setExecutable`, `renameDirectory`. Do not recreate the port. `createSymlink`/`setModified`/`setExecutable` return `bool` rather than throwing, because a platform refusal is the normal path in the Android and iOS sandboxes
- [ ] T013 **Extend** `packages/myenc_adapters/lib/src/io/directory_io_dart.dart` (landed by 004 at this path, not `src/directory_io_dart.dart`) to implement the methods T012 adds; `walk`/`stat`/`createDirectory` and their tests (`packages/myenc_adapters/test/directory_io_dart_test.dart`) already exist. `walk` must use non-following stats (`FileSystemEntity.type(followLinks: false)`, `Link.target()`), yield entries in byte-wise sorted relative-path order, and detect and refuse symlink cycles (FR-006, R4)
- [x] T014 *(landed by 004; `AppCrypto._runBatch` removes `stagingDir` recursively on teardown, pinned by the real-isolate test 'cancelling a mirrored decrypt sweeps the staging tree' in `test/app_crypto_bulk_test.dart`. Reuse it for pack/unpack staging; nothing left to build here.)* Extend the teardown sweep in `AppCrypto._runBatch` (`lib/core/app_crypto.dart`) to remove a staged output **directory** recursively, not only a single `<outPath>.tmp` file. Without this a cancelled folder restore leaves partial plaintext on disk — a Principle IV violation, which is why it lands before any restore UI exists
- [ ] T015 Create `packages/myenc_core/lib/src/domain/safe_unpacker.dart` as the single chokepoint enforcing all eight read-side rejections in `contracts/pack-format.md` §6. Every entry passes through it before any filesystem call; a rejection raises `UnsafeArchiveEntryError` naming the relative path
- [ ] T016 [P] Add `packages/myenc_core/test/safe_unpacker_test.dart` with a hand-built hostile tar stream per rejection: absolute path, `../` traversal, escaping symlink target, hard link, FIFO, device node, declared-size mismatch, duplicate relative path, empty path. Assert zero bytes are written outside the destination root — SC-013, FR-020d
- [ ] T017 [P] Add `packages/myenc_core/test/envelope_v2_test.dart` proving the three failures stay distinguishable and ordered on the same v2 container: wrong passphrase fails at the DEK unwrap before any body chunk; a flipped body byte fails at a chunk tag; a flipped preamble byte fails as corruption at the first chunk's tag — FR-022, FR-023, FR-020c, Principle IV

**Checkpoint**: v2 exists, v1 is provably unharmed, hostile streams write nothing,
and cancellation can no longer leave a staged tree behind.

---

## Phase 3: User Story 1 — Latch a folder and get it back (Priority: P1) 🎯 MVP

**Goal**: A user selects a folder, gets exactly one `.latch` container, and
restores it to the same tree with byte-identical names and content.

**Independent Test**: Protect a folder of nested files, restore it, and diff the
trees — identical. Exactly one container was produced, never one per file.
Separately, protect a user-supplied `.zip` **as a file**: it comes back
byte-for-byte identical and is never expanded.

### Tests for User Story 1

- [ ] T018 [P] [US1] Add `packages/myenc_core/test/folder_pack_test.dart`: packing the same tree twice yields byte-identical streams, entries appear in sorted order, directories precede their contents, and `uid`/`gid`/`userName`/`groupName` carry no ambient state — FR-020, `contracts/pack-format.md` §4
- [ ] T019 [P] [US1] Add `packages/myenc_adapters/test/folder_round_trip_test.dart`: a nested folder round-trips with every entry at its original relative path, byte-identical content, byte-identical names, and restoring twice yields identical trees — SC-001, FR-016, FR-017, FR-018
- [ ] T020 [P] [US1] Add `packages/myenc_adapters/test/archive_as_file_test.dart` covering both directions of SC-012: a `.zip` protected as a file restores byte-identical and is never expanded; a protected folder is never left packed. Assert no code path in pack/unpack consults magic bytes or a file extension — FR-020b

### Implementation for User Story 1

- [ ] T021 [US1] Create `packages/myenc_core/lib/src/domain/folder_pack.dart` turning a `Stream<FolderEntry>` plus a `DirectoryIoPort` into a streaming tar-PAX byte stream per `contracts/pack-format.md` §1–§4. Peak memory must not grow with entry count or with the largest file (FR-027)
- [ ] T022 [US1] Create `packages/myenc_core/lib/src/domain/folder_unpack.dart` turning a tar byte stream into filesystem writes via `SafeUnpacker` and `DirectoryIoPort`, writing only under the staging root
- [ ] T023 [US1] Create `lib/core/folder_scan.dart` producing a `FolderSelection` (root name, entry count, total bytes, unpreservable items, refusal) per `data-model.md`. Total bytes must be known before the stream starts so progress can be a fraction (FR-003, FR-004, FR-026)
- [ ] T024 [US1] Add `cmd` values `pack_encrypt` and `decrypt_unpack` to `latchWorker` in `lib/core/isolate_worker.dart`, dispatching to the new pack/unpack paths. Keep the worker→main message protocol (`file_start`/`progress`/`file_done`/`error`/`done`) **exactly** as it is — one folder is one batch item, so exactly one `file_done` (FR-012, `contracts/ports.md` §3)
- [ ] T025 [US1] Add `AppCrypto.encryptFolder` and `AppCrypto.restoreFolder` to `lib/core/app_crypto.dart`, building the task maps and reusing `_runBatch` unchanged so the "last per-file result before the final 1.0" ordering invariant still holds
- [ ] T026 [US1] Implement the staging discipline from `research.md` R6 in the restore path: unpack into a temporary sibling directory and rename it onto the destination as one step only after the whole unpack succeeds; never write under the final tree name first (FR-021, FR-029)
- [ ] T027 [US1] Extend `lib/core/output_plan.dart` with folder destination rules: a resolvable granted path or app-private storage only, and **never** Downloads for restored plaintext (FR-036, research.md R7)
- [ ] T028 [US1] Add folder selection to the encrypt pick flow in `lib/features/encrypt/encrypt_pick_screen.dart` — a "Choose a folder" affordance alongside the existing file picker, wired to `FilePicker.platform.getDirectoryPath` on desktop/iOS
- [ ] T029 [US1] Add a folder review screen under `lib/features/encrypt/` showing what was found and what will not be preserved, before anything is encrypted, and register its route in `lib/core/router.dart` (FR-003, FR-004)
- [ ] T030 [US1] Wire the folder restore destination and outcome into the decrypt flow in `lib/features/decrypt/`, so a v2 packed-folder container restores to a tree and a v1 or `singleFile` container keeps today's behaviour exactly (FR-025, FR-014)
- [ ] T031 [P] [US1] Add a `testWidgets` walk of the folder pick and review screens to `test/`, doing the real async work inside `tester.runAsync` and excluding the progress screens, matching `test/e2e_flow_test.dart`
- [ ] T032 [P] [US1] Add folder batch completion coverage to `test/app_crypto_batch_test.dart` using plain `test()` on the real event loop — one `file_done` per folder, arriving before the final `1.0`. `testWidgets` cannot drive a real isolate (Principle V)

**Checkpoint**: MVP. A folder round-trips, one container per folder, and an
archive protected as a file is never expanded.

---

## Phase 4: User Story 2 — Awkward folders restore faithfully (Priority: P2)

**Goal**: Modification times, the executable bit, and symlinks-as-links survive
the round trip; where a platform cannot apply them, the restore still succeeds
and says what it could not apply.

**Independent Test**: Round-trip a fixture with known mtimes, an executable file,
an internal symlink, an empty directory, a >100-byte UTF-8 name, and a zero-byte
file. On desktop all in-scope metadata survives; on Android/iOS names, structure,
and content are correct and the report names what was skipped — and the restore
is still reported as a success.

### Tests for User Story 2

- [ ] T033 [P] [US2] Add a fidelity fixture **builder** to `packages/myenc_adapters/test/` that constructs the tree at test setup from a declarative description — git does not preserve mtimes, so the fixture must not be a committed directory
- [ ] T034 [P] [US2] Add `packages/myenc_adapters/test/folder_fidelity_test.dart` asserting mtimes, the executable bit, and symlinks-as-links survive on desktop, and that a >100-byte UTF-8 name forces a PAX header and round-trips byte-identically — SC-002, SC-014, FR-020a, FR-018
- [ ] T035 [P] [US2] Add a test asserting a restore with a non-empty `MetadataApplicationReport` is still reported as a **success**, never as a failed entry, and never as unqualified success either — FR-020e

### Implementation for User Story 2

- [ ] T036 [US2] Encode the in-scope metadata in `folder_pack.dart`: `mode` normalised to `0o755` for directories and executables and `0o644` otherwise, `modified` from the entry, `TypeFlag.symlink` with `linkName` recorded verbatim and never followed, PAX headers only where a USTAR field cannot hold the value (`contracts/pack-format.md` §3)
- [ ] T037 [US2] Apply the in-scope metadata in `folder_unpack.dart` via `DirectoryIoPort`, accumulating a `MetadataApplicationReport` from the `bool` returns instead of failing the entry
- [ ] T038 [US2] Report unpreservable objects — devices, sockets, FIFOs — from `lib/core/folder_scan.dart` so they are named to the user before encryption and never packed (FR-004)
- [ ] T039 [US2] Surface the `MetadataApplicationReport` on the decrypt success screen in `lib/features/decrypt/` as a normal-path outcome, not an error dialog — inside the Android and iOS sandboxes these counts are routinely non-zero (FR-020e)

**Checkpoint**: US1 and US2 both work. Fidelity is delivered where the platform
allows it and honestly reported where it does not.

---

## Phase 5: User Story 3 — Large folders stay usable and interruptible (Priority: P3)

**Goal**: A 10,000-file, ~10 GB folder shows meaningful progress, never blocks
the UI, and cancels cleanly with nothing reachable left behind.

**Independent Test**: Run a 10,000-file folder; progress advances at least once
per second and peak memory stays in the band of a single-file operation of the
same total size. Cancel mid-run twice — once encrypting, once restoring — and
confirm no partial container and no staged plaintext.

### Tests for User Story 3

- [ ] T040 [P] [US3] Add a scale test to `packages/myenc_adapters/test/` over a generated 10,000-entry tree asserting peak memory does not grow with entry count or with the largest file — SC-006, FR-027
- [ ] T041 [P] [US3] Add a cancellation test using plain `test()` in `test/app_crypto_batch_test.dart`: cancel a folder encrypt and a folder restore mid-run and assert no partial container and an empty staging root. This is the case that silently regresses if T014's directory sweep is dropped — SC-007, FR-028, FR-029

### Implementation for User Story 3

- [ ] T042 [US3] Emit byte-weighted progress from both worker commands in `lib/core/isolate_worker.dart`, using the total byte count from `folder_scan`. Entry-counted progress is wrong for a folder of 3 large files; byte-weighted is meaningful for both shapes (FR-026, SC-005)
- [ ] T043 [US3] Show the current stage and entry on the encrypt and decrypt progress screens for folder operations, so the user can tell packing from encrypting (FR-026)
- [ ] T044 [US3] Confirm cancellation kills the isolate and sweeps the staged tree for both folder commands, extending the existing teardown path rather than adding a second one (FR-029)

**Checkpoint**: Large folders are usable, interruptible, and leave nothing behind.

---

## Phase 6: User Story 4 — An unreadable entry aborts loudly (Priority: P3)

**Goal**: Any entry that cannot be read aborts the whole operation, names the
offending entry, and leaves no container and no deleted originals.

**Independent Test**: Make one entry unreadable and protect the folder. The
operation aborts, the entry is named by its relative path, no container exists,
staged work is gone, and the originals are intact even with "delete originals"
selected.

### Tests for User Story 4

- [ ] T045 [P] [US4] Add `packages/myenc_adapters/test/folder_abort_test.dart`: an unreadable entry aborts the batch, names the entry, leaves no container, and leaves the originals untouched regardless of the delete-originals choice — SC-008, FR-031, FR-011, FR-032
- [ ] T046 [P] [US4] Add a size-honesty test: a file whose length changes between `stat` and read aborts the whole operation naming the entry, rather than producing a silently corrupt archive — `contracts/pack-format.md` §5

### Implementation for User Story 4

- [ ] T047 [US4] Implement the abort path in `folder_pack.dart`: any read failure, and any mismatch between a declared tar size and the bytes actually read, aborts the whole stream with the offending relative path attached (FR-031)
- [ ] T048 [US4] Guarantee in `lib/core/app_crypto.dart` that an aborted folder encrypt removes the staged container and **never** reaches the delete-originals step, so a failed capture cannot cost the user their source data (FR-031)
- [ ] T049 [US4] Implement the `SelectionRefusal` states in `lib/core/folder_scan.dart` — symlink cycle, unresolvable Android tree, unreadable entry — and block the encrypt flow from starting on a refused selection. There is no partial-selection state: incompleteness is a refusal, never an output (FR-005, FR-006, FR-011, FR-032)
- [ ] T050 [US4] Present abort and refusal reasons in human copy naming the offending entry, via `lib/shared/error_messages.dart` and the encrypt flow's alert path, with no raw exception text (FR-033)

**Checkpoint**: A folder capture is all-or-nothing, and a failure never costs the
user their originals.

---

## Phase 7: User Story 5 — Picking a folder on Android (Priority: P3)

**Goal**: A folder can be selected through the platform folder-grant picker,
protected, and restored; an unresolvable tree is refused with an explanation
rather than partially captured.

**Independent Test**: On an API 30+ device, grant a folder, protect it, restore
it. Confirm the restore destination is a granted path or app-private storage and
never Downloads. Then select a cloud-provider folder and confirm a clear refusal.
Confirm the whole encrypt-beside-the-originals path prompted for access exactly
once, and that the folder is listed — accurately — in Settings → Save folders.

> **Revisited 2026-09-29.** PRs #66, #74 and #78 landed after this phase was
> written; see `research.md` R7 as rewritten. Two findings changed the work:
> `pickTree` takes read **and** write permission, so selecting the folder already
> grants what output placement needs (T053a); and every persisted grant now
> surfaces in a settings screen that calls them all save destinations, which a
> source-only folder is not (T056a).

### Tests for User Story 5

- [ ] T052a [P] [US5] Add a widget/unit test asserting an encrypt-beside-the-originals folder operation prompts for folder access exactly **once** — the selection — and that a repeat operation on the same folder prompts zero times, because `existingTreeGrantFor` finds the grant selection already took — SC-019, FR-034a
- [ ] T052b [P] [US5] Add a test that declining the destination prompt during a folder operation yields a cancelled plan: zero bytes at the destination, zero staged bytes, no remembered preference, and the next identical operation asks again — SC-021, FR-037a
- [ ] T052c [P] [US5] Add a test that a folder operation whose grant was revoked before it starts re-prompts rather than failing obscurely or using the shared fallback unasked — SC-022
- [ ] T051 [P] [US5] Extend `android/app/src/test/kotlin/.../ExternalStorageDocIdsTest.kt` if T053 touches the id↔path mapping — the two directions must stay exact inverses, and drift is invisible in a running build (Principle V)
- [ ] T052 [P] [US5] Add a test asserting a folder restore never resolves to Downloads, and that an unresolvable source tree produces a refusal rather than a Downloads fallback — FR-036, FR-005

### Implementation for User Story 5

- [ ] T053 [US5] Wire Android folder selection through the existing `SafBridge.pickTree` → `treeUriToPath` path in `lib/core/saf_bridge.dart`, reusing the existing grant machinery and adding no new prefs cache — Android's persisted-permission table stays the only grant record (FR-035)
- [ ] T054 [US5] Refuse a selection whose `content://` tree cannot be resolved to a real filesystem path, with copy explaining why, because the crypto worker is plain `dart:io` and cannot walk a SAF tree (FR-005, FR-034, research.md R7)
- [ ] T053a [US5] Make output placement recognise the grant selection already took, so the ordinary "encrypt this folder, put the `.latch` beside it" path never shows the save-folder prompt. `SafBridge.pickTree` takes `FLAG_GRANT_READ_URI_PERMISSION or FLAG_GRANT_WRITE_URI_PERMISSION` and `existingTreeGrantFor` matches a grant covering the folder or an ancestor, so this should be recognition, not a new code path — if it needs one, say why in the PR (FR-034a, SC-019)
- [ ] T053b [US5] Take no grant for a folder the app already holds one covering, and add none of this feature's own grant bookkeeping. The persisted table only grows until the user gives something back, and at the platform ceiling Android drops the oldest grant silently (FR-035b, FR-035)
- [ ] T054a [US5] Route any destination prompt a folder operation shows through the existing three-outcome decision, cancellation included, and confirm a dismissed dialog reads as cancel rather than as consent to the shared fallback. For a **restore** the shared-fallback answer must not be offered at all, since FR-036 forbids it — that prompt has two answers, a granted folder or cancel (FR-037a, research.md R7)
- [ ] T055 [US5] State the Downloads divergence in the restore UI copy in `lib/features/decrypt/` — single-file decrypt may fall back to Downloads with a banner, a folder restore may not, and a user who has seen the former will otherwise expect it (FR-036)
- [ ] T056a [US5] Correct what `lib/features/settings/save_folders_screen.dart` claims, now that a grant may be held only because a folder was encrypted: the screen title, the row copy, and the revoke dialog's "Latch will lose write access to …" must describe the access actually held rather than assuming every grant is a save destination (FR-035a, SC-020). Do **not** solve this by recording per-grant provenance in the app — that is the grant bookkeeping FR-035 forbids, and the platform cannot supply the intent either, since it records the grant and not the reason. Change what the screen claims

**Checkpoint**: All five stories are independently functional, folder access is
asked for once, and every folder the app can reach is listed accurately.

---

## Phase 8: Cross-Cutting — includes two constitutional gates

**⚠️ T056 and T057 are NOT optional polish.** Principle V makes the independent
oracle a requirement of the format, and `docs/FORMAT.md` is normative.

- [ ] T056 Extend `tool/gen_golden_vectors.py` to emit a **folder** container: build the packed stream with Python's stdlib `tarfile` at `format=tarfile.PAX_FORMAT`, prepend the preamble, and encrypt with `argon2-cffi` + libsodium via `ctypes` — never with the Dart code. Commit the `.latch`/`.json` pair together under `packages/myenc_adapters/test/golden/`; the secretstream header nonce is random, so the pair is only self-consistent as a pair (Principle V)
- [ ] T057 Add a v2 section to `docs/FORMAT.md` from `contracts/payload-preamble.md` and `contracts/pack-format.md`, marking v2 normative and restating that the v1 layout is frozen and unchanged. Note that writers emit the lowest version that expresses the payload
- [ ] T058 [P] Add UC-13 to `project_spec.md` and record the folder-encryption flow in its use-case list
- [ ] T059 [P] Update `CLAUDE.md`: the `.latch` v2 payload preamble, `package:tar` as `myenc_core`'s first non-test dependency, the new `DirectoryIoPort`, the two new worker commands, and the staged-**directory** sweep in `_runBatch`
- [ ] T060 [P] Add the folder flows to `docs/RELEASE_READINESS.md` — accessibility of the review screen, performance at 10,000 entries, and the store-compliance position on folder grants
- [ ] T061 Run every gate: `dart format --set-exit-if-changed .`, then `flutter analyze --no-pub` and `flutter test` at the root, in `packages/myenc_core`, and in `packages/myenc_adapters`, plus `cd android && ./gradlew :app:testDebugUnitTest`. Four separate suites — there is no single command
- [ ] T062 Walk every scenario in `quickstart.md` (S1–S13) and confirm each success criterion it names is discharged
- [ ] T063 Verify the freeze guards one final time, still unmodified, and confirm every container written before this feature still decrypts — SC-009, Principle II

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: depends on Setup — **blocks every user story**
- **US1 (Phase 3)**: depends on Foundational. Nothing else depends on US1's UI, but US2–US5 all extend its pack/unpack path
- **US2 (Phase 4)**: depends on Foundational; extends T021/T022 from US1
- **US3 (Phase 5)**: depends on Foundational; extends T024/T042 progress plumbing
- **US4 (Phase 6)**: depends on Foundational; extends T021's write path
- **US5 (Phase 7)**: depends on Foundational; extends T023/T027 selection and destination
- **Phase 8**: T056 needs the pack format working, so it follows US1. The rest follows the stories in scope

### Critical path inside Foundational

T005 → T006 → T008 → T009 → T010 → T011, and T012 → T013. T014 and T015 are
independent of both chains and can start immediately.

### Story independence

US2, US3, US4, and US5 each extend a *different* seam of the US1 engine —
metadata, progress, the abort path, and platform selection. Two developers can
take two of them concurrently without touching the same file, provided US1 has
landed. They are not independent of US1 itself: without a working pack/unpack
there is nothing for them to extend.

### Parallel Opportunities

- **Phase 1**: T002 and T003 are sequential (T003 exports what T002 adds); T004 follows T002
- **Phase 2**: T007, T012, T016, T017 are marked [P]. T014 and T015 can start in parallel with the preamble chain
- **Phase 3**: T018, T019, T020 in parallel; T031 and T032 in parallel once the engine lands
- **Phase 4**: T033, T034, T035 in parallel
- **Phase 5**: T040, T041 in parallel
- **Phase 6**: T045, T046 in parallel
- **Phase 7**: T051, T052 in parallel
- **Phase 8**: T058, T059, T060 in parallel; T061–T063 are sequential gates and run last

---

## Parallel Example: Foundational

```bash
# Independent of the preamble chain — start immediately:
Task: "T014 Extend the _runBatch teardown sweep to remove a staged directory in lib/core/app_crypto.dart"
Task: "T015 Create the SafeUnpacker chokepoint in packages/myenc_core/lib/src/domain/safe_unpacker.dart"
Task: "T012 Create DirectoryIoPort in packages/myenc_core/lib/src/ports/directory_io_port.dart"

# Once their subjects exist, the test tasks run together:
Task: "T007 Add packages/myenc_core/test/payload_preamble_test.dart"
Task: "T016 Add packages/myenc_core/test/safe_unpacker_test.dart"
Task: "T017 Add packages/myenc_core/test/envelope_v2_test.dart"
```

## Parallel Example: User Story 1

```bash
# Three independent test files:
Task: "T018 Add packages/myenc_core/test/folder_pack_test.dart"
Task: "T019 Add packages/myenc_adapters/test/folder_round_trip_test.dart"
Task: "T020 Add packages/myenc_adapters/test/archive_as_file_test.dart"
```

---

## Implementation Strategy

### MVP First (US1 only)

1. Phase 1 Setup — T001–T004
2. Phase 2 Foundational — T005–T017 (**blocks everything**; T009 must pass with the freeze tests unmodified, and T014 must land before any restore UI exists)
3. Phase 3 US1 — T018–T032
4. **STOP and VALIDATE**: run quickstart S1, S2, S4, S5, S6, S7
5. That is a shippable increment: folders round-trip, one container per folder, archives protected as files are never expanded

### Incremental Delivery

1. Setup + Foundational → v2 format exists, v1 provably unharmed
2. US1 → folder round trip (**MVP**)
3. US2 → fidelity, honestly reported where the platform refuses it
4. US3 → scale, progress, clean cancellation
5. US4 → all-or-nothing capture that never costs the user their originals
6. US5 → Android selection with an honest refusal path
7. Phase 8 → the independent oracle and the normative format doc

### Parallel Team Strategy

1. Everyone on Setup + Foundational; the preamble chain (T005–T011) and the
   guard/port/sweep work (T012–T015) are two independent tracks
2. One developer takes US1 end to end — it is the engine the rest extend
3. Once US1 lands: US2, US3, US4, US5 to four developers; they touch different
   seams and different files

---

## Notes

- **Commit convention**: Conventional Commits with a scope — `feat(core):`, `feat(app):`, `fix(app):`, `build(android):`, `docs:`. No Claude or Co-Authored-By attribution anywhere
- **Before every commit**: `dart format .`, or install the hooks once with `./tool/setup-hooks.sh` (pre-commit = format check, pre-push = the full mirror)
- **Never** `apt install libsodium` or set `LD_LIBRARY_PATH` — `sodium` 4.x ships libsodium via Dart native assets. `tool/gen_golden_vectors.py` is the one exception: it loads a *system* libsodium via `ctypes`
- **`myenc_core` stays free of Flutter and `dart:io`.** If a task seems to need either, the code belongs in `myenc_adapters` behind a port
- **A freeze-guard failure is a bug to revert, never a test to fix** (Principle II)
- **`testWidgets` runs under a fake clock.** Isolate work and real async file I/O belong in plain `test()`, or inside `tester.runAsync` with the sync file APIs
- Stop at any checkpoint and validate that story on its own
