# Phase 1 Data Model: Central Format-Version Registry

**Feature**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Research**: [research.md](./research.md)

All data here is **compile-time constant**. Nothing is persisted, parsed, cached, or
mutated at runtime. The "model" is a closed table the build ships with, and the only
runtime operation on it is lookup.

---

## Entity: Format version entry

One known container version and what it can carry.

| Field | Type | Description |
| --- | --- | --- |
| `number` | `int`, 1–255 | The value written into the container's version byte. Identity of the entry. |
| *(capability fields)* | — | **None in this feature.** Reserved as the documented extension point: a future version declares what it can carry by adding a `final` field with a default. See research.md Decision 3. |

**Constraints**

- Immutable, with a `const` constructor. Entries are declared, never computed.
- `number` is the key under which the entry is registered; the two may not disagree.
- Instances exist only as members of the record. There is no path by which a caller
  constructs an entry for a version the build does not know — that would be a second
  source of truth, which is what FR-009 forbids.

**Instances**

| Instance | `number` | Meaning |
| --- | --- | --- |
| v1 | 1 | The frozen `.latch` v1 layout described normatively by `docs/FORMAT.md` §2. The only version this build knows. |

---

## Entity: Format version record

The complete set of known entries, and the single authority on version questions.

| Member | Kind | Description |
| --- | --- | --- |
| `all` | `const Map<int, FormatVersion>` | Every known version, keyed by number. Contains exactly one pair today: `{1: v1}`. |
| `require(int n)` | lookup, throws | Returns the entry for `n`, or throws the version-too-new error if absent. The decode path's only entry point. |
| `writeDefault` | entry | The version stamped on newly written containers. Today v1. Stated in its own right, **not** derived from `all`'s maximum. |
| `firstUnknown` | derived `int` | The smallest positive integer with no entry. Today 2. Computed, never stored. |

### Invariants

| # | Invariant | Why it matters | Enforced by |
| --- | --- | --- | --- |
| **I1** | `all` is contiguous and begins at 1 — its keys are exactly `1..all.length`. | `firstUnknown` is derived from `all`. A row added for a version the codec cannot actually read would move the known/unknown boundary, and the freeze guard that asserts against that boundary would stop covering the real one. A gap does not crash, corrupt, or fail any other test. | Dedicated test (spec FR-006). Not a runtime `assert` — see research.md Decision 5. |
| **I2** | Every key maps to an entry whose `number` equals that key. | A mismatch would let `require(n)` return an entry describing a different version — a reader interpreting a payload under the wrong version's rules. | Dedicated test. |
| **I3** | `require` throws for every integer with no entry: 0, and everything from `firstUnknown` through 255. | The fail-closed guarantee. Absence must mean refusal, never a default or a nearest match. | Dedicated test iterating all 256 byte values (spec SC-002). |
| **I4** | `writeDefault` is v1, and does not track `all`'s maximum. | A write default that follows the read boundary upward makes every newly written container unopenable by installs that could have read it. | Dedicated test, plus the existing freeze assertion `expect(FileHeader.supportedVersion, 1)` which keeps firing through the forwarding getter. |
| **I5** | `firstUnknown` is not reachable from the decode path. | It iterates. More importantly, a decoder that reads the boundary and compares is back to the inequality this feature removes, and re-admits version 0. See research.md Decision 2. | Code review of `decodeHeader`; the gate contains a lookup and no comparison against any version value. |

### Not modelled

- **State transitions**: none. The record is constant; versions are not created,
  retired, or migrated at runtime.
- **Relationships**: none beyond containment. Entries do not reference each other, and
  there is deliberately no "supersedes" or "upgrades-to" edge — a container's version is
  what it is, and rewrap re-emits it unchanged (spec FR-008).
- **Validation of untrusted input beyond membership**: the version byte's only
  validation is "is it in the record?". Every other header field keeps its existing
  independent bounds checks in `decodeHeader`; this feature does not touch them.

---

## Relationship to existing types

| Existing type | Change |
| --- | --- |
| `FileHeader.version` (instance field) | **Unchanged.** Still a plain `int` carrying the byte read from or written to the container. It is deliberately *not* retyped to a `FormatVersion`: `decodeHeader` must be able to report the offending number in the error for a version it has no entry for, and a header field that can only hold known versions could not represent the input being rejected. |
| `FileHeader.supportedVersion` (static) | **Becomes a derived getter** forwarding to the record's `writeDefault`. Stores nothing, cannot disagree with the record. Retained rather than deleted so 11 existing test references keep compiling — research.md Decision 4. Slated for removal in a separate follow-up. |
| `VersionTooNewError` | **Unchanged**, including its name and its `version` field. The app layer already translates it into user-facing copy, so its identity is part of the observable surface (spec FR-015). Its name is now mildly inexact — version 0 is not "too new" — which is accepted, because a rename would regress a user-facing message for no behavioural gain. |
| Wire format | **Unchanged.** The version byte's offset, width, and encoding are untouched. `docs/FORMAT.md` §2 is not edited. |
