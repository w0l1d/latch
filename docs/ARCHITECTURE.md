# Latch Architecture Standard

**Status:** normative from the date of adoption. Applies to every package.
**Scope:** all source under `lib/`, `packages/myenc_core/lib/`, `packages/myenc_adapters/lib/`, and the Kotlin helpers under `android/app/src/main/kotlin/`.
**Who reads this:** anyone changing more than one file, any reviewer approving a diff, and any agent working in this repository.

This document records **the architecture Latch has**, not an architecture Latch aspires to. It names each rule so a review comment can cite it by ID (`A1`, `A7`, …), and records *why* each choice was made so a future change can argue with the reason rather than guess at it.

Measured baseline at adoption: app `lib/` 12,454 LoC / 58 files · `myenc_core` 1,638 LoC / 19 files · `myenc_adapters` 517 LoC / 5 files · tests 18,768 LoC.

---

## 1. The shape

```
┌──────────────────────────────────────────────────────┐
│  App (Flutter)                                       │
│   features/<flow>/   screens + flow wiring           │
│   core/              platform services, survivor     │
│                      logic, router, isolate worker   │
│   shared/            theme, widgets, error copy      │
└──────────────────┬───────────────────────────────────┘
                   │ package barrels only
        ┌──────────▼───────────┐
        │  myenc_adapters      │  one class per port,
        │                      │  no business policy
        └──────────┬───────────┘
                   │ package barrels only
   ┌───────────────▼──────────────────────────────────┐
   │  myenc_core                                      │
   │   ports/    ← the ONLY contract with a platform  │
   │   domain/   EnvelopeService, DEK wrap, KDF       │
   │             params, batch keys, verification     │
   │   format/   frozen v1 + registry + strategy      │
   └──────────────────────────────────────────────────┘
```

The concurrency seam is the spawned isolate: `AppCrypto` (main isolate) exchanges messages with `latchWorker` through `ReceivePort`/`SendPort`.

---

## 2. The laws

| ID | Name | Rule | Enforcement |
|---|---|---|---|
| **A1** | Core Purity | `myenc_core` imports neither `package:flutter` nor `dart:io` | machine (`test/architecture_test.dart`) |
| **A2** | Port Authority | Domain code reaches infrastructure only through `ports/`; a domain type never names a platform API or an adapter | machine (import graph) + review |
| **A3** | Named Composition Points | Only `lib/main.dart` and `lib/core/isolate_worker.dart` may import `package:sodium` or construct a concrete adapter | machine (allowlist test) |
| **A4** | Feature Isolation | `lib/features/<a>` never imports `lib/features/<b>` | machine (import test) |
| **A5** | Barrel-Only Imports | Packages are consumed via `package:myenc_*/myenc_*.dart`, never `src/` | machine (import test) |
| **A6** | Typed Seams | No stringly-typed payload crosses a module border (router `extra`, worker `cmd`, platform-channel keys) | machine-assisted + review |
| **A7** | Irreversible Decisions Live in the Domain | Anything that can destroy user data or set security parameters is implemented in `myenc_core` and testable with port fakes | review + targeted tests |
| **A8** | Single Composition Root | Services are constructed in `main.dart` and passed explicitly; no mutable global statics | review + dependency object |
| **A9** | Format Freeze | No byte of `.latch` v1 may change; extensions bump the version byte and must fail closed | machine (existing freeze guards) |

### A1 — Core Purity

**Rule.** `packages/myenc_core/lib/**` imports no Flutter and no `dart:io`.

**Why.** `myenc_core` is the package a security reviewer is asked to trust. Platform-free means it can be read, tested and reimplemented independently of any OS or UI framework — which is also what makes the independent Python reference (golden vectors) a meaningful oracle rather than a mirror of the same assumptions.

**How to comply.** If a task seems to need a file path or a platform call in core, model it as a port and implement the port in `myenc_adapters`.

**Current status.** Verified — 0 violations across 19 files.

### A2 — Port Authority

**Rule.** Domain types depend on `CryptoPort`, `FileIoPort`, `DirectoryIoPort`, `FreeSpacePort`, `SecureStoragePort`. They never depend on `SodiumCryptoAdapter`, `FileIoDart`, or a platform type.

