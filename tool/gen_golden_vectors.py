#!/usr/bin/env python3
"""Independent reference producer for Latch `.latch` v1 golden vectors.

This script does NOT use the Dart implementation. It re-derives the whole
format from the spec using two independent crypto sources:

  * Argon2id KEK derivation via `argon2-cffi` (an independent Argon2 codebase,
    NOT libsodium) — this cross-checks Latch's libsodium `crypto_pwhash`.
  * secretbox (XSalsa20-Poly1305) DEK/filename wraps and the XChaCha20-Poly1305
    secretstream body via libsodium through ctypes — the reference C library,
    independent of the Dart `sodium` package's stream wiring.

The framing of the secretstream body exactly reproduces the `sodium` package's
`createPushChunked` behaviour: the plaintext is split into `chunkSize` pieces;
a piece is tagged FINAL iff its length is < chunkSize; if the last emitted
piece is a full chunk (or the plaintext is empty), an extra empty FINAL message
is appended.

Outputs (committed, consumed by golden_vectors_test.dart):
  packages/myenc_adapters/test/golden/golden_kdf.json   — deterministic KDF vectors
  packages/myenc_adapters/test/golden/golden_v1.latch   — end-to-end fixture
  packages/myenc_adapters/test/golden/golden_v1.json    — fixture metadata

Regenerating produces a fresh, valid fixture (the secretstream header nonce is
libsodium-random). The Dart test decrypts whatever pair of .latch/.json is
committed, so a regenerated pair stays self-consistent.

Usage: python3 tool/gen_golden_vectors.py
"""

import ctypes
import json
import os
import struct

from argon2.low_level import hash_secret_raw, Type

# --- locate libsodium ---------------------------------------------------------
_CANDIDATES = [
    "/opt/homebrew/anaconda3/lib/libsodium.dylib",
    "/opt/homebrew/lib/libsodium.dylib",
    "/usr/local/lib/libsodium.dylib",
    "libsodium.dylib",
    "libsodium.so",
]


def _load_sodium():
    last = None
    for path in _CANDIDATES:
        try:
            lib = ctypes.CDLL(path)
            if lib.sodium_init() < 0:
                raise RuntimeError("sodium_init failed")
            return lib
        except OSError as e:  # pragma: no cover - environment dependent
            last = e
    raise RuntimeError(f"could not load libsodium: {last}")


S = _load_sodium()

# libsodium constants (crypto_secretstream_xchacha20poly1305 / crypto_secretbox)
SS_ABYTES = 17
SS_HEADERBYTES = 24
SS_KEYBYTES = 32
SS_TAG_MESSAGE = 0x00
SS_TAG_FINAL = 0x03
SB_NONCEBYTES = 24
SB_MACBYTES = 16

S.crypto_secretstream_xchacha20poly1305_statebytes.restype = ctypes.c_size_t


def argon2id_kek(passphrase: bytes, salt: bytes, opslimit: int, memlimit_kib: int,
                 out_len: int = 32) -> bytes:
    """KEK via argon2-cffi. Matches libsodium crypto_pwhash(argon2id13):
    parallelism=1, version=0x13 (19), memory_cost in KiB, time_cost=opslimit."""
    return hash_secret_raw(
        secret=passphrase, salt=salt,
        time_cost=opslimit, memory_cost=memlimit_kib, parallelism=1,
        hash_len=out_len, type=Type.ID, version=19,
    )


def secretbox_seal(plaintext: bytes, key: bytes, nonce: bytes) -> bytes:
    """crypto_secretbox_easy → nonce || (mac || ciphertext), matching
    SodiumCryptoAdapter.secretboxSeal."""
    assert len(key) == 32 and len(nonce) == SB_NONCEBYTES
    out = ctypes.create_string_buffer(len(plaintext) + SB_MACBYTES)
    rc = S.crypto_secretbox_easy(
        out, plaintext, ctypes.c_ulonglong(len(plaintext)), nonce, key)
    if rc != 0:
        raise RuntimeError(f"crypto_secretbox_easy rc={rc}")
    return nonce + out.raw


def secretstream_body(key: bytes, plaintext: bytes, chunk_size: int):
    """Return (header24, body) reproducing sodium's createPushChunked framing."""
    assert len(key) == SS_KEYBYTES
    state = ctypes.create_string_buffer(
        S.crypto_secretstream_xchacha20poly1305_statebytes())
    header = ctypes.create_string_buffer(SS_HEADERBYTES)
    rc = S.crypto_secretstream_xchacha20poly1305_init_push(state, header, key)
    if rc != 0:
        raise RuntimeError(f"init_push rc={rc}")

    # Split into chunk_size pieces; a partial (< chunk_size) piece is the tail.
    pieces = []
    i, n = 0, len(plaintext)
    while n - i >= chunk_size:
        pieces.append(plaintext[i:i + chunk_size])
        i += chunk_size
    if i < n:
        pieces.append(plaintext[i:n])

    # Tag: FINAL iff shorter than a full chunk (matches the .dart map()).
    msgs = [(p, SS_TAG_FINAL if len(p) < chunk_size else SS_TAG_MESSAGE)
            for p in pieces]
    # push transformer close(): append empty FINAL unless already finalized.
    if not msgs or msgs[-1][1] != SS_TAG_FINAL:
        msgs.append((b"", SS_TAG_FINAL))

    body = bytearray()
    for msg, tag in msgs:
        out = ctypes.create_string_buffer(len(msg) + SS_ABYTES)
        clen = ctypes.c_ulonglong(0)
        rc = S.crypto_secretstream_xchacha20poly1305_push(
            state, out, ctypes.byref(clen),
            msg, ctypes.c_ulonglong(len(msg)),
            None, ctypes.c_ulonglong(0),
            ctypes.c_ubyte(tag))
        if rc != 0:
            raise RuntimeError(f"push rc={rc}")
        body += out.raw[:clen.value]
    return header.raw, bytes(body)


