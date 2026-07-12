# `.latch` File Format — Version 1 (FROZEN)

**Status: frozen as of 2026-07-12.** No field of the v1 layout may change.
Any incompatible change requires bumping the version byte; readers reject
versions they don't know (fail closed). This document is normative; where it
and the code disagree, the golden vectors under
`packages/myenc_adapters/test/golden/` are the ground truth — they were
produced by an independent implementation
(`tool/gen_golden_vectors.py`, argon2-cffi + libsodium via ctypes).

## 1. Design

Envelope encryption. Every file gets its own random 32-byte data-encryption
key (DEK). The body is encrypted with the DEK using the libsodium
XChaCha20-Poly1305 **secretstream** construction. The DEK itself is stored in
the header, wrapped one or more times ("wrap list") — by a
passphrase-derived key, and optionally by a device-bound key. Changing a
passphrase, adding a device wrap, or crypto-erasing the file only ever
touches the header; the body ciphertext is immutable for the life of the
file.

All multi-byte integers are **big-endian**. There is no padding and no
alignment; fields are contiguous.

## 2. Header layout

| Offset | Size | Field | Value / notes |
|---:|---:|---|---|
| 0 | 5 | Magic | ASCII `LATCH` (`4C 41 54 43 48`) |
| 5 | 1 | Version | `0x01` |
| 6 | 1 | Flags | bit0 = filename encrypted; bits 1–7 **reserved, must be 0** |
| 7 | 1 | KDF id | `0x01` = Argon2id (argon2id13) |
| 8 | 2 | Salt length | uint16, always `16` in v1 |
| 10 | 16 | KDF salt | random per file; regenerated on passphrase change |
| 26 | 4 | Argon2 opslimit | uint32 |
| 30 | 4 | Argon2 memlimit | uint32, **KiB** |
| 34 | 1 | Cipher id | `0x01` = XChaCha20-Poly1305 secretstream |
| 35 | 4 | Chunk size | uint32, plaintext bytes per body chunk |
| 39 | 16 | Key-id hint | opaque label, see §6 |
| 55 | 1 | Wrap count | uint8 |
| 56 | var | Wrap list | `wrap count` entries, see §3 |
| — | 2 | Enc-filename length | uint16 — **present only when flags bit0 = 1** |
| — | var | Enc filename | secretbox ciphertext, see §5 |
| — | 24 | Secretstream header | libsodium `crypto_secretstream_xchacha20poly1305` header |
| — | var | Body | encrypted chunks, see §4 |

The fixed prefix (offsets 0–55) is 56 bytes. Total header length is
`56 + Σ(3 + wrap_len) [+ 2 + enc_filename_len] + 24`.

## 3. Wrap list

Each entry:

| Size | Field |
|---:|---|
| 1 | Wrap type |
| 2 | Wrap length (uint16) |
| var | Wrap bytes |

Defined wrap types:

| Code | Type | Wrap bytes |
|---|---|---|
| `0x01` | Passphrase | secretbox of the DEK under the Argon2id-derived KEK — 72 bytes |
| `0x02` | Hardware / device key | secretbox of the DEK under a 32-byte device-bound key — 72 bytes |
| `0x03` | Recipient (X25519) | **reserved in v1** — writers must not emit it; readers reject unknown codes above `0x03` |

secretbox format (libsodium XSalsa20-Poly1305, `crypto_secretbox_easy`):
`nonce (24) ‖ MAC (16) ‖ ciphertext (32)` = 72 bytes for a 32-byte DEK.
The nonce is random per seal.

Rules:

- A **passphrase wrap is always present** and is always sufficient to open
  the file (spec §7.6 — hardware wraps are additive, never sole).
- All wraps in one file wrap the **same DEK**.
- Readers try the passphrase wrap first; a device key is only consulted
  after the passphrase wrap fails to authenticate.
- Changing the passphrase replaces the passphrase wrap (with a fresh salt
  and KEK) and carries every other wrap over verbatim.

## 4. Body: secretstream chunking

The body is the output of libsodium
`crypto_secretstream_xchacha20poly1305` over the plaintext, chunked at
`chunk size` (header offset 35). The 24-byte stream header that libsodium
produces is stored **in the file header** (the last header field), not at
the start of the body.

Framing (matches the Dart `sodium` package and the independent Python
producer, byte-for-byte):

- Plaintext is split into pieces of exactly `chunk size` bytes; the last
  piece may be shorter.
- Each piece is pushed with tag `MESSAGE` (0x00), **except**: a piece is
  tagged `FINAL` (0x03) iff its length is **strictly less** than
  `chunk size`.
- If the last piece is exactly `chunk size` bytes long — or the plaintext
  is empty — an **extra, empty `FINAL` chunk** is appended.
- Each encrypted chunk is `plaintext_len + 17` bytes (1-byte tag encrypted
  into the stream + 16-byte MAC).