**Why.** The ports are the mechanism by which the crypto and I/O implementations can be swapped and, more importantly, *faked* in tests. A port that no caller uses through its interface is documentation, not a seam.

**How to comply.** Type function parameters and fields against the port. Construct the concrete adapter only at a composition point (A3).

**Current status.** Partial. `CryptoPort` is genuinely consumed (`EnvelopeService`, `DekWrap`, `BatchWrapKey`); `FreeSpacePort` is injected in `bulk_plan.dart`. `FileIoPort` and `DirectoryIoPort` have no interface-typed consumer — the worker types against `FileIoDart`. This is the main debt A5/A4 tasks in `specs/005-architecture-enforcement/` address.

### A3 — Named Composition Points

**Rule.** Exactly two files may import `package:sodium` or construct `SodiumCryptoAdapter` / `FileIoDart`: `lib/main.dart` and `lib/core/isolate_worker.dart`.

**Why.** Isolates cannot share objects, so the worker must build its own adapters inside the new isolate — it *is* a composition root, not a leak. Naming it explicitly stops crypto from creeping into feature screens, which is precisely what happened once in `device_check_screen.dart` (running its own Argon2 benchmark) and produces two sources of KDF truth.

**How to comply.** A screen calls a service or `AppCrypto`; it never calls a crypto primitive.

### A4 — Feature Isolation

**Rule.** `lib/features/encrypt`, `decrypt`, `settings`, `onboarding`, `home` do not import one another.

**Why.** Features are screens. Screen-to-screen imports are the fastest way for a small app to become a graph nobody can change safely; shared behaviour belongs in `lib/core` (services, planning) or `lib/shared` (widgets, copy).

**Current status.** Verified — 0 cross-feature imports.

### A5 — Barrel-Only Imports

**Rule.** Consumers import `package:myenc_core/myenc_core.dart` and `package:myenc_adapters/myenc_adapters.dart`. Nothing imports a path under `src/`.

**Why.** `src/` is private by Dart convention and by declaration in `CLAUDE.md`; reaching in turns every internal rename into a breaking change across packages.

**Current status.** Verified — app imports the two barrels only (9 + 4 sites).

### A6 — Typed Seams

**Rule.** A value crossing a module border has a type:

- router payloads are typed classes/records, not `Map<String, Object?>`;
- worker commands are constants or an enum, not bare string literals;
- platform-channel keys are constants shared with the Kotlin side.

**Why.** A renamed map key or command string compiles and fails only at runtime, on a user's device, in a release build. The cost of a typed payload is one small class; the cost of the alternative is exactly the class of bug that is hardest to catch in CI.

**Current status.** Violated: 17 `extra: {…}` payloads (`encrypt_passphrase_screen.dart:282,295`, `decrypt_passphrase_screen.dart:108,119`, …) and stringly worker commands in `isolate_worker.dart`.

### A7 — Irreversible Decisions Live in the Domain

**Rule.** Two categories belong in `myenc_core`, exercised through ports:

1. **destructive decisions** — anything that decides whether original user data may be removed;
2. **security-parameter decisions** — anything that chooses or calibrates KDF parameters.

**Why.** These are the only places where an ordinary refactor can lose a user's file or weaken the encryption. They must be reviewable alongside the format, and testable with fakes rather than a device.

**Current status.** Two violations: `lib/core/verified_delete.dart` (imports `dart:io`, takes concrete adapters) and `lib/features/onboarding/device_check_screen.dart` (runs its own Argon2id benchmark).

### A8 — Single Composition Root

**Rule.** Every service is constructed in `main.dart` and passed explicitly (a small `AppDependencies` object). No mutable `static` service fields.

**Why.** `AppCrypto.passphraseStorage/deviceKeyService/recipientKeys` are assigned after the tree mounts because platform channels must be live. That ordering is currently a convention enforced by nothing; a missing assignment fails far from its cause, and tests must remember to install them.

**Current status.** 3 mutable statics (`app_crypto.dart:46-54`, set in `main.dart:27-31`).

### A9 — Format Freeze

