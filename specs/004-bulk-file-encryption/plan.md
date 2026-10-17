# Implementation Plan: Bulk File Encryption

**Branch**: `004-bulk-file-encryption` (spec pointer only — no git branch exists yet; work currently sits on `001-folder-encryption`) | **Date**: 2026-10-04 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `/specs/004-bulk-file-encryption/spec.md`

## Summary

Pick a folder, encrypt every file in it (optionally recursively) into ordinary
`.latch` v1 containers, and decrypt a folder of containers back. One folder is
**many batch items** (unlike 001, where a folder is one item), so the existing
`encrypt` / `decrypt` worker commands, their per-file `file_done` results, and the
"last result before final 1.0" invariant are reused unchanged.

Technical approach, in one paragraph: the walk (enumeration, header sniffing for
decrypt) and the pre-flight space check run on the main side **before** the worker
spawns; the worker receives a flat list of `(source, relative output path)` pairs
and stages mirrored output into the app cache, exactly as single-file Android output
does today; relocation then moves the staged tree into the one granted destination.
Two things are net-new in the crypto path: an opt-in **shared-KEK batch mode** (derive
Argon2id once, reuse the salt, wrap each file's own fresh DEK — no format change)
and **verified deletion** (reopen, decrypt, byte-compare the container before the
original is removed). Settings (derivation mode, default output placement) live in
`shared_preferences`; nothing about grants is cached.

## Technical Context

**Language/Version**: Dart `^3.12.2`, Flutter 3.44.2 (CI-pinned); Kotlin for the Android SAF bridge

**Primary Dependencies**: existing only — `sodium` 4.x (native assets), `file_picker` ^10.3.3, `shared_preferences` ^2.5.5, `go_router`. **No new packages.**

**Storage**: `shared_preferences` for two preferences (`bulk.keyMode`, `bulk.outputPlacement`); no new secure storage; no grant cache (existing rule)

**Testing**: `flutter test` per package (plain `test()` for anything touching a real isolate; sync file APIs inside `testWidgets`); Gradle JVM tests only if Kotlin changes (`createInTree` nested-path handling, see R6)

**Target Platform**: Android (primary risk surface), iOS, macOS/Linux/Windows desktop

**Project Type**: Flutter app + two path-dependency packages (hexagonal)

**Performance Goals**: no UI-thread blocking at 10,000 files (SC-009); batch mode derives once per operation (spec FR-024–026); verified deletion costs roughly one extra decrypt pass per file and is disclosed (FR-033a)

**Constraints**: `.latch` v1 frozen (zero byte changes); `myenc_core` free of Flutter and `dart:io`; fail closed — never leave partial plaintext (staged decrypt output swept on teardown); no recovery features; no Claude attribution anywhere

**Scale/Scope**: no cap; confirmation required above 10,000 files (FR-026h); 5 user stories, 63 FRs

## Constitution Check

*GATE: passes before Phase 0; re-checked after Phase 1 below.*

| Principle | Status | Basis |
|---|---|---|
| I. Offline / No Recovery | PASS | No network, no recovery path. Batch mode shares a *salt*, not a recovery secret. |
| II. v1 Frozen | PASS | Shared-KEK reuses fields v1 already defines (random 16-byte salt per header, per-file DEK wrap). Container bytes stay valid v1; `codec_freeze_test` and golden vectors untouched. R1 proves no marker is needed. |
| III. Hexagonal Purity | PASS | New ports (`DirectoryIoPort`, `FreeSpacePort`) in `myenc_core`; `dart:io` adapters in `myenc_adapters`. Shared-KEK and sniffing logic are pure Dart. |
| IV. Fail Closed | PASS, with one new obligation | Verified deletion (R4) means *no* original is deleted on any mismatch; staged decrypt output swept on cancel (reuses 001 §4 sweep requirement). |
| V. Independent Verification | PASS | Batch-mode containers must decrypt through the **independent** golden-vector path semantics: a test decrypts shared-salt containers with a reference that derives per header, not through `EnvelopeService`. |

No violations; Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/004-bulk-file-encryption/
├── plan.md
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── core-api.md          # BatchWrapKey, container sniffing, ports
│   ├── worker-protocol.md   # task-map extensions; protocol unchanged
│   └── settings.md          # preference keys, defaults, UI contract
├── checklists/requirements.md
└── tasks.md                 # produced later by /speckit-tasks
```

### Source Code (repository root)

```text
packages/myenc_core/lib/src/
├── domain/
│   ├── dek_wrap.dart                 # + wrapPassphraseWithKek(...)
│   ├── batch_wrap_key.dart           # NEW: derive-once KEK holder
│   └── envelope_service.dart         # + optional BatchWrapKey on encrypt()
├── format/
│   └── container_sniffer.dart        # NEW: "is this a v1 header?" from first bytes
├── ports/
│   ├── directory_io_port.dart        # NEW (shape shared with 001, see R3)
│   └── free_space_port.dart          # NEW (shape shared with 001)
└── format/myenc_errors.dart          # + InsufficientSpaceError (if 001 has not landed it)

packages/myenc_adapters/lib/src/io/
├── directory_io_dart.dart            # NEW: non-following sync walk
└── free_space_dart.dart              # NEW: per-platform; null = unknown

lib/core/
├── bulk_plan.dart                    # NEW: enumerate → BulkInventory (main side)
├── bulk_settings.dart                # NEW: shared_preferences wrapper
├── app_crypto.dart                   # encryptFiles/decryptFiles gain BulkOptions
├── isolate_worker.dart               # mirrored out paths, batch KEK, verify-then-delete
└── output_plan.dart                  # mirrored-tree staging + relocation

android/app/src/main/kotlin/.../MainActivity.kt   # createInTree nested dirs (R6)

lib/features/
├── encrypt/                          # folder entry point, recursion toggle, summary
├── decrypt/                          # folder entry point, "container deleted" option
└── settings/                         # Bulk settings screen; Save-folders wording (FR-038)

test/ , packages/*/test/              # see quickstart.md for scenarios
```

**Structure Decision**: three existing packages, no new package. Ports land in
`myenc_core`, adapters in `myenc_adapters`, orchestration in `lib/core`. See R3 for
how this coexists with 001's unlanded versions of the same ports.

## Complexity Tracking

None — no constitution violations.
