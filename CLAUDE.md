# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> This is the single source of truth for agents. `AGENTS.md` at the repo root is a symlink to this file.

## What this is

Latch is an offline, stateless file-encryption Flutter app. It encrypts arbitrary files into `.latch` containers and decrypts them back — no server, no account, no recovery path. **Forgotten passphrase = unrecoverable, by design; never add "recovery" features.**

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
```

- Flutter pinned to **3.44.2** in CI (`.github/workflows/`); `sdk: ^3.12.2`.
- Local analyze config is `analysis_options.yaml` (includes `package:flutter_lints/flutter.yaml`).
- **CI (`ci.yml`) fails on unformatted code** (`dart format --set-exit-if-changed`) before analyze/test. Run `dart format .` before committing, or enable the local hooks: `./tool/setup-hooks.sh` (pre-commit = format check, pre-push = full format+analyze+test mirror; `.githooks/`, wired via `core.hooksPath`).
- **Releases are tag-driven, not push-driven** (`release.yml`): a plain push to `main` never releases. Cut one via the Release workflow's `workflow_dispatch` (bump `patch`/`minor`/`major`) or by pushing a `v*.*.*-*` tag; the version comes from the tag via `flutter build --build-name/--build-number`, so `pubspec.yaml` is never bumped/committed by CI.
- Do **not** `apt install libsodium` or set `LD_LIBRARY_PATH` — `sodium` 4.x ships libsodium via Dart native assets and `flutter test` bundles it automatically. (Golden-vector regeneration in `tool/gen_golden_vectors.py` is the exception: it loads a *system* libsodium via `ctypes`.)

## Crypto runs in a background isolate

All heavy crypto (Argon2id KDF, secretstream) runs in a spawned isolate so the UI never blocks. This is the single most important control-flow fact in the codebase.

- **`lib/core/app_crypto.dart`** — main-isolate façade. Static entry points: `encryptFiles`, `decryptFiles`, `changePassphraseFiles` (rewrap), `addRecipientFiles`, `secureDeleteFiles` (shred), `generateShareKeypair`. Each builds a task map and calls `_runBatch`, which spawns `latchWorker`, streams progress `0.0→1.0`, and delivers per-file outcomes via an `onFileResult` callback (`BatchResult`: `path`, `ok`, `errorMessage`, `outPath`).
- **`lib/core/isolate_worker.dart`** — the worker. `latchWorker` receives a task map keyed by `cmd` (`encrypt` / `decrypt` / `rewrap` / `add_recipient` / `shred` / `keygen`) and dispatches to `_encryptBatch` / `_decryptBatch` / etc.

**Worker→main message protocol** (matched in `AppCrypto._runBatch`): `file_start` (carries the `outPath` about to be written), `progress` (`pct`), `file_done` (`path`, `ok`, `error`, `outPath`), `error` (typed `code` + `message`), `done`.

Robustness invariants — preserve these when touching the isolate plumbing:
- The worker's `onExit` and `onError` ports feed the **same** `ReceivePort`, so a worker killed under memory pressure surfaces as a stream error instead of hanging the caller forever (a `null` message = exited early; a `List` message = uncaught error).
- On teardown before `done`, `_runBatch` kills the isolate immediately and sweeps the in-flight `<outPath>.tmp`. For decrypt that temp holds **partial plaintext**, so this cleanup is a security property, not just tidiness.
- Progress screens depend on the "last per-file result arrives before the final `1.0`" ordering. This is pinned by `test/app_crypto_batch_test.dart` (plain `test()`, real isolate) because `testWidgets` runs under a fake clock and cannot reliably drive a real isolate — see "Testing gotchas" below.

## Output path resolution — where encrypted/decrypted files land

Goal: outputs land in the **source file's own folder**. The mechanism differs by platform because Android scoped storage (API ≥ 30) forbids the crypto worker (plain `dart:io`) from writing anywhere but app-private storage and public Downloads, and the single-file picker only grants the *picked document*, not its folder. The design lives in **`lib/core/output_plan.dart`** (`OutputPlanner.plan` + `relocateStagedOutputs`) — read it before changing output behavior.

**Desktop / iOS (unchanged):** `OutputPlanner.plan` returns `stagingDir == null`; the worker writes the final file directly via `resolveOutputPath`/`resolveNameCollision` in `file_io_dart.dart` (encrypt name `<source>.latch`, decrypt strips `.latch`). `outputDir` = the user-picked dir, else `DefaultOutput.directoryFor` (`lib/core/default_output.dart`: `null`/beside-original on desktop, app-documents on iOS). Relocation is a no-op.

**Android (SAF folder grant):**
1. **Stage:** `plan` sets `stagingDir`/`outputDir` to an app-cache dir, so the worker writes into always-writable private storage (decrypt plaintext never transits Downloads).
2. **Grant:** per distinct source folder (resolved via `SafBridge.realDirectoryFor` → `content://` URI, which falls back to the provider's `_data` column for Downloads `msf:` / MediaStore documents). `OutputPlanner._grantFor` asks in this order — (a) the app's own prefs cache for exactly that folder, (b) `SafBridge.existingTreeGrantFor` = any grant Android still holds covering the folder *or an ancestor of it* (deepest wins; the returned `subPath` addresses the nested folder inside the grant), (c) only then prompt via `promptSaveFolder` → `SafBridge.pickTree` (`ACTION_OPEN_DOCUMENT_TREE`, persisted, seeded at the source folder). After the picker returns, the grant is re-resolved through (b), so a user who picks a *parent* of the requested folder still gets output in the source folder. A source whose folder can't be resolved at all prompts once per batch with a null folder — never a silent Downloads fallback. A user-picked "choose folder" in encrypt options supplies one `explicitTreeUri` for all files and skips this entirely.
3. **Relocate (main isolate, post-batch):** `relocateStagedOutputs` moves each staged file into its granted tree via `SafBridge.createInTree` (native `DocumentsContract.createDocument` on the tree root, or on the `subPath` folder nested inside the grant; collision handling mirrors `resolveNameCollision`), deleting the cache temp. **No grant / cloud source / write failure → move to Downloads and flag `fellBackToDownloads`**, surfaced as a banner on the success screens.

