# Implementation Plan: Folder Encryption (UC-13)

**Branch**: `001-folder-encryption` | **Date**: 2026-08-26 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/001-folder-encryption/spec.md`

## Summary

Let a user select a **folder** instead of files, protect the whole tree as
**exactly one** `.latch` container, and restore it to the same tree — same
structure, same names, byte-identical content, plus modification times, the
executable bit, and symlinks kept as links.

The tree is packed into a streaming **tar** stream (USTAR + PAX, no compression)
and that stream is the container's payload. Because a restore must never expand a
plaintext that merely *happens* to be an archive, the decision to unpack comes
from an **authenticated, extensible payload-kind** value — carried as an 8-byte
preamble **inside the encrypted payload**, which the secretstream authenticates
for free. That makes this **`.latch` v2**: the version byte goes to `0x02`, and
**not one byte of the v1 layout changes**. Single files still produce v1.

Any unreadable entry aborts the whole operation and names the offending entry; no
half-captured container is ever written.

## Technical Context

**Language/Version**: Dart, SDK `^3.12.2`; Flutter pinned to 3.44.2 in CI

**Primary Dependencies**: `sodium` ^4.0.0 (libsodium via Dart native assets),
`package:tar` ^2.0.2 (new — pure Dart, streaming, no `dart:io`), `file_picker`
^10.3.3, `go_router` ^17.3.0, `path` ^1.9.0

**Storage**: No database. Files on disk plus `flutter_secure_storage` for key
material and `shared_preferences` for user choices. This feature adds **no**
persistent state (FR-040) and no folder→grant cache (FR-035).

**Testing**: `flutter test` per package (three independent suites);
`./gradlew :app:testDebugUnitTest` for the Kotlin SAF helpers; Python
`tool/gen_golden_vectors.py` for the independent oracle

**Target Platform**: Android (API 30+, scoped storage), iOS, macOS/Linux/Windows
desktop

**Project Type**: Mobile + desktop Flutter app, hexagonal, three packages

**Performance Goals**: Progress advances at least once per second for a
10,000-file folder (SC-005). Cancellation takes effect within a few seconds
(SC-007). UI never blocks — all heavy work in the existing spawned isolate
(FR-030).

**Constraints**: Fully offline (FR-038). Peak memory independent of entry count
**and** of the largest file (FR-027, SC-006) — this is what forces streaming
end-to-end and rules out in-memory archivers. No reachable partial plaintext at
any point (FR-021, FR-029). Restored plaintext never passes through a shared or
world-readable location (FR-036).

**Scale/Scope**: Verified against 10,000 files / 10 GB (SC-005, SC-006). One
folder per operation (FR-001).

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1 design.*

| Principle | Gate | Verdict |
|---|---|---|
| **I. Offline, Stateless, No Recovery** | No network, no account, no recovery path, no persistent state describing protected folders | **PASS** — FR-038/039/040 forbid all three; the design adds no storage and no service call. |
| **II. `.latch` v1 Is Frozen** | No v1 byte changes; new capability arrives via a version bump with fail-closed readers | **PASS** — the payload preamble lives inside the ciphertext, so `MyencCodec` header encoding is untouched. Version byte `0x01`→`0x02` for folder containers only. `codec_freeze_test.dart` and the existing golden vectors pass **unmodified**; the reserved v1 flag bits are **not** repurposed. |
| **III. Hexagonal Purity** | `myenc_core` free of Flutter and `dart:io`; platform contact only through ports | **PASS with one tracked cost** — `package:tar` is pure Dart with no `dart:io` (verified in the published 2.0.2 archive) so it may live in the core, but it is the core's first non-test dependency. See Complexity Tracking. All filesystem contact enters through the new `DirectoryIoPort`. |
| **IV. Fail Closed, No Partial Plaintext** | Wrong passphrase fails at the wrap; corruption fails at a chunk tag; decrypt output staged and revealed only on success; teardown sweeps the temp | **PASS, with one required fix** — a folder restore stages into a temporary directory renamed into place on success. `AppCrypto._runBatch` currently sweeps a single `<outPath>.tmp` *file*; it MUST learn to sweep a staged *directory* recursively, or a cancelled restore leaves partial plaintext. Tracked as a P1 task, not an afterthought. |
| **V. Independent Verification** | Crypto pinned by an oracle Dart did not produce; isolate ordering pinned with plain `test()`; exact-inverse mappings unit-tested | **PASS** — tar's PAX subset is readable and writable by Python's stdlib `tarfile`, so `tool/gen_golden_vectors.py` can produce a folder container Dart never touched. This is the decisive reason tar beat a custom pack format. Batch ordering stays in `test/app_crypto_batch_test.dart` under plain `test()`. |
| **Security & Platform Constraints** | Key material zeroized; no misleading affordances; Play-compliant storage; heavy crypto in a spawned isolate | **PASS** — DEK zeroization is unchanged (the payload preamble is plaintext content, not key material). No `MANAGE_EXTERNAL_STORAGE`. FR-020e's "could not apply this metadata" report exists precisely so the app never claims fidelity it did not deliver. |
| **Development Workflow & Quality Gates** | `dart format`, analyze, and test green in all three packages plus the JVM suite | **PASS** — no gate waived. |

**Gate result: PASS.** One violation is tracked (below) and one required
remediation is scheduled inside the plan rather than deferred.

**Post-Phase-1 re-evaluation.** The table above is the *post-design* verdict — it
was re-run against the finished contracts and data model, and two conclusions
changed from the pre-research reading:

- Principle II moved from *at risk* to **PASS** once the payload-kind indicator
  moved inside the ciphertext. The pre-research assumption was a new header field,
  which would have needed either a header-layout change or secretstream
  additional-data; neither is now required.
- Principle IV moved from *PASS* to **PASS with a required fix**: designing the
  staged-directory restore exposed that `AppCrypto._runBatch` sweeps a single
  `.tmp` **file**, so a cancelled folder restore would leave partial plaintext.
  That is a security regression, and it is scheduled in phase P1 — before any UI
  can trigger a restore — rather than tracked as a follow-up.

No new violations appeared in Phase 1, and nothing in the design needs a
constitutional waiver.

## Project Structure

### Documentation (this feature)

```text
specs/001-folder-encryption/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions and rejected alternatives
├── data-model.md        # Phase 1 — entities and their validation rules
├── quickstart.md        # Phase 1 — runnable validation scenarios
├── contracts/
│   ├── payload-preamble.md   # .latch v2 payload preamble (normative)
│   ├── pack-format.md        # the tar subset (normative)
│   └── ports.md              # DirectoryIoPort and the worker protocol
├── checklists/
│   └── requirements.md  # spec quality checklist (16/16)
└── tasks.md             # Phase 2 — created by /speckit-tasks, NOT here
```

### Source Code (repository root)

```text
packages/myenc_core/lib/src/
├── format/
│   ├── file_header.dart          # MODIFY: accept version 2 alongside 1
│   ├── myenc_codec.dart          # MODIFY: version gate only — layout untouched
│   ├── payload_preamble.dart     # NEW: 8-byte preamble, PayloadKind enum
│   └── myenc_errors.dart         # MODIFY: UnknownPayloadKindError, UnsafeArchiveEntryError
├── domain/
│   ├── envelope_service.dart     # MODIFY: emit/consume the preamble on v2
│   ├── folder_pack.dart          # NEW: tree -> deterministic tar stream
│   ├── folder_unpack.dart        # NEW: tar stream -> entries, via SafeUnpacker
│   └── safe_unpacker.dart        # NEW: the single hostile-input chokepoint
└── ports/
    └── directory_io_port.dart    # NEW: walk, mkdir, symlink, setMtime, setExecutable

