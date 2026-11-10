# Android storage & output paths (agent notes)

Read this **before** touching anything about where encrypted/decrypted files land: `lib/core/output_plan.dart`, `default_output.dart`, `save_folder_prompt.dart`, `saf_bridge.dart`, `saf_source.dart`, `unresolved_destination.dart`, `staging_sweep.dart`, the Android `latch/saf` channel, or Settings → Save folders.

Platform-level facts (why a document URI has no parent, grant caps, dead ends already tried, how to research AOSP) live in [`docs/ANDROID_PLATFORM_NOTES.md`](../ANDROID_PLATFORM_NOTES.md). This file covers **how Latch is built on top of those facts** — read the platform note first when the question is "can Android even do this".

## Goal

Outputs land in the **source file's own folder**. The mechanism differs by platform because Android scoped storage (API ≥ 30) forbids the crypto worker (plain `dart:io`) from writing anywhere but app-private storage and public Downloads, and the single-file picker only grants the *picked document*, not its folder. The design lives in **`lib/core/output_plan.dart`** (`OutputPlanner.plan` + `relocateStagedOutputs`) — read it before changing output behavior.

## Desktop / iOS

`OutputPlanner.plan` returns `stagingDir == null`; the worker writes the final file directly via `resolveOutputPath`/`resolveNameCollision` in `file_io_dart.dart` (encrypt name `<source>.latch`, decrypt strips `.latch`). `outputDir` = the user-picked dir, else `DefaultOutput.directoryFor` (`lib/core/default_output.dart`: `null`/beside-original on desktop, app-documents on iOS). Relocation is a no-op.

## Android (SAF folder grant)

