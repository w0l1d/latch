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

# native Android helpers (JVM unit tests, no device/emulator):
cd android && ./gradlew :app:testDebugUnitTest
```

- Flutter pinned to **3.44.2** in CI (`.github/workflows/`); `sdk: ^3.12.2`.
- **One `analysis_options.yaml` per package, not one for the repo.** Root and `myenc_adapters` include `package:flutter_lints/flutter.yaml`; `myenc_core` includes `package:lints/recommended.yaml` (same set minus the Flutter-only rules, which is why it can stay Flutter-free). Each package must carry its own — the analyzer finds the *nearest* options file but resolves `package:` includes against the *nearest package config*, so a package relying on the root file silently gets **no lint rules** while `dart format .` warns once per file. Keep the lint dep (`lints` / `flutter_lints`) in the package's own `dev_dependencies`.
- **CI (`ci.yml`) gates both `main` and `develop`** — push and PR. Work PRs into `develop`, so gating `main` alone would leave every feature/fix PR with no checks. Two jobs: `analyze-and-test` (format → analyze → test, all three packages) and `android-unit-test` (`:app:testDebugUnitTest`, the Kotlin SAF unit tests the Dart suites can't reach). `dependency_audit.yml` is schedule/`workflow_dispatch` only and therefore branch-agnostic.
- **CI (`ci.yml`) fails on unformatted code** (`dart format --set-exit-if-changed`) before analyze/test. Run `dart format .` before committing, or enable the local hooks: `./tool/setup-hooks.sh` (pre-commit = format check, pre-push = full format+analyze+test mirror; `.githooks/`, wired via `core.hooksPath`).
- **Releases are tag-driven, not push-driven** (`release.yml`): a plain push to `main` never releases. Cut one via the Release workflow's `workflow_dispatch` (bump `patch`/`minor`/`major`) or by pushing a `v*.*.*-*` tag; the version comes from the tag via `flutter build --build-name/--build-number`, so `pubspec.yaml` is never bumped/committed by CI.
- **Test APKs come from `dev_build.yml`, not from cutting a release** — that is the point of it existing: every "can you try this build" used to mean a version bump and a published release, until the release history was mostly dev iterations. Triggers on push to `develop` and on `workflow_dispatch` for any branch (with an optional "what to test" note). It re-runs `ci.yml`'s gates itself rather than depending on them (a dispatch on an arbitrary branch may have no CI run), builds `--release --split-per-abi --target-platform android-arm64` (same ~50MB Telegram cap that shaped `release.yml`), versions the APK `<pubspec base>-dev.<short sha>` with the run number as the build number — **no `pubspec.yaml` bump, no tag, no GitHub release** — and posts it to the Telegram dev topic (thread `53`, vs releases' `54`) with a caption that says outright it is not a release. Over the cap it attaches the APK to the workflow run instead of failing.
  - **The dev APK is a separate install**: `-PdevBuild=true` (via `flutter build apk --android-project-arg devBuild=true`) moves `applicationId` to `com.latch.latch.dev` and the launcher label to "Latch dev", so a test build sits beside a release instead of replacing it — no uninstall, no wiped passphrase vault, and its SAF grants and prefs are its own. Both are one `if` in `android/app/build.gradle.kts` plus the `${appLabel}` placeholder in the manifest, **inert without the property** so release builds are untouched; the workflow re-reads the built APK with `aapt dump badging` and fails if the package isn't the `.dev` one, because nothing else would catch a dev build quietly overwriting the release it is being compared against.
- **Every built APK carries its own provenance** (`lib/core/build_info.dart`): both workflows inject `LATCH_BUILD_TAG` / `LATCH_BUILD_SHA` / `LATCH_BUILD_CHANNEL` via `--dart-define`, and Settings → About shows a tap-to-copy **Build** row. `package_info_plus` alone is not enough — `--build-name` carries only the tag's semver, so `v1.0.6-2026.09.08.1` and `v1.0.6-2026.07.20.1` both install as `1.0.6+1`, and the SHA never reaches the app at all. **`String.fromEnvironment` must stay in a const context** (hence `static const` fields, never getters): read non-const, or with the define dropped from the build line, it silently returns its default and a shipped APK reports "local build" — the exact failure the row exists to prevent, and invisible in a build log. `dev_build.yml` therefore greps the tag out of the APK's `libapp.so` (not the whole APK — the tag is also the manifest's `versionName`, so a wider grep would pass with the defines gone). The `local` default is deliberate: an un-injected build under-claims rather than asserting a provenance it lacks.
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
2. **Grant:** per distinct source folder (resolved via `SafBridge.realDirectoryFor` → native `resolvePath`, which derives the path from the document's own metadata — path-shaped externalstorage docIds; MediaStore `RELATIVE_PATH` + `DISPLAY_NAME` for the picker's sidebar shortcuts (Downloads `msf:` ids, media `image:`/`video:`/`audio:`/`document:` ids); the document's own columns for unknown/OEM providers; `_data` only as a last resort — **never from a filesystem stat**, which scoped storage denies for non-media files on API 30+ and would send every batch to the "can't tell which folder" prompt). `OutputPlanner._grantFor` asks in this order — (a) `SafBridge.existingTreeGrantFor` = any grant Android still holds covering the folder *or an ancestor of it* (deepest wins; the returned `subPath` addresses the nested folder inside the grant), (b) only then prompt via `promptSaveFolder`, which never drops the picker on the user unexplained: a rationale dialog first names the source folder ("Save beside the originals?"), and Continue opens the permission picker — `SafBridge.pickTree` (`ACTION_OPEN_DOCUMENT_TREE`, persisted, seeded at the source folder, so granting is one tap). Backing out of either step (or a picker that fails to open, e.g. no intent handler) offers the explicit "Cancel / Use Downloads / Choose folder" choice (choosing reopens the picker, still seeded at the source folder). **Neither picker call may throw out of the prompt** — a device with no handler for the intent must still leave Downloads reachable, not abort the batch by exception. After the picker returns, the grant is re-resolved through (a), so a user who picks a *parent* of the requested folder still gets output in the source folder. A source whose folder can't be resolved at all skips the rationale and prompts once with a null folder — never a silent Downloads fallback — and the answer is remembered (see **Unresolvable sources** below) so it isn't asked every batch. Its picker is still seeded, just by the *document* rather than a path (see **Seeding the picker** below).

   **The prompt has three answers, not two** (`SaveFolderDecision` in `output_plan.dart`): a grant, an explicit "use Downloads", or `cancelled`. Downloads is a destination the user *chooses*, never one they get by declining to choose — conflating the two is what silently wrote whole batches somewhere the user never picked. A cancellation returns `OutputPlan.cancelled` and stops at the first declined prompt (a batch spanning several unfamiliar folders does not march the user through the rest of them); both progress screens then pop exactly the way their Cancel button does. Nothing is written and nothing is remembered: planning runs *before* the crypto worker, so there is no staged output to sweep, and storing a cancellation as an `UnresolvedDestination` would answer the question wrongly for every later batch. Both dialogs stay `barrierDismissible: false` and a dismissed dialog reads as cancel — the old `showDialog<bool>` completing with `null` was read as "Use Downloads". The "Choose folder" → empty-picker case re-offers the choices **once** (the picker may simply not have opened, and Downloads must stay reachable); a second empty picker is taken as the answer and cancels. A user-picked "choose folder" in encrypt options supplies one `explicitTreeUri` for all files and skips this entirely; that picker is seeded at the first source's folder too.

   **Android's persisted-permission table is the only grant record.** The app deliberately caches nothing: a remembered `folderPath→treeUri` can outlive the grant it names, and a stale entry would skip the prompt and route every later batch to Downloads with no way back. Re-asking the platform each batch is one cheap in-process call — don't reintroduce a prefs cache (pinned by ladder test `3b` in `test/output_plan_test.dart`).

   **Grants only grow unless the user gives one back.** One per distinct source folder, against a platform ceiling (`MAX_PERSISTED_URI_GRANTS`: 128, 512 from API 30) at which Android drops the *oldest* grant — a long-time user silently gets re-prompted for folders they already granted. **Settings → Save folders** (`lib/features/settings/save_folders_screen.dart`, `SafBridge.listTreeGrants` / `releaseTreeGrant`, native `listTreeGrants` / `releaseTreeGrant`) is the release valve, and doubles as the honest answer to "what does this app still have write access to". The app deliberately does **not** evict on its own terms: picking the "least useful" grant needs history it refuses to keep. The cap is a mirrored constant (`@hide`, no public accessor) shown as headroom only when within 80% of it — **nothing gates on it**, so a future AOSP change costs a slightly wrong "of 512" and nothing else. `releaseTreeGrant` returns what `persistedUriPermissions` says *after* the release, not whether the call threw: devices that refuse to release exist, and the UI must not claim a revoke that didn't happen. Like every other grant question, the list is read live on entry and after each revoke — no cache.
3. **Relocate (main isolate, post-batch):** `relocateStagedOutputs` moves each staged file into its granted tree via `SafBridge.createInTree` (native `DocumentsContract.createDocument` on the tree root, or on the `subPath` folder nested inside the grant; collision handling mirrors `resolveNameCollision`), deleting the cache temp. **No grant / cloud source / write failure → move to Downloads and flag `fellBackToDownloads`**, surfaced as a banner on the success screens.

The native side (`android/.../MainActivity.kt`, `latch/saf` channel) implements `openTree`, `treeUriToPath`, `existingTreeGrant`, `createInTree`; grants persist across restarts via `takePersistableUriPermission`, and Android's `persistedUriPermissions` is what `existingTreeGrant` reads. The picker is seeded via `EXTRA_INITIAL_URI` (see **Seeding the picker** below); some OEM pickers ignore the extra and open at root regardless. `takePersistableUriPermission` is wrapped in `runCatching` — devices exist that throw or silently fail to persist, and an exception escaping the activity-result callback would leave the parked `MethodChannel.Result` unanswered forever, hanging the batch; the grant is still live for the current process, and a grant that didn't stick simply reads as absent next batch. No `MANAGE_EXTERNAL_STORAGE` — deliberately, though not because Play forbids it: Google's "Use of All files access" policy names *Disk/Folder Encryption and Locking* as an acceptable use, so Latch could declare it behind a Permissions Declaration Form. The reasons to stay on SAF are that it is a far broader permission than the app needs, it adds review friction to every release, and the SAF design works. This reuses the existing "worker stages, main isolate does SAF I/O afterward" pattern (see `_writeBackOriginals`), since the isolate has no platform channels.

**`ExternalStorageDocIds`** (`android/.../ExternalStorageDocIds.kt`) holds the path ↔ document-id mapping (`"primary:Docs/Work"` ↔ `/storage/emulated/0/Docs/Work`) that the native call sites share: `resolvePath` (via its externalstorage branch) and `treeUriToPath` go id→path (matching a grant to a source folder), `initialTreeUri` goes path→id (seeding the picker). **The two directions must stay exact inverses** — when they drift, output silently lands in the wrong folder or the picker opens at the storage root, neither visible in a build. It is deliberately free of Android framework calls (the primary volume's mount point is a parameter) so it is unit-testable on the JVM: `android/app/src/test/kotlin/.../ExternalStorageDocIdsTest.kt`, run by the `android-unit-test` CI job or locally via `cd android && ./gradlew :app:testDebugUnitTest`.

### Seeding the picker — `EXTRA_INITIAL_URI` takes a *document* URI

`SafBridge.pickTree({initialPath, initialDocUri})` passes two candidate seeds; the native `launchOpenTree` prefers a path (via `initialTreeUri`) and falls back to the document URI. The second seed is why the previously-hopeless case works: **`EXTRA_INITIAL_URI` accepts a plain document URI and the system's document navigator resolves its parent** — *"If this URI identifies a non-directory, document navigator will attempt to use the parent of the document as the initial location"* (AOSP `DocumentsContract`). DocumentsUI is privileged and holds `MANAGE_DOCUMENTS`, so it can do the child→parent lookup this app provably cannot (see **Unresolvable sources** below). So even a source whose folder Android refuses to name opens the folder picker *at that folder* — granting is one tap instead of a hunt from the storage root.

**Seeding is best-effort by contract** (*"the initial location is system specific if this extra is missing or document navigator failed to locate the desired initial location"*), and shipping apps have disabled it as unreliable on some devices. Nothing may depend on a seed having worked: an ignored seed leaves the picker exactly where it would have opened anyway. Must be a plain document URI, never a tree URI. Pinned in `test/save_folder_prompt_test.dart`, `test/encrypt_options_screen_test.dart`, and `test/saf_bridge_test.dart`.

### Unresolvable sources — a platform limit, not a bug to fix

**There is no supported way to learn which folder an `ACTION_OPEN_DOCUMENT` pick came from.** A document URI has no parent pointer (`DocumentsContract.findDocumentPath` needs a *tree* URI; there is no `getParentDocumentUri`) — deliberate privacy design: the user shared one file, not its folder. So for the picker's sidebar shortcuts (Downloads `msf:` ids, media `image:`/`video:`/… ids) and cloud providers, `resolvePath` returning null is the **correct** answer, not a failure to engineer around. The app does not need the path to *point the picker* at the folder, though — that is what the document seed above is for; it needs the path only to match a source against grants it already holds. Google's documented answer for "write beside a picked file" is exactly what this app does: hold a tree grant, or fall back and tell the user.

Three fallbacks were tried on-device and all failed; **don't reintroduce them**:
- `MediaStore.getMediaUri()` on a DownloadsProvider (`msf:`) URI — documented to accept *only* `ExternalStorageProvider` and `MediaDocumentsProvider` authorities, so it was out of contract. Now gated by the `MEDIA_URI_AUTHORITIES` set in `MainActivity`.
- `/proc/self/fd/<fd>` canonicalPath — broken by design on API 30+; FUSE-backed scoped storage fronts the fd with a virtualized mount.
- MediaStore row-id queries for `msf:` ids — ownership-filtered to app-owned rows on API 29+, and the id space differs across OS versions and OEM forks.

`UnresolvedDestination` (`lib/core/unresolved_destination.dart`) remembers the folder the user chose for these sources, so they are asked once rather than every batch. **This does not violate the no-cache rule above**, and the distinction is the whole point: it stores a destination *preference*, never a grant. Liveness is re-asked of Android on every use via `SafBridge.isTreeGrantLive` → native `isTreeGrantLive` (reads `persistedUriPermissions`); a revoked grant is forgotten and the user is re-prompted, so the stale-entry failure mode a `folderPath→treeUri` cache would have cannot occur. Pinned by ladder tests `12` and `12b` in `test/output_plan_test.dart`.

**`DocumentPathResolver`** (`android/.../DocumentPathResolver.kt`) is the provider dispatch for `resolvePath` — the decision table turning `(authority, docId, apiLevel)` into one of: direct path (path-shaped externalstorage ids, `raw:` Downloads ids), a MediaStore query by row id (Downloads `msf:`, media shortcut kinds), a document-columns query (unknown/OEM providers), or unknown. Also framework-free and JVM-pinned (`DocumentPathResolverTest.kt`). MainActivity only *executes* the returned step; the media queries build the path from `RELATIVE_PATH` + `DISPLAY_NAME` (respecting `VOLUME_NAME` for SD cards), never from a filesystem stat.

## UI / navigation

- **`lib/core/router.dart`** — go_router routes. Flows: onboarding (`lib/features/onboarding/`), `home`, encrypt (`pick → passphrase → options → review → progress → success`), decrypt (`pick → passphrase → progress → success`), settings (`lib/features/settings/`: change passphrase, sharing keys / recipients, secure delete, passphrase storage, save folders (Android only)).
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
