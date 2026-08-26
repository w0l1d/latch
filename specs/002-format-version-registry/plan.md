# Implementation Plan: Central Format-Version Registry

**Branch**: `002-format-version-registry` | **Date**: 2026-08-26 | **Spec**: [spec.md](./spec.md)

**Base**: `develop` — independent of `001-folder-encryption`

**Input**: Feature specification from `/specs/002-format-version-registry/spec.md`

## Summary

Replace the single loose version constant and the bare inequality that guards
`.latch` header decoding with one authoritative record of known container versions.
The record answers three questions that are currently conflated into one number:
*which versions exist*, *where the known/unknown boundary lies*, and *which version
new containers are stamped with*.

Externally, nothing changes. The record holds exactly one row (v1), so the decoder
accepts and refuses exactly what it accepted and refused on `develop`, with the same
error type. The two freeze guards are the acceptance instrument and both pass
untouched, with one deliberate strengthening (FR-013) made while the guard is green.

**Technical approach**: a new pure-Dart value type and const table in
`packages/myenc_core/lib/src/format/`, exported from the package barrel. The decode
gate becomes a map lookup that throws on absence. `FileHeader.supportedVersion` is
retained as a *derived forwarding getter* rather than deleted outright — see
Complexity Tracking for why, and the follow-up that removes it.

## Technical Context

**Language/Version**: Dart, SDK `^3.12.2`. Flutter pinned to 3.44.2 in CI, but
`myenc_core` is pure Dart and imports neither Flutter nor `dart:io`.

**Primary Dependencies**: None added. `myenc_core` has no runtime dependencies and a
single dev dependency (`test: ^1.24.0`). This feature introduces no dependency of any
kind — a deliberate constraint, since the point is to remove indirection rather than
add machinery.

**Storage**: N/A. The record is compile-time constant data; nothing is persisted, read,
or cached at runtime.

**Testing**: `package:test`, run as `flutter test` inside each package directory.
Verification spans all three packages because the acceptance criteria are
*non*-changes in two of them.

**Target Platform**: Platform-agnostic pure-Dart library, consumed by
`packages/myenc_adapters` and the root Flutter app on Android, iOS, and desktop.

**Project Type**: Library — one of three independently analyzed and tested packages in
a hexagonal layout.

**Performance Goals**: Version resolution sits on the header-decode path, executed once
per container. It must be a constant-time lookup with no allocation. The
smallest-absent-version computation (`firstUnknown`) iterates and therefore MUST NOT
be reachable from the decode path — it exists for tests and for callers naming the
boundary.

**Constraints**:
- No byte of the v1 wire layout may change; `docs/FORMAT.md` §2 untouched.
- Decode behaviour must be bit-identical to `develop` — provable by decrypting the
  golden vector on both and comparing.
- `myenc_core` must not import Flutter or `dart:io`.
- No behaviour change in `packages/myenc_adapters` or the app layer.
- The version-too-new error type keeps its identity, because the app layer already
  translates it into user-facing copy.
- Version refusal must remain ordered *before* any payload byte is read.

**Scale/Scope**: One row today; 255 possible rows ever. Five call sites in
`packages/myenc_core`, one new source file, one new test file, one strengthened
assertion in an existing test. No other package is edited.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design — see below.*

| Principle | Verdict | Basis |
| --- | --- | --- |
| **I. Offline, Stateless, No Recovery** (NON-NEGOTIABLE) | **PASS** | No network, storage, or unlock path is touched. The feature strengthens the opposite of a recovery path: it makes "refuse what we cannot interpret" a stated rule rather than an inequality. No escrow, hint, reset, or alternate door is introduced. |
| **II. The `.latch` v1 Format Is Frozen** (NON-NEGOTIABLE) | **PASS — with a declared, justified freeze-guard edit** | No wire byte moves; `docs/FORMAT.md` §2 is untouched and §10 already states the rule being implemented. The principle's hard prohibition is on editing a freeze guard *to make a failing test pass*. FR-013 does not do that: the assertion is green on `develop`, green after the refactor with the literal untouched, and green after the retarget — the retarget changes the assertion's *form*, not its value or its outcome. See Complexity Tracking row 1 for the enforcement that keeps this honest. |
| **III. Hexagonal Purity — the Core Stays Auditable** | **PASS — improves it** | Entirely within `packages/myenc_core/lib/src/format/`. Pure Dart, zero imports beyond the package's own error type. No port is needed because no platform contact is involved. Net effect on audit surface is a reduction: one place to read instead of five to correlate. |
| **IV. Fail Closed, Never Emit Partial Plaintext** | **PASS — reinforced** | The refusal stays ordered before any body chunk is touched, and stays a distinct typed error rather than collapsing into `CorruptedFileError`. Absence in the record is refusal, never a default or a guess. FR-004 extends the covered range to include version 0, which the base branch's inequality (`version > 1`) silently *accepted*. |
| **V. Independent Verification Over Self-Consistency** | **PASS — this principle is the acceptance instrument** | The externally-generated golden vectors and the byte-layout freeze assertions are what prove behaviour preservation, and neither may be edited (FR-014). Additionally, the gaplessness invariant (FR-006) is exactly the "mapping that must be exact" case the principle calls out: because the boundary is *derived* from the record, drift is invisible in a running build and therefore must be unit-tested. |

