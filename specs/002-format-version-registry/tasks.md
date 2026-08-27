---
description: "Task list for Central Format-Version Registry"
---

# Tasks: Central Format-Version Registry

**Input**: Design documents from `/specs/002-format-version-registry/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Test tasks **are** included. The specification explicitly requires them —
FR-006 mandates a test for the gaplessness invariant, SC-002 requires all 256 version
values have a tested outcome, and SC-004 constrains which test files may change. For
this feature the tests are not incidental verification; they *are* the deliverable's
proof of correctness.

**Organization**: Tasks are grouped by user story. Read the two notes below before
starting — this feature's shape differs from a typical feature in ways that affect
execution order.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)
- Exact file paths are given in every task

## Path Conventions

Three-package hexagonal repo. **Only `packages/myenc_core/` is modified.** Paths are
repository-relative:

- Core (modified): `packages/myenc_core/lib/src/format/`, `packages/myenc_core/test/`
- Adapters (**not** modified, verified): `packages/myenc_adapters/test/`
- App (**not** modified, verified): `lib/`, `test/`

---

## ⚠️ Read first: two things that shape execution

### 1. A refactor is not four independent increments

The four user stories are **not** independently deliverable in the way feature stories
usually are. All four are served by one new source file plus wiring at three call sites.
US2 in particular is not an increment at all — it is the *acceptance gate* for the whole
change. Treating these phases as separately shippable slices would be dishonest about
the work.

What each phase *is* independently: a **verifiable checkpoint** with its own pass/fail
criteria. That is preserved, and the checkpoints are real. What it is not: something you
could ship alone and call value delivered.

### 2. The FR-013 retarget must be the last source-affecting commit

The freeze-guard retarget belongs to US2 (P1), but it carries a hard precondition from
constitution Principle II: the guard must be observed **green immediately before** the
retarget lands, which is what proves the edit is a deliberate hardening rather than a
repair. That observation is only meaningful once every other source change is in.

So the retarget is broken out into **Phase 7**, after US3 and US4, and carries the
`[US2]` label for traceability. Story labels mark ownership, not phase membership.

---

## Phase 1: Setup

**Purpose**: Establish the branch and capture the baseline that every acceptance
criterion is measured against.

- [x] T001 Create branch `002-format-version-registry` from `develop` (not `main`, not `001-folder-encryption`); confirm `git merge-base --is-ancestor develop HEAD` succeeds and that `packages/myenc_core/lib/src/format/payload_preamble.dart` and `packages/myenc_core/test/version_gate_test.dart` are **absent** — their presence means the wrong base branch
- [x] T002 Move `specs/002-format-version-registry/` onto the new branch if it is currently sitting in the `001-folder-encryption` working tree; run `flutter pub get` at the repository root to resolve path dependencies
- [x] T003 [P] Capture the baseline: record test counts from `cd packages/myenc_core && flutter test`, `cd packages/myenc_adapters && flutter test`, and `flutter test` at root. Save the base commit SHA. These are the reference for T023 and T030
- [x] T004 [P] Confirm the baseline is clean before touching anything: `git diff --exit-code -- docs/FORMAT.md packages/myenc_adapters/test/golden/` must exit 0

**Checkpoint**: On a branch off `develop`, baseline recorded, all three suites green.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Create the record. Every user story depends on it.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [x] T005 Create `packages/myenc_core/lib/src/format/format_version.dart` with the format-version entry type: immutable, `const` constructor, a single `number` field (`int`, 1–255). **Declare no capability field** — extensibility comes from the const-constructor-plus-defaulted-field shape, and spec FR-011 forbids shipping a flag that serves only unreleased work (see [research.md](./research.md) Decision 3)
- [x] T006 In `packages/myenc_core/lib/src/format/format_version.dart`, add the record: a `const` map of known versions containing exactly `{1: <v1 entry>}`, plus (a) a lookup that returns the entry for a given integer and throws `VersionTooNewError(n)` when absent — never returns null, never substitutes a nearest match; (b) the write-default version, stated in its own right and **not** derived from the map's maximum; (c) the first-unknown boundary, derived as the **smallest positive integer with no entry**. Do not use `max(keys)+1` or `length+1` — [research.md](./research.md) Decision 1 traces why both are wrong under a gapped record
- [x] T007 Export `src/format/format_version.dart` from `packages/myenc_core/lib/myenc_core.dart`, keeping the existing export ordering convention (format exports before ports before domain)
- [x] T008 Verify core purity and cleanliness: `cd packages/myenc_core && flutter analyze --no-pub` clean, and `grep -rn "package:flutter\|dart:io" lib/` returns nothing (constitution Principle III). Confirm no dependency was added to `packages/myenc_core/pubspec.yaml`

**Checkpoint**: The record exists, compiles, is exported, and nothing consumes it yet — so all three suites must still be green and unchanged.

---

## Phase 3: User Story 1 — Unknown versions are refused, never guessed at (Priority: P1) 🎯 MVP

**Goal**: The decode gate consults the record instead of comparing against a literal.
Absence means refusal.

**Independent Test**: Present the decoder with a container stamped at every version the
build has no entry for — `0`, and everything from the boundary through `255` — and
confirm each is refused with `VersionTooNewError` before any payload byte is read.

### Implementation for User Story 1

- [x] T009 [US1] In `packages/myenc_core/lib/src/format/myenc_codec.dart` (~line 89), replace `if (version > FileHeader.maxReadableVersion) throw VersionTooNewError(version);` with a record lookup that throws on absence. **The gate must contain no comparison against any version value** — an inequality against the boundary would re-admit version 0 and is the pattern this feature removes ([research.md](./research.md) Decision 2)
- [x] T010 [US1] Confirm the boundary computation is not reachable from `decodeHeader` in `packages/myenc_core/lib/src/format/myenc_codec.dart` — it iterates, and must not sit on the path that parses untrusted input (data-model.md invariant I5)
- [x] T011 [US1] Verify refusal ordering in `packages/myenc_core/lib/src/format/myenc_codec.dart`: the version check still precedes every other header-field validation and any payload read, so no partial plaintext can be emitted for an unreadable version (constitution Principle IV)
- [x] T012 [P] [US1] Verify the intentional tightening: a header whose version byte is `0x00` is now refused with `VersionTooNewError`. On `develop` it is **accepted** (empirically confirmed: `decodeHeader` returns a `FileHeader` with `version == 0`). This is the only input whose behaviour differs from the base — see [contracts/format_version_contract.md](./contracts/format_version_contract.md) §3
- [x] T013 [US1] Run `cd packages/myenc_core && flutter test`. The existing version tests must pass **unmodified**: `codec_test.dart:84` (refuses `0xFF`), `envelope_test.dart:819` (refuses `0xFF` end-to-end), and `codec_freeze_test.dart:133` (refuses `2`, with its literal still in place)

**Checkpoint**: The gate is a lookup. All 256 byte values behave correctly. No test file has been edited.

---

## Phase 4: User Story 2 — The refactor is provably behaviour-preserving (Priority: P1)

**Goal**: Establish, by measurement rather than assertion, that decode behaviour is
unchanged.

**Independent Test**: The independently-generated golden vectors and the byte-layout
freeze assertions pass with their files byte-identical to the base branch.

**Re-run this entire phase at every later checkpoint.** These are not one-time tasks —
they are the harness that keeps Phases 5–7 honest.

### Verification for User Story 2

- [x] T014 [P] [US2] Primary acceptance instrument: `cd packages/myenc_adapters && flutter test test/golden_vectors_test.dart`, then `git diff --exit-code -- test/golden_vectors_test.dart test/golden/`. Both must succeed. Regenerating the fixtures to accommodate this work is forbidden (constitution Principle II); a non-zero diff exit fails the feature outright
- [x] T015 [P] [US2] Run the byte-layout assertions in `packages/myenc_core/test/codec_freeze_test.dart` and confirm the file is still unmodified at this point (`git diff --exit-code -- test/codec_freeze_test.dart`)
- [x] T016 [P] [US2] Verify error identity is intact: `VersionTooNewError` keeps its type, name, `version` field, and `toString()` shape. `lib/shared/error_messages.dart` matches on **both** the type and its string form, so both must be preserved — run `flutter test` at the repository root and confirm `test/error_messages_test.dart` passes unmodified
- [x] T017 [P] [US2] Verify the isolate-boundary string contract is intact: `lib/core/isolate_worker.dart` maps `VersionTooNewError` to the `'version'` code and `lib/core/app_crypto.dart` plus `lib/features/decrypt/decrypt_progress_screen.dart` match on its string form. None of these files may be edited; confirm behaviour by running the root suite
- [x] T018 [P] [US2] Verify the failure-mode distinction still holds (constitution Principle IV): an unknown version raises the version error, **not** `CorruptedFileError` and **not** `WrongPassphraseError`; wrong-passphrase still fails at the DEK unwrap and a tampered body still fails at a chunk tag. Covered by the existing `envelope_test.dart` cases — confirm they pass unmodified
- [x] T019 [US2] Verify encode is byte-identical: `MyencCodec.encodeHeader` output is unchanged for every input, and the version byte's offset (5) and width (1) are untouched. Pinned by the existing freeze assertions

**Checkpoint**: Behaviour preservation is measured, not claimed. Golden fixtures and every test file still byte-identical to base.

---

## Phase 5: User Story 3 — Adding a future version touches one place (Priority: P2)

**Goal**: Pin the record's invariants, and prove a new version costs exactly one row.

**Independent Test**: The invariant suite passes; adding a throwaway row moves the
accept/refuse boundary by exactly one with no test file edited.

### Tests for User Story 3

> These tests pin an invariant this feature **introduces** (the record's contiguity),
> which has no equivalent on `develop`. They are not added to make a failing suite pass
> — see [research.md](./research.md) Decision 5 for why this is the permitted side of
> SC-004.

- [x] T020 [US3] Create `packages/myenc_core/test/format_version_test.dart` covering data-model.md invariants **I1** (the record's keys are exactly `1..n`, starting at 1 — a gap would silently relocate what the freeze guard covers) and **I2** (every entry's own number equals the key it is registered under)
- [x] T021 [US3] In `packages/myenc_core/test/format_version_test.dart`, add invariant **I3**: iterate all 256 byte values and assert each has a defined outcome — known values resolve to an entry, and `0` plus everything from the boundary through `255` throws `VersionTooNewError` (spec SC-002)
- [x] T022 [US3] In `packages/myenc_core/test/format_version_test.dart`, assert the boundary is the smallest absent positive integer and currently equals `2`, and that it is computed rather than stored
- [x] T023 [US3] Confirm the diff scope: exactly one test file differs from base at this point (`packages/myenc_core/test/format_version_test.dart`, new). Re-run Phase 4 (T014–T019)

### Implementation for User Story 3

- [x] T024 [US3] Prove no version decision escapes the record: `grep -rn "version" packages/myenc_core/lib | grep -E "[<>]=?|== *[0-9]"` returns nothing outside `format_version.dart`. Any surviving comparison against a version literal fails spec SC-001
- [x] T025 [US3] Demonstrate spec SC-007 and then discard it: temporarily add a row for version 2 to `packages/myenc_core/lib/src/format/format_version.dart`, editing **nothing else**. Confirm `codec_freeze_test.dart` and `format_version_test.dart` both stay green with **zero test edits** — the boundary moves from 2 to 3 on its own. Then `git checkout -- packages/myenc_core/lib/src/format/format_version.dart`. **The row must not be committed** (spec FR-011)

**Checkpoint**: The record's invariants are pinned, no version literal survives outside it, and the one-row property is demonstrated and reverted.

---

## Phase 6: User Story 4 — Write default and read boundary stop being one number (Priority: P2)

**Goal**: Separate the version new containers are stamped with from the highest version
the build can read.

**Independent Test**: Both values are queryable independently; a new container is still
stamped version 1; rewrap still re-emits the source version unchanged.

### Implementation for User Story 4

- [x] T026 [US4] In `packages/myenc_core/lib/src/domain/envelope_service.dart` (~line 87), source the header's version from the record's write default instead of `FileHeader.supportedVersion`
- [x] T027 [US4] In `packages/myenc_core/lib/src/format/file_header.dart`, convert `supportedVersion` from a stored `const` into a **derived getter** forwarding to the record's write default. It stores nothing and cannot disagree with the record, which satisfies spec FR-009's substance while keeping the 11 existing test references compiling (FR-014). **Do not annotate it `@Deprecated`** — `deprecated_member_use_from_same_package` would fire on all 11 in-repo references and fail `flutter analyze`, forcing exactly the test churn this getter exists to avoid. Add a doc comment recording that it is a compatibility alias slated for removal ([research.md](./research.md) Decision 4)
- [x] T028 [US4] Remove the interim constants if present: `maxReadableVersion` and `versionWithPayloadPreamble` must not exist in `packages/myenc_core/lib/src/format/file_header.dart`. On a correct base branch they are already absent (they belong to `001-folder-encryption`); their presence means T001 was done wrong
- [x] T029 [US4] Verify the pass-through paths in `packages/myenc_core/lib/src/domain/envelope_service.dart` (~lines 195 and 253) still re-emit `hdr.version` unchanged — rewrap and add-recipient must neither upgrade nor downgrade a container (spec FR-008)
- [x] T030 [US4] Confirm `FileHeader.version` remains a plain `int` and was not retyped to the entry type: `decodeHeader` must be able to report a version it has no entry for, which a field constrained to known versions could not represent (data-model.md, Relationship to existing types)
- [x] T031 [US4] In `packages/myenc_core/test/format_version_test.dart`, add invariant **I4**: the write default is 1 and is not derived from the record's maximum. Note this edits the same file as T020–T022, so it is **not** parallel with them
- [x] T032 [US4] Run all three suites. The existing `codec_freeze_test.dart:65` assertion (`expect(FileHeader.supportedVersion, 1)`) must still pass through the forwarding getter, along with the 9 references in `codec_test.dart` and `envelope_test.dart:191` — all unmodified. Re-run Phase 4 (T014–T019)

**Checkpoint**: All source changes are complete. Write default and read boundary are independent. Exactly one test file differs from base.

---

## Phase 7: The FR-013 Retarget — final source-affecting change

**Purpose**: Strengthen the freeze guard so it pins the fail-closed *rule* rather than
one instance of it.

**⚠️ This phase must run last, and its ordering is a constitutional requirement, not a
preference.** Principle II forbids editing a freeze guard to make a failing test pass.
The green-before observation in T033 is the evidence that this edit is a deliberate
hardening. It is only meaningful once every other source change is in — hence Phases 5
and 6 come first despite this task belonging to a P1 story.

- [x] T033 [US2] **GATE — do not skip.** With all source changes complete, run `cd packages/myenc_core && flutter test test/codec_freeze_test.dart` and observe it **green with the literal `2` still in the test**. Record the result. **If it is red, STOP**: the refactor changed decode behaviour, and retargeting the assertion at that point would be precisely the prohibited act of editing a freeze guard to make a failing test pass. Diagnose and fix the source instead
- [x] T034 [US2] In `packages/myenc_core/test/codec_freeze_test.dart` (~line 133), retarget the unknown-version case from the hardcoded literal `2` to the record's derived first-unknown boundary. **This is the only permitted edit to this file.** Commit it alone, touching no other file — the asserted value is unchanged (the boundary is 2 today), so the commit is provably value-neutral
- [x] T035 [US2] Re-run `flutter test test/codec_freeze_test.dart` and confirm green again, then `git show --stat HEAD` to confirm the commit touches exactly one file and one assertion. Green → green across a value-neutral commit is the proof this was hardening, not repair
- [x] T036 [US2] Confirm the byte-layout assertions in the same file are untouched: the diff must show only the unknown-version case changed

**Checkpoint**: The freeze guard now pins the rule and can never go stale at a future version bump.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [x] T037 Run `dart format .` at the repository root. CI fails on unformatted code before it reaches analyze, so this must pass before committing (constitution gate 1)
- [x] T038 Run all constitution quality gates: `dart format --set-exit-if-changed .`; `flutter analyze --no-pub && flutter test` at root; `flutter test && flutter analyze --no-pub` in `packages/myenc_core`; same in `packages/myenc_adapters`. Record gate 5 (`cd android && ./gradlew :app:testDebugUnitTest`) as **N/A — no Kotlin changed**, rather than skipping it silently
- [x] T039 [P] Confirm `docs/FORMAT.md` is unmodified: `git diff --exit-code -- docs/FORMAT.md`. §2 is frozen and §10 already states the rule this feature implements, so neither needs amendment (spec FR-012)
- [x] T040 [P] Final diff-scope audit: exactly **two** test files differ from the base commit — `packages/myenc_core/test/format_version_test.dart` (new) and `packages/myenc_core/test/codec_freeze_test.dart` (one assertion retargeted). No test anywhere was weakened, skipped, or deleted (spec SC-004)
- [x] T041 [P] Confirm no file outside `packages/myenc_core/` was modified: `git diff --name-only` against the base shows only paths under `packages/myenc_core/` and `specs/002-format-version-registry/` (spec FR-015)
- [x] T042 Walk [quickstart.md](./quickstart.md) end to end and tick every item in its §9 Definition of Done
- [x] T043 Verify commit hygiene: Conventional Commits with a scope (`refactor(core):` or `feat(core):`), and **no AI attribution of any kind** — no `Co-Authored-By`, no "Generated with" notice (constitution, Commits and releases)
- [x] T044 Record the deliberate follow-up so it is not silently dropped: removing the `FileHeader.supportedVersion` forwarding alias and migrating its 11 test references is a separate, mechanical, test-only change, **explicitly out of scope here** (plan.md Complexity Tracking row 2). File it as an issue or a note in the PR body
- [x] T045 Record the `001-folder-encryption` handoff in the PR body: once this merges, that branch rebases onto it, drops the interim `maxReadableVersion`/`versionWithPayloadPreamble` constants and `test/version_gate_test.dart`, and adds its version as **one row**. Its own freeze-guard failure resolves as a consequence of T034 with no further test edit — which is this feature demonstrating the property it was built for

---

## Dependencies & Execution Order

### Phase dependencies

```
Phase 1 (Setup)
   ↓
