# Feature Specification: Folder Encryption & Faithful Restore

**Feature Branch**: `001-folder-encryption`

**Created**: 2026-08-26

**Status**: Draft

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
  written to — *while* the operation is running.
- The user selects a folder that is a symlink, or that contains a symlink loop
  producing infinite recursion during enumeration.
- The folder contains special filesystem objects that are neither regular files
  nor directories (devices, sockets, FIFOs, macOS packages/bundles presented as
  single items).
- Total entry count or total size exceeds any hard limit the platform or the app
  imposes.

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

- Destination runs out of free space part-way through encryption or restore.
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
- **FR-003**: Before encryption begins, the system MUST show the user what was
  found — at minimum the total number of files, the number of directories, and the
  total size — so they can confirm the selection matches their intent.
- **FR-004**: Before encryption begins, the system MUST tell the user which
  categories of content or metadata present in the selected folder will **not** be
  preserved by a restore, and allow them to cancel.
- **FR-005**: The system MUST refuse a selection it cannot safely process —
  including a folder that contains the intended output destination, and a folder
  it cannot fully enumerate — with a specific reason, rather than proceeding with
  partial coverage.
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
- **FR-011**: Every protected folder that exists MUST be a complete capture of the
  folder as it was read. Because any unreadable entry aborts the whole operation
  (FR-031), a partial capture MUST never be written, and there is therefore no
  "incomplete capture" state for a restore to surface.
- **FR-012**: A latched folder MUST produce exactly ONE protected container for
  the whole folder — never one container per file. The user hands a single file to
  a recipient, and the tree shape and entry names are concealed inside that one
  container as FR-009 requires. The consequence MUST be accepted explicitly: the
  container is a single unit of failure, so corruption of the container may cost
  the whole folder rather than one file.
- **FR-013**: The `.latch` v1 wire layout MUST NOT change in any byte. If this
  feature needs a container-level signal that cannot be expressed within v1 —
  including any use of v1's reserved flag bits — it MUST be introduced by bumping
  the version byte and adding a new reader, and readers MUST fail closed on
  versions they do not recognise.
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

**Partial failure**

- **FR-031**: If any discovered entry cannot be read, the entire folder operation
  MUST abort. No protected container MUST be left at the destination, all staged
  work MUST be removed, and the user MUST be told which entry caused the abort,
  identified by its relative path. Originals MUST NOT be deleted when an operation
  aborts, regardless of the user's "delete originals" choice.
- **FR-032**: The system MUST NOT produce output that presents itself as a
  complete capture of the folder when it is not. Under FR-031's abort rule this
  means no container is written at all unless every discovered entry was
  captured.
- **FR-033**: All per-entry failures MUST be reported to the user in human copy,
  identifying the affected entry by its relative path. Raw exception text MUST NOT
  be shown.

**Platform access**

- **FR-034**: On Android, folder selection MUST use the platform's folder-grant
  mechanism, MUST NOT require broad all-files access, and MUST explain to the user
  what is being requested before the system prompt appears.
- **FR-035**: The system MUST NOT retain its own record of which folder maps to
  which platform grant; the platform's own record of persisted grants MUST remain
  the only source of truth.
- **FR-036**: On Android, restored plaintext MUST NOT pass through any shared or
  public location on its way to the destination.
- **FR-037**: Output placement for folder encryption MUST follow the same rules
  and the same user-visible fallback reporting as the existing per-file behaviour.

**Constraints inherited from the constitution**

- **FR-038**: The feature MUST work entirely offline and MUST NOT transmit folder
  names, tree structure, file contents, or any derived data off the device.
- **FR-039**: The feature MUST NOT introduce any recovery path: no escrow, no
  recovery code, no hint, no reset, and no unlock path other than the existing
  passphrase, device-bound, and recipient wraps.
- **FR-040**: The feature MUST NOT introduce persistent state describing the
  user's folders. Latch stays stateless between operations.

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
- **SC-014**: A fidelity fixture containing files with distinct known modification
  times, an executable file, and a symbolic link to another entry inside the tree
  round-trips with modification times preserved to the platform's granularity, the
  executable bit intact, and the link still a link — on every platform that
  supports each item. On platforms that do not, names, structure and content are
  still correct and the unappliable items are reported to the user.

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

## Dependencies

- The existing encrypt and decrypt flows, output-placement behaviour, and
  Android folder-grant mechanism, all of which this feature extends rather than
  replaces.
- The frozen `.latch` v1 format and its freeze guards, which constrain FR-012 and
  FR-013 and must pass unmodified.
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

**No open questions remain.** The spec is ready for `/speckit-plan`. The packing
format selected there MUST be able to carry everything FR-020a puts in scope.
