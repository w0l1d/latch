# Feature Specification: Bulk File Encryption

**Feature Branch**: `004-bulk-file-encryption`

**Created**: 2026-09-30

**Status**: Draft

**Input**: User description: "based on knowledge of current 001 feature make details a new feature that could provide encrypt in bulk by choosing a folder instead of one file and encrypt all the files within it (optional recursive) as a early solution before the 001 is shipped, give it a proper name after asking question and presenting expected and potential issues in a clear language one by one"

## What this is, and how it differs from 001

Latch today asks the user to pick files one at a time. Feature 001 (Folder
Encryption) will let the user pick a **folder** and get back **one** container
holding the whole tree — but it needs a new container format (`.latch` v2), a
packer, an unpacker, an archive-safety layer and a device-tested Android walk.
It is a large feature and it is not shipped.

**Bulk File Encryption is the small, shippable half of that convenience.** The
user picks a folder; every file inside it is encrypted, but each file becomes
**its own ordinary `.latch` container**, exactly as if the user had picked that
file by hand. Nothing about the container format changes — every file produced
is a normal, already-supported v1 container that today's Latch, and every future
Latch, can open.

The difference matters and the user must be told it plainly:

| | 001 Folder Encryption | 004 Bulk File Encryption (this feature) |
|---|---|---|
| Result | one container for the whole folder | one container per file |
| Format | new `.latch` v2 | unchanged `.latch` v1 |
| Hidden from an observer | file names, file count, per-file sizes, folder structure | **nothing** — all of it stays visible |
| Empty folders, symlinks, permissions, timestamps | preserved | not preserved |
| Cost of the passphrase step | paid once | paid once per file, unless the user opts into batch derivation |
| One bad file | aborts the whole operation | that file fails, the rest still succeed |

**This feature does not become obsolete when 001 ships.** Per-file containers
are the right answer whenever the user wants to move, share, back up or delete
individual encrypted files afterwards; a single folder container is all-or-
nothing. The two are different products and both stay.

## Clarifications

### Session 2026-10-04

- Q: Should bulk decrypt fall back to Downloads when the destination is unreachable? → A: No — cancel; plaintext never lands in a shared location (FR-040 amended, analysis finding I2).

### Session 2026-10-03

- Q: Before a bulk encryption deletes an original file, how thoroughly must the app prove the new container is good? → A: Re-open the container, decrypt it, and compare byte-for-byte against the original before deleting — paid only when the user chose deletion.
- Q: When the user bulk-decrypts a folder, how should the app decide which files are Latch containers? → A: Read the opening bytes of every candidate and select by header; a `.latch`-named file whose header disagrees is reported as skipped by name.
- Q: Should a bulk operation check there is enough free space before it starts, or just deal with running out part-way? → A: Check the destination before starting and refuse with the shortfall named; proceed when the platform cannot report free space; keep the mid-run abort as the backstop. Same rule as 001.
- Q: After a bulk decrypt succeeds, should the app offer to delete the containers it just decrypted? → A: Yes — off by default, and only for containers whose restored file has been verified against a second read of the container.
- Q: Is there an upper limit on how many files one bulk operation may contain, and what should happen at that limit? → A: No hard cap; above 10,000 files the review step warns prominently and requires a deliberate confirmation.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Encrypt every file in a folder (Priority: P1)

A user has a folder of documents. Instead of picking each file, they pick the
folder. Latch shows what it found, they enter a passphrase once, and every file
in that folder comes back as its own `.latch` container.

**Why this priority**: This is the feature. Everything else is a refinement of
it, and it delivers the whole user-visible value on its own.

**Independent Test**: Point the app at a folder of 20 mixed files, encrypt,
confirm 20 containers exist and each one decrypts to the original bytes.

**Acceptance Scenarios**:

1. **Given** a folder holding 20 files and no subfolders, **When** the user
   selects the folder and confirms, **Then** 20 containers are produced, one per
   file, each named after its source, and the originals are untouched.
