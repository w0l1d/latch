# Specification Quality Checklist: Central Format-Version Registry

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

## Validation Notes

**Iteration 1 findings and resolutions:**

1. *Named types leaking as implementation.* An early draft used the concrete
   identifiers from the refactor brief (`FormatVersion`, `require`, `firstUnknown`,
   `all`, `hasPayloadPreamble`, `PayloadKind`, `forPayload`). Resolved: the spec now
   describes a "format version record", a "first unknown version", and "per-version
   capability information" in behavioural terms. Naming is a `/speckit-plan` concern.

2. *Contradictory acceptance criteria in the source brief.* The brief simultaneously
   required the change to be behaviour-preserving with golden vectors passing
   unmodified, and required the version table to contain v2. Admitting v2 **is** a
   decode-behaviour change relative to the base branch, so the two cannot both hold.
   Verified empirically: `codec_freeze_test.dart` "version 2 is rejected" is currently
   RED on `001-folder-encryption` (`decodeHeader` returns a `FileHeader` for version 2),
   while every byte-layout assertion and both golden vectors still pass — so the red
   is caused by that branch's interim gate widening, not by anything this refactor
   needs. Resolved by user decision: this feature is independent of folder encryption,
   is based on `develop`, and ships v1 only (FR-011). Folder encryption depends on this
   work, not the reverse.

3. *Hidden coupling via a capability flag.* Shipping a `hasPayloadPreamble` flag here
   would relocate rather than remove the coupling the feature exists to eliminate, and
   the brief's payload-based version selector depends on a type that only exists on the
   folder-encryption branch. Resolved by splitting into FR-010 (record must be
   *extensible* with capabilities) and FR-011 (record must not *declare* one for
   unreleased work).

4. *An unstated part of the problem.* The base branch's single version constant serves
   as both the write default and the read ceiling, so the two cannot move
   independently — and raising the ceiling must never drag the write default up, or new
   containers become unopenable by installs that could have read them. This was not in
   the source brief. Added as User Story 4 and FR-007.

5. *Missing hard constraints from the project constitution and CLAUDE.md.* Added
   FR-015 (scope confined to the core package; error identity preserved) and FR-016
   (core stays free of Flutter and `dart:io`).

6. *Under-specified fail-closed range.* The brief covered `firstUnknown`..255. Version
   0 was unaddressed. Added to FR-004, the edge cases, and SC-002 (all 256 values have
   a defined outcome).

7. *The gaplessness invariant needed its rationale attached.* Stated inline in FR-006
   and in the edge cases: because the boundary is *derived* from the record, a gap
   silently relocates it and the fail-closed guard stops testing what it claims to.

**Status**: All items pass. No [NEEDS CLARIFICATION] markers. Ready for
`/speckit-plan`.
