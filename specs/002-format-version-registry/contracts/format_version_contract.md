# Contract: `myenc_core` public version surface

**Feature**: [../spec.md](../spec.md) | **Plan**: [../plan.md](../plan.md)

`myenc_core` is a library, so its contract is the public API exported from
`lib/myenc_core.dart`. This document specifies the version-related surface **after**
this feature: what is added, what is retained, and — the part that matters most — what
is guaranteed not to change.

Behavioural contracts are stated as observable outcomes, not signatures. Naming is
fixed at implementation time; the guarantees below are what `tasks.md` must verify.

---

## 1. Added surface

### The record

Exported from the package barrel, since the freeze guard and the adapters' tests reach
it through the public API.

| Operation | Contract |
| --- | --- |
| Resolve a version | Given an integer, returns the entry for that version if the build knows it. Given any integer it does not know — including `0` and everything from the boundary through `255` — throws `VersionTooNewError` carrying the offending number. Never returns `null`, never substitutes a nearest match, never defaults. |
| Enumerate known versions | Exposes the complete keyed table of known versions. Contains exactly one entry (version 1) in this release. |
| Write default | Exposes the version stamped on newly written containers. Is `1`. Is stated independently of the table's maximum, so raising the read boundary cannot move it. |
| Boundary | Exposes the smallest positive integer the build does not know. Is `2`. Derived from the table as the smallest absent positive integer, so it can never disagree with `require`. |

### The entry

| Operation | Contract |
| --- | --- |
| Read a version's number | Returns the byte value written into the container. |
| Read a version's capabilities | No capability is exposed in this release. The type admits new capability fields without changing any call site (research.md Decision 3). |

---

## 2. Retained surface — behaviour frozen

These are the guarantees a reviewer checks to accept the change. Each is observable and
each is verified in [../quickstart.md](../quickstart.md).

| Guarantee | Specifics |
| --- | --- |
| **`VersionTooNewError` keeps its identity** | Same type, same name, same `version` field, same `toString()` shape. The app layer's `userMessageForError` matches on this type *and* on its string form, so both must be preserved. A user opening an unreadable container sees the same message as before. |
| **Header decode is bit-identical for known versions** | For any container the base branch decoded, the resulting `FileHeader` is field-for-field identical and the consumed byte count is the same. |
| **Header encode is byte-identical** | `encodeHeader` output is unchanged for every input. The version byte's offset (5), width (1), and value are untouched. |
| **Refusal ordering is preserved** | An unreadable version is refused during header decode, before any payload byte is read and before any plaintext is emitted anywhere (constitution Principle IV). |
| **Failure-mode distinction is preserved** | An unknown version raises the version error, *not* `CorruptedFileError` and *not* `WrongPassphraseError`. Wrong-passphrase still fails at the DEK unwrap; a tampered body still fails at a chunk tag. |
| **Write default is unchanged** | New containers are stamped version 1. |
| **Rewrap and add-recipient pass through** | Both re-emit the source container's version unchanged, neither upgrading nor downgrading it. |
| **`FileHeader.supportedVersion` still resolves to 1** | Retained as a derived getter so existing consumers and the freeze assertion at `codec_freeze_test.dart:65` keep working. |
| **`FileHeader.version` stays a plain integer** | Not retyped, because `decodeHeader` must be able to report a version it has no entry for. |
| **No new dependency** | `myenc_core`'s dependency set is unchanged: no runtime dependencies, `test` as the only dev dependency. |
| **Core purity** | No Flutter import, no `dart:io` import (constitution Principle III). |

---

## 3. Intentional behaviour change — exactly one

| Input | `develop` | After this feature | Character |
| --- | --- | --- | --- |
| Container with version byte `0x00` | **Accepted** — decodes as a well-formed header (verified empirically, not inferred) | **Refused** with `VersionTooNewError` | Tightening |

The base gate is `version > 1`, so `0` passes it. A record lookup refuses `0` for the
same reason it refuses `200`: there is no entry. This cannot break any container any
Latch version ever wrote — no writer emits `0` — and no existing test asserts that `0`
decodes.

This is the **only** input for which behaviour differs from the base branch. Any other
observable difference found during verification is a defect in this feature, not a
consequence of it.

---

## 4. Explicitly out of contract

- No per-version reader, no version-dispatching decode path. The record states which
  versions exist; it does not branch on them.
- No capability flag, version row, or type serving unreleased work (spec FR-011).
- No downgrade, best-effort, or partial interpretation of an unknown version.
- No change to `packages/myenc_adapters` or the app layer's public surface.
- No change to any other header field's validation.

---

## 5. Consumers to re-verify

Not modified by this feature, but they exercise the surface above and must be confirmed
unaffected rather than assumed so:

| Consumer | What it exercises |
| --- | --- |
| `packages/myenc_adapters/test/golden_vectors_test.dart` | End-to-end decrypt of an independently generated container; asserts `hdr.version == 1`. Must pass with fixtures and test file unmodified — this is the primary acceptance instrument. |
| `packages/myenc_core/test/codec_freeze_test.dart` | Byte-layout freeze plus the write-default assertion at line 65. Only the unknown-version case changes (FR-013). |
| `packages/myenc_core/test/codec_test.dart` | Refuses version `0xFF`; constructs headers via `FileHeader.supportedVersion` in 9 places. Unmodified. |
| `packages/myenc_core/test/envelope_test.dart` | Refuses version `0xFF` end-to-end; asserts written version equals `FileHeader.supportedVersion`. Unmodified. |
| `lib/shared/error_messages.dart` | Maps the version error to user copy by type *and* by string match. Unmodified; behaviour re-verified. |
| `lib/core/isolate_worker.dart`, `lib/core/app_crypto.dart`, `lib/features/decrypt/decrypt_progress_screen.dart` | Carry the version error across the isolate boundary as a string code. Unmodified; the error's string form must not drift. |
