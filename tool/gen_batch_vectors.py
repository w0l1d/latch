#!/usr/bin/env python3
"""Independent reference for Latch shared-salt (bulk "shared key") containers.

A bulk run in "shared key" mode derives the passphrase KEK once and reuses it,
and the salt, for every container in the batch. The containers are ordinary v1
containers; only the salt is shared. This script checks that from outside the
Dart code, using the same independent primitives as gen_golden_vectors.py
(argon2-cffi for Argon2id, libsodium via ctypes for secretbox/secretstream).

  generate (default)  write a NEW fixture, never touching golden_v1.*:
      packages/myenc_adapters/test/golden/golden_batch_v1_a.latch
      packages/myenc_adapters/test/golden/golden_batch_v1_b.latch
      packages/myenc_adapters/test/golden/golden_batch_v1.json
  verify FILE...      decrypt containers produced elsewhere (e.g. by the Dart
      app) by deriving the KEK from each header's own salt, then report the
      salts, whether they are shared, and the plaintext SHA-256.

Run with a Python that has argon2-cffi, e.g. /opt/homebrew/anaconda3/bin/python3.

Usage:
  python3 tool/gen_batch_vectors.py
  python3 tool/gen_batch_vectors.py verify --passphrase "..." a.latch b.latch
"""

import argparse
import ctypes
import hashlib
import json
import os
import struct
import sys

import gen_golden_vectors as g

S = g.S


def secretbox_open(box: bytes, key: bytes) -> bytes:
    nonce, rest = box[:g.SB_NONCEBYTES], box[g.SB_NONCEBYTES:]
    out = ctypes.create_string_buffer(len(rest) - g.SB_MACBYTES)
    rc = S.crypto_secretbox_open_easy(
        out, rest, ctypes.c_ulonglong(len(rest)), nonce, key)
    if rc != 0:
        raise ValueError("secretbox open failed (wrong key or tampered)")
    return out.raw


def secretstream_open(key: bytes, header: bytes, body: bytes,
                      chunk_size: int) -> bytes:
    state = ctypes.create_string_buffer(
        S.crypto_secretstream_xchacha20poly1305_statebytes())
    if S.crypto_secretstream_xchacha20poly1305_init_pull(
            state, header, key) != 0:
        raise ValueError("init_pull failed")
    out_plain = bytearray()
    step = chunk_size + g.SS_ABYTES
    i, saw_final = 0, False
    while i < len(body):
        if saw_final:
            raise ValueError("data after FINAL tag")
        chunk = body[i:i + step]
        i += len(chunk)
        out = ctypes.create_string_buffer(max(len(chunk) - g.SS_ABYTES, 1))
        mlen = ctypes.c_ulonglong(0)
        tag = ctypes.c_ubyte(0)
        rc = S.crypto_secretstream_xchacha20poly1305_pull(
            state, out, ctypes.byref(mlen), ctypes.byref(tag),
            chunk, ctypes.c_ulonglong(len(chunk)), None, ctypes.c_ulonglong(0))
        if rc != 0:
            raise ValueError("secretstream pull failed")
        out_plain += out.raw[:mlen.value]
        saw_final = tag.value == g.SS_TAG_FINAL
    if not saw_final:
        raise ValueError("stream ended without FINAL tag")
    return bytes(out_plain)


def parse_header(data: bytes):
    assert data[:5] == b"LATCH", "bad magic"
    version, flags, kdf_id = data[5], data[6], data[7]
    assert version == 1 and kdf_id == 1
    salt_len = struct.unpack(">H", data[8:10])[0]
    p = 10
    salt = data[p:p + salt_len]; p += salt_len
    opslimit, memlimit = struct.unpack(">II", data[p:p + 8]); p += 8
    p += 1  # cipherId
    chunk_size = struct.unpack(">I", data[p:p + 4])[0]; p += 4
    key_id = data[p:p + 16]; p += 16
    wrap_count = data[p]; p += 1
    wraps = []
    for _ in range(wrap_count):
        wtype = data[p]
        wlen = struct.unpack(">H", data[p + 1:p + 3])[0]
        wraps.append((wtype, data[p + 3:p + 3 + wlen]))
        p += 3 + wlen
    if flags & 0x01:
        elen = struct.unpack(">H", data[p:p + 2])[0]
        p += 2 + elen
    ss_header = data[p:p + g.SS_HEADERBYTES]; p += g.SS_HEADERBYTES
    return dict(salt=salt, opslimit=opslimit, memlimit=memlimit,
                chunk_size=chunk_size, key_id=key_id, wraps=wraps,
                ss_header=ss_header, body=data[p:])