**Quality gates** (constitution, Development Workflow): all five gates apply and are
enumerated as explicit verification steps in [quickstart.md](./quickstart.md). Gate 5
(`gradlew :app:testDebugUnitTest`) is not applicable — no Kotlin changes — and is
recorded as N/A rather than skipped silently.

**Result: PASS.** One item requires justification rather than being a clean pass; it is
documented in Complexity Tracking rather than waved through.

## Project Structure

### Documentation (this feature)

```text
specs/002-format-version-registry/
├── spec.md                              # Feature specification
├── plan.md                              # This file
├── research.md                          # Phase 0 — design decisions and rejected alternatives
├── data-model.md                        # Phase 1 — the record and its entry type
├── quickstart.md                        # Phase 1 — how to verify behaviour preservation
├── contracts/
│   └── format_version_contract.md       # Phase 1 — public API surface of myenc_core
├── checklists/
│   └── requirements.md                  # Spec quality checklist
└── tasks.md                             # Phase 2 — NOT created by /speckit-plan
```

### Source Code (repository root)

Only `packages/myenc_core` is touched. The other two packages appear here solely to
record that their non-modification is a deliberate acceptance criterion.

```text
packages/myenc_core/                          # THE ONLY PACKAGE MODIFIED
├── lib/
│   ├── myenc_core.dart                       # MODIFIED — export the new file
│   └── src/
│       ├── format/
│       │   ├── format_version.dart           # NEW — the record and its entry type
│       │   ├── file_header.dart              # MODIFIED — supportedVersion becomes derived
│       │   ├── myenc_codec.dart              # MODIFIED — decode gate consults the record
│       │   └── myenc_errors.dart             # UNCHANGED — error identity preserved
│       └── domain/
│           └── envelope_service.dart         # MODIFIED — write default from the record
└── test/
    ├── format_version_test.dart              # NEW — record invariants and full-byte-range gate
    ├── codec_freeze_test.dart                # MODIFIED — one assertion retargeted (FR-013 only)
    ├── codec_test.dart                       # UNCHANGED — must pass as-is
    └── envelope_test.dart                    # UNCHANGED — must pass as-is

packages/myenc_adapters/                      # NOT MODIFIED — verified, not assumed
└── test/
    ├── golden_vectors_test.dart              # UNCHANGED — acceptance instrument
    └── golden/                               # UNCHANGED — fixtures not regenerated

lib/, test/                                   # NOT MODIFIED — app layer untouched
docs/FORMAT.md                                # NOT MODIFIED — §2 frozen, §10 already correct
```