1. **Stage** — `plan` sets `stagingDir`/`outputDir` to an app-cache dir, so the worker writes into always-writable private storage (decrypt plaintext never transits Downloads).
2. **Grant** — per distinct source folder (resolved via `SafBridge.realDirectoryFor` → native `resolvePath`, which derives the path from the document's own metadata: path-shaped externalstorage docIds; MediaStore `RELATIVE_PATH` + `DISPLAY_NAME` for the picker's sidebar shortcuts (Downloads `msf:` ids, media `image:`/`video:`/`audio:`/`document:` ids); the document's own columns for unknown/OEM providers; `_data` only as a last resort — **never from a filesystem stat**, which scoped storage denies for non-media files on API 30+ and would send every batch to the "can't tell which folder" prompt).
   `OutputPlanner._grantFor` asks in this order: **(a)** `SafBridge.existingTreeGrantFor` = any grant Android still holds covering the folder *or an ancestor of it* (deepest wins; the returned `subPath` addresses the nested folder inside the grant); **(b)** only then prompt via `promptSaveFolder`, which never drops the picker on the user unexplained: a rationale dialog first names the source folder ("Save beside the originals?"), and Continue opens the permission picker — `SafBridge.pickTree` (`ACTION_OPEN_DOCUMENT_TREE`, persisted, seeded at the source folder, so granting is one tap). Backing out of either step (or a picker that fails to open, e.g. no intent handler) offers the explicit "Cancel / Use Downloads / Choose folder" choice (choosing reopens the picker, still seeded at the source folder). **Neither picker call may throw out of the prompt** — a device with no handler for the intent must still leave Downloads reachable, not abort the batch by exception. After the picker returns, the grant is re-resolved through (a), so a user who picks a *parent* of the requested folder still gets output in the source folder. A source whose folder can't be resolved at all skips the rationale and prompts once with a null folder — never a silent Downloads fallback — and the answer is remembered (see **Unresolvable sources**) so it isn't asked every batch. Its picker is still seeded, just by the *document* rather than a path.
3. **Relocate** (main isolate, post-batch) — `relocateStagedOutputs` moves each staged file into its granted tree via `SafBridge.createInTree` (native `DocumentsContract.createDocument` on the tree root, or on the `subPath` folder nested inside the grant; collision handling mirrors `resolveNameCollision`), deleting the cache temp. **No grant / cloud source / write failure → move to Downloads and flag `fellBackToDownloads`**, surfaced as a banner on the success screens.

### The prompt has three answers, not two

`SaveFolderDecision` in `output_plan.dart`: a grant, an explicit "use Downloads", or `cancelled`. Downloads is a destination the user *chooses*, never one they get by declining to choose — conflating the two is what silently wrote whole batches somewhere the user never picked.

- A cancellation returns `OutputPlan.cancelled` and stops at the first declined prompt (a batch spanning several unfamiliar folders does not march the user through the rest of them); both progress screens then pop exactly the way their Cancel button does.
- Nothing is written and nothing is remembered: planning runs *before* the crypto worker, so there is no staged output to sweep, and storing a cancellation as an `UnresolvedDestination` would answer the question wrongly for every later batch.
- Both dialogs stay `barrierDismissible: false` and a dismissed dialog reads as cancel — the old `showDialog<bool>` completing with `null` was read as "Use Downloads".
- The "Choose folder" → empty-picker case re-offers the choices **once** (the picker may simply not have opened, and Downloads must stay reachable); a second empty picker is taken as the answer and cancels.
- A user-picked "choose folder" in encrypt options supplies one `explicitTreeUri` for all files and skips this entirely; that picker is seeded at the first source's folder too.

### Android's persisted-permission table is the only grant record

The app deliberately caches nothing: a remembered `folderPath→treeUri` can outlive the grant it names, and a stale entry would skip the prompt and route every later batch to Downloads with no way back. Re-asking the platform each batch is one cheap in-process call — **don't reintroduce a prefs cache** (pinned by ladder test `3b` in `test/output_plan_test.dart`).

### Grants only grow unless the user gives one back

One per distinct source folder, against a platform ceiling (`MAX_PERSISTED_URI_GRANTS`: 128, 512 from API 30) at which Android drops the *oldest* grant — a long-time user silently gets re-prompted for folders they already granted.

**Settings → Save folders** (`lib/features/settings/save_folders_screen.dart`, `SafBridge.listTreeGrants` / `releaseTreeGrant`, native `listTreeGrants` / `releaseTreeGrant`) is the release valve, and doubles as the honest answer to "what does this app still have write access to". The app deliberately does **not** evict on its own terms: picking the "least useful" grant needs history it refuses to keep. The cap is a mirrored constant (`@hide`, no public accessor) shown as headroom only when within 80% of it — **nothing gates on it**, so a future AOSP change costs a slightly wrong "of 512" and nothing else. `releaseTreeGrant` returns what `persistedUriPermissions` says *after* the release, not whether the call threw: devices that refuse to release exist, and the UI must not claim a revoke that didn't happen. Like every other grant question, the list is read live on entry and after each revoke — no cache.

## Native side (`android/.../MainActivity.kt`, `latch/saf` channel)

Implements `openTree`, `treeUriToPath`, `existingTreeGrant`, `createInTree`; grants persist across restarts via `takePersistableUriPermission`, and Android's `persistedUriPermissions` is what `existingTreeGrant` reads. The picker is seeded via `EXTRA_INITIAL_URI` (see below); some OEM pickers ignore the extra and open at root regardless. `takePersistableUriPermission` is wrapped in `runCatching` — devices exist that throw or silently fail to persist, and an exception escaping the activity-result callback would leave the parked `MethodChannel.Result` unanswered forever, hanging the batch; the grant is still live for the current process, and a grant that didn't stick simply reads as absent next batch.

No `MANAGE_EXTERNAL_STORAGE` — deliberately, though not because Play forbids it (see the platform note). The reasons to stay on SAF are that it is a far broader permission than the app needs, it adds review friction to every release, and the SAF design works.

This reuses the existing "worker stages, main isolate does SAF I/O afterward" pattern (see `_writeBackOriginals`), since the isolate has no platform channels.

### `ExternalStorageDocIds`

(`android/.../ExternalStorageDocIds.kt`) Holds the path ↔ document-id mapping (`"primary:Docs/Work"` ↔ `/storage/emulated/0/Docs/Work`) that the native call sites share: `resolvePath` (via its externalstorage branch) and `treeUriToPath` go id→path (matching a grant to a source folder), `initialTreeUri` goes path→id (seeding the picker). **The two directions must stay exact inverses** — when they drift, output silently lands in the wrong folder or the picker opens at the storage root, neither visible in a build. It is deliberately free of Android framework calls (the primary volume's mount point is a parameter) so it is unit-testable on the JVM: `android/app/src/test/kotlin/.../ExternalStorageDocIdsTest.kt`, run by the `android-unit-test` CI job or locally via `cd android && ./gradlew :app:testDebugUnitTest`.

## Seeding the picker — `EXTRA_INITIAL_URI` takes a *document* URI

`SafBridge.pickTree({initialPath, initialDocUri})` passes two candidate seeds; the native `launchOpenTree` prefers a path (via `initialTreeUri`) and falls back to the document URI. The second seed is why the previously-hopeless case works: **`EXTRA_INITIAL_URI` accepts a plain document URI and the system's document navigator resolves its parent** — *"If this URI identifies a non-directory, document navigator will attempt to use the parent of the document as the initial location"* (AOSP `DocumentsContract`). DocumentsUI is privileged and holds `MANAGE_DOCUMENTS`, so it can do the child→parent lookup this app provably cannot. So even a source whose folder Android refuses to name opens the folder picker *at that folder* — granting is one tap instead of a hunt from the storage root.

**Seeding is best-effort by contract** (*"the initial location is system specific if this extra is missing or document navigator failed to locate the desired initial location"*), and shipping apps have disabled it as unreliable on some devices. Nothing may depend on a seed having worked: an ignored seed leaves the picker exactly where it would have opened anyway. Must be a plain document URI, never a tree URI. Pinned in `test/save_folder_prompt_test.dart`, `test/encrypt_options_screen_test.dart`, and `test/saf_bridge_test.dart`.

## Unresolvable sources — a platform limit, not a bug to fix

**There is no supported way to learn which folder an `ACTION_OPEN_DOCUMENT` pick came from.** A document URI has no parent pointer (`DocumentsContract.findDocumentPath` needs a *tree* URI; there is no `getParentDocumentUri`) — deliberate privacy design: the user shared one file, not its folder. So for the picker's sidebar shortcuts (Downloads `msf:` ids, media `image:`/`video:`/… ids) and cloud providers, `resolvePath` returning null is the **correct** answer, not a failure to engineer around. The app does not need the path to *point the picker* at the folder, though — that is what the document seed above is for; it needs the path only to match a source against grants it already holds. Google's documented answer for "write beside a picked file" is exactly what this app does: hold a tree grant, or fall back and tell the user.

Three fallbacks were tried on-device and all failed; **don't reintroduce them** (details and citations in `docs/ANDROID_PLATFORM_NOTES.md`): `MediaStore.getMediaUri()` on a DownloadsProvider (`msf:`) URI; `/proc/self/fd/<fd>` canonicalPath; MediaStore row-id queries for `msf:` ids.

`UnresolvedDestination` (`lib/core/unresolved_destination.dart`) remembers the folder the user chose for these sources, so they are asked once rather than every batch. **This does not violate the no-cache rule above**, and the distinction is the whole point: it stores a destination *preference*, never a grant. Liveness is re-asked of Android on every use via `SafBridge.isTreeGrantLive` → native `isTreeGrantLive` (reads `persistedUriPermissions`); a revoked grant is forgotten and the user is re-prompted, so the stale-entry failure mode a `folderPath→treeUri` cache would have cannot occur. Pinned by ladder tests `12` and `12b` in `test/output_plan_test.dart`.

### `DocumentPathResolver`

(`android/.../DocumentPathResolver.kt`) The provider dispatch for `resolvePath` — the decision table turning `(authority, docId, apiLevel)` into one of: direct path (path-shaped externalstorage ids, `raw:` Downloads ids), a MediaStore query by row id (Downloads `msf:`, media shortcut kinds), a document-columns query (unknown/OEM providers), or unknown. Also framework-free and JVM-pinned (`DocumentPathResolverTest.kt`). MainActivity only *executes* the returned step; the media queries build the path from `RELATIVE_PATH` + `DISPLAY_NAME` (respecting `VOLUME_NAME` for SD cards), never from a filesystem stat.
