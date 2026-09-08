# Quickstart: Validating Folder Encryption (UC-13)

How to prove this feature works. Every scenario names the success criteria it
discharges. Details of layout and rules live in
[`contracts/`](./contracts/) and [`data-model.md`](./data-model.md) — this file
is the run guide.

## Prerequisites

```sh
flutter pub get                       # at root; resolves the path-deps too
```

- Flutter 3.44.2 (CI pin), SDK `^3.12.2`.
- Do **not** `apt install libsodium` or set `LD_LIBRARY_PATH` — `sodium` 4.x
  ships libsodium via Dart native assets and `flutter test` bundles it.
- Golden-vector regeneration only: Python with `argon2-cffi`, plus a **system**
  libsodium loadable via `ctypes`.

## The gates — run all four, they are separate suites

```sh
dart format --set-exit-if-changed .                        # CI fails first on this
flutter analyze --no-pub && flutter test                   # app (root)
cd packages/myenc_core     && flutter test && flutter analyze --no-pub
cd packages/myenc_adapters && flutter test && flutter analyze --no-pub
cd android && ./gradlew :app:testDebugUnitTest             # JVM SAF helpers
```

Or install the hooks once and let pre-push mirror all of it:

```sh
./tool/setup-hooks.sh
```

---

## S1. The v1 freeze is intact — run this first, and after every change

```sh
cd packages/myenc_core     && flutter test test/codec_freeze_test.dart
cd packages/myenc_adapters && flutter test test/golden_vectors_test.dart
```

**Expected:** pass, with **both files unmodified**. If either fails, the v1
layout changed — revert the change; do not edit the test (Principle II).

**Discharges:** FR-013, FR-014, SC-009.

---

## S2. Folder round trip

Protect a folder, restore it, compare.

**Expected:** every entry present at its original relative path with
byte-identical content and byte-identical names; exactly **one** `.latch`
container was produced, never one per file; restoring twice yields identical
trees.

**Discharges:** SC-001, FR-012, FR-020.

---

## S3. Fidelity fixture

The fixture MUST be **built at test setup** from a declarative description, not
committed as a directory — git does not preserve mtimes.

Contents: files with distinct known modification times, one file with the
executable bit set, one symlink pointing inside the tree, one empty directory,
one file with a >100-byte UTF-8 name (forces a PAX header), one zero-byte file.

**Expected on desktop:** mtimes, the executable bit, and the symlink-as-link all
survive. **Expected on Android/iOS:** names, structure, and content are correct,
and the metadata report says which items could not be applied — the restore still
**succeeds** (FR-020e).

**Discharges:** SC-002, SC-014, FR-020a, FR-020e.

---

## S4. Archive-as-file — the bug this design exists to prevent

Both directions matter:

1. Protect a user-supplied `.zip` **as a file**. Restore it. It MUST come back
   byte-for-byte identical and MUST NOT be expanded into a tree.
2. Protect a folder. Restore it. It MUST come back as a tree and MUST NOT be
   left as an archive for the user to unpack by hand.

**Expected:** the unpack decision came from the authenticated payload kind alone
— no magic-byte sniffing, no extension check anywhere in the path.

**Discharges:** SC-012, FR-020b.

---

## S5. Hostile packed stream

Hand-build tar streams in `myenc_core` tests — no filesystem needed to prove
nothing escapes. One case each: an absolute path, a `../` traversal, a symlink
whose target escapes the destination root, a rejected type flag (hard link, FIFO,
device), a declared size that disagrees with the bytes, a duplicate relative
path, and an empty path.

**Expected:** each aborts with `UnsafeArchiveEntryError` naming the offending
relative path, and **zero bytes** are written outside the destination root.

**Discharges:** SC-013, FR-020d.

---

## S6. Unknown payload kind

Hand-build v2 containers whose preamble carries an undefined kind, then a
non-zero reserved byte, then a non-zero compression byte.

**Expected:** each is rejected with the "made by a newer version of Latch"
message; **zero** payload bytes are emitted; and none of the three is confused
with a wrong passphrase or with a corrupt container. Check all three messages —
the point of FR-020h is that they differ.

**Discharges:** SC-015, FR-020g, FR-020h.

---

## S7. The three failures stay distinguishable

Against the **same** folder container: (a) a wrong passphrase, (b) a byte flipped
in the body, (c) a byte flipped in the preamble.

**Expected:** (a) fails at the DEK unwrap before any body chunk is touched;
(b) fails at a chunk authentication tag; (c) fails as corruption at the first
chunk's tag, since the preamble is inside the secretstream. None emits partial
plaintext, and each produces its own distinct user copy.

**Discharges:** FR-022, FR-023, FR-020c, Principle IV.

---

## S8. Abort on an unreadable entry

Make one entry unreadable inside a folder and protect it.

**Expected:** the whole operation aborts; the offending entry is named by its
relative path; **no container** is left behind; staged work is removed; and the
originals are untouched even when "delete originals" was chosen.

**Discharges:** SC-008, FR-031, FR-011, FR-032.

---

## S9. Cancellation leaves nothing reachable

Cancel a folder encryption mid-run, then a folder restore mid-run.

**Expected:** cancellation takes effect within a few seconds; no partial
container; and for the restore, the staging directory is gone — **no partial
plaintext anywhere reachable**. Verify the staged *directory* sweep specifically:
`AppCrypto._runBatch` previously swept only a single `.tmp` file, so this is the
case that regresses silently if the fix is dropped.

**Discharges:** SC-007, FR-028, FR-029, Principle IV.

---

## S10. Scale and memory

A 10,000-file, ~10 GB folder.

**Expected:** progress advances at least once per second; peak memory stays in
the same band as a single-file operation of the same total size — it must not grow
with entry count **or** with the size of the largest file; the UI never blocks.

**Discharges:** SC-005, SC-006, FR-027, FR-030.

---

## S11. Independent oracle for v2 — Principle V

Extend `tool/gen_golden_vectors.py` to emit a **folder** container: build the
packed stream with Python's `tarfile` at `format=tarfile.PAX_FORMAT`, prepend the
preamble, and encrypt with `argon2-cffi` + libsodium via `ctypes`. Never with the
Dart code.

**Expected:** Dart restores the Python-produced container to the expected tree,
and the pre-existing v1 vectors still pass untouched. Commit the `.latch`/`.json`
pair together — the secretstream header nonce is random, so the pair is only
self-consistent as a pair.

**Discharges:** Principle V for the v2 format.

---

## S12. Android

On a device or emulator (API 30+): select a folder via the platform folder-grant
picker, protect it, restore it.

**Expected:** the folder is fully enumerated, protected, and restored; the
restore destination is a granted path or app-private storage and **never**
Downloads (FR-036) — note this deliberately differs from single-file decrypt,
which may fall back to Downloads with a banner. A folder whose `content://` tree
cannot be resolved to a real path is **refused with a clear explanation**, not
silently partially captured.

**Discharges:** SC-010, FR-005, FR-034, FR-036.

---

## S13. Steps-to-start

Count the taps from the home screen to starting protection on a folder.

**Expected:** no more steps than the existing single-file flow needs, plus the
folder-contents confirmation that FR-003 and FR-004 require.

**Discharges:** SC-004.
