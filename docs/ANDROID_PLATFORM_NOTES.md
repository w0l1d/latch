# Android platform notes — scoped storage, SAF, and how to research it

Findings from the "Latch can't tell which folder these files came from" investigation
(Aug–Sep 2026), written down so the same ground is not re-covered. Two parts:

1. **What is actually true about the platform** — each claim with the source that
   settles it, and each dead end marked dead so it is not retried.
2. **How the answers were found** — the research methodology, including which tools
   were useless and why.

Read part 2 first if you are starting a *new* Android platform question. Part 1 is the
reference for this subsystem specifically; the SAF design itself is documented in
`CLAUDE.md` under "Output path resolution".

---

## Part 1 — Established platform facts

### A document URI has no parent. This is deliberate and there is no workaround.

The user shared **one file**, not its folder, so the platform exposes no path from an
`ACTION_OPEN_DOCUMENT` result back to its container:

- `DocumentsContract.findDocumentPath` requires a **tree** URI. `isTreeUri()` is
  literally "first path segment == `tree`", and `DocumentsProvider.callUnchecked`
  enforces `MANAGE_DOCUMENTS` (`signature|privileged`) for `METHOD_FIND_DOCUMENT_PATH`
  on anything else. In a normal app it throws `SecurityException`, always.
- There is no `getParentDocumentUri`. `DocumentFile.fromSingleUri(...).getParentFile()`
  returns null unconditionally, and `.createFile()` throws
  `UnsupportedOperationException`. The framework's own words: the provider "only
  defines a forward mapping from parent to child".
- The complete `DocumentsContract.Document` column set is **8 columns**, none of which
  carries a parent, path, or relative path. `COLUMN_DOCUMENT_ID` is documented opaque —
  *"must not be parsed"*.

Consequence: for the picker's sidebar shortcuts (Downloads `msf:` ids, media
`image:`/`video:`/`audio:`/`document:` ids) and for cloud providers, `resolvePath`
returning **null is the correct answer**, not an engineering failure.

### But you do not need the path to *point the picker* at the folder

This was the breakthrough, and it was missed through three earlier failed fixes.
`DocumentsContract.EXTRA_INITIAL_URI` accepts a plain **document** URI:

> *"Location should specify a document URI or a tree URI with document ID. If this URI
> identifies a non-directory, document navigator will attempt to use the parent of the
> document as the initial location. The initial location is system specific if this
> extra is missing or document navigator failed to locate the desired initial
> location."*
> — AOSP `frameworks/base/core/java/android/provider/DocumentsContract.java`

DocumentsUI is privileged and holds `MANAGE_DOCUMENTS`, so **it** can do the
child→parent lookup the app cannot. Applies to `ACTION_OPEN_DOCUMENT`,
`ACTION_CREATE_DOCUMENT`, and `ACTION_OPEN_DOCUMENT_TREE`.

Three verified constraints on it:

- Must be a plain document URI, **never a tree URI**.
- `/Android/data`, `/Android/obb`, `/Android/sandbox` are pre-emptively rejected and
  redirect to the last-accessed stack.
