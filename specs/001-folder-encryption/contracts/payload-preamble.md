# Contract: `.latch` v2 Payload Preamble (normative)

**Status:** partially implemented. The preamble codec and its validation order (§3, §5) landed in `myenc_core/format/payload_preamble.dart` (001 T005–T007). **Not yet implemented:** registering v2 and emitting/consuming the preamble in `EnvelopeService` (001 T008, T010, T011), so no v2 container can be produced yet. Becomes normative in `docs/FORMAT.md` only once those land. Feature 004 does not use v2 — its containers are plain v1.

This contract defines the **only** difference between `.latch` v1 and v2. It adds
nothing to the header. Not one byte of the v1 layout in `docs/FORMAT.md` §2–§6
changes, and the reserved flag bits 1–7 stay reserved and zero.

## 1. What v2 means

| Version byte | Meaning |
|---:|---|
| `0x01` | The decrypted plaintext **is** the payload. Exactly as today. |
| `0x02` | The decrypted plaintext begins with an 8-byte **payload preamble**; the payload is everything after it. |

A reader MUST reject any version it does not know with `VersionTooNewError`
(fail closed). A v1-only reader therefore refuses a v2 container cleanly rather
than handing a user a file with 8 junk bytes on the front.

## 2. Writer policy — emit the lowest version that works

- A single opaque file MUST be written as **v1**, byte-identical to today
  (FR-014). No preamble.
- A packed folder MUST be written as **v2** with `kind = packedFolder`.
- `kind = singleFile` in a v2 container is **legal to read** but MUST NOT be
  produced by default. It exists so the enum is complete, not as an output mode.

Rationale: Latch has no server and users hand containers to each other. A
container that an older install can still open is strictly better whenever the
payload allows it.

## 3. Preamble layout

All fields are single bytes; there is no length field, no loop, and no
variable-width integer. Total: **8 bytes**.

| Offset | Size | Field | Value |
|---:|---:|---|---|
| 0 | 4 | Magic | ASCII `LPLD` (`4C 50 4C 44`) |
| 4 | 1 | Payload kind | `0x01` single opaque file, `0x02` packed folder |
| 5 | 1 | Pack format | `0x00` none, `0x01` tar (PAX subset, see `pack-format.md`) |
| 6 | 1 | Compression | `0x00` none |
| 7 | 1 | Reserved | MUST be `0x00` |

## 4. Authentication

The preamble is part of the plaintext, so it is inside the
XChaCha20-Poly1305 **secretstream** and is authenticated by the first chunk's tag.
Altering any preamble byte in transit therefore fails as **corruption at a chunk
tag**, before any payload byte is emitted (FR-020c, Principle IV).

It is also **confidential**: whether a container holds a file or a folder is not
observable from the ciphertext.

## 5. Validation, in order

A reader MUST apply these in this exact order and stop at the first failure,
emitting **zero** payload bytes:

1. Magic ≠ `LPLD` → `CorruptedFileError`.
2. Payload kind not in {`0x01`, `0x02`} — including `0x00` → `UnknownPayloadKindError`.
3. Compression ≠ `0x00` → `UnknownPayloadKindError`.
4. Reserved ≠ `0x00` → `UnknownPayloadKindError`.
5. `kind == packedFolder` and pack format ≠ `0x01` → `CorruptedFileError`.
6. `kind == singleFile` and pack format ≠ `0x00` → `CorruptedFileError`.

`UnknownPayloadKindError` maps to user copy about a **newer version of Latch**;
`CorruptedFileError` maps to the existing corruption copy. The distinction is
required by FR-020h and is not cosmetic: one tells the user to update the app,
the other tells them the file is damaged.

## 6. Ordering guarantee

Three failures, three stages, in this order — this is what keeps them
distinguishable (Principle IV):

1. **Wrong passphrase** — at the DEK unwrap, before any body chunk is touched.
2. **Corruption or tampering** — at a chunk authentication tag.
3. **Unknown payload kind** — after the first chunk authenticates, at preamble
   validation.

A reader MUST NOT reorder these, and MUST NOT emit payload bytes before step 3
completes.

## 7. Extension rule

Adding a payload kind MUST NOT change the meaning or encoding of a defined kind,
and MUST NOT require readers that predate it to understand it — only to reject it
via rule 2 above. A new kind therefore needs **no version bump** (FR-020g).