A reader therefore consumes encrypted chunks of `chunk size + 17` bytes;
only the final chunk may be shorter (down to 17 bytes for the empty-FINAL
case). Decryption MUST fail if the stream ends without a `FINAL` tag
(truncation) or any chunk fails authentication (tampering / reordering —
the stream construction chains chunk state, so reordering breaks the MAC).

## 5. Encrypted filename

Present only when flags bit0 = 1. The original filename is encoded as
**UTF-8**, then sealed with secretbox **under the DEK itself**:
`nonce (24) ‖ MAC (16) ‖ ciphertext (name_len)`.

Because it is encrypted with the DEK (not the KEK), the filename survives
passphrase changes unchanged and is recoverable through any wrap.

## 6. Key-id hint

An opaque **random** 16-byte label linking the file to a stored-passphrase
entry (UC-9). It is deliberately *not* derived from the passphrase — a
passphrase-derived label would give an attacker a fast offline dictionary
oracle that bypasses Argon2id. It carries no entropy about any secret and
may be freely disclosed. When a stored passphrase entry is overwritten, its
key-id is retained so previously encrypted files still resolve.

## 7. KDF

libsodium `crypto_pwhash` with `crypto_pwhash_ALG_ARGON2ID13`:

- output: 32 bytes (the KEK)
- `opslimit` = Argon2 time cost (header offset 26)
- `memlimit` = header value in **KiB** (libsodium takes bytes: `memlimit × 1024`)
- parallelism: 1 (fixed by libsodium)
- Argon2 version: 0x13

Equivalent argon2-cffi call (verified byte-identical by the golden KDF
vectors): `argon2.low_level.hash_secret_raw(time_cost=opslimit,
memory_cost=memlimit_kib, parallelism=1, hash_len=32, type=Type.ID,
version=19)`.

**Write floor (v1 writers):** `opslimit ≥ 2`, `memlimit ≥ 65536` KiB
(64 MiB). Writers must refuse to encrypt below the floor.
**Read bounds (v1 readers, DoS sanity — a weak-but-well-formed file must
still decrypt):** `1 ≤ opslimit ≤ 64`, `8 ≤ memlimit ≤ 1 048 576` KiB,
`64 ≤ chunk size ≤ 16 777 216`.

## 8. Validation rules (fail closed)

A v1 reader MUST reject, with no partial output:

| Condition | Error |
|---|---|
| Magic ≠ `LATCH` | not a latch file |
| Version > 1 | version too new (tell the user to update) |
| Any reserved flag bit set | corrupted |
| KDF id ≠ `0x01`, cipher id ≠ `0x01`, salt length ≠ 16 | corrupted |
| opslimit / memlimit / chunk size outside read bounds | corrupted |
| Unknown wrap type code | corrupted |
| Any truncation (header or body), missing `FINAL` | corrupted |
| Wrap fails to authenticate | wrong passphrase |
| Body chunk fails to authenticate | corrupted / tampered |

Wrong passphrase and corruption are distinguishable for free: the wrong
passphrase fails at the 72-byte wrap before the body is ever touched.

## 9. Operations that rewrite the header only

- **Change passphrase:** unwrap DEK with old passphrase → new salt → new
  KEK → new passphrase wrap; other wraps, key-id, secretstream header,
  encrypted filename, and every body byte are carried over verbatim.
- **Crypto-erase (secure delete):** overwrite the entire header
  (offset 0 through the end of the secretstream header) in place with
  random bytes and flush, then delete the file. This destroys every wrap
  and the stream header, so the body is permanently undecryptable even if
  the deleted file is later recovered from flash.

## 10. Versioning policy

- The version byte is the only compatibility signal. v1 readers reject
  version ≥ 2 files with a clear "update the app" error.
- Reserved flag bits are validation-enforced to zero in v1, so a future
  version can repurpose them without ambiguity: a v1 file with a set
  reserved bit is by definition corrupt.
- New wrap types (e.g. `0x03` recipient) require a version bump, because
  v1 readers reject unknown wrap codes.
- The golden vectors freeze this layout: `golden_v1.latch` (341 bytes,
  produced independently of the Dart implementation) must decrypt
  correctly forever, and `codec_freeze_test.dart` pins the header bytes
  structurally.

## 11. What the format does and does not protect

Protected: body confidentiality and integrity (per-chunk AEAD, chained,
FINAL-terminated); filename confidentiality (optional); wrong-passphrase
detection before any body work.

Not protected (accepted v1 limitations, documented in the threat model):

- **Header fields are not bound to the body as associated data.** Tampering
  with KDF params or salt merely makes the wrap fail (indistinguishable
  from a wrong passphrase); tampering with chunk size breaks framing and
  fails authentication. No tampering path yields plaintext, but v1 cannot
  always *attribute* the failure to tampering.
- **File size leaks** (no padding), and the chunk count is inferable from
  the length.
- The key-id hint and KDF parameters are visible metadata.
