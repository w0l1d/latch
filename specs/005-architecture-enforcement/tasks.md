---
description: "Task list for Architecture Enforcement (005)"
---

# Tasks: Architecture Enforcement

**Input**: `docs/ARCHITECTURE.md` (laws A1–A9), plus the 2026-11-02 architecture audit at `/tmp/latch-arch/architecture-report.md`.

**Priority**: P0 — high. This is the first work item after the current device-E2E run completes.

**Status**: ⏸ **Deferred — do not start while the device E2E suite is running.** No source file may be edited until that run is finished; the suite tests an installed APK and must not be interleaved with refactors whose effect it cannot observe.

**Tests**: Included and mandatory. Every task that moves logic adds tests that exercise the moved code through **ports/fakes**, not only through the app. The `.latch` v1 freeze guards must pass **unedited** throughout (A9).

**Format**: `- [ ] AE## [P?] [A#] Description with file path`. `[P]` = different files, no dependency on an incomplete task.

**Commands** (run per package, never one command for all):
`dart format .` · `flutter analyze --no-pub && flutter test` (root) · same inside `packages/myenc_core` and `packages/myenc_adapters` · `cd android && ./gradlew :app:testDebugUnitTest` when Kotlin changes.

---

## Why this exists

The audit found the architecture is **real where it matters** — core purity, barrel imports, feature isolation and the format freeze all hold — but five laws are only partly true, and the strongest one (A1) has no regression guard beyond review. Without a machine check, the next refactor can silently undo it.

The purpose of this spec is **not** to redesign Latch. It is to:

1. make the laws the code already obeys impossible to break by accident (AE01);
2. bring the five partially-true laws into compliance (AE03–AE09);
3. remove scaffolding that describes a design the code does not use (AE10).

Every task must leave user-visible behaviour unchanged. The only acceptable visible difference is the removal of a defect found in the same area (e.g. the duplicated accessibility label found on the encrypt pick screen).

---

## Law coverage

| Law | Today | Covered by |
|---|---|---|
| A1 Core Purity | verified | AE01 (lock it) |
| A2 Port Authority | partial | AE04, AE05 |
| A3 Named Composition Points | violated (2 sites) | AE03, AE01 |
| A4 Feature Isolation | verified | AE01 (lock it) |
| A5 Barrel-Only Imports | verified | AE01 (lock it) |
| A6 Typed Seams | violated (17 maps, stringly cmds) | AE06, AE07, AE08 |
| A7 Irreversible Decisions | violated (2 sites) | AE03, AE04 |
| A8 Single Composition Root | violated (3 statics) | AE09 |
| A9 Format Freeze | verified | AE02 (verify no drift) |

---

## Phase 1 — Lock what already holds (no behaviour change)

- [ ] **AE01** [P] [A1,A3,A4,A5] Add `test/architecture_test.dart` at the repo root. Checks: (a) no `package:flutter` / `dart:io` import under `packages/myenc_core/lib`; (b) no import of `lib/features/<other>` from any feature; (c) no import path containing `myenc_*/src/` anywhere in `lib/`; (d) `package:sodium` and concrete adapter constructions appear only in `lib/main.dart` and `lib/core/isolate_worker.dart`. Fails with the offending path in the message. Runs in the existing root `flutter test` job.
- [ ] **AE02** [P] [A9] Confirm after every subsequent task that `codec_freeze_test.dart`, `golden_vectors_test.dart` and `codec_test.dart` pass with the golden files **unmodified** (`git diff --exit-code packages/myenc_adapters/test/golden/`). Add this check to the PR checklist, not only to CI, because a regenerated golden would still pass.

## Phase 2 — Move decisions into the domain (A7)

- [ ] **AE03** [P] [A3,A7] Move the Argon2id calibration out of `lib/features/onboarding/device_check_screen.dart:60-95`. Add `KdfCalibration` to `packages/myenc_core/lib/src/domain/`, taking a `CryptoPort` and returning the chosen parameters. The screen calls it through the existing service layer. Delete the `package:sodium` import from the feature. Test with a fake `CryptoPort` that reports controlled timings.
- [ ] **AE04** [A2,A7] Move `verifyContainerMatchesSource` from `lib/core/verified_delete.dart` into `packages/myenc_core/lib/src/domain/verified_delete.dart`, parameterised by `CryptoPort` + `FileIoPort`. Keep only path/collision plumbing in the app. Tests must cover: match, one-byte difference, truncated container, container that fails to decrypt; each must assert the source is preserved on failure. This is the safety-critical task — do not merge it without the fakes proving the "never delete on doubt" property.

## Phase 3 — Make the ports real (A2)

- [ ] **AE05** [A2] Type the worker's internal functions against `CryptoPort` / `FileIoPort` instead of `SodiumCryptoAdapter` / `FileIoDart` (`lib/core/isolate_worker.dart:67,113-114,215-216,323-324,391-392,463`). Construction stays exactly where it is (`:24-25`) — that is a composition point under A3, not a leak. No behaviour change; analyze must stay clean.
- [ ] **AE05b** Enforce that `FileIoPort` and `DirectoryIoPort` each have at least one interface-typed consumer, or delete them. A port with only an implementation is not a seam; keep it only if it is cited by a caller.

