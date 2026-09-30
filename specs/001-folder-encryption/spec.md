# Feature Specification: Folder Encryption & Faithful Restore

**Feature Branch**: `001-folder-encryption`

**Base**: `develop` — rebased 2026-09-29, after features 002 and 003 shipped

**Created**: 2026-08-26

**Last updated**: 2026-09-29

**Status**: Specified; implementation started. The payload preamble and its two
failure types exist in `packages/myenc_core` (WIP, not wired into the codec). No
container is written as v2 yet.

**Input**: User description: "I want to implement a new feature where we could select a folder instead of files, and latch the whole folder with its content, with the possibility on decryption to restore it to exactly its previous state."

## Overview

Today Latch operates on a user-picked *set of files*. Each file becomes its own
`.latch` container and each container decrypts back to one file. A user who wants
to protect a project directory, a photo album, or a nested archive of documents
must pick every file by hand, loses the directory structure entirely, and has no
way to put it back.

This feature adds **folder** as a selectable unit. The user picks one folder;
Latch protects that folder and everything inside it; and a later decryption
reproduces the folder — its tree shape and its contents — as it was at the moment
of encryption.

This is a new use case in the product spec's numbering: **UC-13 — Encrypt a
folder / restore a folder**. It extends UC-1 (encrypt a file), UC-2 (decrypt a
file) and UC-3 (batch) rather than replacing them.

**What this feature is not**: it is not a backup product, not a sync product, and
not an archive browser. There is no way to list, search, or extract a single
entry from a protected folder without unlocking it, and there is no recovery path
if the passphrase is lost — a protected folder is exactly as unrecoverable as a
protected file, by design.

## Clarifications

### Session 2026-08-26

- Q: Should a latched folder produce one protected container for the whole folder, or one per file mirroring the tree? → A: ONE container for the whole folder.
- Q: What must "exactly its previous state" preserve, and how is the folder captured? → A: Pack the folder into a single lossless archive stream, protect that, and unpack on restore. Critically: never unpack a plaintext that merely happens to be an archive — a user-supplied `.zip` protected as a file must come back byte-identical, so the unpack decision must come from an authenticated in-container indicator, not from sniffing the plaintext.
- Q: When one entry of many cannot be read, does the operation abort or complete-and-report? → A: Abort the whole operation and report which entry caused it.
- Q: Beyond structure, names and content, what else must survive a round trip? → A: Modification times, the executable bit, and symlinks kept as links. Creation times, full POSIX permissions, and extended attributes are out of scope; where a platform cannot apply an in-scope item, restore content correctly and report what could not be applied.
- Q: Should the folder-vs-file indicator be a boolean or an extensible value? → A: An extensible enumerated payload-kind with room for future kinds. Exactly two are valid now (single opaque file, packed folder); any other value must fail closed as "made by a newer version", distinct from wrong-passphrase and corrupt.

### Session 2026-09-29 — version management

Features **002 (central format-version registry)** and **003 (codec version
strategies)** shipped into `develop` after this spec was written. They changed
*how* a new container version comes into existence, which FR-013 had described in
the abstract. These answers replace that abstraction with the mechanism that now
exists.

- Q: FR-013 says a new container signal arrives by "bumping the version byte and adding a new reader". What is that concretely, now that 002 and 003 have shipped? → A: One row in the central version registry plus one strategy object holding that version's layout. The feature adds those two things; it does not build, replicate, or bypass version machinery, and it holds no version comparison of its own.
- Q: Does adding v2 to the registry change what version *new* containers are stamped with? → A: No. What the build can read and what it writes are separately stated and must move separately. Adding v2 makes v2 readable and nothing else.
- Q: Then which version does a writer stamp? → A: The lowest version that can carry the payload, decided per container. A single opaque file stays v1 forever, so installs that predate this feature keep opening ordinary files; only a packed folder is written as v2.
- Q: Who owns fail-closed on an unknown version — this feature or the shipped registry? → A: The registry, already. This feature inherits that behaviour and must not add a second version gate. Its own new rejection is the unknown *payload-kind*, which is a different failure at a different stage.
- Q: What protects v1 from this feature? → A: The freeze guards and the pre-refactor compatibility corpora that 002 and 003 committed, which must keep passing unedited. A guard that needs editing means v1 moved, which is a bug to revert.

### Session 2026-09-29 — Android folder access, after #66, #74 and #78