2. **Given** the same folder, **When** the user reaches the review step,
   **Then** the screen states how many files were found, their total size, and
   what will be excluded — before any passphrase is requested.
3. **Given** a folder containing a file the app cannot read, **When** the
   operation runs, **Then** that one file is reported as failed with its name
   and reason, **and every other file still succeeds**.
4. **Given** a folder containing zero eligible files, **When** the user selects
   it, **Then** the app says so and does not ask for a passphrase.

---

### User Story 2 - Decrypt a folder full of containers (Priority: P1)

The same user later wants their documents back. They pick the folder of `.latch`
files and decrypt them all in one operation.

**Why this priority**: Shipping bulk encryption without bulk decryption creates
work the user cannot undo at the same speed. It is the matching half of P1, not
an enhancement.

**Independent Test**: Take the output of User Story 1, bulk-decrypt it, and
compare every file byte-for-byte with the original.

**Acceptance Scenarios**:

1. **Given** a folder of containers all made with the same passphrase, **When**
   the user bulk-decrypts it, **Then** every file is restored with its original
   name and content.
2. **Given** a folder holding both containers and unrelated files, **When** the
   user bulk-decrypts it, **Then** only the containers are attempted and the
   others are listed as skipped, not as failures.
3. **Given** a folder where one container was made with a *different*
   passphrase, **When** the user bulk-decrypts, **Then** that container is
   reported as "wrong passphrase" by name and the rest still decrypt.
4. **Given** a folder where one container is corrupt, **When** the user
   bulk-decrypts, **Then** it is reported as corrupt — distinctly from a wrong
   passphrase — and **no partial plaintext** from it is left anywhere reachable.

---

### User Story 3 - Include subfolders, only when asked (Priority: P2)

A user whose folder has subfolders turns on "Include subfolders" and gets
everything underneath, with the folder structure recreated in the output.

**Why this priority**: Valuable, but it multiplies scope, cost and blast radius,
so it must be a deliberate act. P1 has to be safe and predictable without it.

**Independent Test**: Run the same folder twice, toggle off then on, and compare
the file counts and output layout.

**Acceptance Scenarios**:

1. **Given** a folder with subfolders, **When** the toggle is **off** (the
   default), **Then** only files directly inside the chosen folder are
   processed, and the review step says how many files were left out.
2. **Given** the same folder, **When** the toggle is **on**, **Then** files at
   every depth are processed and the output recreates the same relative folder
   structure.
3. **Given** a folder containing a symbolic link to one of its own ancestors,
   **When** the toggle is on, **Then** the operation does not loop and does not
   follow the link out of the selected folder.
4. **Given** any operation, **When** it starts, **Then** the toggle is off
   again — it is chosen per operation and never silently remembered.

---

### User Story 4 - Choose speed or separation for the passphrase step (Priority: P2)

A user encrypting 2,000 files discovers the operation will take over twenty
minutes. In settings they find "Batch key derivation", read what it trades away,
and turn it on. The same operation now spends half a second on the passphrase
step instead of sixteen minutes.

**Why this priority**: Without it, a folder picker becomes an easy way to start
an operation that runs for over an hour. With it always on, the app would
silently weaken protection nobody asked it to weaken. It has to be a choice, and
an informed one.

**Independent Test**: Encrypt the same 200-file folder in each mode and compare
elapsed time; confirm both outputs decrypt with the same passphrase and with
unmodified existing readers.

**Acceptance Scenarios**:

1. **Given** the default setting, **When** a batch is encrypted, **Then** every
   container carries its own independently random salt.
2. **Given** batch derivation enabled, **When** a batch is encrypted, **Then**
   the passphrase is processed once for the batch, the operation is dramatically
   faster, and every container is still a fully valid `.latch` file that opens
   in an unmodified copy of the app.
