---

description: "Task list for Bulk File Encryption (004)"
---

# Tasks: Bulk File Encryption

**Input**: `/specs/004-bulk-file-encryption/` — plan.md, spec.md, research.md (R1–R8), data-model.md, contracts/, quickstart.md

**Tests**: Included. The constitution (Principles IV, V) and the plan's contracts require them; the `.latch` v1 freeze guards must pass **unedited** throughout.

**Format**: `- [ ] T### [P?] [US?] Description with file path`. `[P]` = different files, no dependency on an incomplete task.

**Commands** (run per package, never one command for all):
`dart format .` · `flutter analyze --no-pub && flutter test` (root) · same inside `packages/myenc_core` and `packages/myenc_adapters` · `cd android && ./gradlew :app:testDebugUnitTest` when Kotlin changes.

**Commits**: Conventional Commits with scope, no attribution lines of any kind.

## Phase 1: Setup

- [x] T001 Create a git branch `004-bulk-file-encryption` from the current head and move the uncommitted `specs/004-bulk-file-encryption/` and `.specify/feature.json` onto it; confirm `./tool/setup-hooks.sh` hooks are active
- [x] T002 Check whether `001-folder-encryption` already defines `DirectoryIoPort`, `FreeSpacePort` or `InsufficientSpaceError` in `packages/myenc_core/lib/src/`; record the result at the top of `specs/004-bulk-file-encryption/research.md` R3 so T006–T008 land the single shared definition

## Phase 2: Foundational (blocks every story)

**Device gate first** — it can invalidate Android design (research R6).

- [ ] T003 **Device read test (API ≥ 30)**: add a throwaway debug action that picks a tree via `SafBridge.pickTree`, resolves it with `treeUriToPath`, and attempts a `dart:io` `Directory.list` + read of one file from the plain Dart side; record outcome (works / denied, device, API level) in `research.md` R6. If denied, stop and revisit R6 before T029
- [x] T004 [P] Add `InsufficientSpaceError` (shortfall bytes + which location is short) to `packages/myenc_core/lib/src/format/myenc_errors.dart` unless T002 found it; add human copy in `lib/shared/error_messages.dart`
- [x] T005 [P] Define `FolderEntry`/`EntryStamp`/`SkippedEntry` value types in `packages/myenc_core/lib/src/ports/directory_io_port.dart`, matching `specs/001-folder-encryption/contracts/ports.md`
- [x] T006 Define `DirectoryIoPort` (`walk`, `stat`, `createDirectory`) in `packages/myenc_core/lib/src/ports/directory_io_port.dart` and export it from `packages/myenc_core/lib/myenc_core.dart`
- [x] T007 [P] Define `FreeSpacePort` (`freeBytesAt`, null = proceed) in `packages/myenc_core/lib/src/ports/free_space_port.dart` and export it
- [x] T008 [P] Implement `ContainerSniffer.sniff` (`SniffResult`: container / notContainer / newerVersion / truncated; never throws; ignores extension) in `packages/myenc_core/lib/src/format/container_sniffer.dart`, reusing `MyencCodec`'s magic/version check
- [x] T009 [P] Test sniffer: valid v1 header, wrong magic, truncated, future version byte, `.latch`-named non-container, renamed container, in `packages/myenc_core/test/container_sniffer_test.dart`
- [x] T010 Implement non-following sync-`dart:io` `DirectoryIoDart` (`walk` byte-sorted, cycle-safe, classify-not-reject) in `packages/myenc_adapters/lib/src/io/directory_io_dart.dart`; export it
- [x] T011 [P] Test `DirectoryIoDart` with sync temp dirs: nested tree, ancestor-link cycle, symlink not followed, unreadable entry skipped *and listed*, empty dir, deterministic order, in `packages/myenc_adapters/test/directory_io_dart_test.dart`
- [x] T012 [P] Implement `FreeSpaceDart` (desktop `df`/`GetDiskFreeSpaceEx`, Android `StatFs` via channel in T013, iOS capacity key; never throws, null on unknown) in `packages/myenc_adapters/lib/src/io/free_space_dart.dart`
- [x] T013 [P] Add native `freeBytes(path)` method to the `latch/saf` channel in `android/app/src/main/kotlin/.../MainActivity.kt` and expose `SafBridge.freeBytesAt` in `lib/core/saf_bridge.dart`
- [x] T014 [P] Test `FreeSpaceDart` contract (null on unresolvable path, no throw) in `packages/myenc_adapters/test/free_space_dart_test.dart`
- [x] T015 Add `BulkOptions`, `BulkItem`, `BulkInventory`, `BulkFileOutcome` per `data-model.md` in `lib/core/bulk_plan.dart`
- [x] T016 Implement enumeration in `lib/core/bulk_plan.dart`: run `DirectoryIoDart.walk` via `Isolate.run`, build `BulkInventory` (every entry in exactly one of items/skipped), derive `outRelPath`, normalise separators, reject any `..`
- [x] T017 [P] Test enumeration invariants (no silent drops, path safety, non-recursive depth 1) with sync temp dirs in `test/bulk_plan_test.dart`
- [x] T018 Extend `AppCrypto.encryptFiles`/`decryptFiles` in `lib/core/app_crypto.dart` to accept per-file `outRelPath` and `BulkOptions`; extend `latchWorker` task maps in `lib/core/isolate_worker.dart` (`encrypt`/`decrypt` entries `{path, outRelPath?}`) per `contracts/worker-protocol.md`; message protocol unchanged
- [x] T019 In `lib/core/isolate_worker.dart`, create parent directories for mirrored output and apply `resolveNameCollision` per output path
- [x] T020 Add staged-**directory** recursive sweep on teardown before `done` in `AppCrypto._runBatch` (`lib/core/app_crypto.dart`)
- [x] T021 Plain-`test()` real-isolate test: cancel a mirrored bulk decrypt mid-run, assert staging tree and destination hold no plaintext for unfinished files, in `test/app_crypto_bulk_test.dart`; confirm `test/app_crypto_batch_test.dart` passes unmodified

