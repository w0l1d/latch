# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **This file is loaded into every session — keep it lean.** Deep detail lives in
> `docs/agents/*.md` and is read on demand through the router below. Add a fact there,
> not here, unless it must be known *before* any action.
> `AGENTS.md` is a symlink to this file.

Latch is an offline, stateless file-encryption Flutter app: encrypt any file into a self-contained `.latch` container and decrypt it back. No server, no account, no recovery path. **Forgotten passphrase = unrecoverable, by design; never add "recovery" features.**

## Project map

| Path | What lives there |
|---|---|
| `lib/core/` | App-layer services + orchestration: isolate façade, worker, output planning, SAF bridge, router, build info |
| `lib/features/` | Screens by flow: `onboarding`, `home`, `encrypt`, `decrypt`, `settings` |
| `lib/shared/` | `theme/app_theme.dart` (`LatchColors`), `widgets/`, `error_messages.dart` (`userMessageForError`) |
| `packages/myenc_core/` | Pure Dart: `.latch` codec, envelope service, DEK wrap, KDF params, typed errors, **ports** |
| `packages/myenc_adapters/` | Port implementations: `SodiumCryptoAdapter`, `FileIoDart` |
| `android/` | Kotlin SAF bridge (`MainActivity.kt`, `ExternalStorageDocIds.kt`, `DocumentPathResolver.kt`) + JVM tests |
| `test/` | Dart tests: freeze guards, real-isolate batches, output/SAF planners, widget flows |
| `e2e/`, `integration_test/` | Maestro UI flows and the on-device pipeline test |
| `docs/` | Normative docs (`ARCHITECTURE.md`, `FORMAT.md`), platform notes, `agents/` deep notes |
| `specs/` | Feature specs + task lists (`001`–`005`) |
| `tool/` | Golden-vector generators, git-hook setup |

## Repository = three packages

Hexagonal architecture split across three independently-analyzed/tested packages (CI runs each separately — there is no single command for all three):

- **`packages/myenc_core/`** — pure Dart, **no Flutter, no `dart:io`**. The auditable heart: `.latch` codec (`format/myenc_codec.dart`, `format/file_header.dart`), envelope service (`domain/envelope_service.dart`), DEK wrapping (`domain/dek_wrap.dart`), KDF params, typed errors (`format/myenc_errors.dart`), and the **ports** (`ports/crypto_port.dart`, `ports/file_io_port.dart`, `ports/secure_storage_port.dart`). If you find yourself importing Flutter or `dart:io` here, you are in the wrong package.
- **`packages/myenc_adapters/`** — concrete port implementations: `SodiumCryptoAdapter` (libsodium via the `sodium` package) and `FileIoDart` (streaming `dart:io` file I/O). Depends on Flutter + `myenc_core`.
- **`/` (repo root)** — the Flutter app (`lib/`, `test/`, `android/`, `ios/`). `lib/main.dart` boots `AppCrypto`, wires services, runs `LatchApp`.

`myenc_*` are **path dependencies** of the app — editing them changes the app build with no version bump.

## Commands

The repo is three packages that must each be analyzed and tested independently — exactly what CI does. There is no single command that runs all three.

```sh
flutter pub get                       # at root first; resolves path-deps too
flutter analyze --no-pub              # app (root)
flutter test                          # app (root)

# per package — run inside the package dir:
cd packages/myenc_core     && flutter test && flutter analyze --no-pub
cd packages/myenc_adapters && flutter test && flutter analyze --no-pub

flutter test test/foo_test.dart           # single file
flutter test --plain-name "expr"          # single test by name

# native Android helpers (JVM unit tests, no device/emulator):
cd android && ./gradlew :app:testDebugUnitTest
```

- Flutter pinned to **3.44.2** in CI (`.github/workflows/`); `sdk: ^3.12.2`. `dart format .` before committing — CI fails on unformatted code (`./tool/setup-hooks.sh` installs local mirrors).
- **One `analysis_options.yaml` per package, not one for the repo.** Root and `myenc_adapters` include `package:flutter_lints/flutter.yaml`; `myenc_core` includes `package:lints/recommended.yaml` (same set minus the Flutter-only rules, which is why it can stay Flutter-free). Each package must carry its own — the analyzer finds the *nearest* options file but resolves `package:` includes against the *nearest package config*, so a package relying on the root file silently gets **no lint rules** while `dart format .` warns once per file. Keep the lint dep (`lints` / `flutter_lints`) in the package's own `dev_dependencies`.
- **Do not `apt install libsodium`** or set `LD_LIBRARY_PATH` — `sodium` 4.x ships libsodium via Dart native assets and `flutter test` bundles it automatically. (`tool/gen_golden_vectors.py` is the exception: it loads a *system* libsodium via `ctypes`.)
- CI gates both `main` and `develop`; releases are tag-driven; test APKs come from `dev_build.yml`. See `docs/agents/builds-ci-and-provenance.md` before touching workflows or versions.

## Crypto runs in a background isolate

All heavy crypto (Argon2id KDF, secretstream) runs in a spawned isolate so the UI never blocks. This is the single most important control-flow fact in the codebase.