3. **Given** the settings screen, **When** the user opens the option, **Then**
   it states in plain language what each mode does, what batch mode gives up,
   and that it affects only files encrypted from then on.
4. **Given** any bulk operation, **When** it is running, **Then** the app does
   **not** ask which mode to use — the choice lives in settings and the review
   screen only reports which mode is in effect.

---

### User Story 5 - Decide once where output goes, override when needed (Priority: P3)

A user sets their preferred destination once in settings. For one particular
job they want the output elsewhere, so they change it on the options screen for
that operation only.

**Why this priority**: Bulk operations make output placement matter far more
than single-file ones — a wrong default scatters hundreds of files. But a sane
default plus an override is a refinement of an already-working P1.

**Independent Test**: Set each default in settings, run a bulk operation without
touching options, and confirm where the files land; then override once and
confirm the setting itself did not change.

**Acceptance Scenarios**:

1. **Given** no change to settings, **When** a bulk operation runs, **Then**
   output goes to one folder the user picks, with the source folder structure
   mirrored inside it.
2. **Given** the default changed in settings to "beside the originals", **When**
   a bulk operation runs, **Then** each container is written next to its source
   file and the user is not asked again.
3. **Given** any default, **When** the user changes the destination on the
   options screen, **Then** that change applies to this operation only and the
   saved default is unchanged next time.
4. **Given** a destination already holding a file of the same name, **When**
   output is written, **Then** nothing is overwritten — the same collision
   handling the single-file flow already uses applies.

---

### Edge Cases

- **A file changes while the batch is running.** That one file fails with a
  clear reason; the batch continues. Unlike 001, one changed file cannot
  invalidate the whole operation, because the other containers are complete and
  correct in their own right.
- **A file disappears between listing and reading.** Reported as failed by name,
  not as a crash, and not as a corrupt container.
- **Something in the folder is not a regular file** — a socket, a pipe, a device
  node, a subfolder when recursion is off. Skipped, listed as skipped before the
  operation starts *and* in the result, and never counted as a failure.
- **A file is already a `.latch` container** and the user is encrypting. It is
  encrypted again like any other file (double-wrapping is legitimate), but the
  review step says how many of the selected files already look like containers,
  because doing that by accident is the likelier case.
- **The destination cannot hold the output.** The operation is refused before
  anything is written, naming the shortfall. If the platform cannot report free
  space, the operation runs instead of being blocked; should it then run out
  part-way, the files already written stay valid and the rest are reported as
  failed for lack of space, with the shortfall named — not as a generic write
  error.
- **The user cancels mid-batch.** Files already finished stay. The one in flight
  leaves nothing behind — in particular a cancelled *decrypt* must leave no
  partial plaintext anywhere the user can reach.
- **A very large single file inside the folder.** Memory use must not grow with
  it, and progress must keep moving during it rather than freezing at one
  percentage for minutes.
- **Deleting containers after a bulk decrypt, with partial success.** Only
  containers whose restored file verified are removed. A container that failed,
  was skipped, or needed a different passphrase is always kept.
- **"Delete originals" with partial success.** Only files whose containers were
  written and verified are deleted. A failed or skipped file is never deleted.
  Empty folders left behind are not removed.
- **Bulk decrypt where two containers restore to the same name** (same source
  name from different subfolders, flattened into one destination). Nothing is
  overwritten; the second is renamed or reported, never silently lost.
- **A container was renamed**, losing its `.latch` extension. Bulk decrypt still
  finds it and restores it.
- **A file is named `.latch` but is not a container.** It is listed as skipped
  by name at review and in the result, never attempted and never counted as a
  failure.
- **A file cannot be opened at all during the listing step**, so its kind cannot
  be determined. It is listed as skipped with that reason; it does not abort the
  listing.
- **Android: files in the folder come from several different storage locations.**
  The user is not marched through a separate permission prompt for each one; see
  FR-038.
- **The chosen folder holds 10,000 files.** The app must stay responsive, must
  show progress that moves, and must let the user cancel.