packages/myenc_adapters/lib/src/
└── directory_io_dart.dart        # NEW: dart:io implementation of DirectoryIoPort

lib/
├── core/
│   ├── app_crypto.dart           # MODIFY: encryptFolder / restoreFolder; sweep staged DIRS
│   ├── isolate_worker.dart       # MODIFY: cmd 'pack_encrypt', 'decrypt_unpack'
│   ├── folder_scan.dart          # NEW: enumerate + total size + unpreservable report
│   └── output_plan.dart          # MODIFY: folder destination rules (never Downloads)
├── features/encrypt/             # MODIFY: folder pick, folder review screen
├── features/decrypt/             # MODIFY: folder restore destination + metadata report
└── shared/error_messages.dart    # MODIFY: copy for the new typed errors

android/app/src/main/kotlin/.../MainActivity.kt   # MODIFY only if selection needs it
```

**Structure Decision.** The existing three-package hexagonal split is kept
exactly as-is; this feature adds files, it does not move any. Packing, unpacking,
the preamble, and the safety guard are all **pure byte-level logic**, so they
belong in `myenc_core` where they can be tested without a filesystem — which is
also what makes SC-013's hostile-stream test possible without touching disk. Every
real directory operation crosses the new `DirectoryIoPort` into
`myenc_adapters`. The app layer gains folder-aware screens and worker commands but
no new architectural concept.

## Phased delivery

Ordered so that each phase is independently verifiable and the security-critical
pieces land before the UI that would expose them.

| Phase | Content | Proves |
|---|---|---|
| **P0** | `payload_preamble.dart`, error types, version-2 gate; v1 freeze guards re-run untouched | v2 exists and v1 is provably unharmed (FR-013, FR-014, SC-009) |
| **P1** | `folder_pack` / `folder_unpack` / `safe_unpacker`; `DirectoryIoPort` + `DirectoryIoDart`; `_runBatch` staged-**directory** sweep | Round trip and fidelity in pure Dart + adapters; hostile streams write nothing (SC-002, SC-013, SC-014); the Principle IV fix is in before any UI can trigger a restore |
| **P2** | Worker commands, `AppCrypto.encryptFolder` / `restoreFolder`, `folder_scan` | One-container-per-folder, byte-weighted progress, abort-on-unreadable, cancellation cleanliness (FR-012, FR-026–FR-031) |
| **P3** | Encrypt folder-pick and review screens; restore destination and metadata report | FR-003, FR-004, FR-020e, SC-004 |
| **P4** | Python folder golden vector; Android selection path and its refusal case | Principle V for v2; SC-010 |

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| `package:tar` becomes `myenc_core`'s first non-test dependency, enlarging the audit surface Principle III's rationale is about | Streaming pack/unpack with mtime, executable bit, and symlink support is required by FR-020a and FR-027, and tar's PAX subset is the only candidate with an **independent oracle** (Python `tarfile`) as Principle V demands | A hand-rolled "latchpack" format needs no dependency, but its Python oracle would be a transliteration of the Dart code — Principle V's external oracle collapses into self-consistency, and the hostile-input parser gets written from scratch instead of hardened at one chokepoint. The dependency is pure Dart, `dart:io`-free, and 11 source files — small enough to actually read. |
| `.latch` v2 introduced | FR-020b needs a folder indicator and FR-020c needs it authenticated — container-level metadata, which Principle II says requires a version bump | Repurposing v1's reserved flag bits changes v1's meaning for existing readers (a direct Principle II violation) and leaves the indicator unauthenticated (FR-020c violation). |