- **`lib/core/app_crypto.dart`** — main-isolate façade. Static entry points: `encryptFiles`, `decryptFiles`, `changePassphraseFiles` (rewrap), `addRecipientFiles`, `secureDeleteFiles` (shred), `generateShareKeypair`. Each builds a task map and calls `_runBatch`, which spawns `latchWorker`, streams progress `0.0→1.0`, and delivers per-file outcomes via an `onFileResult` callback (`BatchResult`: `path`, `ok`, `errorMessage`, `outPath`).
- **`lib/core/isolate_worker.dart`** — the worker. `latchWorker` receives a task map keyed by `cmd` (`encrypt` / `decrypt` / `rewrap` / `add_recipient` / `shred` / `keygen`) and dispatches to `_encryptBatch` / `_decryptBatch` / etc.

**Worker→main message protocol** (matched in `AppCrypto._runBatch`): `file_start` (carries the `outPath` about to be written), `progress` (`pct`), `file_done` (`path`, `ok`, `error`, `outPath`), `error` (typed `code` + `message`), `done`.

Robustness invariants — preserve these when touching the isolate plumbing:
- The worker's `onExit` and `onError` ports feed the **same** `ReceivePort`, so a worker killed under memory pressure surfaces as a stream error instead of hanging the caller forever (a `null` message = exited early; a `List` message = uncaught error).
- On teardown before `done`, `_runBatch` kills the isolate immediately and sweeps the in-flight `<outPath>.tmp`. For decrypt that temp holds **partial plaintext**, so this cleanup is a security property, not just tidiness.
- Progress screens depend on the "last per-file result arrives before the final `1.0`" ordering. This is pinned by `test/app_crypto_batch_test.dart` (plain `test()`, real isolate) because `testWidgets` runs under a fake clock and cannot reliably drive a real isolate — see `docs/agents/testing.md`.

Services (`passphrase_storage_service.dart`, `device_key_service.dart`, `recipient_key_service.dart`) are set on `AppCrypto` static fields by `main()` **after** the tree mounts, because platform channels must be live. Decrypt tries hardware-key wraps (device-bound recovery) and X25519 recipient wraps as fallbacks when the passphrase wrap fails.

## The `.latch` format is FROZEN (v1)

**Do not change any byte of the v1 wire layout.** `docs/FORMAT.md` is normative and frozen since 2026-07-12. If a test that pins the layout fails, the layout changed — that is a bug to *revert*, not a test to "fix".

Two freeze guards, neither editable to make a test pass:

- `packages/myenc_core/test/codec_freeze_test.dart` — pins the header byte layout against an independent Python-derived hex string.
- `packages/myenc_adapters/test/golden/` (`golden_v1.latch` + `golden_v1.json` + `golden_kdf.json`) + `golden_vectors_test.dart` — end-to-end vectors produced by an **independent** reference implementation (`tool/gen_golden_vectors.py`, using `argon2-cffi` + libsodium via `ctypes`, never the Dart code).

To legitimately extend the format, **bump the version byte**; readers must fail closed on unknown versions.

## Non-negotiable constraints

- **Wrong-passphrase vs corrupt-file distinction:** a wrong passphrase fails fast at the DEK wrap *before* the body is touched; a corrupt/tampered file fails at a chunk tag and never emits partial plaintext. Preserve both when editing crypto code.
- **Commits:** Conventional Commits with a scope, e.g. `feat(core):`, `feat(app):`, `fix(app):`, `build(android):`, `docs:`, `docs+test:`. Scopes in use: `app`, `core`, `encrypt`, `android`, plus scopeless `fix:`/`docs:`. Em-dash `—` is used in bodies. **No Claude / Co-Authored-By attribution** in commits, files, or any output (repo owner convention).

## Where to read next — load only what the task needs

| If the task touches… | Read first |
|---|---|
| Output location, SAF, file pickers, Downloads, tree grants, Settings → Save folders, Android storage Kotlin | `docs/agents/android-storage-and-output-paths.md`, then `docs/ANDROID_PLATFORM_NOTES.md` for platform limits |
| Bulk folder flows, `BulkPlan`, shared KEK, verified delete, placement | `docs/agents/bulk-encryption.md` |
| Workflows, dev APK, release/versioning, `lib/core/build_info.dart` | `docs/agents/builds-ci-and-provenance.md` |
| Writing widget/isolate tests, or a `FakeAsync` hang | `docs/agents/testing.md` |
| Changing more than one file, or where logic belongs | `docs/ARCHITECTURE.md` (laws **A1–A9**; cite the law ID), backlog in `specs/005-architecture-enforcement/tasks.md` |
| Any byte of the container layout | `docs/FORMAT.md` (normative, frozen) |
| A feature's requirements | `specs/<feature>/spec.md` |
| Accessibility, performance, store compliance | `docs/RELEASE_READINESS.md` |
| Threat model, use-cases (`UC-N`), roadmap | `project_spec.md` |
| iOS build, pods, signing | `ios_build_notes.md` |
| Maestro UI flows | `e2e/README.md` |

## Things to leave alone

- `bugreport-*.zip` at root is a captured Android bug report, not source.
- `build/`, `*/build/`, `.dart_tool/`, `.idea/` artifacts — ignore.

## graphify

This project has a knowledge graph at `graphify-out/` with god nodes, community structure, and cross-file relationships.

- When `graphify-out/graph.json` exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than `GRAPH_REPORT.md` or raw grep output.
- If `graphify-out/wiki/index.md` exists, use it for broad navigation instead of raw source browsing.
- Read `graphify-out/GRAPH_REPORT.md` only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed `graphify-out/graph.json` is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.