- **The chosen folder holds far more than 10,000 files.** The operation is not
  refused, but the review step warns and demands a deliberate confirmation
  before it can start.

## Requirements *(mandatory)*

### Selection and inspection

- **FR-001**: Users MUST be able to choose a **folder** as the input to an
  encryption operation, in addition to the existing file selection.
- **FR-002**: Users MUST be able to choose a **folder** as the input to a
  decryption operation.
- **FR-003**: The system MUST list the contents of the chosen folder and present
  a summary — number of files to process, total size, number skipped and why —
  **before** requesting a passphrase and before any file is written.
- **FR-004**: The system MUST offer an "Include subfolders" option that is
  **off by default** and MUST reset to off for every new operation.
- **FR-005**: When recursion is off, the system MUST report how many items were
  excluded because they are in subfolders, so the user is never left believing a
  folder was fully processed when it was not.
- **FR-006**: The system MUST NOT follow symbolic links out of the selected
  folder and MUST NOT loop on a link that points to one of its own ancestors.
- **FR-007**: Entries that are not regular files MUST be **skipped and
  reported**, never silently dropped and never fatal.
- **FR-008**: For decryption, the system MUST decide what is a Latch container
  by reading each candidate file's opening bytes, **not** by its name. A
  container whose name was changed MUST still be found.
- **FR-008a**: A file whose header does not identify it as a Latch container
  MUST be reported as **skipped**, not failed — including a file named `.latch`
  that is not one, which MUST be named individually in the skip report rather
  than quietly dropped, because a user who sees it in the folder will otherwise
  believe it was processed.
- **FR-008b**: This classification MUST happen during the listing step, so the
  counts shown at review (FR-003) are the counts that will actually be
  processed.
- **FR-008c**: Matching a header is a classification step, not a security
  claim. A file that looks like a container MUST still fail normally — and
  distinguishably — if it turns out to be corrupt or to need a different
  passphrase (FR-014).
- **FR-009**: The review step MUST state how many selected files already appear
  to be Latch containers when the operation is an encryption, judged by the
  same header check as FR-008 rather than by name.

### Encryption and per-file independence

- **FR-010**: Each selected file MUST produce **exactly one** container, in the
  unchanged, currently-shipped container format. No byte of the existing format
  may change for this feature (Constitution, Principle II).
- **FR-011**: A failure on one file MUST NOT abort the batch. Remaining files
  MUST still be processed.
- **FR-012**: The system MUST report a per-file outcome for every selected file:
  succeeded, failed with a specific reason, or skipped with a specific reason.
- **FR-013**: A failed file MUST leave **no partial container** behind.
- **FR-014**: Wrong passphrase and corrupt container MUST remain distinguishable
  per file in a bulk decrypt, and neither may produce partial plaintext the user
  can reach (Constitution, Principle IV).
- **FR-015**: The result screen MUST make failures impossible to miss when some
  files succeeded and others did not — a batch that is partly done MUST NOT be
  presented as simply "done".

### Key derivation modes

- **FR-016**: The system MUST support two key-derivation modes for a bulk
  operation:
  - **Separate keys per file (default)** — each container gets its own random
    salt and its own derivation.
  - **One key per batch** — the passphrase is processed once and the resulting
    key protects every file in that batch.
- **FR-017**: Separate-per-file MUST be the default and MUST stay the default
  after any update.
- **FR-018**: Batch mode MUST be reachable from advanced settings, MUST be off
  until the user turns it on, and MUST apply only to operations started
  afterwards.
- **FR-019**: The settings entry MUST explain, in plain language and without
  jargon, what each mode does and precisely what batch mode gives up (the text
  is specified in *Key derivation modes, in plain language* below).
- **FR-020**: The system MUST NOT ask the user to choose a mode during an
  operation. Security posture is configured deliberately, never under time
  pressure (mirrors the deletion-mode rule in 001).
