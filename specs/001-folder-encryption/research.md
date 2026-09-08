# Phase 0 Research: Folder Encryption (UC-13)

**Feature**: `specs/001-folder-encryption/` | **Date**: 2026-08-26

Every decision below is checked against `.specify/memory/constitution.md` v1.0.0
and the requirement it serves. Nothing here is a preference; each entry names the
requirement that forces it.

---

## R1. Where the payload-kind indicator lives

**Decision.** The payload-kind lives **inside the encrypted payload**, as a fixed
8-byte preamble at the very start of the plaintext stream. The `.latch` header
gains **no new field**; only the version byte changes, from `0x01` to `0x02`, to
mark "this container's plaintext begins with a payload preamble".

**Rationale.**

- **FR-020c demands authentication.** The v1 header is *not* authenticated —
  there is no header MAC (`docs/FORMAT.md` §2; only the secretstream body carries
  tags). A new header field would therefore be *unauthenticated* unless
  secretstream additional-data were introduced, which is a second format change.
  Bytes inside the secretstream are authenticated by construction, at zero design
  cost.
- **FR-013 / Principle II demand no v1 byte changes.** This touches no v1 field
  at all. `MyencCodec.encodeHeader`/`decodeHeader` keep their exact layout; the
  only edit is widening the accepted version set. `codec_freeze_test.dart` and the
  golden vectors keep passing **unmodified** — which is the point of a freeze
  guard.
- **Free confidentiality win.** Whether a container holds a file or a folder is
  not observable from the ciphertext. FR-009 only requires entry names and tree
  shape to be confidential; this gives more than asked without extra work.
- **FR-020h falls out naturally.** An unknown payload-kind is discovered only
  *after* the DEK unwrapped and the first chunk authenticated — so it is
  structurally impossible to confuse with a wrong passphrase (fails at the wrap)
  or corruption (fails at a chunk tag). The three messages are distinguishable
  because the three failures happen at three different, ordered stages, which is
  exactly Principle IV's ordering guarantee.

**Alternatives rejected.**

| Alternative | Rejected because |
|---|---|
| New header field (e.g. reuse reserved flag bits 1–7) | Unauthenticated — flipping the bit would silently change payload interpretation, violating FR-020c. Reusing reserved v1 bits also breaks Principle II directly: a v1 reader accepts the byte and misreads the container. |
| New header field + secretstream additional-data on chunk 0 | Authenticated, but a strictly larger change: touches the header codec, the crypto port (`createEncryptTransformer` has no AAD parameter), and the golden-vector producer. Leaks folder-vs-file to an observer. No compensating benefit. |
| Sniff the plaintext for tar/zip magic | Explicitly forbidden by FR-020b, and would expand a user's `.zip` into a tree — the exact bug the clarification session was about. |

**Version-emission policy.** Writers emit the **lowest version that can express
the payload**: a single file still produces **v1**, byte-identical to today
(FR-014); only a packed folder produces v2. A v2 container declaring kind
"single opaque file" is legal and readable, but is never produced by default.
This keeps containers readable by installs that predate the feature whenever it
is possible at all.

---

## R2. Packing format for the folder tree

**Decision.** **tar**, restricted to a defined subset: USTAR base records with
**PAX extended headers** for long paths, long link targets, and non-ASCII names.
Read and written with **`package:tar` ^2.0.2**. No compression.

**Rationale.**

- **Pure Dart, no `dart:io`.** Verified against the published archive: the only
  occurrence of `dart:io` in `package:tar` 2.0.2 `lib/` is inside a doc comment.
  Its transitive deps are `async`, `meta`, `typed_data` — all pure Dart. It can
  therefore live in `myenc_core` without violating **Principle III**.
- **Streaming both directions.** `TarWriter` consumes and `TarReader` produces
  entries as streams, so a 10 GB file is never materialised. This is what
  **FR-027** (peak memory independent of entry count *and* of largest file) and
  **SC-006** require, and it is what rules the alternatives out.
- **Carries exactly the in-scope metadata of FR-020a and no more.** A tar header
  has `mode` (executable bit), `modified` (mtime), and `TypeFlag.symlink` with
  `linkName`. Creation times, ACLs, and xattrs have no place in the subset — so
  FR-020a's out-of-scope list is enforced by the format, not by discipline.
- **An independent oracle exists for free — Principle V.** Python's stdlib
  `tarfile` with `format=tarfile.PAX_FORMAT` reads and writes the same subset.
  `tool/gen_golden_vectors.py` can therefore produce a folder container whose
  packed stream was never touched by Dart, which is precisely what Principle V
  requires and what a hand-rolled format cannot offer.

**Alternatives rejected.**