## Phase 4 — Typed seams (A6)

- [ ] **AE06** [A6] Introduce typed route payloads for the encrypt flows (`pick → passphrase → options → review → progress → success`), replacing `extra: {…}` at `encrypt_passphrase_screen.dart:282,295` and siblings. One immutable class or record per payload; the receiving screen asserts the type once. Migrate one flow at a time.
- [ ] **AE07** [A6] Same for the decrypt flows (`decrypt_passphrase_screen.dart:108,119`, folder screens).
- [ ] **AE08** [A6] Replace the worker's string `cmd` values with constants (a `WorkerCmd` class or enum) shared by `AppCrypto` and `latchWorker`. Keep the wire values unchanged so nothing on the protocol side changes. After AE06–AE08 land, extend `architecture_test.dart` to reject new `extra: {` literals and bare `cmd:` string literals.

## Phase 5 — Composition root (A8)

- [ ] **AE09** [A8] Add an `AppDependencies` object constructed in `main.dart`, holding the three services now stored as statics on `AppCrypto` (`app_crypto.dart:46-54`). Expose it through a small `InheritedWidget` (no new package) or pass it explicitly to `LatchApp`. Remove the mutable statics. Ensure the pre-tree-mount ordering is enforced by construction, not convention: `AppDependencies.create()` must be awaited before `runApp`.

## Phase 6 — Remove misleading scaffolding

- [ ] **AE10** [P] Decide the fate of two pieces of dormant code, and record the decision in the commit body: `tar: ^2.0.2` in `packages/myenc_core/pubspec.yaml` (declared with a comment claiming it serves the v2 packed-folder payload, imported nowhere) and `PayloadPreamble` (`format/payload_preamble.dart`, exported and tested, referenced by no production code). Either wire them when 001-folder-encryption resumes, or remove them until it does. A manifest must not describe a usage that does not exist.

## Phase 7 — Close the loop

- [ ] **AE11** [P] Cite law IDs in the PR review checklist. (The `CLAUDE.md` → "Docs worth reading" link was added on 2026-11-02 when this spec was created, so the standard is discoverable before the enforcement work starts.)
- [ ] **AE12** Re-run the audit checks and update the "Current status" line under each law in `docs/ARCHITECTURE.md` from *violated/partial* to *verified*, with the enforcing test named.

---

## Sequencing

`AE01` and `AE02` first (they protect every following commit). Then `AE03` and `AE04` (highest risk, so they land early while the code is fresh). `AE05` is mechanical and can go any time after `AE04`. `AE06`–`AE08` are independent of each other. `AE09` last in the source refactors because it touches `main` and every service consumer. `AE10`–`AE12` can interleave.

`AE03` and `AE04` are the only tasks that change *where* a safety-critical decision is made; treat them as the review priority, not the typing cleanups.

---

## Acceptance criteria

- [ ] `test/architecture_test.dart` passes and is referenced from CI's existing root test job.
- [ ] `package:sodium` appears in exactly two files: `lib/main.dart`, `lib/core/isolate_worker.dart`.
- [ ] No `lib/features/*` file imports another feature; no file imports `myenc_*/src/`.
- [ ] `verified_delete` and KDF calibration live in `myenc_core/domain` and are covered by tests using fake ports.
- [ ] No `extra: {` map remains in any flow migrated by this spec; worker commands are constants.
- [ ] No mutable service statics remain on `AppCrypto`; `AppDependencies` is constructed before `runApp`.
- [ ] Golden/freeze files are byte-identical to their committed state (`git diff --exit-code` on `packages/myenc_adapters/test/golden/`).
- [ ] All three packages pass `dart format --set-exit-if-changed .`, `flutter analyze --no-pub`, `flutter test`; Kotlin tests pass if any Kotlin changed.
- [ ] No user-visible behaviour change other than the removal of a defect explicitly noted in the commit that fixes it.

## Out of scope

- Any change to `docs/FORMAT.md`, the version byte, or the wire layout (A9).
- Introducing a DI container, a state-management library, repositories, or codegen (D4, D5, D9).
- Re-slicing features into `data/domain/presentation`.
- The v2 folder-encryption feature (001) — AE10 only records what to do with its leftovers.
- Accessibility fixes found during device testing (tracked separately; may be done in the same area but are not this spec's goal).

## Risks

| Risk | Mitigation |
|---|---|
| A refactor changes crypto behaviour invisibly | Freeze guards run after every task; AE02's `git diff` check catches a regenerated golden |
| AE04 moves the deletion rule and a case is missed | Tests enumerate match/mismatch/truncated/undecryptable and assert the source survives on every failure |
| Typed payload migration breaks navigation | One flow per commit; the flow's widget/e2e test must pass before the next |
| Work starts while device testing runs | Status is explicitly deferred; do not edit `lib/` or `packages/` until the suite completes |
| A law proves wrong in practice | Amend `docs/ARCHITECTURE.md` in the same change, state the new evidence, add the enforcing test (see §4 of that document) |