**Structure Decision**: The existing three-package hexagonal layout is kept as-is and
no new package, directory, or layer is introduced. The record belongs in
`lib/src/format/` beside `file_header.dart` and `myenc_codec.dart` because it describes
the wire format, not domain policy — the same reason `FileHeader` lives there. It is
exported from the package barrel `lib/myenc_core.dart` because tests in
`packages/myenc_adapters` and the freeze guard reach it through the public surface.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| **Editing `codec_freeze_test.dart`**, which Principle II forbids editing to make a failing test pass (spec FR-013) | The guard currently hardcodes `2` as its example of an unknown version. That pins one *instance* of the fail-closed rule, so it goes stale at the next version bump and starts asserting the opposite of what it means. Retargeting it to the record's derived boundary makes it pin the rule itself, permanently. | Leaving the literal `2` in place was rejected because it defers a guaranteed future failure into the branch that can least afford it — the one adding a version, where a red freeze guard is indistinguishable from a real layout regression. **Enforcement that keeps this within the principle:** the retarget lands as its own commit, and the guard must be observed green immediately *before* and immediately *after* it. That sequence is what proves the edit is a deliberate hardening rather than a fix for a failure, and it is a required verification step in quickstart.md. The value asserted is unchanged (`firstUnknown == 2` today), so the commit is provably value-neutral. |
| **`FileHeader.supportedVersion` is retained as a derived forwarding getter rather than deleted**, where spec FR-009 says the constant must be removed | The identifier has 11 references across existing tests — `codec_test.dart` (×9), `envelope_test.dart:191`, and `codec_freeze_test.dart:65`. Deleting it would force edits to two test files that FR-014 requires pass unmodified, and one of those (`codec_freeze_test.dart:65`, `expect(FileHeader.supportedVersion, 1)`) is itself a freeze assertion on the write default that is *valuable to keep working*. FR-009's substance is "no second source of truth", and a getter that returns `FormatVersion.writeDefault.number` stores nothing and can never disagree with the record. | Deleting the constant and updating 11 test references in the same change was rejected because it converts a provably behaviour-preserving refactor into one with a wide test diff, destroying the property that makes it reviewable — the reviewer could no longer tell an unchanged test from an adjusted one. **Follow-up:** removing the alias and migrating its references is a separate, mechanical, test-only change that can land immediately after, when its diff is legible in isolation. It is deliberately out of scope here and must be recorded as such in `tasks.md`. |

---

## Constitution Check — post-design re-evaluation

*Re-run after Phase 1. Design artifacts: [research.md](./research.md),
[data-model.md](./data-model.md),
[contracts/format_version_contract.md](./contracts/format_version_contract.md),
[quickstart.md](./quickstart.md).*

The design surfaced one fact that the pre-design check did not have, and it changes the
answer for Principle IV.

**New finding.** The base branch's gate is `version > 1`, so **a container stamped
`0x00` is accepted today**. Verified empirically rather than inferred: decoding such a
header on the current tree returns a well-formed `FileHeader` with `version == 0`. A
record lookup refuses `0` for the same reason it refuses `200` — absence — so the hole
closes as a consequence of the design rather than needing a special case.

| Principle | Pre-design | Post-design | Change |
| --- | --- | --- | --- |
| I. Offline, Stateless, No Recovery | PASS | **PASS** | No change. No network, storage, or unlock path is touched. |
| II. `.latch` v1 Format Frozen | PASS with justification | **PASS with justification** | Unchanged, and the justification is now *enforceable* rather than asserted: quickstart.md step 3a requires the freeze guard be observed **green before** the retarget commit, with an explicit stop condition if it is red. That sequence is the evidence the edit is a hardening and not a repair. |
| III. Hexagonal Purity | PASS | **PASS** | Confirmed by design: one new pure-Dart file in `lib/src/format/`, no port, no platform contact, no new dependency of any kind. |
| IV. Fail Closed, Never Emit Partial Plaintext | PASS (reinforced) | **PASS — materially strengthened** | Upgraded on evidence. The feature closes a real fail-open hole the source brief did not identify. All 256 byte values now have a defined, tested outcome (data-model.md I3) where the base branch left one accepting a value it should refuse. Refusal ordering, and the distinction between the version error and `CorruptedFileError`/`WrongPassphraseError`, are pinned in the contract. |
| V. Independent Verification | PASS | **PASS** | Sharpened into a hard gate: quickstart.md step 2 requires `git diff --exit-code` over the golden fixtures *and* their test file, so "unmodified" is measured rather than claimed. The gaplessness invariant is a dedicated test, not a runtime `assert` — an `assert` is stripped in release builds, so it would be absent exactly where a malformed record does damage (research.md Decision 5). |

**Complexity Tracking re-check.** Both rows stand, neither grew, and no new violation
appeared. Row 1's enforcement is now concrete (quickstart step 3a). Row 2's follow-up —
removing the `supportedVersion` forwarding alias — must be recorded in `tasks.md` as
explicitly out of scope here, so it is not silently dropped.

**Design-time scope confirmation.** Verified against `develop` rather than assumed:
`packages/myenc_core/lib/src/format/payload_preamble.dart` does **not** exist there, and
neither does `test/version_gate_test.dart`. Both are artifacts of
`001-folder-encryption`. This confirms the record can be designed with no reference to
folder encryption, which is what spec FR-011 requires and what keeps the dependency
one-way.

**Result: PASS.** Ready for `/speckit-tasks`.