The native side (`android/.../MainActivity.kt`, `latch/saf` channel) implements `openTree`, `treeUriToPath`, `existingTreeGrant`, `createInTree`; grants persist across restarts (`takePersistableUriPermission` + a SharedPreferences `folderPath→treeUri` map seeded by `SafBridge.loadTreeGrants()` in `main.dart`). No `MANAGE_EXTERNAL_STORAGE` — Play-compliant. This reuses the existing "worker stages, main isolate does SAF I/O afterward" pattern (see `_writeBackOriginals`), since the isolate has no platform channels.

## UI / navigation

- **`lib/core/router.dart`** — go_router routes. Flows: onboarding (`lib/features/onboarding/`), `home`, encrypt (`pick → passphrase → options → review → progress → success`), decrypt (`pick → passphrase → progress → success`), settings (`lib/features/settings/`: change passphrase, sharing keys / recipients, secure delete, passphrase storage).
- Screens pass data forward via go_router `extra` maps.
- Shared UI in `lib/shared/` (`theme/app_theme.dart` = `LatchColors`, `widgets/`, `error_messages.dart` = `userMessageForError` for translating raw error strings to human copy).

## App-layer services (`lib/core/`)

- `passphrase_storage_service.dart`, `device_key_service.dart`, `recipient_key_service.dart` — secure-storage-backed services set on `AppCrypto` static fields by `main()` after the tree mounts (platform channels must be live). Decrypt tries hardware-key wraps (device-bound recovery) and X25519 recipient wraps as fallbacks when the passphrase wrap fails.
- `saf_bridge.dart` — Android Storage Access Framework bridge (content:// → real path, tree grants).
- `incoming_file_service.dart` — files shared *into* the app (`receive_sharing_intent`).
- `crypto_stub.dart` — pure heuristic passphrase strength (no real crypto).

## Testing gotchas (FakeAsync vs isolates)

`testWidgets` runs under a fake clock. Anything needing the **real** Dart event loop hangs inside it and leaves a dangling ReceivePort that hangs teardown:

- Spawning the crypto worker isolate (`AppCrypto.*Files().listen()`, i.e. the encrypt/decrypt **progress** screens) is not reliably drivable from `flutter test`. Crypto completion + the "last result before final 1.0" invariant the progress screens depend on are pinned instead by `test/app_crypto_batch_test.dart` (plain `test()`, real event loop, real isolate).
- `await Directory.delete(recursive:)` and other real async file I/O in a `testWidgets` body also hang. Use the **sync** variants in widget tests: `Directory.systemTemp.createTempSync(...)`, `file.deleteSync(...)`.
- In a `testWidgets`, do real-async/isolate work inside `tester.runAsync(() async {...})` so it runs on the real loop, then `pumpAndSettle()` for the resulting setState/navigation. See `test/e2e_flow_test.dart` (which drives every button/navigation screen but the progress screens).

Importing a transitive platform interface (`*_platform_interface`) in tests is normal here; add it to root `dev_dependencies` to satisfy `depend_on_referenced_packages`.

## The `.latch` format is FROZEN (v1)

**Do not change any byte of the v1 wire layout.** `docs/FORMAT.md` is normative and frozen since 2026-07-12. If a test that pins the layout fails, the layout changed — that is a bug to *revert*, not a test to "fix".

Two freeze guards, neither editable to make a test pass:

- `packages/myenc_core/test/codec_freeze_test.dart` — pins the header byte layout against an independent Python-derived hex string.
- `packages/myenc_adapters/test/golden/` (`golden_v1.latch` + `golden_v1.json` + `golden_kdf.json`) + `golden_vectors_test.dart` — end-to-end vectors produced by an **independent** reference implementation (`tool/gen_golden_vectors.py`, using `argon2-cffi` + libsodium via `ctypes`, never the Dart code).

To legitimately extend the format, **bump the version byte**; readers must fail closed on unknown versions.

## `sodium` package / native libs

- `sodium` 4.x ships libsodium via **Dart native assets**. `flutter test` builds/bundles it automatically — do **not** `apt install libsodium` or set `LD_LIBRARY_PATH`; that breaks the native-assets flow (CI comment is explicit about this).
- Regenerating golden vectors (`tool/gen_golden_vectors.py`) is the opposite case: it loads a system libsodium via `ctypes` from `/opt/homebrew/lib`, `/usr/local/lib`, or `anaconda3/lib`. Needs `argon2-cffi` installed. Regeneration produces a fresh self-consistent `.latch`+`.json` pair (secretstream header nonce is random); commit the pair together. Only regenerate when intentionally updating the fixture — the committed pair must keep decrypting.

## Non-negotiable constraints & conventions

- **Wrong-passphrase vs corrupt-file distinction:** a wrong passphrase fails fast at the DEK wrap *before* the body is touched; a corrupt/tampered file fails at a chunk tag and never emits partial plaintext. Preserve both when editing crypto code.
- **Forgotten passphrase = unrecoverable, by design.** There is no server and no recovery path. Don't add "recovery" features.
- **Commits:** Conventional Commits with a scope, e.g. `feat(core):`, `feat(app):`, `fix(app):`, `build(android):`, `docs:`, `docs+test:`. Scopes in use: `app`, `core`, `encrypt`, `android`, plus scopeless `fix:`/`docs:`. Em-dash `—` is used in bodies. **No Claude / Co-Authored-By attribution** in commits, files, or any output (repo owner convention).

## Things to leave alone

- `bugreport-*.zip` at root is a captured Android bug report, not source.
- `build/`, `*/build/`, `.dart_tool/`, `.idea/` artifacts — ignore.
- `packages/myenc_core` must stay free of Flutter and `dart:io` imports. If you find yourself importing either there, you're in the wrong package.

## Docs worth reading before non-trivial work

- `project_spec.md` — full design spec, threat model, roadmap (§11); use-cases referenced in code as UC-N.
- `docs/FORMAT.md` — normative frozen `.latch` v1 layout.
- `docs/RELEASE_READINESS.md` — accessibility / performance / store-compliance audit.
- `ios_build_notes.md` — iOS not yet built; `file_picker` plist keys, pod install, signing notes.
