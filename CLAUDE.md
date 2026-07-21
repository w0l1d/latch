# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> A detailed `AGENTS.md` already lives at the repo root. It is the source of truth for the `.latch` format freeze, testing gotchas, and the `sodium` native-assets flow — read it before non-trivial work. This file focuses on the runtime architecture and control flow that require reading several files to reconstruct, so you don't have to re-explore each session.

## What this is

Latch is an offline, stateless file-encryption Flutter app. It encrypts arbitrary files into `.latch` containers and decrypts them back — no server, no account, no recovery path. **Forgotten passphrase = unrecoverable, by design; never add "recovery" features.**

## Repository = three packages

Hexagonal architecture split across three independently-analyzed/tested packages (CI runs each separately — there is no single command for all three):

- **`packages/myenc_core/`** — pure Dart, **no Flutter, no `dart:io`**. The auditable heart: `.latch` codec (`format/myenc_codec.dart`, `format/file_header.dart`), envelope service (`domain/envelope_service.dart`), DEK wrapping (`domain/dek_wrap.dart`), KDF params, typed errors (`format/myenc_errors.dart`), and the **ports** (`ports/crypto_port.dart`, `ports/file_io_port.dart`, `ports/secure_storage_port.dart`). If you find yourself importing Flutter or `dart:io` here, you are in the wrong package.
- **`packages/myenc_adapters/`** — concrete port implementations: `SodiumCryptoAdapter` (libsodium via the `sodium` package) and `FileIoDart` (streaming `dart:io` file I/O). Depends on Flutter + `myenc_core`.
- **`/` (repo root)** — the Flutter app. `lib/main.dart` boots `AppCrypto`, wires services, runs `LatchApp`.

`myenc_*` are **path dependencies** of the app — editing them changes the app build with no version bump.

## Commands

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

- Flutter pinned to **3.44.2** in CI; `sdk: ^3.12.2`.
- Do **not** `apt install libsodium` or set `LD_LIBRARY_PATH` — `sodium` 4.x ships libsodium via Dart native assets and `flutter test` bundles it automatically. (Golden-vector regeneration in `tool/gen_golden_vectors.py` is the exception: it loads a *system* libsodium via `ctypes`.)

## Crypto runs in a background isolate

All heavy crypto (Argon2id KDF, secretstream) runs in a spawned isolate so the UI never blocks. This is the single most important control-flow fact in the codebase.

- **`lib/core/app_crypto.dart`** — main-isolate façade. Static entry points: `encryptFiles`, `decryptFiles`, `changePassphraseFiles` (rewrap), `addRecipientFiles`, `secureDeleteFiles` (shred), `generateShareKeypair`. Each builds a task map and calls `_runBatch`, which spawns `latchWorker`, streams progress `0.0→1.0`, and delivers per-file outcomes via an `onFileResult` callback (`BatchResult`: `path`, `ok`, `errorMessage`, `outPath`).
- **`lib/core/isolate_worker.dart`** — the worker. `latchWorker` receives a task map keyed by `cmd` (`encrypt` / `decrypt` / `rewrap` / `add_recipient` / `shred` / `keygen`) and dispatches to `_encryptBatch` / `_decryptBatch` / etc.

**Worker→main message protocol** (matched in `AppCrypto._runBatch`): `file_start` (carries the `outPath` about to be written), `progress` (`pct`), `file_done` (`path`, `ok`, `error`, `outPath`), `error` (typed `code` + `message`), `done`.

Robustness invariants — preserve these when touching the isolate plumbing:
- The worker's `onExit` and `onError` ports feed the **same** `ReceivePort`, so a worker killed under memory pressure surfaces as a stream error instead of hanging the caller forever (a `null` message = exited early; a `List` message = uncaught error).
- On teardown before `done`, `_runBatch` kills the isolate immediately and sweeps the in-flight `<outPath>.tmp`. For decrypt that temp holds **partial plaintext**, so this cleanup is a security property, not just tidiness.
- Progress screens depend on the "last per-file result arrives before the final `1.0`" ordering. This is pinned by `test/app_crypto_batch_test.dart` (plain `test()`, real isolate) because `testWidgets` runs under a fake clock and cannot reliably drive a real isolate — see AGENTS.md "Testing gotchas".

## Output path resolution — where encrypted/decrypted files land

Goal: outputs land in the **source file's own folder**. The mechanism differs by platform because Android scoped storage (API ≥ 30) forbids the crypto worker (plain `dart:io`) from writing anywhere but app-private storage and public Downloads, and the single-file picker only grants the *picked document*, not its folder. The design lives in **`lib/core/output_plan.dart`** (`OutputPlanner.plan` + `relocateStagedOutputs`) — read it before changing output behavior.