def encode_header(*, flags, salt, opslimit, memlimit_kib, chunk_size,
                  key_id_hint, wrap_bytes, enc_filename, ss_header) -> bytes:
    h = bytearray()
    h += b"LATCH"                       # magic
    h += bytes([1])                     # version
    h += bytes([flags])                 # flags
    h += bytes([0x01])                  # kdfId = Argon2id
    h += struct.pack(">H", len(salt))   # saltLen
    h += salt
    h += struct.pack(">I", opslimit)
    h += struct.pack(">I", memlimit_kib)
    h += bytes([0x01])                  # cipherId = XChaCha20-Poly1305
    h += struct.pack(">I", chunk_size)
    h += key_id_hint                    # 16 bytes
    h += bytes([1])                     # wrapCount
    h += bytes([0x01])                  # wrap type = passphrase
    h += struct.pack(">H", len(wrap_bytes))
    h += wrap_bytes
    if flags & 0x01:
        h += struct.pack(">H", len(enc_filename))
        h += enc_filename
    h += ss_header
    return bytes(h)


def build_fixture():
    # Fixed secret inputs (deterministic except the ss-header nonce).
    passphrase = b"correct horse battery staple"
    salt = bytes(range(16))
    key_id_hint = bytes(range(16, 32))
    dek = bytes(range(100, 132))                 # 32 bytes
    wrap_nonce = bytes([7] * SB_NONCEBYTES)
    fn_nonce = bytes([9] * SB_NONCEBYTES)
    opslimit = 3
    memlimit_kib = 65536
    chunk_size = 64
    filename = b"quarterly-report.pdf"
    plaintext = (b"Latch golden vector v1. This plaintext deliberately spans "
                 b"two 64-byte secretstream chunks.")

    kek = argon2id_kek(passphrase, salt, opslimit, memlimit_kib)
    wrap_bytes = secretbox_seal(dek, kek, wrap_nonce)          # 24+16+32 = 72
    enc_filename = secretbox_seal(filename, dek, fn_nonce)     # 24+16+len
    ss_header, body = secretstream_body(dek, plaintext, chunk_size)

    header = encode_header(
        flags=0x01, salt=salt, opslimit=opslimit, memlimit_kib=memlimit_kib,
        chunk_size=chunk_size, key_id_hint=key_id_hint, wrap_bytes=wrap_bytes,
        enc_filename=enc_filename, ss_header=ss_header)

    latch = header + body
    meta = {
        "note": "Produced independently by tool/gen_golden_vectors.py "
                "(argon2-cffi + libsodium ctypes). Do not edit by hand.",
        "passphrase": passphrase.decode(),
        "wrong_passphrase": "not the passphrase",
        "salt_hex": salt.hex(),
        "key_id_hint_hex": key_id_hint.hex(),
        "opslimit": opslimit,
        "memlimit_kib": memlimit_kib,
        "chunk_size": chunk_size,
        "flags": 0x01,
        "filename": filename.decode(),
        "plaintext_hex": plaintext.hex(),
    }
    return latch, meta


def build_kdf_vectors():
    cases = [
        (b"correct horse battery staple", bytes(range(16)), 3, 65536),
        (b"", bytes([0xAB] * 16), 2, 65536),
        (b"\xf0\x9f\x94\x92 latch", bytes([i * 7 & 0xFF for i in range(16)]), 4, 131072),
    ]
    out = []
    for pw, salt, ops, mem in cases:
        out.append({
            "passphrase_hex": pw.hex(),
            "salt_hex": salt.hex(),
            "opslimit": ops,
            "memlimit_kib": mem,
            "kek_hex": argon2id_kek(pw, salt, ops, mem).hex(),
        })
    return out


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = os.path.join(
        here, "..", "packages", "myenc_adapters", "test", "golden")
    out_dir = os.path.normpath(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    latch, meta = build_fixture()
    with open(os.path.join(out_dir, "golden_v1.latch"), "wb") as f:
        f.write(latch)
    with open(os.path.join(out_dir, "golden_v1.json"), "w") as f:
        json.dump(meta, f, indent=2)
        f.write("\n")

    with open(os.path.join(out_dir, "golden_kdf.json"), "w") as f:
        json.dump(build_kdf_vectors(), f, indent=2)
        f.write("\n")

    print(f"wrote golden vectors to {out_dir}")
    print(f"  golden_v1.latch  {len(latch)} bytes")


if __name__ == "__main__":
    main()
