# Feature Specification: Central Format-Version Registry

**Feature Branch**: `002-format-version-registry`

**Base**: `develop` — independent of `001-folder-encryption`

**Created**: 2026-08-26

**Status**: Draft

**Input**: User description: "There is no central place that answers 'what does container version N mean?'. Version handling is one integer and one comparison spread across five sites in `packages/myenc_core`. Replace it with a single version table that states which versions exist and fails closed on the rest. Scope: `packages/myenc_core` only. No wire-format change. No `.latch` byte moves."

## Overview

A `.latch` container carries a single-byte format version. `docs/FORMAT.md` §10 states
the compatibility rule in prose: *the version byte is the only compatibility signal,
and a reader rejects versions it predates with a clear "update the app" error.* That
sentence has no single implementation. Instead the byte is compared against a loose
constant at the point of decode, and that same constant doubles as the version new
containers are stamped with — so "what we can read" and "what we write" are one
number that cannot be moved independently.

This feature gives that sentence one implementation: an authoritative record of the
container versions this build knows, which the decoder consults instead of comparing
against a literal.

**Behaviour is preserved, with exactly one intentional exception.** The same containers
are accepted, the same containers are refused, the refusal is the same error, and no
byte of the wire format moves. That is the point — a refactor whose behaviour differs
from its base is not this feature.

The exception is a tightening. The base branch's gate is `version > 1`, so a container
stamped `0x00` is currently **accepted** — verified empirically, not inferred. A record
lookup refuses `0` for the same reason it refuses `200`: there is no entry. No writer
has ever emitted `0`, so no container that exists is affected, and no existing test
asserts that `0` decodes. It is stated here so it is not mistaken for an accident.

### Why this stands alone

This is a refactor of shipped decode behaviour, and it is specified against
`develop` with no knowledge of any unreleased feature. The design problem exists
today, at one version, and compounds at every future version regardless of what else
ships. Work that introduces a new container version depends on this record existing;
this record must not depend on, reference, or anticipate any particular future
version. A registry that ships a capability flag for a feature on another branch has
simply relocated the coupling it was meant to remove.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A container from a newer app is refused, never guessed at (Priority: P1)

Someone receives a `.latch` file produced by a future version of Latch that this
install predates. They open it. The app refuses it immediately with a clear "update
the app" message, and never attempts to interpret the container under assumptions
that do not hold for it.

**Why this priority**: This is the user-visible safety property the feature exists to
protect, and the only one with consequences if it regresses. A version byte that is
guessed at rather than refused is the path to a reader interpreting a payload under
the wrong rules. It must hold before any other part of this work matters.

**Independent Test**: Present the decoder with a container stamped at every version
value the build has no entry for — from the first unknown value through 255, and
including 0 — and confirm each is refused with the version-too-new error before any
payload byte is read.

**Acceptance Scenarios**:

1. **Given** a container whose version byte has no entry in the record, **When** the
   user opens it, **Then** it is refused before any payload is processed, with the
   version-too-new error, and the user sees the same "update the app" message as
   before this change.
2. **Given** a container whose version byte does have an entry, **When** the user
   opens it, **Then** it decodes exactly as it did on the base branch — byte-for-byte
   identical output.
3. **Given** a version byte of 0, **When** it is decoded, **Then** it is refused. There
   is no version 0 and it must not be treated as unset or defaulted.

---

### User Story 2 - The refactor is provably behaviour-preserving (Priority: P1)

A reviewer needs to be convinced that replacing the version check changed no
behaviour. They run the two independent freeze guards — the byte-layout freeze test
and the externally-generated golden vectors — without touching either, and both pass.

**Why this priority**: Co-P1 with Story 1, because it is the acceptance instrument for
the whole change rather than a feature of it. A refactor of crypto-adjacent decode
logic that cannot be shown to preserve behaviour is not reviewable, and the guards are
worthless if this work is allowed to adjust them.

**Independent Test**: Run every existing test in all three packages against the
refactored core with no test file modified except the single retarget in FR-013.
Everything passes.

**Acceptance Scenarios**:

1. **Given** the independently-produced golden vectors and their test, **When** they
   run against the refactored core, **Then** they pass with the fixtures and the test
   file unmodified.
2. **Given** the byte-layout assertions in the format freeze guard, **When** they run,
   **Then** they pass unmodified.
3. **Given** the full test suites of all three packages, **When** they run, **Then**
   the only test file that differs from the base branch is the freeze guard, and its
   one changed assertion is stronger, not weaker.

---

### User Story 3 - Adding a future format version touches one place (Priority: P2)