Three platform changes shipped into `develop` after this spec was written, all
touching the folder-grant machinery this feature's Android story rests on: the
picker is now seeded from the source document (#66), declining the save-folder
prompt now cancels the batch instead of silently using Downloads (#74), and
**Settings → Save folders** now lists and revokes every persisted grant (#78).

- Q: Selecting a source folder takes a persisted tree grant, and that grant is read **and** write. Does that make the source folder's grant a separate thing from the output folder's? → A: No — it is the same grant, and that is a simplification, not a problem. Picking a folder to encrypt already carries the write access needed to put output beside the originals, so the common folder case never reaches the save-folder prompt at all.
- Q: That grant then appears in a settings screen called "Save folders", whose copy says Latch will lose *write* access. Is that acceptable? → A: No. Whatever the app shows the user about which folders it can reach must describe the access it actually holds. A folder the user only ever encrypted must not be presented as somewhere Latch saves files.
- Q: Should a source-folder grant be persisted at all, or taken for the operation only? → A: Persisted, using the same mechanism as everywhere else. A transient grant would mean re-picking the folder on every operation, and would put this feature's access outside the one list the user can audit and revoke — the opposite of what #78 exists for.
- Q: Does the three-answer save-folder prompt apply to folder operations? → A: Yes, unchanged, including cancellation. A declined prompt cancels the operation, writes nothing and remembers nothing.
- Q: FR-035 forbids the app keeping its own record of which folder maps to which grant, but `UnresolvedDestination` shipped and does remember something. Contradiction? → A: No. FR-035 forbids caching a *grant*, which can go stale and silently misroute output. Remembering a destination the user *chose*, with liveness re-asked of the platform on every use, is a different thing and stays permitted.

### Session 2026-09-29 — edge cases without requirements

The **Edge Cases** section listed cases that no functional requirement answered.
These answers close that gap; each names the requirement it produced.

- Q: When a folder is too big to fit — in the staging area or at the destination — should Latch check free space before starting, or discover it when a write fails? → A: Both. A pre-flight estimate refuses up front and names the shortfall and where it is, because the Android path stages the whole container in app-private cache before copying it to the granted folder and therefore needs roughly twice the container size. A pre-flight estimate can still be wrong — another app may consume the disk mid-run — so running out anyway MUST abort, clean up every partial byte under FR-029, and be reported as a space problem rather than a generic write failure (FR-029a).
- Q: When enumeration finds an entry that is neither a regular file nor a directory — a device node, socket, FIFO, or a macOS bundle — does the operation skip it or abort? → A: Skip only the filesystem plumbing that cannot be meaningfully captured (devices, sockets, FIFOs), and report every skipped entry to the user by relative path; a macOS bundle is an ordinary directory on disk and MUST be captured in full, not treated as a single opaque item. Silence is what makes a skip dangerous, so no skip may be silent (FR-002a). Critically, anything not captured MUST NOT be deleted: where the user chose to delete the originals, the deletion covers only entries the container actually holds, and every skipped entry is left in place (FR-002b).
- Q: If the tree changes while the operation is running — an entry added, deleted, renamed, or written to — what does the container end up holding? → A: The operation aborts. Latch has no snapshot facility on any supported platform, so "the tree as it was at listing time" is not available to capture; detecting the change and stopping is. The report MUST identify the entry by relative path **and say what changed about it** — that it disappeared, was replaced by a different kind of entry, grew, shrank, or was modified while being read — because "something changed" leaves the user unable to judge whether their data is at risk or another program simply touched a log file (FR-031a).
- Q: When the user asks for the originals to be deleted after a folder is protected, how thoroughly is the original folder destroyed? → A: By default, shred each captured file through the existing secure-delete path and then remove the directories, so the tree's *names* disappear too — a path like `Tax returns/2019/settlement.pdf` leaks plenty even with every byte gone. The user MUST be told plainly what each mode actually does, including that overwriting cannot be guaranteed on flash storage, and MUST be able to change the default in advanced settings rather than being asked on every operation (FR-041, FR-041a). A stored preference is not a violation of FR-040: it describes a user choice, not the user's folders.
- Q: Does Latch impose a maximum folder size or file count, and what happens above it? → A: No app-imposed cap. Latch's own design does not need one — memory stays bounded by FR-027 and the container streams — so inventing a ceiling would mean picking a number the project cannot justify. Above a threshold the pre-flight screen warns that the selection is large and says what to expect, and the user may proceed (FR-003a). Genuine limits are still refused with a specific reason rather than discovered hours in: insufficient space (FR-029a) and a container that would exceed what the destination filesystem can hold (FR-005a).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Latch a folder and get it back (Priority: P1)

A user has a folder of documents they want to protect. They choose "select
folder" instead of "select files", pick the folder, enter a passphrase, and Latch
produces encrypted output representing the whole folder. Later — possibly on a
different device, possibly after a fresh install — they select that output,
enter the passphrase, and get back a folder whose tree and file contents are
identical to the original.

**Why this priority**: This is the feature. Without a working round trip nothing
else in this spec has any value, and an encrypt path that cannot be restored is
worse than no feature at all — it destroys data.

**Independent Test**: Create a folder containing a handful of files across two
or three levels of subdirectories, latch it, delete the original, restore it, and
compare the restored tree against a recorded inventory of names, relative paths,
and byte-for-byte file contents.

**Acceptance Scenarios**:

1. **Given** a folder with files in nested subdirectories, **When** the user
   latches it with a passphrase and then restores it with the same passphrase,
   **Then** every original file exists at the same relative path with
   byte-identical content, and no extra entries appear.
2. **Given** protected folder output and a **wrong** passphrase, **When** the user
   attempts to restore, **Then** the app reports a wrong-passphrase error, and no
   file or directory from the folder is written anywhere the user can reach.
3. **Given** protected folder output whose bytes have been modified after
   encryption, **When** the user attempts to restore with the correct passphrase,
   **Then** the app reports a corruption/tamper error and no partial restored
   tree is left behind.
4. **Given** a restore target where a folder of the same name already exists,
   **When** the user restores, **Then** the existing folder is not overwritten or
   merged into; the restored folder is placed under a non-colliding name and the
   user is told the name that was used.
5. **Given** a successful restore, **When** the user inspects the result,
   **Then** the top-level folder carries the original folder's name.

---

### User Story 2 - Awkward folders restore faithfully (Priority: P2)

Real folders are not tidy. They contain empty subdirectories that carry meaning,
names with accents, emoji, spaces, and characters that are legal on one platform
and illegal on another; they nest deeply; they contain dotfiles the user forgot
about; and they may contain symbolic links or aliases. A user who latches such a
folder expects "restore to exactly its previous state" to hold for those too, or
to be told plainly and *before* encrypting which parts cannot be preserved.

**Why this priority**: "Exactly its previous state" is the promise in the
request. Silently dropping empty directories or mangling a non-ASCII filename is
data loss the user will only discover long after the original is gone. It is
second only to the round trip itself.

**Independent Test**: Build a fixture tree that deliberately contains an empty
directory, a directory containing only empty directories, names using non-ASCII
and combining Unicode characters, a name at the platform's maximum length, deep
nesting, and hidden/dot-prefixed entries; round-trip it and assert the restored
tree matches the fixture inventory exactly.

**Acceptance Scenarios**:

1. **Given** a folder containing an empty subdirectory, **When** it is round
   tripped, **Then** the empty subdirectory exists in the restored tree.
2. **Given** entry names containing non-ASCII characters, combining accents, and
   emoji, **When** the folder is round tripped on the same platform, **Then** the
   restored names compare equal to the originals byte-for-byte in their encoded
   form.
3. **Given** a folder containing hidden / dot-prefixed files and folders,
   **When** it is round tripped, **Then** those entries are present in the
   restored tree (they are in scope by default — see Assumptions).
4. **Given** a folder whose contents include a zero-byte file, **When** it is
   round tripped, **Then** the restored file exists and is zero bytes.
5. **Given** a folder containing an entry the app will not preserve faithfully
   (for example a symbolic link, or metadata the platform cannot reproduce),
   **When** the user reviews the selection before encrypting, **Then** the app
   states what will not be preserved, and the user can proceed or cancel.
6. **Given** a restore onto a platform whose filesystem rejects a name that was
   legal on the source platform, **When** the restore runs, **Then** the app
   fails that entry with a clear, specific message naming the problematic entry
   rather than writing it under a silently altered name.

---

### User Story 3 - Large folders stay usable and interruptible (Priority: P3)

A user latches a folder containing thousands of files and several gigabytes of
data. They expect the app to remain responsive, to show progress that actually
moves and means something, to be able to stop it, and to know what state their
disk is in after stopping.

**Why this priority**: Folders are the case where the existing per-file batch
model breaks down. It is not required for a first demonstrable slice, but the
feature is unusable on real folders without it — and an uncancellable multi-hour
operation with an ambiguous aftermath is a support and trust problem.

**Independent Test**: Generate a synthetic tree with a large file count and a
large total size, run encryption and restore, and observe that progress advances
monotonically with a meaningful unit, that memory use stays bounded and
independent of tree size and of the largest file's size, and that cancelling
mid-way leaves no reachable partial output.

**Acceptance Scenarios**:

1. **Given** a folder of many thousands of entries, **When** the user latches it,
   **Then** the app displays progress that advances as work completes and does not
   sit at a single value for the whole run, and the UI stays responsive
   throughout.
2. **Given** an encryption or restore in progress, **When** the user cancels,
   **Then** the operation stops, and every incomplete output — including any
   staged or temporary data — is removed, leaving no partially written container
   and no partially restored plaintext tree.
3. **Given** a folder whose total size or largest single file is far larger than
   available memory, **When** it is latched and restored, **Then** the operation
   completes without exhausting memory.
4. **Given** the app is stopped by the operating system mid-operation, **When** the
   user reopens it, **Then** no reachable partial plaintext from a restore
   remains, and the user is not shown a protected-folder output that cannot be
   restored as if it were complete.

---

### User Story 4 - An unreadable entry aborts loudly (Priority: P3)

A folder of 10,000 files contains one file the app cannot read — locked by
another process, permission-denied, or a broken link. Rather than quietly
producing a container that covers 9,999 of them, the operation stops, names the
entry that stopped it, and leaves the user's originals untouched.

**Why this priority**: The failure is common at scale and the wrong answer here
causes data loss: a user who deletes an original folder trusting a container that
silently skipped 12 files has lost those files. Aborting means the user is never
handed a container they could mistake for complete.

**Independent Test**: Attempt to latch a tree containing one deliberately
unreadable entry; assert the operation aborts, the entry is named by relative
path, no container or staged remnant exists afterwards, and every original is
still present.

**Acceptance Scenarios**:

1. **Given** a folder containing one unreadable file, **When** the user latches
   the folder, **Then** the operation aborts and the outcome names that entry by
   its relative path in human copy.
2. **Given** an aborted folder operation, **When** the user inspects the
   destination and the staging area afterwards, **Then** no protected container
   and no partial remnant exists anywhere.
3. **Given** an aborted folder operation for which the user had chosen "delete
   originals", **When** the abort is reported, **Then** every original is still
   present — an aborted operation never deletes originals.
4. **Given** an abort part-way through a long folder, **When** the user retries
   after fixing the unreadable entry, **Then** the operation can be started again
   from scratch with no leftover state interfering.
5. **Given** a restore in which one entry cannot be written to the destination,
   **When** the operation finishes, **Then** the user is told which entries
   failed and why, in human copy rather than raw error text, and no partially
   restored tree is left reachable.

---

### User Story 5 - Picking a folder on Android (Priority: P3)

An Android user taps "select folder". Android's scoped storage grants access to a
folder tree only via an explicit permission grant, which is a different and more
consequential prompt than picking a file. The user should understand what they
are granting and why before the system picker appears, and their output should
still land beside the originals wherever the platform allows it.

**Why this priority**: Android is a primary target and, unlike desktop, folder
*reading* — not just writing — depends on a granted tree. Without this the
feature simply does not function there. It is separable from the core round trip,
which can be demonstrated on desktop first.

**Independent Test**: On Android, select a folder from several storage locations
(app-visible internal storage, Downloads, an SD card, a cloud-backed provider),
and verify the read grant is obtained with a rationale shown first, that the
whole tree is enumerated, and that output placement matches the documented
behaviour for each location.

**Acceptance Scenarios**:

1. **Given** an Android user choosing "select folder", **When** the flow starts,
   **Then** a rationale explaining what access is being requested and why is shown
   before the system permission picker opens.
2. **Given** the user backs out of the permission picker or the picker cannot be
   opened at all, **When** the flow continues, **Then** the app presents an
   explicit choice rather than aborting the operation or silently doing nothing.
3. **Given** a granted folder tree, **When** the app enumerates it, **Then** every
   entry inside the tree — at any depth — is discovered, including nested
   subdirectories.
4. **Given** a selected folder that is backed by a cloud or virtual provider
   whose contents are not fully materialised on the device, **When** the user
   attempts to latch it, **Then** the app states that the folder cannot be fully
   read rather than producing output that silently omits unmaterialised entries.
5. **Given** a successful folder encryption on Android, **When** output cannot be
   written beside the originals, **Then** the output goes to the documented
   fallback location and the user is told where it went.
6. **Given** a user encrypting a folder with output beside the originals, **When**
   the operation runs, **Then** access is requested exactly once — at selection —
   and a repeat operation on the same folder requests none at all.
7. **Given** a folder the user has only ever encrypted, **When** they open the
   app's folder-access settings, **Then** that folder is listed and described by
   the access actually held, not as a place Latch saves files.
8. **Given** a folder operation that asks the user to choose a destination,
   **When** the user declines or dismisses the prompt, **Then** the operation is
   cancelled with nothing written, nothing staged and nothing remembered — never
   silently redirected to the shared fallback.

---

### Edge Cases

**Selection & scope**

- The selected folder is empty (no files, no subdirectories).
- The selected folder is a storage root, a system folder, or the app's own
  storage — the app should refuse or warn rather than attempt it.
- The selected folder contains, at any depth, the destination the output would be
  written to (self-containment), or contains a previously produced `.latch`
  output of itself.
- The folder or an entry inside it changes — file added, removed, renamed, or
  written to — *while* the operation is running (FR-031a).
- The user revokes, in the app's own folder-access settings, the grant that a
  folder the app is mid-operation on depends on; or revokes it between selecting
  the folder and starting the operation.
- The platform discards the app's oldest folder grant on its own, because a
  folder operation pushed the app past the platform's ceiling on how many it may
  hold.
- The user selects a folder that is a symlink, or that contains a symlink loop
  producing infinite recursion during enumeration.
- The folder contains special filesystem objects that are neither regular files
  nor directories (devices, sockets, FIFOs, macOS packages/bundles presented as
  single items) (FR-002a).
- Total entry count or total size is very large, or the resulting container would
  exceed the destination filesystem's maximum file size (FR-003a, FR-005a).

**Naming & fidelity**

- Two entries in the same directory whose names differ only by Unicode
  normalisation form or only by case, restored onto a filesystem that treats them
  as the same name.
- An entry name that is reserved or illegal on the restore platform (trailing
  dot or space, `CON`, `:`, `\`).
- A relative path whose total length exceeds the restore platform's path limit,
  even though each component was legal on the source.
- Very deep nesting that exhausts a path or recursion limit on the restore side.

**Failure & interruption**

- Destination or staging area runs out of free space, either before the
  operation starts or part-way through it (FR-029a).
- The restore destination is read-only, or the app loses its write grant
  mid-operation.
- One entry is unreadable in an otherwise healthy tree (User Story 4).
- The protected output is truncated — the tail of the data is missing.
- The output is complete and authentic but its internal description of the folder
  is inconsistent with what it actually contains.
- The user attempts to restore output produced by a *newer* version of Latch than
  the one they are running.
- The user attempts a folder restore on output that is a plain single-file
  container, or a single-file restore on folder output.

## Requirements *(mandatory)*

### Functional Requirements

**Selection**

- **FR-001**: Users MUST be able to select a single folder as the unit of
  encryption, as an alternative to the existing multi-file selection, without
  losing the ability to select files.
- **FR-002**: The system MUST include, by default, every regular file and every
  directory at every depth beneath the selected folder.
- **FR-002a**: Where an entry is neither a regular file nor a directory — a
  device node, socket, or FIFO — the system MUST skip it rather than abort, and
  MUST report every skipped entry to the user by its relative path as part of the
  operation's outcome. No skip may be silent. A directory that a platform merely
  *presents* as a single item, such as a macOS application bundle, is an ordinary
  directory for this purpose and MUST be captured in full under FR-002.
- **FR-002b**: Where the user has chosen to delete the originals after
  encryption, the deletion MUST cover only entries the container actually holds.
  Any entry skipped under FR-002a, and anything else not captured, MUST be left
  in place. The system MUST NOT delete a source it did not protect.
- **FR-003**: Before encryption begins, the system MUST show the user what was
  found — at minimum the total number of files, the number of directories, and the
  total size — so they can confirm the selection matches their intent.
- **FR-003a**: The system MUST NOT impose its own ceiling on entry count or total
  size. Where a selection is large enough that the operation will take
  substantial time, the pre-flight information of FR-003 MUST say so and indicate
  what the user should expect, and the user MUST be able to proceed. A warning is
  not a refusal.
- **FR-004**: Before encryption begins, the system MUST tell the user which
  categories of content or metadata present in the selected folder will **not** be
  preserved by a restore, and allow them to cancel.
- **FR-005**: The system MUST refuse a selection it cannot safely process —
  including a folder that contains the intended output destination, and a folder
  it cannot fully enumerate — with a specific reason, rather than proceeding with
  partial coverage.
- **FR-005a**: Limits that genuinely exist MUST be refused with a specific
  reason naming the limit, and MUST be detected before the work begins wherever
  the platform makes that possible rather than after hours of processing. These
  are the destination's own constraints, not Latch's: insufficient free space
  (FR-029a) and a container that would exceed the maximum file size the
  destination filesystem or the platform's own file-writing mechanism supports.
- **FR-006**: The system MUST detect and refuse to follow cycles during
  enumeration, so a symlink loop cannot cause unbounded work.

**Protecting a folder**

- **FR-007**: The system MUST protect the contents of every included file such
  that no plaintext file content is readable in the output without the passphrase.
- **FR-008**: The system MUST record, alongside the protected content, enough
  description of the folder to reconstruct it: the relative path of every entry,
  whether each entry is a file or a directory, and the size of each file.
- **FR-009**: The description of the folder — including all entry names and the
  tree shape — MUST be protected to the same standard as file content. Entry names
  and the tree shape MUST NOT be readable from the output without the passphrase.
- **FR-010**: The system MUST record the original name of the selected folder so a
  restore can recreate the folder under that name.
- **FR-011**: Every protected folder that exists MUST be a complete capture of
  everything in scope under FR-002 — every regular file and every directory —
  as it was read. Because any unreadable entry aborts the whole operation
  (FR-031), as does an entry that changes mid-operation (FR-031a), a partial
  capture MUST never be written, and there is therefore no "incomplete capture"
  state for a restore to surface. The special filesystem objects skipped under
  FR-002a are outside that scope rather than gaps in it, which is precisely why
  FR-002a requires each one to be reported to the user and FR-002b forbids
  deleting any of them.
- **FR-012**: A latched folder MUST produce exactly ONE protected container for
  the whole folder — never one container per file. The user hands a single file to
  a recipient, and the tree shape and entry names are concealed inside that one
  container as FR-009 requires. The consequence MUST be accepted explicitly: the
  container is a single unit of failure, so corruption of the container may cost
  the whole folder rather than one file.
- **FR-013**: The `.latch` v1 wire layout MUST NOT change in any byte. If this
  feature needs a container-level signal that cannot be expressed within v1 —
  including any use of v1's reserved flag bits — it MUST be introduced as a new
  container version, and readers MUST fail closed on versions they do not
  recognise.
- **FR-013a**: A new container version MUST be introduced through the shipped
  version machinery: one entry in the central version registry (feature 002)
  declaring that the version exists, and one strategy object (feature 003) owning
  that version's layout. This feature MUST NOT introduce a second place that
  answers "which versions exist", MUST NOT compare a version byte against a
  literal anywhere, and MUST NOT add a version gate of its own. The invariant that
  every registered version has a strategy and every strategy a registered version
  MUST continue to hold, and MUST remain enforced as a failing test rather than as
  a runtime failure on a user's file.
- **FR-013b**: What this build can *read* and what it *writes* MUST remain
  separately stated and separately movable. Registering a new version MUST make
  that version readable and MUST NOT, by that act alone, change the version
  stamped on any container the build already writes. A container that an existing
  install can open today MUST NOT become unopenable by it because a newer version
  was registered.
- **FR-013c**: A writer MUST stamp the **lowest** container version capable of
  carrying that container's payload, decided per container rather than globally.
  Concretely: a single opaque file MUST continue to be written at the version it
  is written at today, so installs predating this feature keep opening ordinary
  files; only a payload that cannot be expressed at that version — a packed
  folder — MUST be written at the new version.
- **FR-013d**: Refusing an unrecognised container version is the shipped
  registry's behaviour and MUST be inherited unchanged, not reimplemented. It is
  distinct from this feature's own new rejection, the unknown payload-kind of
  FR-020g: the first refuses a container the build cannot parse at all, before any
  key is used; the second refuses a payload shape the build does not understand,
  after authentication. Both MUST fail closed and both MUST emit zero payload
  bytes, and the user copy for each MUST be reachable through the existing
  message-mapping layer rather than by showing raw exception text.
- **FR-013e**: The existing freeze guards and the compatibility corpora committed
  by features 002 and 003 MUST keep passing **unedited** throughout this feature's
  implementation. Containers written before this feature MUST decode to identical
  results, and the same header inputs MUST encode to identical bytes. A guard that
  requires editing is evidence that v1 moved, and is a defect to revert rather
  than a test to update.
- **FR-014**: Existing single-file containers MUST continue to encrypt and decrypt
  with unchanged behaviour, and every container written before this feature MUST
  remain restorable.

**Restoring a folder**

- **FR-015**: Users MUST be able to restore a protected folder, producing a
  directory tree, in a flow recognisably parallel to the existing decrypt flow.
- **FR-016**: A restore MUST recreate every captured entry at its original
  relative path, with directories — including directories that contain no files —
  recreated even when they hold nothing.
- **FR-017**: Restored file contents MUST be byte-for-byte identical to the
  originals.
- **FR-018**: Restored entry names MUST be byte-for-byte identical to the
  originals in their recorded encoded form, wherever the destination filesystem
  permits it. Where it does not, the system MUST fail that entry with a specific
  message rather than write it under a silently altered name.
- **FR-019**: A restore MUST NOT overwrite, merge into, or delete anything that
  already exists at the destination. A colliding top-level folder name MUST be
  resolved to a new non-colliding name, and the name actually used MUST be
  reported to the user.
- **FR-020**: A folder MUST be captured by packing the tree into a single
  lossless byte stream, which is then protected as the container's payload; a
  restore MUST unpack that stream to reproduce the tree. The packing MUST be
  lossless with respect to everything in scope per FR-020a, and MUST be
  deterministic enough that restoring the same capture twice yields identical
  trees.
- **FR-020a**: In addition to relative paths, entry names, and file content, the
  packing MUST preserve and a restore MUST reproduce:
  - file modification times, to the granularity the destination filesystem
    supports;
  - the executable bit;
  - symbolic links, kept as links to their recorded targets rather than followed
    and stored as copies of their targets' content.

  Creation times, the POSIX permission set beyond the executable bit, and extended
  attributes are explicitly OUT of scope. No acceptance test MAY depend on them,
  and the product MUST NOT claim to preserve them.
- **FR-020e**: Where a destination platform cannot reproduce an in-scope metadata
  item — notably the executable bit and symbolic links inside the Android and iOS
  app sandboxes — the restore MUST still reproduce names, tree structure, and file
  content correctly, and MUST report which metadata could not be applied. It MUST
  NOT fail the entry over unappliable metadata, and it MUST NOT report unqualified
  success as though the metadata had been applied.
- **FR-020b**: A restore MUST decide how to interpret the payload based ONLY on an
  authenticated **payload-kind** value recorded in the container by the encrypt
  side. It MUST NOT infer that decision by inspecting the decrypted plaintext,
  sniffing for archive magic bytes, or reading the source file's extension. A
  single file that merely happens to be an archive — a user-supplied `.zip`,
  `.tar.gz`, or similar — MUST be protected as an opaque file and restored
  byte-for-byte identical, and MUST NOT be expanded into a tree. Conversely a
  protected folder MUST NOT be left packed as an archive for the user to unpack by
  hand. Because payload-kind is container-level metadata, FR-013 governs how it is
  introduced.
- **FR-020c**: Payload-kind MUST be covered by the container's authentication, so
  that altering it in transit is detected as tampering rather than silently
  changing how the payload is interpreted.
- **FR-020g**: Payload-kind MUST be an extensible enumerated value, not a boolean.
  Its encoding MUST leave room for kinds not yet defined, so that a future payload
  shape (for example a multi-file bundle that is not a directory tree) can be added
  without a further format-version bump.

  Exactly two kinds are defined and valid in this version:

  | Kind | Meaning |
  |------|---------|
  | Single opaque file | The payload is one file's bytes, restored byte-for-byte identical. Current v1 behaviour. |
  | Packed folder | The payload is the lossless packed stream of a directory tree, expanded on restore. |

  Every other value MUST be treated as unknown. A reader encountering an unknown
  payload-kind MUST fail closed with a message telling the user the container was
  made by a newer version of the app, and MUST NOT guess, fall back to another
  kind, or emit any payload bytes. Adding a kind MUST NOT change the meaning or
  encoding of an already-defined kind, and MUST NOT require readers that predate it
  to understand it — only to reject it safely.
- **FR-020h**: The unknown-payload-kind rejection MUST be distinguishable, in what
  the user is told, from a wrong passphrase and from a corrupt or tampered
  container. "Made by a newer version" is a different user action (update the app)
  from "wrong passphrase" (try again) and "corrupt" (the file is damaged).
- **FR-020f**: Compression is OPTIONAL and independent of packing: packing MUST be
  lossless, and whether the packed stream is also compressed is a planning
  decision. If compression is used, the threat model MUST acknowledge that
  container size then correlates with how compressible the folder's content is,
  which is a weak disclosure beyond the total-size disclosure a container already
  makes. FR-009's confidentiality requirement covers entry names and tree shape,
  not the approximate size of the whole.
- **FR-020d**: A restore MUST NOT write outside the destination root it was given,
  under any content of the packed stream. Entries whose recorded path is absolute,
  escapes the root via parent-directory traversal, or resolves outside the root
  through a symbolic link MUST be rejected as corrupt or hostile input, and the
  restore MUST fail closed rather than write the entry. This holds even though
  Latch only unpacks streams it produced itself: a container is attacker-supplied
  data by the time it is restored, and its authentication proves only that it was
  produced with the passphrase, not that its contents are benign.
- **FR-021**: A restore MUST NOT reveal any part of the restored tree at the
  user-visible destination until the restore has succeeded; incomplete output MUST
  be staged where the user cannot mistake it for a finished result and MUST be
  removed on failure, cancellation, or abnormal termination.
- **FR-022**: A wrong passphrase MUST be reported as a wrong passphrase, and MUST
  be detected before any file content is written anywhere.
- **FR-023**: Corruption or tampering MUST be reported as corruption, distinctly
  from a wrong passphrase, and MUST NOT result in any partial plaintext reachable
  by the user.
- **FR-024**: The system MUST reject output whose internal description of the
  folder is inconsistent with its actual contents, rather than restoring a tree it
  cannot vouch for.
- **FR-025**: Attempting a folder restore on single-file output, or a single-file
  decrypt on folder output, MUST produce a clear explanation of the mismatch
  rather than an unexplained failure.

**Progress, scale, and interruption**

- **FR-026**: The system MUST report progress at a granularity meaningful for both
  a folder of 3 large files and a folder of 10,000 small ones, and MUST make clear
  which entry or stage is being worked on.
- **FR-027**: Peak memory use MUST NOT grow with the number of entries in the
  folder, nor with the size of the largest file.
- **FR-028**: Users MUST be able to cancel a folder encryption or restore while it
  is running and receive a clear statement of what, if anything, was left on disk.
- **FR-029**: Cancellation, failure, or abnormal termination MUST leave no
  reachable partial plaintext and no output that a user could mistake for a
  complete, restorable result.
- **FR-030**: Heavy work MUST NOT block the user interface for the duration of the
  operation.
- **FR-029a**: Before a folder operation begins, the system MUST estimate the
  free space it requires — at the destination, and separately at any staging
  location the platform requires it to write through first — and MUST refuse to
  start when the available space is insufficient, telling the user how much is
  short and which location is short of it. Because that estimate can be
  overtaken by other activity on the device, exhausting space mid-operation MUST
  still abort under FR-029's cleanup rule and MUST be reported to the user as a
  space problem, distinct from a generic write failure.

**Partial failure**

- **FR-031**: If any discovered entry cannot be read, the entire folder operation
  MUST abort. No protected container MUST be left at the destination, all staged
  work MUST be removed, and the user MUST be told which entry caused the abort,
  identified by its relative path. Originals MUST NOT be deleted when an operation
  aborts, regardless of the user's "delete originals" choice.
- **FR-031a**: If an entry changes between being listed and being read — it no
  longer exists, its type has changed, or its size or modification time differs
  from what was recorded at listing — the operation MUST abort under FR-031's
  rules. The report MUST identify the entry by its relative path **and state the
  nature of the change** in human copy: that it disappeared, that it is now a
  different kind of entry, that it grew or shrank, or that it was modified while
  being read. Reporting only that "the folder changed" is insufficient, because
  the user cannot then tell whether their data is at risk or a background process
  merely touched an unimportant file.
- **FR-032**: The system MUST NOT produce output that presents itself as a
  complete capture of the folder when it is not. Under FR-031's abort rule this
  means no container is written at all unless every discovered in-scope entry was
  captured, and the outcome MUST disclose anything skipped under FR-002a rather
  than let the user infer that nothing was.
- **FR-033**: All per-entry failures MUST be reported to the user in human copy,
  identifying the affected entry by its relative path. Raw exception text MUST NOT
  be shown.

**Platform access**

- **FR-034**: On Android, folder selection MUST use the platform's folder-grant
  mechanism, MUST NOT require broad all-files access, and MUST explain to the user
  what is being requested before the system prompt appears.
- **FR-034a**: The grant obtained when the user selects a source folder MUST be
  the same kind of persisted folder grant the rest of the app already uses, taken
  through the same mechanism, and MUST NOT be a parallel or transient access path
  known only to this feature. Because that grant carries write access to the
  selected folder, a folder operation whose output lands beside the originals
  MUST recognise the grant it already holds and MUST NOT prompt the user a second
  time for the folder they just picked.
- **FR-035**: The system MUST NOT retain its own record of which folder maps to
  which platform grant; the platform's own record of persisted grants MUST remain
  the only source of truth. This prohibits caching a *grant*, which can outlive
  the permission it names and silently misroute an operation. It does NOT
  prohibit remembering a destination the **user chose** for a source whose folder
  the platform will not name, provided the grant's liveness is re-asked of the
  platform on every use and a revoked grant is forgotten and re-prompted — the
  behaviour already shipped for single files, which this feature inherits
  unchanged rather than re-deciding.
- **FR-035a**: Wherever the app shows the user which folders it can reach, the
  list MUST account for folders held only because they were encrypted, and MUST
  describe the access actually held rather than assuming every grant is a save
  destination. Revoking a grant MUST state what the user loses in terms that
  match how that folder is used. A folder the user has only ever encrypted MUST
  NOT be presented as a place Latch saves files.
- **FR-035b**: Because folder operations consume the same limited pool of
  persisted grants as output placement, and the platform silently discards the
  oldest grant once its ceiling is reached, this feature MUST NOT take a grant it
  does not need. In particular it MUST NOT take a second grant for a folder
  already covered by one the app holds.
- **FR-036**: On Android, restored plaintext MUST NOT pass through any shared or
  public location on its way to the destination.
- **FR-037**: Output placement for folder encryption MUST follow the same rules
  and the same user-visible fallback reporting as the existing per-file behaviour.
- **FR-037a**: Where a folder operation asks the user to choose a destination, the
  choice MUST have the same three outcomes the existing flow has — a granted
  folder, an explicitly chosen shared fallback, or cancellation — and MUST NOT
  collapse declining into choosing. Cancelling MUST abort the operation before
  anything is written, MUST leave nothing staged, MUST record no preference, and
  MUST return the user where cancelling the operation itself would. A dismissed
  prompt MUST read as cancellation, never as consent to the fallback.

**Constraints inherited from the constitution**

- **FR-038**: The feature MUST work entirely offline and MUST NOT transmit folder
  names, tree structure, file contents, or any derived data off the device.
- **FR-039**: The feature MUST NOT introduce any recovery path: no escrow, no
  recovery code, no hint, no reset, and no unlock path other than the existing
  passphrase, device-bound, and recipient wraps.
- **FR-040**: The feature MUST NOT introduce persistent state describing the
  user's folders. Latch stays stateless between operations. A stored *setting*
  such as the deletion default of FR-041a is not such state: it records a choice
  the user made about the app's behaviour, not anything about their folders,
  their contents, their names, or where they are.

**Deleting originals**

- **FR-041**: Where the user chooses to delete the originals after a folder is
  successfully protected, the default MUST be to shred each captured file using
  the same secure-delete path the app already applies to single files, and then
  to remove the now-empty directories, so that entry and directory **names** are
  destroyed along with content. Names alone can disclose as much as content, so a
  deletion that leaves the tree's structure behind is not sufficient by default.
  Subject always to FR-002b: only captured entries are deleted.
- **FR-041a**: The user MUST be able to change this default in the app's advanced
  settings, choosing between shredding and ordinary deletion. Wherever the choice
  is presented, the copy MUST state plainly what each mode does and what it does
  not guarantee — specifically that overwriting cannot be guaranteed to destroy
  the original bytes on flash storage, because wear levelling may relocate
  writes, and that ordinary deletion removes the entries without overwriting
  anything. The choice MUST NOT be posed as a question on every operation.

### Key Entities

- **Folder Selection**: The user's chosen root folder plus the enumeration of
  everything found beneath it. Holds the root's name, the entry inventory, counts,
  total size, and any entries that could not be read or will not be preserved.
- **Folder Entry**: One item in the tree. Has a relative path from the selection
  root, a kind (file, directory, or symbolic link), a size for files, and the in-scope
  metadata of FR-020a (modification time, executable bit, link target).
- **Folder Description (manifest)**: The protected record of the tree that a
  restore reads to rebuild it — the entry list, the root folder's original name,
  and the completeness flag. Confidential to the same degree as file content.
- **Protected Folder Output**: Whatever the user is handed at the end of
  encryption and selects at the start of restore. Per FR-012 this is exactly one
  container.
- **Operation Outcome**: The per-entry result set surfaced to the user: what
  succeeded, what was skipped or failed and why, whether the capture is complete,
  and where the result was written.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A folder round trip reproduces 100% of the original tree: every
  relative path present, no extra entries, and every file byte-identical —
  verified against an inventory recorded before encryption.
- **SC-002**: 100% of a fidelity fixture tree survives a round trip, where that
  fixture deliberately includes an empty directory, a directory of only empty
  directories, non-ASCII and combining-character names, emoji names, dot-prefixed
  entries, a zero-byte file, a maximum-length name, and nesting at least 10 levels
  deep.
- **SC-003**: In zero cases does a wrong passphrase or a corrupted input leave any
  restored file or directory reachable at the user's destination.
- **SC-004**: A user can select a folder and start protecting it in no more steps
  than the existing multi-file flow requires, and without needing to know how many
  files it contains.
- **SC-005**: For a folder of 10,000 files, progress advances at least once per
  1% of total work, and the interface stays responsive to input throughout.
- **SC-006**: Peak memory use for a 10,000-file, 10 GB folder is within the same
  order of magnitude as for a single 100 MB file — i.e. it does not scale with
  entry count or with the largest file's size.
- **SC-007**: Cancellation takes effect within a few seconds of the request, and a
  filesystem inspection afterwards finds zero leftover partial outputs and zero
  leftover plaintext.
- **SC-008**: When an entry cannot be read, the operation aborts; the offending
  entry is named to the user by its relative path in 100% of cases; a filesystem
  inspection afterwards finds no container and no staged remnant; and no original
  has been deleted.
- **SC-009**: Every container written before this feature still decrypts
  correctly, and the format freeze guards pass unmodified.
- **SC-010**: On Android, a folder can be selected, fully enumerated, protected,
  and restored on a device without all-files access, from each supported storage
  location, and the user is told where output landed in every case.
- **SC-011**: A user handed only the protected output and the correct passphrase
  can restore the folder on a different device with a fresh install, with no
  additional information.
- **SC-012**: Verified in both directions: a user-supplied archive file (`.zip`,
  `.tar.gz`) protected as a single file restores byte-for-byte identical and is
  never expanded into a tree, and a protected folder always restores as a tree and
  is never left as an archive for the user to unpack.
- **SC-013**: A deliberately hostile packed stream — containing an absolute path,
  a `../` traversal, and a symlink resolving outside the root — writes zero bytes
  outside the destination root and is reported as corrupt input.
- **SC-015**: A container carrying a payload-kind value that this version does not
  define is rejected with a "newer version" message, emits zero payload bytes, and
  is never confused with a wrong passphrase or a corrupt container. Verified with a
  hand-built fixture for at least one undefined kind value.
- **SC-019**: A folder encrypted on Android with output beside the originals
  prompts the user for folder access exactly **once** — the selection itself — and
  never a second time for the same folder, verified by counting prompts across a
  first and a repeat operation on the same folder.
- **SC-020**: Every folder the app holds access to appears in the app's
  folder-access settings, including one held only because it was encrypted, and
  each row states the access actually held. No row describes a folder the user has
  only encrypted as a place Latch saves files.
- **SC-021**: Declining the destination prompt during a folder operation leaves
  zero bytes written at the destination, zero staged bytes on disk, and no
  remembered preference — verified by re-running the same operation and being
  asked again.
- **SC-022**: A folder operation whose grant is revoked before it starts re-asks
  the user rather than failing obscurely or writing to the shared fallback
  unasked.
- **SC-016**: Every container version this build accepts is declared in exactly
  one place. Searching the codec for a version-byte comparison against a literal
  returns nothing outside that declaration, and removing a version's layout while
  leaving it declared (or the reverse) turns a test red before anything is built.
- **SC-017**: Protecting a single opaque file after this feature ships produces a
  container byte-identical in version stamp to one produced before it, and an
  install predating this feature opens it normally. Only a protected folder is
  refused by that older install, and it is refused with the "update the app"
  message rather than a corruption message or a crash.
- **SC-018**: Every container written before this feature restores to an identical
  result afterwards, verified by the committed compatibility corpora and freeze
  guards passing without a single edit to their expected values.
- **SC-014**: A fidelity fixture containing files with distinct known modification
  times, an executable file, and a symbolic link to another entry inside the tree
  round-trips with modification times preserved to the platform's granularity, the
  executable bit intact, and the link still a link — on every platform that
  supports each item. On platforms that do not, names, structure and content are
  still correct and the unappliable items are reported to the user.
- **SC-023**: A folder operation started with too little free space is refused
  before any work begins, with a message naming the shortfall and the location
  that is short; and a folder operation whose space is exhausted mid-run aborts,
  leaves zero partial bytes at the destination and zero in staging, and is
  reported as a space problem rather than a generic failure. Verified on a
  constrained volume for both the destination and the staging location.
- **SC-024**: A fixture tree containing a device node, a socket and a FIFO
  alongside ordinary files latches successfully; every skipped entry is named to
  the user by relative path; a macOS bundle in the same tree round-trips as a
  complete directory rather than one opaque item; and when the same operation is
  run with "delete originals" chosen, every skipped entry is still present on
  disk afterwards while the captured originals are gone.
- **SC-025**: For each mutation kind — an entry deleted, replaced by a different
  entry type, appended to, and truncated, each applied mid-operation — the
  operation aborts, no container and no staged remnant survives, no original is
  deleted, and the message names both the entry's relative path and which of
  those things happened to it.
- **SC-026**: After a successful folder encryption with "delete originals"
  chosen under the default mode, a filesystem inspection finds no original file
  content and no original directory or entry names remaining; the settings screen
  offers both modes with copy stating what each does and its limits; and changing
  the default there changes the behaviour of the next operation without the user
  being prompted during it.
- **SC-027**: No selection is refused for being large alone: a tree well beyond
  the 10,000-file and 10 GB figures used elsewhere here is accepted, warned about
  before it starts, and completes. A selection whose container would exceed the
  destination filesystem's maximum file size is refused before any work begins,
  with a message naming that limit rather than a generic failure.

## Assumptions

These are the reasonable defaults chosen where the request did not specify.
Anything here that would be expensive to get wrong is a candidate for
`/speckit-clarify`.

- **One folder at a time.** A single selected root per operation. Multi-folder
  selection and mixed file+folder selection are out of scope for the first
  iteration.
- **Hidden entries are included.** Dot-prefixed and platform-hidden files and
  folders inside the selected folder are part of the folder and are protected. The
  pre-encryption summary makes their presence visible so the user is not surprised.
- **No filtering, exclusion patterns, or size caps** in this iteration. What is in
  the folder is what gets protected.
- **No selective extraction.** Restore rebuilds the whole folder. Browsing or
  extracting a single entry without a full restore is out of scope.
- **No compression** is assumed. Adding it would be an optimisation decision, not
  a requirement of this feature.
- **No deduplication** across entries, and no attempt to detect that a folder has
  been latched before.
- **A source-folder grant is persisted, not transient.** Selecting a folder to
  encrypt takes the same persisted grant the rest of the app uses, so the folder
  stays reachable for a later operation and stays visible in the one list where
  the user can audit and revoke it. The alternative — grant access for the
  duration of one operation only — was rejected because it would put this
  feature's access outside that list.
- **The folder is expected to be stable during the operation.** Concurrent
  modification is treated as an error condition to detect and report, not a
  scenario to support.
- **Special filesystem objects** — devices, sockets, FIFOs — are not preserved.
  They are reported as unpreserved under FR-004.
- **Symlinks are never followed** (following them risks escaping the selected
  folder and duplicating unbounded data). They are preserved *as links* to their
  recorded targets per FR-020a.
- **Restore target selection reuses the existing output-placement rules**,
  including the platform-specific behaviour and the existing fallback reporting;
  no new placement concept is introduced.
- **Passphrase, stored-passphrase, device-bound, and recipient-wrap behaviour is
  unchanged.** A protected folder unlocks by the same means a protected file does.
- **Restore is expected to be same-platform in the common case.** Cross-platform
  restore must fail loudly on names it cannot write, not silently rewrite them.
- **Empty selected folder** is permitted and round-trips to an empty folder.
- **The version machinery already exists.** The central version registry and the
  per-version strategy seam shipped into `develop` ahead of this feature, so
  introducing a container version is adding a row and a strategy, not building
  the mechanism that makes versions possible. This feature is the registry's
  first real customer; if adding a version turns out to need more than those two
  additions, that is a finding about the seam, not licence to route around it.
- **Adding a payload kind never costs a version bump.** Payload-kind is
  extensible by construction (FR-020g), so a future payload shape is a new kind
  rather than a new container version. Only a change the container format itself
  cannot express justifies another version.

## Dependencies

- The existing encrypt and decrypt flows, output-placement behaviour, and
  Android folder-grant mechanism, all of which this feature extends rather than
  replaces. Three parts of that machinery changed after this spec was written and
  are depended on in their current form: the picker seeded from the source
  document (PR #66), the destination prompt's three outcomes including
  cancellation (PR #74), and the folder-access settings screen that lists and
  revokes persisted grants (PR #78). FR-034a, FR-035a, FR-035b and FR-037a rest
  on them.
- The frozen `.latch` v1 format and its freeze guards, which constrain FR-012 and
  FR-013 and must pass unmodified.
- **Feature 002 — central format-version registry** (`specs/002-format-version-registry`,
  shipped into `develop`). Supplies the single authority on which container
  versions exist, the fail-closed refusal of the rest, and the deliberate
  separation between the read boundary and the version new containers are stamped
  with. FR-013a, FR-013b and FR-013d depend on it directly.
- **Feature 003 — codec version strategies** (`specs/003-codec-version-strategies`,
  shipped into `develop`). Supplies the per-version strategy seam a new layout
  slots into, the totality invariant that catches a registered version with no
  layout, and the compatibility corpora that prove v1 did not move. FR-013a and
  FR-013e depend on it directly.
- The existing background-work model that keeps the interface responsive, which
  FR-026 to FR-030 depend on.

## Open Questions Requiring User Decision

Resolved in the 2026-08-26 clarification session (see **Clarifications** above):

1. ~~**Container shape**~~ — resolved: one container for the whole folder
   (FR-012).
2. ~~**Capture mechanism**~~ — resolved: pack into a lossless archive stream,
   protect that, unpack on restore, with the unpack decision driven by an
   authenticated in-container indicator rather than plaintext sniffing
   (FR-020, FR-020b, FR-020c).
3. ~~**Partial-failure policy**~~ — resolved: abort the whole operation and name
   the offending entry (FR-031).

4. ~~**Metadata fidelity scope**~~ — resolved: modification times, the
   executable bit, and symlinks preserved as links; creation times, full POSIX
   permissions, and extended attributes out of scope (FR-020a, FR-020e).

5. ~~**How a new container version is introduced**~~ — resolved in the 2026-09-29
   session, once features 002 and 003 shipped: one registry row plus one strategy
   object, with the read boundary and the write version moving separately, and a
   writer stamping the lowest version its payload permits (FR-013a to FR-013e).

Resolved in the 2026-09-29 edge-case session (see **Clarifications** above), all
of which were listed as edge cases that no requirement answered:

6. ~~**Running out of space**~~ — resolved: pre-flight refusal naming the
   shortfall and its location, plus safe abort if space runs out anyway
   (FR-029a).
7. ~~**Special filesystem objects**~~ — resolved: skip devices, sockets and
   FIFOs and report every skip; bundles are ordinary directories and are captured
   in full; nothing skipped is ever deleted (FR-002a, FR-002b).
8. ~~**The tree changing mid-operation**~~ — resolved: abort, naming the entry
   and what changed about it (FR-031a).
9. ~~**What "delete originals" destroys**~~ — resolved: shred contents then
   remove directories so names go too, with the mode changeable in advanced
   settings and honest copy about flash storage (FR-041, FR-041a).
10. ~~**A maximum folder size or file count**~~ — resolved: no app-imposed cap;
    warn above a threshold, refuse only genuine platform limits (FR-003a,
    FR-005a).

**No open questions remain.** The spec is ready for `/speckit-plan`. The packing
format selected there MUST be able to carry everything FR-020a puts in scope, and
the plan MUST express the container-version work as a registry row plus a strategy
object rather than as new version handling.