**Checkpoint**: ports, sniffer, enumeration, mirrored paths, sweep ready.

## Phase 3: User Story 1 — Encrypt every file in a folder (P1) 🎯 MVP

**Goal**: pick a folder, encrypt its top-level files into one picked destination, mirrored layout, per-file results, optional verified source deletion.
**Independent test**: quickstart scenarios 1, 3, 6, 8.

- [x] T022 [P] [US1] Verified deletion test: corrupt a staged container → original kept, typed failure, others deleted, in `test/app_crypto_bulk_test.dart`
- [x] T023 [US1] Implement verified deletion in `_encryptOne` (`lib/core/isolate_worker.dart`): reopen container, re-unwrap the DEK from its wrap with the held KEK, decrypt (`requireFinalized`), lockstep byte-compare with source, delete the original only on exact match and length; on failure delete the container, keep the original, report the file by name (FR-033c); set `verified`/`sourceRemoved` on `file_done`
- [x] T024 [P] [US1] Change-detection: stat before/after read via `DirectoryIoPort.stat`; a changed file fails that file only (research R8) in `lib/core/isolate_worker.dart`
- [x] T025 [US1] Pre-flight in `lib/core/bulk_plan.dart` (peak-space calculation that credits reclaimed originals, FR-026d): space check for destination **and** Android staging cache via `FreeSpacePort`, naming the short location; `null` = proceed; refusal writes/stages nothing
- [x] T026 [P] [US1] Test pre-flight with a fake `FreeSpacePort` (short destination, short staging, null) in `test/bulk_plan_test.dart`
- [x] T027 [US1] Extend `OutputPlanner`/`relocateStagedOutputs` in `lib/core/output_plan.dart` for mirrored trees: stage under cache, relocate each file with `subPath` = relative dir; reuse `existingTreeGrantFor` before prompting; decrypt cancels (not Downloads) when the destination is unreachable (FR-040); encrypt output keeps the per-file Downloads fallback and notice
- [x] T028 [P] [US1] Extend `test/output_plan_test.dart` ladder with mirrored-tree cases: covering ancestor grant (no re-prompt), cancelled plan, relative-dir mapping
- [x] T029 [US1] Android: verify or extend native `createInTree` in `android/app/src/main/kotlin/.../MainActivity.kt` to create missing intermediate folders; keep the path-split logic framework-free and JVM-tested in `android/app/src/test/kotlin/.../`
- [x] T030 [US1] Folder entry point and summary screen in `lib/features/encrypt/` (count, size, skipped list with reasons, destination, delete-source disclosure that verification doubles read cost); route in `lib/core/router.dart`
- [x] T031 [US1] >10,000-file deliberate confirmation (FR-026h) on the summary screen in `lib/features/encrypt/`
- [x] T032 [US1] Progress/success screens: per-file outcomes, byte-weighted progress, "last result before 1.0" respected, in existing `lib/features/encrypt/` screens
- [x] T033 [P] [US1] Widget tests for summary/skip list/confirmation using sync file APIs in `test/bulk_encrypt_screen_test.dart`; extend `test/e2e_flow_test.dart` with the folder path

