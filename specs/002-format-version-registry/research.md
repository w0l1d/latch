# Phase 0 Research: Central Format-Version Registry

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Date**: 2026-08-26

The Technical Context in plan.md carries no `NEEDS CLARIFICATION` markers: the language,
dependencies, testing approach, and constraints are all fixed by the existing repository
and the constitution. What needed research was not the stack but the design — five
decisions where a plausible-looking choice silently weakens the fail-closed guarantee.

All findings below were verified against `develop`, not assumed.

---

## Baseline: what `develop` actually does

Established by inspection before any design work, because the whole feature is defined
as *behaviour-preserving relative to this*:

| Site | Code on `develop` |
| --- | --- |
| `format/file_header.dart:5` | `static const int supportedVersion = 1;` |
| `format/myenc_codec.dart:29` | `buf.setUint8(o++, h.version);` — writes whatever the caller set |
| `format/myenc_codec.dart:89` | `if (version > FileHeader.supportedVersion) throw VersionTooNewError(version);` |
| `domain/envelope_service.dart:87` | `version: FileHeader.supportedVersion` — the only writer |
| `domain/envelope_service.dart:195,253` | `version: hdr.version` — rewrap and add-recipient pass-through |

One constant serves two unrelated roles, and the only question ever asked of the byte is
whether it exceeds that constant.

**Finding that changed the design:** the gate is `version > 1`, so **version 0 is
currently accepted**. `develop` decodes a container stamped `0x00` as though it were
well-formed. This was not in the source brief. It is not a live vulnerability — no
writer emits 0, and the fields behind the version byte are still validated — but it is a
real hole in the fail-closed story and closing it is free here, because a record lookup
refuses 0 for the same reason it refuses 200: absence.

**Note this is the one intentional behaviour difference from `develop`.** It is a
*tightening* (a previously-accepted value is now refused), it cannot break any container
any Latch version ever wrote, and no existing test asserts that 0 decodes. It is called
out explicitly here so it is not mistaken for an accident during review.

---

## Decision 1 — How `firstUnknown` is derived

**Decision**: `firstUnknown` is the **smallest positive integer with no entry** in the
record.

**Rationale**: This is the literal meaning of the name, and it is the only definition
that stays correct if the record is ever malformed. Correctness under malformation
matters here specifically because `firstUnknown` is what the freeze guard asserts
against (FR-013) — a definition that degrades quietly would disarm the guard rather
than fail it.

Traced against a hypothetical gapped record `{1, 3}`:

| Definition | Result | Consequence |
| --- | --- | --- |
| **smallest absent** (chosen) | `2` | Correct. The guard tests the true boundary. The gaplessness test (FR-006) still fails loudly, so the gap is caught — but the guard was never disarmed in the meantime. |
| `all.length + 1` | `3` | Wrong, and dangerously so: 3 *is* a known version, so the guard would assert a readable version is refused and fail — but with a message pointing at the guard rather than at the malformed record. Diagnosis lands in the wrong place. |
| `max(keys) + 1` | `4` | Wrong and silent. Version 2 is genuinely unknown and correctly refused by `require`, but the guard skips over it and tests 4 instead. The guard keeps passing while no longer covering the real boundary — precisely the failure the spec's edge case warns about. |

**Alternatives considered**: `max(keys) + 1` was the intuitive first choice and is what
the phrase "first unknown" loosely suggests when gaplessness is taken for granted.
Rejected because taking gaplessness for granted is exactly what the invariant test
exists to stop, and a derived value must not assume the invariant it is protected by.

**Consequence**: the computation iterates and so must never reach the decode path. See
Decision 2.

---

## Decision 2 — What the decode path is allowed to call

**Decision**: the decode gate calls **only** the map lookup (`require`). `firstUnknown`
is never reachable from `decodeHeader`.

**Rationale**: two reasons, and the second is the load-bearing one.

1. Cost. `require` is a constant-time lookup on a `const` map with no allocation.
   `firstUnknown` iterates from 1 upward. Header decode runs once per container, so the
   difference is immaterial in wall-clock terms — but there is no reason to put an
   unbounded loop on the path that parses untrusted input.
2. Semantics. A decoder that asks "where is the boundary?" and then compares is back to
   an inequality, with the record demoted to a lookup table feeding the same comparison
   the feature exists to remove. The gate must ask "is there an entry for this byte?"
   and refuse on absence. That is what makes version 0 fall out correctly instead of
   needing a special case.

**Alternatives considered**: `if (version >= FormatVersion.firstUnknown) throw …`.
Rejected — it is the original inequality with a longer right-hand side. It re-admits
version 0, and it would need a second explicit check to close that, which is the
scattering the record is meant to end.

---

## Decision 3 — Extensibility without declaring a capability now

**Decision**: the entry is a class with a `const` constructor. A future capability is
added as a new `final` field with a default value. **No capability field ships in this
feature.**

