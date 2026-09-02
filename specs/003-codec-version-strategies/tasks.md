# Tasks: Codec Version Strategies

**Feature branch**: `refactor/core-versioned-codec-seam` (off `develop`, after PR #61 merges)

**Execution rule**: fixtures are generated on the untouched code and committed first — every
later phase is proven against them. Any edit to a fixture, the freeze guard, or the golden
vectors after Phase 2 means the refactor leaked behaviour: revert, don't fix.

## Phase 1: Setup

- [ ] T001 Create branch `refactor/core-versioned-codec-seam` from `develop` (blocked on PR #61 merge approval)

## Phase 2: Foundational — pre-refactor fixtures (on untouched code)

- [ ] T002 [P] [US2] Generate the header corpus (shape matrix: zero/one/multiple wraps, encrypted-filename present/absent, boundary chunk sizes, flag variants → encoded hex) and the pinning test in `packages/myenc_core/test/fixtures/` + `packages/myenc_core/test/fixtures_header_corpus_test.dart`
- [ ] T003 [P] [US1] Generate the compatibility corpus (raw files: empty, 1 byte, small, >1 chunk, binary; `.latch` fixtures encrypted by the current code with a known test passphrase; manifest of raw-file SHA-256 hashes) in `packages/myenc_adapters/test/fixtures/compat_v1/`
- [ ] T004 [P] [US1] Write `packages/myenc_adapters/test/compat_v1_test.dart`: decrypt every fixture and assert plaintext hash == manifest; wrong-passphrase fixture fails fast at the key wrap; tampered-body fixture fails at a chunk tag with no partial plaintext
- [ ] T005 Commit 0 — fixtures + tests, green on untouched code (baseline counts: core 86, adapters 36, app 143)

## Phase 3: US1+US2 — the extraction (neutrality proof)

- [ ] T006 [US2] Move the v1 decode/encode body verbatim from `packages/myenc_core/lib/src/format/myenc_codec.dart` into `_V1Strategy` in `packages/myenc_core/lib/src/format/format_strategy_v1.dart`; the façade keeps minimum length + magic + version byte + `require()` gate and dispatches
- [ ] T007 Commit 1 — extraction. Acceptance: `codec_freeze_test.dart`, golden vectors, header corpus, and compat corpus all pass with zero edits

## Phase 4: US3+US4 — the machinery

- [ ] T008 [P] [US3] Create `FormatVersionStrategy` contract (pure `decode(bytes, offset) → (FileHeader, consumed)` / `encode(FileHeader) → bytes`) and the dispatch table keyed by `FormatVersion` entries in `packages/myenc_core/lib/src/format/format_strategy.dart`; export through the package public API
- [ ] T009 [P] [US3] Write the totality test in `packages/myenc_core/test/format_strategy_totality_test.dart`: dispatch key set == `FormatVersionRegistry.all` value set, both directions
- [ ] T010 [P] [US4] Write the rewrap round-trip test in `packages/myenc_core/test/`: parse → re-encode via the public `encodeHeader` → version byte and version-specific fields byte-identical
- [ ] T011 Commit 2 — machinery (contract + dispatch + totality + rewrap guards)

## Phase 5: US2 — attach the v1 battery to the strategy

- [ ] T012 [P] [US2] Move the v1 exhaustive battery (round-trips, per-field corruption, every-prefix truncation sweep, single-byte mutation sweep, random-garbage property tests) from `packages/myenc_core/test/codec_test.dart` into `packages/myenc_core/test/format_strategy_v1_test.dart`, targeting the strategy directly
- [ ] T013 [P] [US2] Keep the façade-level tests in `packages/myenc_core/test/codec_test.dart`: magic mismatch, version gate / `VersionTooNewError`, dispatch correctness, truncation at the prefix
- [ ] T014 Commit 3 — test reorganization (counts may only rise; `codec_freeze_test.dart` stays untouched)

## Phase 6: Polish & cross-cutting

- [ ] T015 SC-004 negative demonstration: temporarily remove the v1 strategy → totality test goes red → restore; record the evidence in the PR description
- [ ] T016 Run the full gates: `dart format .` + `flutter analyze --no-pub` + `flutter test` in all three packages; verify counts ≥ baseline plus the new suites; Android gate N/A (no Kotlin touched)
- [ ] T017 Open the PR against `develop`; body references `specs/003-codec-version-strategies/`, PRs #59/#61, BL-001/BL-004, and the four-commit discipline

## Dependencies

- Phase 2 blocks everything after it (fixtures must come from the untouched code).
- Phase 3 blocks 4 and 5 (dispatch must exist before totality/rewrap guards; the strategy must
  exist before its battery can target it).
- Phase 4 and 5 are independent of each other once Phase 3 lands; T008–T010 and T012–T013 are
  each parallelizable within their phase (different files).

## Story completion order

US1+US2 (neutrality) → US3 (totality) → US4 (rewrap). US1's negative fixtures and US2's
corpus are generated together in Phase 2 because both must precede the extraction.

## Parallel execution examples

- Phase 2: T002, T003, T004 in parallel (different packages/files, all read-only w.r.t. source).
- Phase 4: T008, T009, T010 in parallel.
- Phase 5: T012, T013 in parallel.

## Independent test criteria

- US1: `flutter test test/compat_v1_test.dart` in `packages/myenc_adapters` — green on
  pre-refactor fixtures, unedited.
- US2: `flutter test test/fixtures_header_corpus_test.dart test/format_strategy_v1_test.dart`
  in `packages/myenc_core` — corpus byte-identical, battery green.
- US3: `flutter test test/format_strategy_totality_test.dart` — red without the strategy,
  green with it.
- US4: rewrap round-trip test in `packages/myenc_core/test/` — version byte and
  version-specific fields byte-identical.

## MVP scope

User Story 1 + 2 (Phases 1–3 + Phase 5 battery): the neutrality proof — pre-refactor
fixtures, extraction, and the v1 battery attached to the strategy. US3/US4 (Phase 4) are the
machinery payoff and ship in the same PR per the four-commit plan.