- [x] T061 [US1] Time estimate (FR-026) from file count, total size and key mode, in `lib/core/bulk_plan.dart` (`estimateDuration`), shown on the summary screens; unit-tested in `test/bulk_plan_test.dart`
- [x] T062 [US1] Privacy disclosure copy (FR-044/045: names, count, sizes visible; 001 hides them; never "equivalent") on both summary screens in `lib/features/encrypt/` and `lib/features/decrypt/`, plus widget test that it is shown before the start action in `test/bulk_encrypt_screen_test.dart`
- [x] T063 [US1] On encrypt, run `ContainerSniffer` during enumeration and show "N already look like Latch containers" (FR-009); show the key mode in effect (FR-021) — `lib/core/bulk_plan.dart`, `lib/features/encrypt/`
- [x] T064 [US1] Map a mid-run out-of-space failure to `InsufficientSpaceError` with shortfall for the remaining files (FR-026f) in `lib/core/isolate_worker.dart` and `lib/shared/error_messages.dart`; test in `test/app_crypto_bulk_test.dart`
- [x] T065 [US1] Result screen: partly-failed runs never read as "done" (FR-015), state where output was written (FR-032), and note that emptied folders remain when deleting (FR-035) in `lib/features/encrypt/`
- [x] T066 [P] [US1] Streaming/memory test: peak memory does not grow with file count or largest file (FR-025) in `test/app_crypto_bulk_test.dart`

**Checkpoint**: MVP — shippable folder encrypt, non-recursive, per-file keys.

## Phase 4: User Story 2 — Decrypt a folder of containers (P1)

**Goal**: bulk-decrypt by header sniffing, mirrored output, optional container deletion after verified write.
**Independent test**: quickstart scenarios 3, 5, 7.

- [x] T034 [US2] Sniff during enumeration (`lib/core/bulk_plan.dart`): read only the fixed header prefix per file; non-containers and newer-version files go to `skipped` with reasons
- [x] T035 [P] [US2] Enumeration test: renamed container accepted, text file named `x.latch` skipped, newer version reported, in `test/bulk_plan_test.dart`
- [x] T036 [US2] Decrypt output naming: strip `.latch` if present else append a neutral suffix; collision handling; in `lib/core/bulk_plan.dart`
- [x] T037 [US2] Container deletion after decrypt (FR-035b/c/d) in `_decryptOne` (`lib/core/isolate_worker.dart`): re-read the container independently, decrypt, compare byte-for-byte to the restored file; delete the container only on exact match; on mismatch keep it, name it, never report it as decrypted
- [x] T038 [P] [US2] Test: wrong passphrase on one container fails that file only and leaves its container; corrupt container never emits partial plaintext, in `test/app_crypto_bulk_test.dart`
- [x] T039 [US2] Decrypt folder UI in `lib/features/decrypt/` (summary, skipped list, "delete containers after" option); route in `lib/core/router.dart`
- [x] T040 [P] [US2] Widget test for decrypt folder summary in `test/bulk_decrypt_screen_test.dart`

## Phase 5: User Story 3 — Recursion, only when asked (P2)

**Goal**: opt-in subfolder inclusion; off every operation.
**Independent test**: quickstart scenarios 1, 2, 9.

- [x] T041 [US3] Recursion flag in `BulkOptions`; non-recursive enumeration lists subfolder contents as "not included (recursion off)" in `lib/core/bulk_plan.dart`
- [x] T042 [US3] Recursion toggle (default off, never persisted) on both summary screens in `lib/features/encrypt/` and `lib/features/decrypt/`
- [x] T043 [P] [US3] Tests: nested tree mirrors exactly; toggle default off on every entry; 10,000-entry walk does not block (frame/time budget), in `test/bulk_plan_test.dart`

## Phase 6: User Story 4 — Per-file vs shared key (P2)

**Goal**: opt-in shared-KEK batch mode, no format change.
**Independent test**: quickstart scenario 4; Principle V reference test.

- [x] T044 [US4] Add `DekWrap.wrapPassphraseWithKek` in `packages/myenc_core/lib/src/domain/dek_wrap.dart`
- [x] T045 [US4] Implement `BatchWrapKey.derive/dispose` in `packages/myenc_core/lib/src/domain/batch_wrap_key.dart`; export
- [x] T046 [US4] Add optional `batchKey` to `EnvelopeService.encrypt` in `packages/myenc_core/lib/src/domain/envelope_service.dart` (shared salt, fresh DEK/stream header per file; params must match; disposed key → `StateError`)
- [x] T047 [P] [US4] Core tests per `contracts/core-api.md`: shared-salt containers decrypt unchanged; DEKs/nonces/stream headers distinct; disposed key throws, in `packages/myenc_core/test/batch_wrap_key_test.dart`
- [x] T048 [P] [US4] Independent verification: extend `tool/gen_golden_vectors.py`  to decrypt a shared-salt batch container by deriving from the header salt; add as a **new** fixture, never altering `golden_v1.*` or `codec_freeze_test.dart`, with test in `packages/myenc_adapters/test/`
- [x] T049 [US4] Wire `keyMode` through `AppCrypto.encryptFiles` and `_encryptBatch` (`lib/core/app_crypto.dart`, `lib/core/isolate_worker.dart`): derive once before first file, dispose in `finally`
- [x] T050 [P] [US4] Test (plain `test()`, real isolate): N files in shared mode complete with one derivation; all decrypt via the normal path, in `test/app_crypto_bulk_test.dart`
- [x] T051 [US4] Advanced-settings entry with plain-language per-file vs shared comparison and one-time warning at selection, in `lib/features/settings/bulk_settings_screen.dart`; link from `lib/features/settings/settings_screen.dart`