Phase 2 (Foundational — the record)     ← BLOCKS everything
   ↓
Phase 3 (US1 — the decode gate)          ← MVP
   ↓
Phase 4 (US2 — verification harness)     ← re-run after Phases 5, 6, 7
   ↓
Phase 5 (US3 — invariants)   ─┐
                              ├→ both must complete before Phase 7
Phase 6 (US4 — write/read)   ─┘
   ↓
Phase 7 (FR-013 retarget)    ← LAST source-affecting change; constitutional ordering
   ↓
Phase 8 (Polish)
```

### Story dependencies

- **US1 (P1)** — depends on Phase 2 only. The MVP.
- **US2 (P1)** — verification tasks (T014–T019) depend on US1. The retarget (T033–T036) additionally depends on **US3 and US4 being complete**, per constitution Principle II.
- **US3 (P2)** — depends on Phase 2. Independent of US4 except that T031 writes to the file T020 creates.
- **US4 (P2)** — depends on Phase 2. Independent of US3 except for that shared test file.

### Why Phase 7 breaks priority order

US2 is P1 but its final task runs after two P2 phases. This is deliberate: T033's
green-before observation is the constitutional justification for editing a freeze guard
at all, and it is only meaningful once the source is final. A proof must come after the
thing it proves.

### Parallel opportunities

- **Phase 1**: T003, T004 in parallel
- **Phase 3**: T012 parallel with T010/T011 (different concerns, no shared edit)
- **Phase 4**: T014–T018 all parallel — independent read-only verifications across different packages. The highest-value parallel block in the feature
- **Phase 5 / Phase 6**: the two phases can proceed concurrently **except** T031, which writes to the file T020 creates — sequence those two
- **Phase 8**: T039, T040, T041 in parallel

### Not parallel — common mistakes

- T005 → T006 → T007: same file, then dependent export
- T020, T021, T022, T031: all write `format_version_test.dart`
- T033 → T034 → T035: a strict ordered sequence; T033 is a gate whose result is the justification for T034
- T009 must not be parallel with anything in Phase 4 — the harness measures the gate's effect

---

## Parallel Example: Phase 4 verification harness

```bash
# Five independent verifications across three packages, no shared files:
Task: "T014 Golden vectors + git diff --exit-code on fixtures and test file"
Task: "T015 Byte-layout freeze assertions, confirm file unmodified"
Task: "T016 Error identity: type, name, toString, error_messages_test"
Task: "T017 Isolate-boundary string contract across app layer"
Task: "T018 Failure-mode distinction: version vs corrupt vs wrong-passphrase"
```

---

## Implementation Strategy

### MVP (Phases 1–4)

1. Setup + Foundational — the record exists, nothing consumes it, suites still green
2. US1 — the decode gate becomes a lookup
3. US2 verification harness — prove behaviour is preserved
4. **STOP and VALIDATE**: at this point the fail-closed guarantee routes through the
   record, the version-0 hole is closed, and no test file has been touched. This is a
   coherent, defensible, landable state.

### Then

5. US3 + US4 concurrently (minding the shared test file) — invariants pinned, write
   default separated
6. Phase 7 — the retarget, with its green-before gate
7. Phase 8 — gates, audits, handoff notes

### Do not

- Do not run Phase 7 before Phases 5 and 6. The gate loses its meaning and the edit
  becomes indefensible under Principle II.
- Do not edit a golden fixture, or any test file other than the two named in T040, to
  make something pass. A freeze-guard failure means the layout changed; the change is
  the bug (constitution Principle II).
- Do not commit the throwaway version-2 row from T025.
- Do not add a capability field for folder encryption. That coupling is what this
  feature exists to prevent (spec FR-011).

---

## Notes

- 45 tasks. Only `packages/myenc_core/` is modified: 1 new source file, 3 modified
  source files, 1 modified barrel, 1 new test file, 1 retargeted assertion.
- Two intentional deviations from the spec's literal text, both justified in plan.md
  Complexity Tracking: the freeze-guard edit (T034) and retaining
  `supportedVersion` as a derived alias (T027).
- One intentional behaviour change from base: version `0` is now refused (T012).
  Everything else must be bit-identical.
- Commit after each task or logical group; every checkpoint is a valid stopping point.