def decrypt_container(data: bytes, passphrase: bytes):
    h = parse_header(data)
    kek = g.argon2id_kek(passphrase, h["salt"], h["opslimit"], h["memlimit"])
    wrap = next(b for t, b in h["wraps"] if t == 0x01)
    dek = secretbox_open(wrap, kek)
    plain = secretstream_open(dek, h["ss_header"], h["body"], h["chunk_size"])
    return h, dek, plain


def build_batch():
    passphrase = b"one passphrase for the whole batch"
    salt = bytes(range(32, 48))                 # shared by both containers
    opslimit, memlimit_kib, chunk_size = 3, 65536, 64
    kek = g.argon2id_kek(passphrase, salt, opslimit, memlimit_kib)

    files = [
        # (dek, wrap_nonce, key_id_hint, plaintext)
        (bytes(range(1, 33)), bytes([21] * 24), bytes(range(48, 64)),
         b"batch file A: shorter than one 64-byte chunk."),
        (bytes(range(65, 97)), bytes([22] * 24), bytes(range(64, 80)),
         b"batch file B: this one is long enough to span more than one "
         b"64-byte secretstream chunk, so the FINAL tag sits on a later one."),
    ]
    containers = []
    for dek, nonce, key_id, plain in files:
        wrap = g.secretbox_seal(dek, kek, nonce)
        ss_header, body = g.secretstream_body(dek, plain, chunk_size)
        containers.append(g.encode_header(
            flags=0x00, salt=salt, opslimit=opslimit,
            memlimit_kib=memlimit_kib, chunk_size=chunk_size,
            key_id_hint=key_id, wrap_bytes=wrap, enc_filename=b"",
            ss_header=ss_header) + body)
    meta = {
        "note": "Produced independently by tool/gen_batch_vectors.py "
                "(argon2-cffi + libsodium ctypes). Do not edit by hand.",
        "passphrase": passphrase.decode(),
        "wrong_passphrase": "not the batch passphrase",
        "shared_salt_hex": salt.hex(),
        "opslimit": opslimit,
        "memlimit_kib": memlimit_kib,
        "chunk_size": chunk_size,
        "files": [
            {"name": "golden_batch_v1_a.latch", "plaintext_hex": files[0][3].hex()},
            {"name": "golden_batch_v1_b.latch", "plaintext_hex": files[1][3].hex()},
        ],
    }
    return containers, meta


def cmd_generate():
    out_dir = os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "packages",
        "myenc_adapters", "test", "golden"))
    containers, meta = build_batch()
    for c, f in zip(containers, meta["files"]):
        with open(os.path.join(out_dir, f["name"]), "wb") as fh:
            fh.write(c)
    with open(os.path.join(out_dir, "golden_batch_v1.json"), "w") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")
    # Self-check: the reference reader must open what the reference wrote.
    for c, f in zip(containers, meta["files"]):
        _, _, plain = decrypt_container(c, meta["passphrase"].encode())
        assert plain.hex() == f["plaintext_hex"]
    print(f"wrote batch vectors to {out_dir}")


def cmd_verify(passphrase: str, paths):
    salts, deks, headers = set(), set(), set()
    for path in paths:
        data = open(path, "rb").read()
        h, dek, plain = decrypt_container(data, passphrase.encode())
        salts.add(h["salt"]); deks.add(dek); headers.add(h["ss_header"])
        print(f"{os.path.basename(path)}: ok salt={h['salt'].hex()} "
              f"sha256={hashlib.sha256(plain).hexdigest()}")
    n = len(paths)
    print(f"{n} files; distinct salts={len(salts)} distinct DEKs={len(deks)} "
          f"distinct stream headers={len(headers)}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd")
    v = sub.add_parser("verify")
    v.add_argument("--passphrase", required=True)
    v.add_argument("files", nargs="+")
    a = ap.parse_args()
    if a.cmd == "verify":
        cmd_verify(a.passphrase, a.files)
    else:
        cmd_generate()


if __name__ == "__main__":
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    main()