| Alternative | Rejected because |
|---|---|
| Custom "latchpack" format | No independent oracle: the Python producer would be a transliteration of the Dart code, so Principle V's "external oracle" degrades to self-consistency. Also writes the hostile-input parser — the riskiest code in the feature — from scratch. |
| `package:archive` | Its tar/zip encoders build in memory rather than streaming, so peak memory scales with archive size. Fails FR-027 and SC-006. |
| zip | The central directory is at the *end* and requires seeking, so a forward-only stream cannot be read without buffering the whole archive. Symlink support is a non-portable extension field. |
| tar with GNU long-name extensions instead of PAX | Python `tarfile` handles both, but PAX is the POSIX.1-2001 standard and encodes names as UTF-8 by specification — needed for FR-018 (byte-identical names). |

**Determinism (FR-020).** The tar subset must be written deterministically or
"restoring twice yields identical trees" is not testable. Rules:

- entries emitted in a **stable sorted order** by relative path, byte-wise on the
  UTF-8 encoding;
- `uid`/`gid` written as `0`, `userName`/`groupName` empty — these are out of
  scope per FR-020a and would otherwise leak the encrypting user's identity into
  the container;
- `mode` normalised to `0o755` for directories and executables, `0o644`
  otherwise — the executable bit is in scope, the rest of the permission set is
  not;
- no tar padding beyond the format's own 512-byte blocking.

**Concurrent modification (Assumptions).** A tar header states a file's size
*before* its content. If the file grows or shrinks between `stat` and read, the
archive is silently corrupt. The writer MUST compare bytes actually read against
the declared size and **abort the whole operation** on mismatch, naming the
entry — the same abort path as FR-031.

---

## R3. Compression

**Decision.** **No compression** in this feature. Pack format id `0x00` (none) is
the only value written; the preamble reserves a byte so compression can be added
later without a version bump.

**Rationale.** FR-020f makes compression optional and warns that it makes
container size correlate with content compressibility — a disclosure the product
does not currently make. Declining it costs nothing the spec asks for, keeps the
streaming path simple, and avoids widening the threat model for a size win the
success criteria never mention.

---

## R4. Folder enumeration and metadata access

**Decision.** A new port, `DirectoryIoPort`, in `myenc_core/lib/src/ports/`,
implemented as `DirectoryIoDart` in `myenc_adapters`. It is the *only* way the
core learns anything about a real directory.

**Rationale.** Principle III: `myenc_core` cannot import `dart:io`, and
`FileIoPort` is file-shaped (`openRead`, `writeChunked`, `fileSize`) with no
notion of a tree, a symlink, an mtime, or a mode. Extending `FileIoPort` with
directory operations would make every existing adapter and test fake implement
methods irrelevant to single-file work; a separate port keeps both interfaces
small and the fakes honest.

**Symlink handling.** Enumeration MUST use a non-following stat
(`Link.target()` / `FileSystemEntity.type(followLinks: false)`), never a
following one. Following would both escape the selection root and allow an
unbounded-size capture — see FR-006 (cycles) and the Assumptions section.

---

## R5. Hostile packed streams — the unpack guard

**Decision.** A single chokepoint, `SafeUnpacker`, in `myenc_core`. Every entry
coming out of `TarReader` passes through it before any filesystem call. It
rejects, fail-closed, before writing a byte:

- absolute paths, and paths containing a root or drive prefix;
- any path segment equal to `..`, and any path that after normalisation does not
  start with the destination root;
- symlink targets that are absolute, or that resolve outside the destination
  root once joined to the link's own directory;
- hard links, device nodes, FIFOs, sockets, and any tar typeflag outside the
  defined subset;
- entries whose declared size disagrees with the bytes read;
- duplicate relative paths within one archive.

**Rationale.** FR-020d states it plainly: a container is attacker-supplied data
by the time it is restored, and its authentication proves only that it was
produced with the passphrase — not that its contents are benign. Successful
authentication is therefore **not** an argument for trusting the packed stream.
Concentrating the checks in one class is what makes them reviewable (Principle
III) and directly testable (SC-013).

**A note on ordering.** The guard runs on entries, and entries are only produced
after the secretstream authenticates each chunk. So a corrupt container fails at
a chunk tag (Principle IV) *before* the guard ever sees a malicious path — the
two defences are sequential, not alternatives.

---

## R6. Restore output staging — no reachable partial plaintext

**Decision.** Restore unpacks into a **temporary sibling directory** and only
then renames it into place as one step. Nothing is written under the final tree
name until the entire unpack has succeeded. On cancellation, failure, or worker
death, the temporary directory is removed recursively.