**Rule.** `docs/FORMAT.md` is normative and frozen. No byte of v1 changes. A new version bumps the version byte, and readers fail closed on unknown versions.

**Enforcement.** `packages/myenc_core/test/codec_freeze_test.dart` and `packages/myenc_adapters/test/golden/golden_vectors_test.dart`. Never edit a freeze guard to make a test pass.

**Why.** A user's `.latch` files outlive the app. Changing v1 would silently strand containers written by any earlier build, with no recovery path (there is no server and no recovery by design).

---

## 3. Decisions and why

Each decision below was chosen deliberately; each records the cost accepted and the condition under which it should be revisited.

| ID | Decision | Why chosen | Cost accepted | Revisit when |
|---|---|---|---|---|
| **D1** | Three packages, not one | The trust claim needs a reviewable core; CI analyzes each package separately so a core regression cannot hide behind app code | Path deps; three analyze/test runs | Never — this is the product's audit boundary |
| **D2** | Hexagonal core, not Clean Architecture per feature | There is no network or database to abstract; ports exist only where a real platform exists (crypto, file I/O, storage) | App layer is less formally stratified | A second storage or crypto backend appears |
| **D3** | Feature-sliced app | Screens map to user flows; slicing prevents sideways coupling | Shared logic must be pushed to `lib/core` | — |
| **D4** | No DI container | Three services and two composition points do not justify a container or a dependency | Wiring is explicit and manual (`AppDependencies`) | Service count or optionality grows enough to need scopes |
| **D5** | No state-management library | Flows are linear; 95 `setState` calls across 23 widgets at 14k LoC are not a problem | Screens are not independently unit-testable; state cannot be shared by non-adjacent screens | A flow needs state shared by non-adjacent screens, or a screen's logic outgrows its layout |
| **D6** | Isolate boundary as the concurrency seam | Argon2 and secretstream must not block the UI; a message protocol keeps the main isolate responsive and swappable | No shared objects, so the worker must build its own adapters (hence A3) | — |
| **D7** | Best-effort `catch` is allowed, silently swallowing is not | Cleanup (deleting a temp, reading optional package info) must not mask the primary error | 7 empty catches must each carry a comment explaining why the failure is irrelevant | Any empty catch without a reason |
| **D8** | Freeze by version bump | Compatibility with already-written containers | No in-place format evolution | — |
| **D9** | No repositories / no codegen | No persistence layer, and generated code slows the per-package CI | Slightly more verbose route payloads and models | Persistence or many serialized models appear |

**Explicitly rejected options** (recorded so they are not re-proposed without new evidence): a per-feature `data/domain/presentation` split (would roughly double file count to protect a 14k-LoC app from changes it does not have); Bloc/Riverpod/get_it (indirection without a demonstrated need); micro-packages per port (five packages with one class each would multiply CI without adding a boundary).

---

## 4. How this is enforced

1. **Machine-checked (A1, A3, A4, A5, A6-partial, A9).** `test/architecture_test.dart` at the repo root reads the tree and fails on a violating import, plus the existing freeze guards. It runs in the root `flutter test` job that `ci.yml` already executes — no new workflow.
2. **Machine-assisted (A6).** The same test rejects new `extra: {` literals once the flows migrate to typed payloads; the allowlist for `package:sodium` becomes an exact two-file set.
3. **Review-enforced (A2, A7, A8).** A reviewer may cite the law ID in a comment. These are judgment calls about where logic belongs; a grep cannot distinguish a legitimate port wrapper from a bypass.
4. **Amendment process.** To change a law: open a spec under `specs/`, state the new evidence, update this file in the same change, and add or update the enforcing test. A law that is not enforced by at least one of the mechanisms above is a suggestion, not a law.

---

## 5. Relationship to other documents

- `CLAUDE.md` — the operating guide for agents; references this file for architectural questions.
- `docs/FORMAT.md` — normative wire format (A9).
- `specs/005-architecture-enforcement/` — the task list that brings the code into full compliance with A2, A3, A6, A7 and A8.
- `docs/RELEASE_READINESS.md` — accessibility, performance and store compliance (orthogonal to these laws).

Last updated: 2026-11-02