A maintainer needs to introduce a new container version. They add one row to the
record. Nothing else in the core package must be found, understood, or edited for the
decoder to accept it, and no other file holds a number that must be kept in step by
hand.

**Why this priority**: This is the durable value and the reason the symptom cannot
just be patched. It is not required for correct behaviour today, so it ranks below the
two P1 stories — but every future version bump pays the cost of not having it.

**Independent Test**: Search the core package for any decision made against a version
literal outside the record; the search returns nothing. Then add a throwaway row and
observe the accept/refuse boundary move by exactly one with no other source edit.

**Acceptance Scenarios**:

1. **Given** the refactored core package, **When** it is searched for version
   comparisons against hard-coded numbers, **Then** none exist outside the record.
2. **Given** the record, **When** a maintainer asks "what does version N mean?",
   **Then** the answer is a row, not an inequality to be interpreted.
3. **Given** one row added for a hypothetical next version, **When** the decoder is
   exercised, **Then** that version is accepted, the next-higher one is refused, and
   the freeze guard still passes with no edit — because it names the boundary rather
   than a value.

---

### User Story 4 - What we write and what we read stop being one number (Priority: P2)

A maintainer needs to reason about, or change, the version stamped on new containers
without touching the highest version the build can read — or the reverse.

**Why this priority**: Today one constant answers both questions, so the two cannot
move independently even though they are independent by design: raising the read
ceiling must never drag the write default up with it, or every newly written container
becomes unopenable by installs that could have read it. Separating them is a
prerequisite for any future version bump being safe, but it changes nothing today
(both values are 1), so it is P2.

**Independent Test**: Query the record for the write-default version and for the
known/unknown boundary separately, and confirm each is stated in its own right rather
than derived from the other.

**Acceptance Scenarios**:

1. **Given** the record, **When** the write default and the read boundary are queried,
   **Then** each is answered independently, and today both are consistent with the
   frozen v1 behaviour.
2. **Given** a plain container written after this change, **When** its version byte is
   inspected, **Then** it is 1, unchanged.

---

### Edge Cases

- **Version byte is 0**: No such version. Refused fail-closed, not defaulted.
- **The record has a gap**: Because the known/unknown boundary is *derived* from the
  record, a row added for a version the codec cannot actually read would silently
  relocate the boundary and the fail-closed guard would stop testing what it claims
  to. The record must be contiguous and begin at 1, and that must be asserted rather
  than assumed. This is the single most important invariant introduced here.
- **Write default drifts upward**: The version stamped on new containers must not
  follow the read boundary upward. See Story 4.
- **Rewrap and add-recipient**: These re-emit an existing container's version rather
  than choosing one. They must keep carrying the original version through unchanged —
  a rewrap must neither upgrade nor downgrade a container.
- **Error identity**: The refusal must stay the same error type the app layer already
  translates into user-facing copy, or a message regresses for no benefit.
- **An empty or single-row record**: The record legitimately holds exactly one row
  today. The design must not require two rows to be coherent, and must not invent a
  second one to look complete.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The core package MUST contain exactly one authoritative record of the
  container versions it knows, keyed by version number.
- **FR-002**: The decoder MUST decide whether to accept a container's version by
  consulting that record, and MUST NOT compare the version byte against any literal
  outside it.
- **FR-003**: A version with no entry MUST be refused with the existing
  version-too-new error, before any payload data is read or emitted.
- **FR-004**: Every version value with no entry MUST be refused — 0, and every value
  from the first unknown value through 255 inclusive.
- **FR-005**: The record MUST expose the first unknown version as a value derived from
  its own contents, so callers and tests can name the known/unknown boundary without
  restating a number.
- **FR-006**: The record MUST be contiguous and MUST begin at version 1, and this MUST
  be asserted by a test — because FR-005 derives the boundary from the record, a gap
  would silently move it.
- **FR-007**: The record MUST state the version stamped on newly written containers
  independently of the read boundary. That value MUST remain 1.
- **FR-008**: Paths that re-emit an existing container's version MUST carry the
  original version through unchanged.
- **FR-009**: The version constant currently held on the file-header type MUST be
  removed in favour of the record, leaving no second source of truth. Its two present
  roles — write default and read ceiling — MUST be separated per FR-007.
- **FR-010**: The record MUST be extensible with per-version capability information
  without changes at its call sites, so a future version can declare what it can carry.
- **FR-011**: The record MUST NOT declare any capability flag, version row, or type
  that exists only to serve an unreleased feature. It describes what this build knows.
- **FR-012**: No byte of the v1 wire layout may change. `docs/FORMAT.md` §2 MUST remain
  untouched; §10 already states the rule being implemented and needs no amendment.