- **FR-021**: The review step MUST state which mode is in effect for the
  operation about to run.
- **FR-022**: Containers produced in **either** mode MUST be indistinguishable
  in format and MUST open in an unmodified copy of the app, and in any future
  version, with no special handling and no marker recording which mode was used.
- **FR-023**: Batch mode MUST scope the shared key to **one operation**. Two
  separate operations with the same passphrase MUST NOT share a key.

### Throughput

- **FR-024**: The bulk encryption path MUST be optimised so that, with the
  passphrase step excluded, per-file overhead does not grow with the number of
  files in the batch: fixed setup work MUST be done once for the batch rather
  than once per file, and file contents MUST be streamed rather than held in
  memory.
- **FR-025**: Memory use MUST NOT grow with the number of files in the batch,
  nor with the size of the largest file in it.
- **FR-026**: Before starting, the system MUST show an estimate of how long the
  operation will take, computed from the measured file count and total size and
  from the key-derivation mode in effect, so that a user about to start an
  hour-long run learns it beforehand rather than discovering it at minute forty.
- **FR-026g**: There MUST be no hard limit on the number of files in one
  operation. The app MUST NOT refuse work it is able to perform.
- **FR-026h**: Above **10,000 files**, the review step MUST warn prominently and
  MUST require a deliberate confirmation distinct from the ordinary "start"
  action, so a very large selection cannot be started inattentively. Below the
  threshold, no extra confirmation is added.

### Space

- **FR-026a**: Before any file is written, the system MUST check whether the
  destination can hold what the operation will produce, and MUST refuse the
  operation when it demonstrably cannot. The refusal MUST name the shortfall in
  bytes.
- **FR-026b**: When the platform will not report free space, the operation MUST
  **proceed**. "Unknown" is not a refusal — refusing on an unanswered question
  would block operations that would have succeeded.
- **FR-026c**: Where the platform stages output somewhere other than the final
  destination, both locations MUST be checked, and a refusal MUST say which one
  is short — they are routinely different volumes.
- **FR-026d**: The requirement MUST be calculated against what the operation
  actually needs at its peak. When originals are being deleted as the batch
  proceeds, space is reclaimed along the way, and the check MUST NOT refuse an
  operation on a total that will never be occupied at once.
- **FR-026e**: A refusal MUST happen before anything is written, so there is
  nothing to clean up and no original has been touched.
- **FR-026f**: When space runs out despite the check, the remaining files MUST
  be reported as having failed **for lack of space**, with the shortfall named
  — never as a generic write error. Files already completed stay valid.

### Output placement

- **FR-027**: The default destination MUST be **one folder the user picks, with
  the source folder structure mirrored inside it**.
- **FR-028**: A setting MUST let the user change that default to one of: mirror
  into a picked folder, place each output beside its own source file, or place
  all outputs flat into a picked folder.
- **FR-029**: The user MUST be able to override the destination for a single
  operation without changing the saved default.
- **FR-030**: Output MUST NOT overwrite an existing file. The collision handling
  already used by the single-file flow applies unchanged.
- **FR-031**: When two outputs in a batch would land on the same name, the
  system MUST resolve or report the conflict; it MUST NOT let one silently
  replace the other.
- **FR-032**: The result screen MUST state where the output was written.

### Deleting the source after success

- **FR-033**: "Delete originals" MUST apply **only** to files whose container
  was written and **verified** in the sense of FR-033a. Failed and skipped files
  MUST be left alone.
- **FR-033a**: Verification means the container is re-opened, decrypted, and
  compared byte-for-byte against the source file; the original MUST NOT be
  deleted unless that comparison succeeds. Writing the container without error
  is **not** sufficient — it proves bytes reached the disk, not that the
  original can be reconstructed from them.
- **FR-033b**: This verification MUST run only when the user chose to delete the
  source. An operation that keeps it MUST NOT pay for the verification.