## Phase 7: User Story 5 — Output placement default + override (P3)

**Goal**: persisted default placement, per-operation override.
**Independent test**: quickstart scenario 10.

- [x] T052 [US5] Implement `BulkSettings` (`bulk.keyMode`, `bulk.outputPlacement`, try/catch around prefs) in `lib/core/bulk_settings.dart`
- [x] T053 [P] [US5] Test `BulkSettings` defaults and persistence in `test/bulk_settings_test.dart`
- [x] T054 [US5] Placement default (mirrored / beside / flat, FR-028; flat collisions via FR-031) in settings screen (`lib/features/settings/bulk_settings_screen.dart`) and per-operation override on summary screens; `besideOriginals` path through `OutputPlanner`
- [x] T055 [US5] Reword **Save folders** copy so an encryption-only grant is not called a save destination (FR-038) in `lib/features/settings/save_folders_screen.dart`; no per-grant provenance; update `test/` for the screen

## Phase 8: Polish

- [x] T056 [P] Update `CLAUDE.md` (bulk flow, verified deletion, shared-KEK invariants, staged-tree sweep) without duplicating the spec
- [x] T057 [P] Update `docs/RELEASE_READINESS.md` for accessibility/localisation of the new screens (the item deliberately deferred in clarify)
- [x] T058 Reconcile with 001: update `specs/001-folder-encryption/tasks.md` and `plan.md` so its ports task points at 004's landed ports; mark `contracts/payload-preamble.md` status
- [x] T059 Run every `quickstart.md` scenario on desktop and one Android device (API ≥ 30); record results
  - **Result (2026-10-06), desktop/headless only — scenarios 1–9 are pinned by automated tests that drive the real isolate and real files, not by a hand-run GUI:** 1–2 `bulk_plan_test.dart`, `bulk_encrypt_screen_test.dart`; 3 and 7 `app_crypto_bulk_test.dart` (tampered container kept, cancel sweeps staging tree); 4 `batch_wrap_key_test.dart` + `app_crypto_bulk_test.dart` (shared mode; one salt, distinct DEKs/nonces; wrong passphrase still rejected); 5 `container_sniffer_test.dart`, `bulk_plan_test.dart`; 6 `verified_delete_test.dart`; 8 `app_crypto_bulk_test.dart` (`hdiutil` tiny volume, macOS only) + `free_space_dart_test.dart`; 9 `bulk_*_screen_test.dart` (confirmation gate at `bulkConfirmThreshold`). Frame-time responsiveness for >10,000 files was not measured.
  - **NOT DONE — needs a device:** scenarios 10 (single grant, no second prompt, one Save-folders entry) and 11 (worker can read/walk the picked folder's real path on API 30+, the carried risk behind T003/R6). No Android device or emulator was available. Do not treat the Android placements (mirrored / beside / flat via SAF) as verified until these are run; if scenario 11 fails, stop and revisit R6.
- [x] T060 Final gates: `dart format .`, analyze + test in all three packages, Gradle unit tests; confirm `codec_freeze_test.dart` and `golden_v1.*` unmodified via `git diff --stat`
  - **Result (2026-10-06):** format 0 changes; analyze clean in all three packages; tests green — core 149, adapters 104, app 304; Gradle `:app:testDebugUnitTest :app:compileDebugKotlin` BUILD SUCCESSFUL; freeze-guard `git diff --stat` empty.

## Dependencies & Order

- Phase 1 → Phase 2 → stories. T003 (device gate) precedes T016 on Android and T027–T029.
- US1 and US2 share Phase 2 and are independent of each other; US2 touches the same `bulk_plan.dart` as US1 (sequence T034 after T016).
- US3 depends on T016/T041 only. US4 is core-first (T044→T046) and independent of UI stories. US5 follows US1 (placement already hardcoded mirrored there).
- Polish last.

## Parallel Examples

- Phase 2: T004, T005, T007, T008 together; then T009, T011, T012–T014 together.
- After Phase 2: US1 (T022–T033), US4 core (T044–T048), and US2 (T034–T040) by different people.

## Implementation Strategy

MVP = Phases 1–3 (US1): ship folder encrypt, non-recursive, per-file keys. Then US2 (decrypt, so output is recoverable in-app), US3, US4, US5. Run the T003 device gate before investing in Android relocation.