- **FR-013**: The freeze guard's unknown-version case MUST be retargeted from the
  hard-coded literal `2` to the record's derived first-unknown value. Today these are
  the same number, so the assertion's effect is unchanged — but it then pins the rule
  instead of one instance of it and can never go stale at a future bump. **This is the
  only intended test edit in this feature.**
- **FR-014**: Every other existing test in all three packages MUST pass unmodified,
  including the externally-generated golden vectors and the byte-layout freeze
  assertions.
- **FR-015**: Changes MUST be confined to `packages/myenc_core`. No behaviour of
  `packages/myenc_adapters` or the application layer may change, and the error type
  the application already translates MUST keep its identity.
- **FR-016**: The core package MUST remain free of Flutter and `dart:io` imports.

### Key Entities

- **Format version entry**: One known container version. Carries its number and,
  where a future version needs it, that version's capabilities. Declared, not computed.
- **Format version record**: The complete, contiguous set of known entries, keyed by
  number. The single authority on which versions exist, where the known/unknown
  boundary lies, and which version new containers are written at. Holds exactly one
  entry today.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A search of the core package for version-literal comparisons outside the
  record returns zero results.
- **SC-002**: All 256 possible version byte values have a defined, tested outcome:
  each known value decodes, each remaining value is refused with the version-too-new
  error.
- **SC-003**: The externally-generated golden vectors and the byte-layout freeze
  assertions pass with zero modifications, demonstrating no decode behaviour and no
  wire byte changed.
- **SC-004**: Exactly one test assertion changes, and it is strictly stronger. No test
  is weakened, skipped, deleted, or added to make a failing suite pass.
- **SC-005**: Decoding output for existing containers is byte-identical to the base
  branch — verifiable by decrypting the golden vector on both and comparing.
- **SC-006**: A user opening a container stamped at an unknown version sees the same
  "update the app" message as before.
- **SC-007**: Introducing a hypothetical future version requires adding one row and
  editing no other source file, and moves the accept/refuse boundary by exactly one.
- **SC-008**: All three packages analyze clean, their test suites pass, and the tree is
  correctly formatted.

## Assumptions

- The existing version-too-new error type is kept as-is, name and all. It is already
  surfaced to users through the app's error-message layer, so renaming or replacing it
  would regress user-facing copy for no benefit. Only how the decision to throw it is
  reached changes.
- The record ships with exactly one row, for v1, because that is what `develop` knows.
  Modelling a second version here would import a dependency on unreleased work and
  break the behaviour-preserving guarantee that makes this reviewable.
- No capability flags are shipped. FR-010 requires the record be *extensible* with
  them; FR-011 forbids inventing one now. The first real capability arrives with the
  first version that has one.
- The write default stays 1 and the read boundary stays "reject 2 and above". Both are
  frozen properties, not consequences of this refactor.
- `docs/FORMAT.md` needs no change. §10 already states the rule; this work gives it an
  implementation.
- No migration or user-visible transition. Existing `.latch` files on disk are
  unaffected, and no file written before this change reads differently after it.
- Verification is the existing suites plus the two independent freeze guards. No new
  verification mechanism is introduced.

## Dependencies

- **`docs/FORMAT.md` §10 (versioning policy)** is the normative statement this work
  implements. If the record and the document disagree, the document wins.
- **The two independent freeze guards** — the byte-layout freeze test and the
  externally-generated golden vectors — are the acceptance instrument for
  "behaviour-preserving". Neither may be edited to accommodate this work, with the
  single exception in FR-013.
- **Base branch `develop`**, which is strictly ahead of `main` and byte-identical to it
  across `packages/myenc_core`.

## Downstream Consumers

`specs/001-folder-encryption` depends on this feature; this feature does not depend on
it, name it, or accommodate it. Once this lands, that branch rebases onto it, drops the
interim version-gate constants it currently carries on the file-header type, and adds
its version as one row. Its own freeze-guard failure resolves as a consequence of
FR-013 rather than needing a further test edit — which is the registry demonstrating
the property it was built for.

## Out of Scope

- Any change to the `.latch` wire format.
- Defining, admitting, or anticipating any container version beyond v1.
- Folder encryption, payload packing, payload preambles, and everything else in
  `specs/001-folder-encryption`.
- Changes to `packages/myenc_adapters` or the application layer.
- Per-version decoders or a version-dispatching read path. The record states which
  versions exist; it does not introduce branching readers.
- Any recovery, downgrade, or best-effort interpretation of an unknown version.
  Unknown means refused.