- **FR-033c**: A file whose verification fails MUST be reported individually by
  name, its container MUST be removed rather than left as a container the user
  may trust, and its original MUST be kept. The rest of the batch continues.
- **FR-034**: Deletion MUST iterate the list of files actually processed, never
  a fresh listing of the folder taken afterwards.
- **FR-035a**: The system MUST offer, for a bulk **decryption**, an option to
  delete each container after its contents have been restored. It MUST be
  **off by default**.
- **FR-035b**: A container MUST NOT be deleted until the restored file on disk
  has been compared against a second, independent read of that container and
  found to match. Writing the restored file without error is not sufficient,
  for the same reason it is not sufficient in FR-033a.
- **FR-035c**: A container whose restored file fails that comparison MUST be
  kept, reported individually by name, and MUST NOT be presented as
  successfully decrypted. The rest of the batch continues.
- **FR-035d**: Deleting containers MUST obey FR-033b–FR-033c in their mirrored
  form: the verification runs only when the user asked for deletion, and
  skipped or failed containers are never deleted.
- **FR-035**: Emptied folders MUST be left in place. This feature deletes files,
  not folder structure, and the user MUST be told so — the folder skeleton and
  its names remain visible after a bulk encryption with deletion.

### Android storage

- **FR-036**: Choosing a folder MUST use the platform's folder-grant mechanism,
  so one grant covers the whole folder rather than one prompt per file.
- **FR-037**: When output goes beside the originals, existing permissions the
  app already holds MUST be reused before the user is prompted for anything new.
- **FR-038**: The system MUST NOT issue a separate permission prompt for each
  source folder in a recursive run. Grants MUST be requested at the level of the
  chosen folder.
- **FR-039**: Decrypted content MUST be staged in app-private storage and moved
  to its destination only after the file succeeds (Constitution, Security &
  Platform Constraints).
