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
half-captured container is ever written. Entries the format cannot represent at
all — device nodes, sockets, FIFOs — are **skipped and reported by path** rather
than treated as failures (FR-002a); a skip is never silent, and anything skipped
is excluded from the post-encryption deletion (FR-002b).

Three guards added by the 2026-09-29 clarification round wrap that core: a
**pre-flight space estimate** at both the destination and the staging area which
refuses before any work begins and names the shortfall (FR-029a); **change
detection** that aborts and states *what* changed if an entry moves under the
operation's feet (FR-031a); and a **deletion mode** for originals — shred each
captured file, then remove the emptied directories so the names die too —
defaulted, explained, and changeable in advanced settings rather than asked on
every run (FR-041, FR-041a).

## Technical Context

**Language/Version**: Dart, SDK `^3.12.2`; Flutter pinned to 3.44.2 in CI

**Primary Dependencies**: `sodium` ^4.0.0 (libsodium via Dart native assets),
`package:tar` ^2.0.2 (already added to `packages/myenc_core/pubspec.yaml` — pure
Dart, streaming, no `dart:io`; the core's first non-test dependency), `file_picker`
^10.3.3, `go_router` ^17.3.0, `path` ^1.9.0

**Storage**: No database. Files on disk plus `flutter_secure_storage` for key
material and `shared_preferences` for user choices. This feature stores **no
folder state** — no path, name, entry list, timestamp or size of anything the
user protected (FR-040), and no folder→grant cache (FR-035). It adds exactly one
`shared_preferences` key: the deletion mode for originals (FR-041a). That is a
*setting*, not folder state — the same distinction FR-035 already draws when it
permits `UnresolvedDestination` to remember a chosen destination while forbidding
a remembered grant. The key's value is one enum; it names no folder.

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
folder per operation (FR-001). **No app-imposed ceiling** on entry count or total
size (FR-003a) — a large selection warns in pre-flight and proceeds; only a
genuine platform limit refuses (FR-005a). Android needs roughly **2×** the
container size free, because the worker stages into app cache and the main
isolate then relocates through SAF — the pre-flight estimate must check both
locations, not just the destination (FR-029a, R10).

## Constitution Check

*GATE: evaluated before Phase 0 and re-evaluated after Phase 1 design.*

| Principle | Gate | Verdict |
|---|---|---|
| **I. Offline, Stateless, No Recovery** | No network, no account, no recovery path, no persistent state describing protected folders | **PASS** — FR-038/039/040 forbid all three; the design adds no service call. It adds one stored value: the FR-041a deletion mode, an enum that names no folder and reveals nothing about what the user protected. Principle I bars *state describing protected folders*, not user preferences — the app already stores several (passphrase policy, save-folder choices). A pre-flight space estimate and a change-detection record are both **in-memory for one operation** and are never written down. |
| **II. `.latch` v1 Is Frozen** | No v1 byte changes; new capability arrives via a version bump with fail-closed readers | **PASS** — the payload preamble lives inside the ciphertext, so `MyencCodec` header encoding is untouched. Version byte `0x01`→`0x02` for folder containers only; single files stay v1 (FR-013c). Since features 002 and 003 shipped, the bump is one registry row plus one strategy object, and fail-closed on unknown versions is inherited from `FormatVersionRegistry.require` rather than written here (FR-013a, FR-013d). `codec_freeze_test.dart`, the golden vectors, and 002/003's compatibility corpora pass **unmodified**; the reserved v1 flag bits are **not** repurposed. |
| **III. Hexagonal Purity** | `myenc_core` free of Flutter and `dart:io`; platform contact only through ports | **PASS with one tracked cost** — `package:tar` is pure Dart with no `dart:io` (verified in the published 2.0.2 archive) so it may live in the core, but it is the core's first non-test dependency. See Complexity Tracking. All filesystem contact enters through the new `DirectoryIoPort`. |
| **IV. Fail Closed, No Partial Plaintext** | Wrong passphrase fails at the wrap; corruption fails at a chunk tag; decrypt output staged and revealed only on success; teardown sweeps the temp | **PASS, with one required fix** — a folder restore stages into a temporary directory renamed into place on success. `AppCrypto._runBatch` currently sweeps a single `<outPath>.tmp` *file*; it MUST learn to sweep a staged *directory* recursively, or a cancelled restore leaves partial plaintext. Tracked as a P1 task, not an afterthought. Two clarification-round additions strengthen the same principle rather than straining it: the FR-029a pre-flight estimate makes the commonest cause of a half-written restore (no space) a refusal *before* any plaintext exists, and FR-031a turns a source changing mid-read — which would otherwise yield a container whose tar headers disagree with its own content — into an abort that names the path and the change. The FR-041 deletion runs **after** the container is written and verified, and only over entries the container demonstrably holds (FR-002b), so a failed or partial encryption can never destroy an original. |
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

**Re-run 2026-09-29 against the clarification round.** The ten requirements added
by `/speckit-clarify` were re-evaluated against every principle. One verdict
gained a caveat and none changed:

- Principle I now has to account for **one stored value** — the FR-041a deletion
  mode. It stays PASS: the principle bars persistent state *describing protected
  folders*, and an enum naming a deletion strategy describes none. If a later
  change makes that key hold a path, a name, or a count, this verdict is void.
- Principle IV is *strengthened*, not strained, by FR-029a and FR-031a — both
  convert a class of half-finished operation into an early refusal. FR-041's
  deletion is sequenced after the container is written and verified and is
  bounded by the captured manifest (FR-002b), so it cannot destroy an original
  the container does not hold.
- FR-005a asks for a pre-flight refusal when the container would exceed the
  destination filesystem's maximum file size. No platform will *say* what that
  limit is — `StructStatVfs`, `StatFs` and `StorageVolume` all lack a filesystem
  type, and scoped storage fronts every app-visible path with FUSE. The limit is
  nonetheless discoverable by **provoking** it: allocating the estimated size
  ahead of the work and reading the errno. On FAT32 that refusal arrives in
  microseconds with `EFBIG`; on any filesystem with sparse files a success costs
  nothing. **FR-005a therefore stands as written** (research R15) — the probe is
  gated at >4 GiB, timed out, and on Android runs natively against the SAF
  destination rather than in Dart against the staging cache.

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
│   ├── format_version.dart       # MODIFY: one row — register v2 in `all`; writeDefault stays v1
│   ├── format_strategy.dart      # MODIFY: one entry — key v2 into formatVersionStrategies
│   ├── format_strategy_v2.dart   # NEW: v2 header layout (identical to v1; may delegate)
│   ├── file_header.dart          # UNCHANGED — no version constant lives here any more
│   ├── myenc_codec.dart          # UNCHANGED — the façade already dispatches by registry
│   ├── payload_preamble.dart     # NEW: 8-byte preamble, PayloadKind enum
│   └── myenc_errors.dart         # MODIFY: UnknownPayloadKindError, UnsafeArchiveEntryError
├── domain/
│   ├── envelope_service.dart     # MODIFY: emit/consume the preamble on v2
│   ├── folder_pack.dart          # NEW: tree -> deterministic tar stream; detects
│   │                             #   an entry changing mid-read (FR-031a)
│   ├── folder_unpack.dart        # NEW: tar stream -> entries, via SafeUnpacker
│   └── safe_unpacker.dart        # NEW: the single hostile-input chokepoint
├── format/
│   └── myenc_errors.dart         # (above) + InsufficientSpaceError,
│                                 #   SourceChangedError, UnpreservableEntrySkipped
└── ports/
    ├── directory_io_port.dart    # LANDED by 004: walk, stat, createDirectory
    │                             #   (+ classification, FR-002a). 001 ADDS: symlink,
    │                             #   setMtime, setExecutable, rename/delete directory
    └── free_space_port.dart      # LANDED by 004: freeBytesAt(path) -> int?; null = unknowable

packages/myenc_adapters/lib/src/
├── io/directory_io_dart.dart     # LANDED by 004 (walk/stat/createDirectory); 001 extends
└── io/free_space_dart.dart       # LANDED by 004: free space. 001 ADDS the max-file-size probe (R10, R15)

lib/
├── core/
│   ├── app_crypto.dart           # MODIFY: encryptFolder / restoreFolder; sweep staged DIRS
│   ├── isolate_worker.dart       # MODIFY: cmd 'pack_encrypt', 'decrypt_unpack'
│   ├── folder_scan.dart          # NEW: enumerate + total size + skipped-entry
│   │                             #   report (FR-002a) + per-entry (kind,size,mtime)
│   │                             #   snapshot used for FR-031a change detection
│   ├── preflight_check.dart      # NEW: space estimate at destination AND staging,
│   │                             #   large-selection warning (FR-029a, FR-003a)
│   ├── original_deletion.dart    # NEW: shred captured files, then remove emptied
│   │                             #   dirs; consumes the captured manifest, never a
│   │                             #   fresh walk (FR-041, FR-002b)
│   ├── deletion_mode.dart        # NEW: the one shared_preferences key (FR-041a)
│   ├── output_plan.dart          # MODIFY: folder destination rules (never Downloads);
│   │                             #   reuse the read+write grant selection already took
│   └── saf_bridge.dart           # UNCHANGED — pickTree/existingTreeGrantFor suffice
├── features/encrypt/             # MODIFY: folder pick, folder review screen
├── features/decrypt/             # MODIFY: folder restore destination + metadata report
├── features/settings/
│   ├── save_folders_screen.dart  # MODIFY: a grant may now be held only because a
│   │                             #   folder was encrypted — the screen must stop
│   │                             #   calling every grant a save destination
│   └── deletion_mode_screen.dart # NEW: advanced setting; states what each mode
│                                 #   does and its limits (FR-041a)
└── shared/error_messages.dart    # MODIFY: copy for the new typed errors

android/app/src/main/kotlin/.../MainActivity.kt   # MODIFY only if selection needs it
```

**Revisited 2026-09-29.** This map was drawn before PRs #66, #74 and #78. Two
entries changed as a result: `output_plan.dart`'s folder work is now mostly
*recognising* the grant that folder selection already took (it is read **and**
write), rather than adding a destination path; and `save_folders_screen.dart`
joins the map, because this feature makes it possible to hold a folder grant for
a folder the user only ever encrypted, which that screen currently describes as a
save destination. See `research.md` R7.

**Revisited again 2026-09-29 (clarification round).** Five answers added ten
requirements, and they land in four new app-layer files (`preflight_check.dart`,
`original_deletion.dart`, `deletion_mode.dart`, `deletion_mode_screen.dart`), one
new port (`free_space_port.dart` + its adapter), and two additions to existing
core files (change detection in `folder_pack.dart`, three new error types). None
of it touches the format, the codec, or the v1 freeze — the `.latch` v2 design is
unchanged by this round. See `research.md` R10–R13.

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
| **P2** | Worker commands, `AppCrypto.encryptFolder` / `restoreFolder`, `folder_scan` incl. skip classification and the `(kind,size,mtime)` snapshot | One-container-per-folder, byte-weighted progress, abort-on-unreadable, skip-and-report, mid-operation change abort, cancellation cleanliness (FR-002a, FR-012, FR-026–FR-031a, SC-024, SC-025) |
| **P2b** | `free_space_port.dart` + adapter, `preflight_check.dart` | Refusal before work begins naming the shortfall *and* the location; large-selection warning that does not refuse (FR-029a, FR-003a, FR-005a, SC-023, SC-027) |
| **P3** | Encrypt folder-pick and review screens; restore destination and metadata report; skipped-entry and change-abort copy | FR-003, FR-004, FR-020e, SC-004, SC-024 |
| **P3b** | `deletion_mode.dart`, `deletion_mode_screen.dart`, `original_deletion.dart` | Default shred-then-remove-emptied-dirs; setting reachable and explained; nothing skipped is ever deleted (FR-002b, FR-041, FR-041a, SC-026) |
| **P4** | Python folder golden vector; Android selection path and its refusal case | Principle V for v2; SC-010 |

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| `package:tar` becomes `myenc_core`'s first non-test dependency, enlarging the audit surface Principle III's rationale is about | Streaming pack/unpack with mtime, executable bit, and symlink support is required by FR-020a and FR-027, and tar's PAX subset is the only candidate with an **independent oracle** (Python `tarfile`) as Principle V demands | A hand-rolled "latchpack" format needs no dependency, but its Python oracle would be a transliteration of the Dart code — Principle V's external oracle collapses into self-consistency, and the hostile-input parser gets written from scratch instead of hardened at one chokepoint. The dependency is pure Dart, `dart:io`-free, and 11 source files — small enough to actually read. |
| A free-space probe adds a small platform surface (`FreeSpacePort` + per-OS implementation) to an app that otherwise reaches the platform only for storage grants and secure storage | FR-029a requires a refusal *before* work begins that names the shortfall and the location, and Android needs the check at **two** locations (staging cache and destination). `dart:io` exposes no free-space API at all, so there is no zero-platform option | Relying only on the mid-run write failure (FR-029) is simpler and stays pure Dart, but it converts "we can tell you now, for free, that this will not fit" into "we destroyed an hour of your battery and then failed" — and on Android it fails *after* staging, at relocation, which is the worst moment. The pub.dev candidates were read at source and rejected on contract rather than quality: `storage_space` and `storage_info` take **no path argument**, returning one device-wide reading from a hardcoded location, and `disk_space_plus` — which does take a path, using the same two native calls chosen here — returns rounded megabytes and throws when the path is not statable, which is exactly the SAF case. All three are Android/iOS only. It answers a different question than FR-029a asks — on an SD-card destination it would report internal free space and let a doomed operation start, which is worse than returning `null`. Its four lines of native code are kept as a reference implementation (notably the correct iOS key, `volumeAvailableCapacityForImportantUsageKey`). See research R10. The same port carries the maximum-file-size pre-flight (`canHoldSingleFile`), which shares the destination path and the native call site; see research R15. |
| `.latch` v2 introduced | FR-020b needs a folder indicator and FR-020c needs it authenticated — container-level metadata, which Principle II says requires a version bump | Repurposing v1's reserved flag bits changes v1's meaning for existing readers (a direct Principle II violation) and leaves the indicator unauthenticated (FR-020c violation). |