- Third-party providers that don't implement `findDocumentPath` make it fail outright
  (`UnsupportedOperationException: findDocumentPath not supported` → "Failed to build
  document stack for uri" — see Nextcloud android#11101).

**It is best-effort by contract.** With no seed, or an unresolvable one, DocumentsUI
falls back to the last-accessed stack. Never write code that depends on a seed having
worked; an ignored seed must leave behavior exactly as it was.

### Tree grants cannot cover certain directories (API 30+)

`ACTION_OPEN_DOCUMENT_TREE` will not grant: the root of internal storage, the root of
an SD volume, `Android/data`, `Android/obb`, **or the top-level `Download` directory**.
Subfolders *inside* Download are grantable normally.

Downloads is one of the most common places a user's file lives, so this is not an edge
case — prompting there burns a picker round-trip only to guarantee a Downloads
fallback. `OutputPlanner._isTopLevelDownloadDir` short-circuits it.

### Persisted grants are capped and can die silently

- `MAX_PERSISTED_URI_GRANTS` = **128**, raised to **512** in Android 11. Only in AOSP
  `UriGrantsManagerService` — the public docs state no number.
- A grant dies when the document is moved or deleted, even after
  `takePersistableUriPermission`.
- Some shipping devices (InkBook, some Samsung, per Mihon's own code comment) do not
  implement persistable grants properly and throw or silently fail to persist. Wrap the
  call; on Android an exception escaping an activity-result callback leaves a parked
  `MethodChannel.Result` unanswered forever, which hangs the batch.

Latch takes one grant per distinct source folder. It used to release none, which was
monotonic growth against that cap (issue #67): at the ceiling the platform drops the
*oldest* grant, so a long-time user silently starts getting the "choose a folder" prompt
again for folders they already granted, and the dropped one is not necessarily one they
stopped caring about.

**Settings → Save folders** (`lib/features/settings/save_folders_screen.dart`) is the
answer, and deliberately the only one: it lists the grants the app holds and lets the
user revoke any of them. The app does not evict on its own terms — deciding which grant
is "least useful" needs history the app refuses to keep (see the no-cache rule below),
and a wrong automatic revoke costs the user a prompt they didn't ask for. The mirrored
cap is shown as headroom (`SafTreeGrants.limit`, 0 = unknown) and **nothing gates on
it**: `MAX_PERSISTED_URI_GRANTS` is `@hide` with no public accessor, so if a future
release changes the number, a slightly wrong "of 512" is the entire consequence.
`releaseTreeGrant` reports what `persistedUriPermissions` says *after* the release
rather than whether the call threw — devices that refuse to release exist (above), and
the UI must not claim a revoke that didn't happen.

### `contentResolver.persistedUriPermissions` is the only grant record worth keeping

Every well-built app surveyed re-asks the platform rather than trusting a cache:
Cryptomator re-checks at open, Aegis re-verifies before *every* write, Aves matches
paths against currently-held grants by prefix. A cached `folderPath→treeUri` can
outlive the grant it names, and the stale entry then skips the prompt and routes every
later batch to Downloads with no way back. Pinned by ladder test `3b` in
`test/output_plan_test.dart` — **do not reintroduce a prefs cache.**

### Dead ends — tried on-device, all failed. Do not retry.

| Attempt | Why it cannot work |
| --- | --- |
| `MediaStore.getMediaUri()` on a Downloads (`msf:`) URI | Documented to accept **only** `ExternalStorageProvider` and `MediaDocumentsProvider` authorities; throws `IllegalArgumentException` for `com.android.providers.downloads.documents`. Now gated by `MEDIA_URI_AUTHORITIES` in `MainActivity`. |
| `/proc/self/fd/<fd>` canonicalPath | Broken **by design** on API 30+; FUSE-backed scoped storage fronts the fd with a virtualized mount. |
| MediaStore row-id queries for `msf:` ids | Ownership-filtered to app-owned rows on API 29+ (Latch declares no `READ_MEDIA_*` at all), *and* the `msf:`/`msd:` id space is a private constant that differs across OS versions and OEM forks. |
| `findDocumentPath` on a single-document URI | Requires `MANAGE_DOCUMENTS`. `SecurityException`, always. |
| Deriving a path from a filesystem stat | Scoped storage denies it for non-media files on API 30+, and it silently sends every batch to the "can't tell which folder" prompt. Always derive from the document's own metadata. |

Zero relevant API changes across prebuilts/sdk 33/34/35/36 and AOSP main (signature
diffs empty); nothing new in Android 16/17. This is not a "wait for the next release"
problem.

### `MANAGE_EXTERNAL_STORAGE` is not actually barred by Play policy

Google's [Use of All files access](https://support.google.com/googleplay/android-developer/answer/10467955)
names **"Disk/Folder Encryption and Locking"** as an acceptable use. It requires a
Permissions Declaration Form and passes a "no effective privacy-friendly alternative"
test — which a working SAF implementation arguably fails.

**Recommendation stands: stay on SAF.** It is a far broader permission than Latch
needs, adds review friction to every release, and the current design works. But any
claim that the option simply doesn't exist is wrong, and shouldn't be written down as
if it were.

### How other apps actually solve this (5 patterns, source-verified at HEAD)

1. **Vault / one-tree-grant** — dominant among encryption apps. The encryption unit *is*
   a granted folder, so "beside the input" never arises. Cryptomator, EDS Lite, Mihon,
   Aegis, DroidFS-on-export. Google's own `buildDocumentUriUsingTree` javadoc endorses
   it: it "doesn't require the user to separately confirm each new document access".
2. **Per-save `ACTION_CREATE_DOCUMENT`** — dominant for single outputs, and *nobody
   batches it*. OpenKeychain's `showOutputFileDialog()` **throws `IllegalStateException`
   if `getModelCount() != 1`**; for N>1 there is no picker at all, results leave via the
   share sheet. ImageToolbox's Cipher tool: one picker per output.
3. **Fixed location, no picker ever** — best batch UX. Signal writes to
   `Pictures/Signal`, `Movies/Signal`, `Music/Signal`, else `Downloads/Signal` via
   MediaStore `RELATIVE_PATH`; N inserts, zero pickers, no persisted grants, no
   `MANAGE_EXTERNAL_STORAGE`.
4. **Escape scoped storage entirely** — what every file manager does. Material Files,
   Amaze, Fossify all declare `MANAGE_EXTERNAL_STORAGE` +
   `requestLegacyExternalStorage`, and all three ship on Play under the file-manager
   exemption.
5. **Derive the input's folder without a grant** — verified real, but **media-only**.
   ImageToolbox parses the SAF document ID string (`primary:Docs/foo.jpg`) the same way
   `ExternalStorageDocIds` does, then falls back to MediaStore `RELATIVE_PATH` — but the
   whole path is gated on `ImageSaveTarget`, so arbitrary files never reach it. Which is
   exactly why its Cipher tool uses `ACTION_CREATE_DOCUMENT` instead. MediaStore
   `RELATIVE_PATH` is also only honored under a collection's allowed top-level dirs, and
   is a *hint* the store may ignore.

**Net: 0 of the surveyed encryption apps solve "beside the input" for arbitrary files in
a batch.** Latch's `OutputPlanner` is attempting something none of them do. The closest
published precedent is **Aves** (also Flutter): no cache, prefix-matches each path
against currently-held grants, seeds the picker from the path, and carries the comment
*"initial URI should not be a `tree document URI`, but a simple `document URI`"*.

---

## Part 2 — Research methodology that worked

Ordered by how much signal each produced. The first two did nearly all the work.

### 1. Read AOSP source directly — the single highest-value move

`developer.android.com` is incomplete on exactly the questions that matter, and
**`WebFetch` on it returns only the nav menu**, not the content. Fetch the source:

```
https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/provider/DocumentsContract.java?format=TEXT
```

The `?format=TEXT` suffix returns base64 of the raw file — the verbatim javadoc, the
private constants, the permission enforcement. Every decisive fact in Part 1 came from
this. Useful paths:

- `frameworks/base/core/java/android/provider/DocumentsContract.java` — the contract,
  incl. `EXTRA_INITIAL_URI` semantics
- `frameworks/base/core/java/android/provider/DocumentsProvider.java` — `callUnchecked`
  permission gates
- `frameworks/base/services/core/java/com/android/server/uri/UriGrantsManagerService.java`
  — `MAX_PERSISTED_URI_GRANTS`
- `packages/apps/DocumentsUI/` — actual picker behavior, incl. initial-location fallback
- `packages/providers/MediaProvider/.../MediaStoreDownloadsHelper.java` — the private
  `msf:`/`msd:` id scheme

Also diff API signatures across SDK levels (`prebuilts/sdk/*/public/api/android.txt`) to
answer "did a newer Android add a way?" — here, empty diffs, which is a real answer.

### 2. Read shipping open-source apps' source at HEAD

Docs say what is possible; shipping code says what actually works on devices. This is
where the OEM caveats came from — nothing in any official doc says "InkBook devices
don't implement persistable grants", but Mihon's try/catch comment does.

Method: `git clone --depth 1`, then grep for the API. High-value repos for storage
questions: Cryptomator, Aegis, KeePassDX, DroidFS, OpenKeychain, ImageToolbox,
Signal-Android, Aves (Flutter), Mihon, Material Files, Amaze, Fossify.

Read the **manifest first** — an app using `MANAGE_EXTERNAL_STORAGE` is not evidence
about scoped storage, however sophisticated its SAF code looks. ImageToolbox looked like
a clean counter-example until its manifest showed all-files access, legacy storage, and
`READ_MEDIA_IMAGES`.

Two traps worth naming:

- **`--depth 1` cannot date files.** Per-file `git log -1` reports the HEAD commit date
  for every path. "Present at HEAD" ≠ "current practice". For real dates, clone
  `--filter=blob:none` instead.
- **A public repo can lag the shipped binary.** EDS Lite's is a 2020 snapshot at
  targetSdk 28 — useless as evidence about modern behavior.

### 3. Check whether widely-cited "known bugs" are real

Two of the three sources that had discouraged this fix did not survive checking:

- The much-cited Commonsware "`EXTRA_INITIAL_URI` isn't working" thread turned out to be
  **user error** (shared SharedPreferences keys), not a platform bug.
- Organic Maps ships `// Sic: EXTRA_INITIAL_URI doesn't work` — a real shipping app's
  real comment, but one app's undated observation, not a contract. Worth treating as a
  caution (hence best-effort), not as a blocker.
- `issuetracker.google.com/issues/291241154` is login-walled and could not be verified
  either way. Say so rather than citing it.

**Three failed fixes had produced a "not fixable" conclusion. It was wrong.** The
recovery was rereading the primary source from scratch rather than accumulating more
secondary opinions.

### 4. What did not work

- **context7 — 7 queries, no useful result.** It resolved
  `/git_android_googlesource_com/platform_frameworks_base` (High reputation, 4854
  snippets) and still returned "No documentation matched" twice and raw
  `api/current.txt` signature dumps once. It indexes API *signature* text, not
  `DocumentsContract` behavioral semantics. For Android framework behavior, go straight
  to googlesource.
- **`WebFetch` on developer.android.com** — returns the nav menu. Use googlesource, or
  `support.google.com` for policy (which does fetch fine).

### 5. Process notes that mattered

- **Write the JVM-testable core framework-free.** `ExternalStorageDocIds` and
  `DocumentPathResolver` take the mount point as a parameter and make no framework
  calls, so `./gradlew :app:testDebugUnitTest` pins the id↔path inverse without a
  device. When those two directions drift, output silently lands in the wrong folder and
  nothing in a build shows it.
- **Instrument the boundary before theorizing.** The behavior only reproduces on a real
  device with a real provider; the resolver's decision table
  `(authority, docId, apiLevel)` → step exists so the failing input is identifiable from
  a log line rather than guessed.
- **Three failed fixes = question the architecture, not fix #4.** That rule is what
  forced the re-read that found `EXTRA_INITIAL_URI`.
