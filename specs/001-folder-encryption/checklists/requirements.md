# Specification Quality Checklist: Folder Encryption & Faithful Restore

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-08-26
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

- Items marked incomplete require spec updates before `/speckit-clarify` or `/speckit-plan`

### Validation findings (iteration 2 — after clarification session 2026-08-26)

Three of the four decisions are now resolved and encoded. **One
`[NEEDS CLARIFICATION]` marker remains (FR-020a)**, so that item stays unchecked.

Resolved:

1. **FR-012 — container shape.** One container for the whole folder. The
   single-unit-of-failure consequence is now stated explicitly in FR-012 rather
   than left implicit.
2. **FR-020 / FR-020b / FR-020c — capture mechanism.** Pack the tree into a
   lossless archive stream, protect that, unpack on restore. The decisive added
   constraint is FR-020b: the unpack decision must come from an authenticated
   in-container indicator, never from sniffing the plaintext or the source
   extension, so a user-supplied `.zip` protected as a file returns byte-identical
   (SC-012). FR-020c requires that indicator to be under the container's
   authentication, so flipping it reads as tampering.
3. **FR-031 — partial-failure policy.** Abort the whole operation and name the
   offending entry. FR-011, FR-032, SC-008 and User Story 4 were rewritten to
   match; the previous "incomplete capture" state no longer exists anywhere in the
   spec.

4. **FR-020a / FR-020e — metadata fidelity scope.** Resolved: modification times,
   the executable bit, and symlinks kept as links are IN scope; creation times,
   the POSIX permission set beyond the executable bit, and extended attributes are
   OUT of scope and no test may depend on them. FR-020e covers the platforms that
   cannot apply an in-scope item (Android and iOS sandboxes): restore content
   correctly and report what could not be applied, rather than failing the entry
   or claiming silent success. SC-014 is the acceptance test.

**No open questions remain — all 16 checklist items pass.**

Two requirements were added during clarification that were not user decisions but
follow from the ones made:

- **FR-020d / SC-013 — path traversal.** Introducing a packed stream introduces a
  traversal vector (absolute paths, `../`, symlinks resolving outside the root)
  that FR-019's no-overwrite rule does not cover. A container is attacker-supplied
  data by the time it is restored, and its authentication proves only that it was
  made with the passphrase — not that its contents are benign. Restore must fail
  closed.
- **FR-020c — authenticated indicator.** The folder/file indicator must be under
  the container's authentication, so flipping it in transit reads as tampering
  rather than silently changing how the payload is interpreted.

**Note on scope discipline for iteration 2.** "Pack into a lossless archive
stream" is closer to a mechanism than the rest of the spec, and it was a
deliberate user decision rather than a spec-derived one. It is recorded here
because it materially constrains the plan (it rules out per-file containers and
rules in a serialisation step), but it deliberately does **not** name a format —
tar, zip, or otherwise — which remains a `/speckit-plan` decision bounded by
FR-020a. The "No implementation details" item is judged still passing on that
basis.

### Validation findings (iteration 1 — superseded above)

**Three `[NEEDS CLARIFICATION]` markers remain, deliberately, at the limit of 3.**
Each was retained rather than defaulted because a wrong guess changes what gets
built, not merely how:

1. **FR-012 — container shape.** One container for the whole folder vs. one per
   file mirroring the tree. Determines what the user hands to a recipient,
   whether entry names can be concealed at all (FR-009), the blast radius of a
   single corrupt byte, and how much container-level structure is new. No
   defensible default exists.
2. **FR-020 — fidelity scope.** Which metadata "exactly its previous state" must
   include (modification/creation times, permission and executable bits, extended
   attributes, symlinks). Each item in scope is additional data to capture and
   protect, and several cannot be reproduced on every target platform.
3. **FR-031 — partial-failure policy.** Abort-all vs. complete-and-report vs.
   user choice, when one entry in a large tree is unreadable. This is a
   safety-versus-usability trade-off for a product whose users delete originals
   afterwards.

**Constitution compliance checked** against `.specify/memory/constitution.md`
v1.0.0:

- Principle I (offline / stateless / no recovery) — FR-038, FR-039, FR-040.
- Principle II (`.latch` v1 frozen) — FR-013, FR-014, SC-009; the format question
  is explicitly deferred to FR-012 rather than pre-decided.
- Principle IV (fail closed, no partial plaintext) — FR-021 to FR-024, FR-029,
  SC-003, SC-007.
- Security & platform constraints (Android SAF, no grant caching, no plaintext in
  shared locations) — FR-034 to FR-037; non-blocking UI — FR-030.

**Notes on borderline items:**

- "Written for non-technical stakeholders" — the spec names platform concepts
  (scoped storage, folder grants, Unicode normalisation) where they are the
  user-visible reality of the constraint, not an implementation choice. Judged to
  pass; the spec prescribes no mechanism.
- "No implementation details" — the spec deliberately does **not** state how the
  tree is serialised, how many containers exist, or which format version is used.
  Those are `/speckit-plan` decisions gated on Question 1.

---

### Validation findings (iteration 4 — version-management refresh, 2026-09-29)

Re-validated after features **002 (format-version registry)** and **003 (codec
version strategies)** shipped into `develop` and this branch was rebased onto
them. Every item above still passes. What changed and why it still passes:

**Content Quality — still passes.**

- FR-013a to FR-013e name the version *registry* and the per-version *strategy
  object*. Judged to pass "no implementation details" for the same reason the
  spec already names `.latch` v1 and its freeze guards: these are shipped,
  separately-specified constraints this feature must work within (see
  Dependencies), not mechanisms this spec is choosing. No file paths, no APIs and
  no type signatures appear in spec.md — those live in `plan.md` and `tasks.md`,
  where they belong.
- FR-013c (write the lowest version the payload permits) reads as a technical
  rule but is a user-facing compatibility promise: it is what keeps an install
  that predates this feature able to open ordinary files. Stated as an outcome in
  SC-017.

**Requirement Completeness — still passes.**

- No new `[NEEDS CLARIFICATION]` markers. The five version-management questions
  raised by 002/003 shipping were resolved in the 2026-09-29 clarification
  session and encoded as FR-013a to FR-013e, not deferred.
- New success criteria SC-016 to SC-018 are measurable and verifiable without
  knowing the implementation: one declaration site, an older install still
  opening single-file containers, and the committed corpora passing unedited.
- Dependencies now name 002 and 003 explicitly, with which requirements rest on
  each.

**Feature Readiness — still passes.**

- Every new requirement has an acceptance criterion: FR-013a → SC-016, FR-013b
  and FR-013c → SC-017, FR-013e → SC-018, FR-013d → SC-015 (already present).

**Sibling artifacts updated to match** (they described version handling that no
longer exists):

- `plan.md` — file map and the Principle II constitution row.
- `tasks.md` — T001–T007 marked shipped (commit `fefc408`); T008 rewritten as
  "one registry row + one strategy object"; T008a and T008b added for the
  write-default pin and the totality invariant; the former T009 blocker note
  replaced with the record of its resolution.

**Verification run after the rebase**, all three packages: `flutter analyze
--no-pub` clean and `flutter test` green in `packages/myenc_core` (126 tests),
`packages/myenc_adapters` (77), and the app (180) — including the freeze guard
and the v1 compatibility corpora, unedited.

**Status**: ready for `/speckit-plan` re-run or direct continuation at T008.