**Rationale.** Principle IV requires decrypt output to be written to a temporary
path and revealed only on success, and its cleanup is called out as a *security
property*, not tidiness. The existing single-file path already does this with
`<outPath>.tmp` swept by `AppCrypto._runBatch` on teardown. A folder is the same
problem one directory up: FR-021 ("MUST NOT reveal any part of the restored tree
at the destination before the restore is known to have succeeded") and FR-029
(no reachable partial plaintext) leave no other shape.

**Consequence to flag.** `AppCrypto._runBatch`'s teardown currently sweeps a
single `<outPath>.tmp` *file*. It must learn to sweep a staged *directory*
recursively, or a cancelled folder restore leaves partial plaintext on disk —
a security regression, not a cosmetic one.

---

## R7. Android — folder selection and restore destination

**Decision.** Folder selection uses the existing SAF tree grant
(`SafBridge.pickTree` → `treeUriToPath`). The feature requires a **resolvable
real filesystem path** for both the source folder and the restore destination.
Where the path cannot be resolved — a cloud DocumentsProvider, a non-external
volume — the feature **refuses the selection with a clear explanation** under
FR-005 rather than degrading.

**Rationale.** The crypto worker is plain `dart:io` and has no platform channels
(`CLAUDE.md`, "Output path resolution"); it cannot walk a `content://` tree.
Enumerating and writing a whole tree through SAF from the main isolate would be a
second, much larger feature. FR-005 already requires refusing a selection the
system cannot safely process, and FR-034 requires *selection* to go through the
platform's folder-grant mechanism — which it does. Refusing loudly is compliant;
silently capturing a partial tree is not (FR-011, FR-032).

**Restore destination — a deliberate divergence from single-file decrypt.**
Single-file decrypt may fall back to Downloads with a banner. A folder restore
**MUST NOT**: FR-036 forbids restored plaintext passing through any shared or
world-readable location. So the destination is either a resolvable granted path
or **app-private storage** — never Downloads. This difference must be stated in
the UI copy, or a user will reasonably expect the Downloads fallback they have
seen before.

---

## R8. Progress reporting and the worker protocol

**Decision.** Reuse the existing worker→main protocol verbatim
(`file_start` / `progress` / `file_done` / `error` / `done`) with a **new `cmd`
value** — `pack_encrypt` and `decrypt_unpack` — and treat the whole folder as
**one** batch item. Progress is a two-stage weighted fraction: bytes packed and
encrypted, then, on restore, bytes unpacked.

**Rationale.** FR-012 makes the folder one container, so it is one unit of
success or failure — one `file_done`. FR-026 requires progress meaningful for
both "3 large files" and "10,000 small ones", which byte-weighted progress gives
and per-entry counting does not. Crucially, the **"last per-file result arrives
before the final 1.0" ordering invariant** (`test/app_crypto_batch_test.dart`,
Principle V) is a property of the protocol, not of the payload — keeping the
protocol unchanged is what keeps that invariant, and its test, valid.

**Total size must be known before the stream starts** for progress to be a
fraction (SC-005: progress advances at least once per second for 10,000 files).
Enumeration therefore happens **before** encryption begins — which FR-003 and
FR-004 already require, since the user is shown what was found and what will not
be preserved before anything is encrypted.

---

## R9. Testing strategy

| What | Where | Why there |
|---|---|---|
| Preamble encode/decode, unknown-kind rejection, reserved-byte rejection | `packages/myenc_core/test/` | Pure Dart, no platform. |
| `SafeUnpacker` against hostile streams (absolute path, `..`, escaping symlink, bad typeflag, size mismatch, duplicate path) | `packages/myenc_core/test/` | SC-013. Hand-built hostile tar streams — no filesystem needed to prove zero bytes escape. |
| Determinism: same tree packs to identical bytes twice | `packages/myenc_core/test/` | FR-020. |
| v1 freeze guards | `packages/myenc_core/test/codec_freeze_test.dart` (**unmodified**) | Principle II. If it fails, the change is wrong. |
| Golden folder container produced by Python (`tarfile` PAX + argon2-cffi + libsodium) | `packages/myenc_adapters/test/golden/` | Principle V — an oracle Dart did not produce. Committed alongside the existing v1 vectors, which keep passing. |
| Fidelity fixture round trip: known mtimes, an executable file, an internal symlink | `packages/myenc_adapters/test/` | SC-002, SC-014. Needs a real filesystem. |
| Archive-as-file: a `.zip` protected as a file restores byte-identical and is never expanded | `packages/myenc_adapters/test/` | SC-012, FR-020b — the bug this design exists to prevent. |
| Folder batch completion and the last-result-before-1.0 ordering | root `test/app_crypto_batch_test.dart` (plain `test()`) | Principle V and the FakeAsync gotcha: `testWidgets` cannot drive a real isolate. |
| Folder pick / review / progress / success screens | root `test/` `testWidgets`, real work inside `tester.runAsync` | Matches `test/e2e_flow_test.dart`; progress screens stay excluded. |

**Fixture creation caveat.** A fidelity fixture cannot be committed as a
directory with mtimes and symlinks intact — git does not preserve mtimes. The
fixture MUST be **built at test setup** from a declarative description, so the
mtimes and the executable bit are set by the test, not by the checkout.

---

## Open technical risks carried into Phase 1

1. **`_runBatch` teardown sweeps a file, not a tree** (R6). Security-relevant.
2. **Android metadata loss is expected, not exceptional** (FR-020e): the app
   sandbox will refuse the executable bit and symlinks routinely, so the
   "could not apply" report is a normal-path UI surface, not an error dialog.
3. **`package:tar` becomes a `myenc_core` dependency** — the first one beyond
   `test`. It is pure Dart and small, but it does enlarge the audit surface that
   Principle III's rationale is about. Recorded in Complexity Tracking.