**Desktop / iOS (unchanged):** `OutputPlanner.plan` returns `stagingDir == null`; the worker writes the final file directly via `resolveOutputPath`/`resolveNameCollision` in `file_io_dart.dart` (encrypt name `<source>.latch`, decrypt strips `.latch`). `outputDir` = the user-picked dir, else `DefaultOutput.directoryFor` (`lib/core/default_output.dart`: `null`/beside-original on desktop, app-documents on iOS). Relocation is a no-op.

**Android (SAF folder grant):**
1. **Stage:** `plan` sets `stagingDir`/`outputDir` to an app-cache dir, so the worker writes into always-writable private storage (decrypt plaintext never transits Downloads).
2. **Grant:** per distinct source folder (resolved via `SafBridge.realDirectoryFor` → `content://` URI), reuse a cached grant or prompt via `promptSaveFolder` → `SafBridge.pickTree` (`ACTION_OPEN_DOCUMENT_TREE`, persisted, seeded at the source folder). A user-picked "choose folder" in encrypt options supplies one `explicitTreeUri` for all files.
3. **Relocate (main isolate, post-batch):** `relocateStagedOutputs` moves each staged file into its granted tree via `SafBridge.createInTree` (native `DocumentsContract.createDocument`, collision handling mirrors `resolveNameCollision`), deleting the cache temp. **No grant / cloud source / write failure → move to Downloads and flag `fellBackToDownloads`**, surfaced as a banner on the success screens.

The native side (`android/.../MainActivity.kt`, `latch/saf` channel) implements `openTree`, `treeUriToPath`, `createInTree`; grants persist across restarts (`takePersistableUriPermission` + a SharedPreferences `folderPath→treeUri` map seeded by `SafBridge.loadTreeGrants()` in `main.dart`). No `MANAGE_EXTERNAL_STORAGE` — Play-compliant. This reuses the existing "worker stages, main isolate does SAF I/O afterward" pattern (see `_writeBackOriginals`), since the isolate has no platform channels.

## UI / navigation

- **`lib/core/router.dart`** — go_router routes. Flows: onboarding (`lib/features/onboarding/`), `home`, encrypt (`pick → passphrase → options → review → progress → success`), decrypt (`pick → passphrase → progress → success`), settings (`lib/features/settings/`: change passphrase, sharing keys / recipients, secure delete, passphrase storage).
- Screens pass data forward via go_router `extra` maps.
- Shared UI in `lib/shared/` (`theme/app_theme.dart` = `LatchColors`, `widgets/`, `error_messages.dart` = `userMessageForError` for translating raw error strings to human copy).

## App-layer services (`lib/core/`)

- `passphrase_storage_service.dart`, `device_key_service.dart`, `recipient_key_service.dart` — secure-storage-backed services set on `AppCrypto` static fields by `main()` after the tree mounts (platform channels must be live). Decrypt tries hardware-key wraps (device-bound recovery) and X25519 recipient wraps as fallbacks when the passphrase wrap fails.
- `saf_bridge.dart` — Android Storage Access Framework bridge (content:// → real path).
- `incoming_file_service.dart` — files shared *into* the app (`receive_sharing_intent`).
- `crypto_stub.dart` — pure heuristic passphrase strength (no real crypto).

## Non-negotiable constraints

- **The `.latch` v1 wire format is FROZEN.** Do not change any byte. Two freeze guards exist (`packages/myenc_core/test/codec_freeze_test.dart` and the `packages/myenc_adapters/test/golden/` vectors) and neither is editable to make a test pass. To extend the format, bump the version byte; readers must fail closed on unknown versions. See `docs/FORMAT.md` (normative) and AGENTS.md.
- **Wrong-passphrase vs corrupt-file distinction:** a wrong passphrase fails fast at the DEK wrap *before* the body is touched; a corrupt/tampered file fails at a chunk tag and never emits partial plaintext. Preserve both when editing crypto code.
- **Commits:** Conventional Commits with a scope (`feat(core):`, `fix(app):`, `build(android):`, `docs:`, plus scopeless `fix:`/`docs:`). **No Claude / Co-Authored-By attribution** in commits, files, or any output (repo owner convention).

## Docs worth reading before deeper work

- `AGENTS.md` — format freeze, testing gotchas, sodium/native-assets specifics.
- `project_spec.md` — full design spec, threat model, roadmap (§11); use-cases referenced in code as UC-N.
- `docs/FORMAT.md` — normative frozen `.latch` v1 layout.
- `docs/RELEASE_READINESS.md`, `ios_build_notes.md`.