**Rationale**: spec FR-010 requires the record be extensible with per-version
capabilities; FR-011 forbids declaring one that exists only to serve unreleased work.
Both are satisfied structurally rather than by adding anything: a class with a const
constructor and defaulted fields can gain a capability without touching a single call
site or existing row. Extensibility is a property of the shape, so it needs no
placeholder to demonstrate — and a placeholder is precisely what FR-011 forbids.

This is the decision that keeps 002 independent of 001. Shipping a payload-preamble
flag here would relocate the coupling rather than remove it, and would additionally
require a payload-kind type that does not exist on `develop` at all — verified:
`packages/myenc_core/lib/src/format/payload_preamble.dart` is absent from `develop`.

**Alternatives considered**:
- Ship `hasPayloadPreamble: false` on v1 now, so the consuming branch adds only a row.
  Rejected: it names a feature this build has no concept of, and the spec forbids it.
  The saving is one field on one row.
- Model capabilities as a `Set<enum>` rather than named fields. Rejected as premature —
  it needs a populated enum to be meaningful, so it cannot be introduced without
  violating FR-011 either. Named boolean fields are also cheaper to read, which matters
  in the package whose selling point is being small enough to audit.

---

## Decision 4 — Splitting the write default from the read boundary

**Decision**: the record states the write default explicitly as its own member.
`FileHeader.supportedVersion` is retained as a getter that forwards to it, storing
nothing.

**Rationale**: the two values are independent by design and must be able to move
independently — raising the read boundary must never drag the write default up, or every
newly written container becomes unopenable by installs that could have read it. On
`develop` they are one constant, so that separation is impossible to express.

The forwarding getter resolves a genuine conflict between two spec requirements. FR-009
says the constant must go; FR-014 says every other existing test must pass unmodified.
The identifier has 11 test references, so both cannot hold literally. A getter satisfies
FR-009's substance — there is exactly one place the number lives, and the alias cannot
disagree with it — while preserving FR-014 in full. It also keeps
`codec_freeze_test.dart:65` (`expect(FileHeader.supportedVersion, 1)`) working, which is
desirable: that is a freeze assertion on the write default and should keep firing.

**Deliberately not annotated `@Deprecated`.** The `deprecated_member_use_from_same_package`
lint would then fire on all 11 in-repo references and fail `flutter analyze`, so the
annotation would force the very test churn the getter exists to avoid. A doc comment
records the intent instead, and removal is a separate follow-up. Recorded here so the
omission reads as a decision, not an oversight.

**Alternatives considered**: delete the constant and update all 11 references in this
change. Rejected — it turns a diff whose reviewability *is* the deliverable into one
where an unchanged test cannot be distinguished from an adjusted one. The migration is
mechanical and lands cleanly on its own afterwards.

---

## Decision 5 — Where the gaplessness invariant is asserted

**Decision**: a new test file, `packages/myenc_core/test/format_version_test.dart`,
asserting that the record is contiguous and begins at 1, alongside full-byte-range gate
coverage.

**Rationale**: constitution Principle V requires that a mapping whose drift is invisible
in a running build be unit-tested. This is that case exactly: a gap does not crash, does
not corrupt, and does not fail any existing test — it silently relocates what the freeze
guard covers. It must be asserted directly.

A new file is the right home rather than appending to `codec_freeze_test.dart`, which is
scoped to the frozen v1 byte layout and is a guard this feature must minimally disturb.

**On SC-004's "no test is added to make a failing suite pass":** this file adds no
coverage of existing behaviour and fixes no failure — it pins a new invariant introduced
by this feature (the record's contiguity), which has no equivalent on `develop` because
there is no record. Distinguishing the two is the point of the criterion, and this is the
permitted side of it.

**Alternatives considered**: asserting contiguity with a runtime `assert` in the record
itself. Rejected — `assert` is stripped in release builds, so the check would be absent
exactly where a malformed record does damage, and it cannot be observed by a reviewer
reading the test suite.

---

## Summary of resolved unknowns

| Question | Resolution |
| --- | --- |
| How is the known/unknown boundary derived? | Smallest positive integer absent from the record (Decision 1) |
| What does the decode gate call? | The map lookup only; refusal is absence, not comparison (Decision 2) |
| How is the record extensible without coupling to unreleased work? | `const` constructor plus defaulted fields; no capability ships now (Decision 3) |
| How do write default and read boundary separate without breaking 11 test references? | Record states the default; `FileHeader.supportedVersion` forwards to it, un-annotated (Decision 4) |
| Where does the gaplessness invariant live? | New dedicated test file, not a runtime `assert` (Decision 5) |
| Is version 0 in scope? | Yes — `develop` accepts it; the record refuses it. The one intentional behaviour change, a tightening (Baseline) |