- **FR-040**: Where **encrypted** output cannot be written to the intended
  destination, the existing fallback behaviour and its user-visible notice apply
  unchanged, per file rather than per batch. Where **decrypted** output cannot
  reach the intended destination, the operation MUST be cancelled before any
  plaintext is written there; restored plaintext MUST NOT fall back to a shared
  location such as Downloads (this deliberately differs from single-file
  decrypt, mirroring 001's restore rule).

### Progress, cancellation, and disclosure

- **FR-041**: Progress MUST advance during the operation and MUST reflect work
  actually completed, remaining meaningful both for a folder of 5 large files
  and for one of 10,000 small files.
- **FR-042**: The operation MUST be cancellable, and cancellation MUST take
  effect promptly rather than at the end of the batch.
- **FR-043**: On cancellation, already-completed files MUST remain valid, and
  the file in flight MUST leave nothing behind — for decryption this includes
  leaving no partial plaintext anywhere reachable.
- **FR-044**: Before the operation starts, the system MUST state plainly that
  per-file containers reveal **file names, file count and individual file
  sizes**, and that folder encryption (001) is the option that hides them. The
  user MUST NOT have to infer this from the output.
- **FR-045**: The system MUST NOT present bulk encryption as equivalent to
  folder encryption anywhere in its copy.

### Key derivation modes, in plain language

This text exists because FR-019 requires the app to explain the trade honestly.
It is the substance the settings screen must convey.

**How the passphrase becomes a key.** Latch does not use the passphrase
directly. It deliberately runs it through a slow, memory-hungry calculation
first — roughly half a second per run on a phone — mixed with a random value
called a *salt* that is stored in the container. The slowness is the point: it
is what makes guessing passphrases expensive for an attacker.

**Separate keys per file (the default).** Every file gets its own random salt,
so that half-second is paid once per file.

- **What it costs you:** time, multiplied by the number of files.

| Files | Time spent on the passphrase step alone |
|---|---|
| 10 | ~5 seconds |
| 100 | ~1 minute |
| 1,000 | ~8 minutes |
| 10,000 | ~1 hour 20 minutes |

- **What it buys you:** an attacker who wants to test one guessed passphrase
  against your files must pay that half-second **for every file separately**. To
  try a million guesses against 1,000 files costs them a thousand times what it
  costs against one file. It also means your containers are not linkable to each
  other: two containers from the same batch carry unrelated salts, so someone
  holding both cannot tell from the salts that they were made together or with
  the same passphrase.

**One key per batch.** The half-second is paid once, and the resulting key
protects every file in that one operation.

- **What it buys you:** the passphrase step stops scaling. 10,000 files cost the
  same half a second as one file. On large folders this is the difference
  between an operation you can run and one you will not.
- **What it costs you — the honest version:**
  1. **The attacker's cost stops multiplying too.** One half-second of guessing
     now tests the whole batch at once instead of a single file. The protection
     on any *individual* file is unchanged — a single file was always worth one
     derivation — but the extra difficulty that came from having many files
     disappears.
  2. **The containers in a batch become visibly related.** They share a salt, so
     anyone holding two of them can tell they were produced together with the
     same passphrase, without decrypting either.
  3. **They share a fate.** Recovering the key for one file in the batch
     recovers it for all of them. With separate keys, each file is its own
     problem to solve.

**What does *not* change either way.** Every file still gets its own
independently random encryption key and its own randomised encryption, so no two
files ever share an encryption stream — this mode affects only how the
passphrase is turned into the key that protects those per-file keys. Nothing
about the container format changes; a batch-mode container is an ordinary
container that any version of Latch opens normally. And the strength of your
passphrase matters far more than either mode.

**The recommendation.** Leave it on separate keys. Turn on batch mode when the
folder is large enough that the default is not practical, and prefer a longer
passphrase when you do.

### Key Entities

- **Bulk selection**: the chosen folder, whether subfolders are included, and
  the resulting list of files to process — fixed at the moment of review, and
  the only list any later step (including deletion) may act on.
- **Per-file outcome**: for each selected file — succeeded, failed, or skipped —
  with a specific reason and where its output went.
- **Batch summary**: counts of succeeded, failed and skipped; total bytes; the
  destination; the key-derivation mode that was used.
- **Output placement preference**: the saved default (mirror / beside / flat)
  plus the per-operation override that does not modify it.
- **Key derivation mode**: separate-per-file (default) or one-per-batch; a saved
  setting, never a mid-operation question.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A user can encrypt every file in a 50-file folder in no more
  interactions than encrypting one file, plus the folder-contents confirmation
  and the destination choice.
- **SC-002**: Every file in a bulk operation round-trips byte-for-byte: bulk
  encrypt, then bulk decrypt, produces content identical to the originals for
  100% of files, in both key-derivation modes.
- **SC-003**: Containers produced by a bulk operation open in an unmodified,
  previously released copy of the app — in both modes — with no special
  handling.
- **SC-004**: In a batch where some files fail, 100% of the non-failing files
  still produce valid containers, and every failure is named individually with
  its own reason.
- **SC-005**: With batch key derivation enabled, the time spent on the
  passphrase step is the same for 10,000 files as for 1 file.
- **SC-006**: Excluding the passphrase step, encrypting 1,000 small files takes
  no more than 1.2× the time of encrypting the same bytes as 100 files — that
  is, per-file overhead does not grow with batch size.
- **SC-007**: Peak memory during a 10,000-file, 10 GB bulk operation stays in
  the same band as a single-file operation of the same total size, growing with
  neither the file count nor the largest file.
- **SC-008**: Progress advances at least once per second throughout a
  10,000-file operation, and the interface never stops responding.
- **SC-009**: Cancellation takes effect within 3 seconds, leaves every
  already-completed file valid, and leaves zero partial output — verified by
  searching every reachable location for plaintext after cancelling a decrypt.
- **SC-010**: With "delete originals" on and some files failing, 100% of failed
  and skipped files still exist afterwards.
- **SC-010b**: No container is deleted whose restored file does not match it —
  demonstrated by damaging the restored file between writing and verification
  and confirming the container survives and the batch completes.
- **SC-010a**: No original is deleted whose container does not decrypt back to
  it byte-for-byte — demonstrated by corrupting a container between writing and
  verification and confirming that original survives, that container is gone,
  and the batch still completes.
- **SC-017**: A selection of more than 10,000 files cannot be started without a
  confirmation separate from the ordinary start action, and a selection below
  the threshold requires no extra step.
- **SC-018**: No selection is refused for being too large.
- **SC-015**: An operation aimed at a destination too small for it is refused
  before a single file is written, the message names the shortfall in bytes and
  which location is short, and nothing is left to clean up.
- **SC-016**: An operation aimed at a destination whose free space the platform
  will not report is **not** refused.
- **SC-011**: Before the passphrase is requested, the user has been shown the
  file count, the total size, the exclusions, the estimated duration, the
  destination, and the statement that names and sizes remain visible — all six.
- **SC-012**: On Android, encrypting a folder of 100 files across 5 subfolders
  requires at most one permission grant.
- **SC-012a**: In a folder holding a renamed container, a correctly named
  container, a `.latch`-named file that is not a container, and an unrelated
  file, a bulk decrypt restores exactly the two containers and names the other
  two as skipped — 0 failures.
- **SC-013**: A bulk decrypt containing one wrong-passphrase container and one
  corrupt container reports them with two different explanations, and neither
  leaves readable output behind.
- **SC-014**: Nothing in this feature changes the existing format: the format
  freeze checks pass untouched before and after it ships.

## Assumptions

- Per-file containers are the intended result, not a compromise to be hidden.
  The privacy difference from 001 is disclosed rather than designed away.
- The feature reuses the app's existing multi-file processing, per-file outcome
  reporting, output resolution and storage-permission machinery; it adds folder
  selection, folder listing, the two placement preferences and the derivation
  mode on top of them, rather than introducing a parallel path.
- "One key per batch" is understood to mean sharing the value derived from the
  passphrase across the files of a single operation. Each file keeps its own
  independently random encryption key and its own randomisation; no encryption
  stream is ever reused. This produces ordinary containers and needs no format
  change.
- The half-second-per-file figure is the current mid-range-phone cost of the
  app's existing passphrase settings. If those settings change, the numbers in
  the explanatory text change with them; the trade does not.
- Bulk decrypt places restored content according to the same destination rules
  as bulk encrypt, and keeps the platform behaviour the single-file decrypt flow
  already has, including its existing fallback notice.
- Verified deletion roughly doubles the I/O for files whose originals are being
  removed. This is accepted deliberately: deletion is the one irreversible act
  in the feature, Latch has no recovery path, and the cost falls only on users
  who asked for it.
- Identifying containers by header costs one small read per candidate file
  during listing. At the scales this feature targets that is accepted as part of
  the listing step rather than treated as a separate cost.
- Recursion depth is not artificially capped; the practical limits are the
  file count and the total size, both of which the review step shows, with a
  deliberate confirmation required past 10,000 files.
- Files are processed one at a time. Processing several at once is a possible
  later optimisation, out of scope here, and would need its own answer for
  progress reporting and memory.

## Out of Scope

- Any change to the container format, including anything from 001's `.latch` v2.
- Securely overwriting (shredding) deleted files. Both deletion options here
  remove files the same way the existing single-file flow does; the app's
  separate secure-delete feature remains the way to overwrite.
- Packing several files into one container — that is 001, and this feature must
  not partially reimplement it.
- Preserving timestamps, permission bits, symbolic links or empty folders.
  Per-file containers carry file contents; they do not carry folder metadata.
- Compression.
- Encrypting file names. The names remain visible; FR-044 requires saying so.
- Watching a folder, scheduling, or re-encrypting automatically when files
  change.
- Processing files in parallel.
