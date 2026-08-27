# Phase 0 Research: Codec Version Strategies

## Baseline: what `develop` actually does

- `MyencCodec.decodeHeader`: minimum length → magic `LATCH` → version byte →
  `FormatVersionRegistry.require` gate → inline v1 field parsing (flags mask, kdfId/cipherId
  equality, salt, opslimit/memlimit bounds, chunk bounds, key-id, wraps, encrypted-filename,
  secretstream header) → `(FileHeader, consumed)`.
- `MyencCodec.encodeHeader`: inline v1 layout writer. A pure function of `FileHeader` — salt
  and secretstream header are inputs; all randomness lives above the codec (envelope service).
- Envelope rewraps (`changePassphrase` / `addRecipient`) re-emit `hdr.version` unchanged.
- Existing pins: `codec_test.dart` (round-trips, per-field corruption, fuzz/property),
  `codec_freeze_test.dart` (independently derived hex + version policy), `envelope_test.dart`,
  golden vectors in the adapters package.

## Decision 1 — Header handling lives in the codec, not the registry

**Decision**: Per-version strategy objects in the codec layer, dispatched by a public façade.
The registry remains version authority only (gate, `writeDefault`, `firstUnknown`).

**Rationale**: The registry's value is being a tiny, total, auditable record. Parsing needs
byte offsets, per-layout tables, and typed errors — knowledge that describes *one* layout, not
"versions in general". Merging them couples two things that change for different reasons.

**Alternatives considered**: Registry-held layout schemas (BL-002 option b) — rejected: v1's
variable-length fields (wrap list, encrypted-filename, secretstream header) make a declarative
schema nearly as complex as the parser it would drive, and it would still need an interpreter.
Only reconsider if the format ever grows many structurally distinct versions.

## Decision 2 — Strategy objects, not one generic parser

**Decision**: An abstract contract (`decode` / `encode`) with one concrete implementation per
version; the façade owns only the version-independent prefix.

**Rationale**: Layouts diverge in structure. Sharing parsing code across layouts would create
cross-version coupling and make per-version freeze pins ambiguous. Concrete parsers behind one
entry point keep each version auditable in isolation.

**Alternatives considered**: The status quo (inline version switches in one function) — this is
what the feature replaces; a single data-driven parser — rejected per Decision 1.

## Decision 3 — Superset `FileHeader`; sealed hierarchy is the escape hatch

**Decision**: One `FileHeader` with optional fields (precedent: `encryptedFilename`). Consumers
gate on capabilities (BL-001), never on version numbers.

**Rationale**: A sealed hierarchy would ripple through the envelope service, the app, and the
tests for what may be a single optional field. The superset keeps the public API stable.

**Alternatives considered**: Sealed per-version subclasses — deferred; becomes right only if a
future version's model cannot be expressed as optional fields.

## Decision 4 — Extract the machinery now, at one version

**Decision**: Ship the seam while exactly one version exists.

**Rationale**: The freeze guard and golden vectors passing **unedited** after a pure move *is*
the proof the move leaked nothing — cleanest possible while one version exists. At v2, that PR
is purely additive (strategy file + tests), keeping "mechanical move" and "new layout" auditable
separately.

**Alternatives considered**: Defer to the v2 PR — rejected: it would entangle the neutrality
proof with new behaviour and make review of both changes impossible as one diff.

## Decision 5 — The determinism correction: three-layer corpus

**Finding**: Full-file encryption output is salted and nonced per run (fresh salt, fresh
wrapped DEK, fresh secretstream header), so byte-identical re-encryption is impossible without
fixing randomness — and must stay impossible; nonce reuse would be a security bug.
`encodeHeader` / `decodeHeader`, however, are pure functions of their inputs.

**Decision**: Three layers — (L1) pre-refactor full-file `.latch` fixtures decrypt to plaintext
matching a committed hash manifest; (L2) a header corpus pins that identical `FileHeader` input
produces byte-identical encode output; (L3, deferred) a deterministic full-file byte-pin via
fixed salt/DEK/secretstream header through an adapter-level test path.

**Alternatives considered**: "Encrypt the same file with old and new code and compare hashes" —
rejected: it fails by design on unmodified code because of the salt/nonce, and pursuing it
would encode a security antipattern. L3 also duplicates the role of `golden_v1.latch`
(independently produced) while the adapters are untouched here — add only if body encryption
ever changes.

## Decision 6 — The totality invariant

**Decision**: The dispatch table is keyed by `FormatVersion` entries; a test asserts the key
set equals the registry's entry set, in both directions.

**Rationale**: A registry row without a strategy becomes a red test at merge time, not a
runtime failure on a user's file. Fail-closed is guaranteed structurally. SC-004 requires a
negative demonstration (temporarily remove a strategy → test goes red).

**Alternatives considered**: `switch` over entries — cannot be compiler-checked for
exhaustiveness because entries are runtime values; a `strategyFor` that may return null —
rejected: reintroduces exactly the null path the design exists to remove.

## Decision 7 — Rewrap goes through the façade

**Decision**: Envelope re-encode calls the public `encodeHeader` (the dispatch), pinned by a
round-trip test asserting the version byte and version-specific fields survive byte-identically.

**Rationale**: Rewraps preserve `hdr.version`; a hardcoded v1 encoder on the rewrap path would
silently drop future version-specific fields — the precise failure mode this architecture
exists to prevent.

## Summary of resolved unknowns

None remain. Every decision above was settled with the maintainer during the design discussion
and is recorded here for the implementation phase; the spec carries zero `[NEEDS CLARIFICATION]`
markers.
