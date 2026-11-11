# `e2e/` — on-device UI suite (layer 3 of 3)

Latch is tested at three levels. This folder is the outermost one.

| Layer | Where | What it can prove |
|---|---|---|
| L1 | `packages/*/test`, `test/` | Pure logic and crypto on the host. Fast, but runs against a host-built libsodium and a desktop filesystem. |
| L2 | `integration_test/` | The shipped native library, the real crypto isolate, real app-private storage — inside the installed APK, driven by Dart. |
| **L3** | **`e2e/` (this folder)** | **The app a user actually touches: DocumentsUI, SAF grants, the save-folder prompt, navigation, and the bytes that end up next to the originals.** |

L3 exists because the failure modes that reach users on Android are almost all
platform-shaped: a picker that opens somewhere unexpected, a grant that was
never persisted, an output file that landed in app cache instead of beside the
original. None of those can be seen from a unit test.

## Requirements

- A connected Android device or emulator (`adb devices`), API 30+.
- **The device unlocked.** A secure keyguard blocks UI automation; `run.sh`
  checks for it up front and stops with a clear message instead of letting
  every selector time out.
- [Maestro](https://maestro.dev) on `PATH` (`maestro --version`).
- The **dev** build installed as `dev.walidahdouf.latch.dev`:

  ```sh
  flutter build apk --debug --android-project-arg devBuild=true
  adb install -r build/app/outputs/flutter-apk/app-debug.apk
  ```

  The suite targets the `.dev` package so it never touches a real install or
  its passphrase vault. Override with `APP_ID=... ./e2e/run.sh`.

## Run

```sh
./e2e/run.sh                 # all flows, regenerating fixtures first
./e2e/run.sh --only 01 03    # just those flows (numeric prefix match)
./e2e/run.sh --keep-state    # skip `pm clear` between flows (faster, dirtier)
./e2e/run.sh --no-fixtures   # reuse the files already on the device
./e2e/run.sh --no-detect     # don't open the picker to read the volume label
```

Exit status is the number of failed checks. A failing flow's Maestro log is
copied to `$TMPDIR/latch-e2e-<flow>.log`.

**Read `RESULT:` in the log, not the shell's status, once the run is piped.**
The documented invocation ends in `| tee …`, and a pipeline's status is `tee`'s,
which is always 0 — a run with three failures reports `[exited with code 0]`.
Either grep the log for the `RESULT:` line (printed last, and the only summary
line there is) or run under `set -o pipefail`. Backlog BL-012.

**The line starts with a space** — `echo " RESULT: …"` in the summary block at the bottom of
`run.sh`, for
alignment under the indented flow output. A waiter anchored `^RESULT:` never
matches and sits there reporting "still running" after the run is long over; it
cost two of them. Anchor on `'^ RESULT:'`, or leave the anchor off entirely.

When a waiter seems stuck, the cheapest diagnosis is to count both spellings:

```sh
grep -ac '^RESULT:' log   # 0
grep -ac  'RESULT:' log   # 1  -> the anchor is wrong, not the run
```

### The internal volume's name

`open_fixtures.yaml` taps the internal volume in the picker's drawer, and that
row is named after the device, not fixed by Android: AOSP says "Internal
storage", this Samsung says "Walid's A54 backup". Waiting for the AOSP string on
hardware that renamed it produces a selector timeout that reads exactly like a
broken picker — which is what the first end-to-end run did.

The name cannot be read over adb (a `content query` on the documents provider is
refused for uid 2000, and DocumentsUI is not exported so `am start` cannot reach
it), so the suite reads it off the screen: `subflows/detect_internal_root.yaml`
opens the picker once, `lib/root_label.py` parses the drawer out of the view
tree, and the result is cached per device serial under `$TMPDIR`. A failed probe
falls back to the AOSP name and says so; it does not fail the run.

To skip the probe, or to state the label yourself:

```sh
INTERNAL_ROOT="Internal storage" ./e2e/run.sh --no-detect
INTERNAL_ROOT="Internal storage" ./e2e/run.sh      # an explicit value implies --no-detect
```

`./e2e/lib/root_label_test.sh` checks the parser against captured drawer dumps,
so a change to the drawer's markup fails there instead of as a picker timeout.

## Offline check (no device)

```sh
./e2e/lint-selectors.sh
```

Every `id:` a flow taps must still be declared in `lib/`. On-device, a renamed
widget surfaces as a selector timeout that reads like a flaky phone; here it is
one second and names the id. Identifiers reach `Semantics` through three
spellings (`identifier:`, `LatchButton`'s `semanticsId:`, and local `id:` props),
and the script accepts all three — a new widget with its own id prop has to be
added to its `DECL` pattern or a correct build gets reported as broken.

It also checks flow **variables**: every `${NAME}` a flow references must be
declared in `lib/common.sh` or passed through a `runFlow: env:` block. Maestro
substitutes only the names it was given — an undeclared one is not an empty
string, it aborts the flow on an unresolved variable, which reads like a broken
selector on the first line that uses it. `run.sh` builds its `-e` arguments from
`common.sh`'s declarations for exactly that reason, so adding a fixture variable
is a one-file edit.

It also prints the reverse: identifiers the app declares that **no flow taps**.
That list is where coverage gaps hide — a whole feature can ship with its ids
wired up and nothing exercising them, and a green suite will never say so.

## What a run does

1. Generates fixtures into a temp dir and pushes them to
   `/sdcard/Download/LatchE2E` (a dedicated folder — `push_fixtures` refuses to
   `rm -rf` anything else).
2. For each flow: `pm clear` → snapshot the fixture folder → run Maestro →
   run the matching host assertion.
3. Prints a summary and exits non-zero on any failure.

## Two kinds of assertion

The split is the point of the suite.

**Flows** (`flows/*.yaml`) drive the UI. They assert what the screen says —
"1 file locked.", "Incorrect passphrase" — and nothing more. A flow that passes
has proved the app is *navigable* and *talks* the way it should.

**Host assertions** (`asserts/*.sh`) read the phone's filesystem over `adb`.
They are the only place an on-device run proves anything about bytes:

- `assert_v1_container` — the output starts with `LATCH` + version `01`, the
  same frozen-format invariant the unit tests pin, re-checked against a file
  the *shipped binary* wrote.
- `assert_same_content` — a decrypted file hashes identically to its source.
  Round-trip fidelity, not "a file appeared".
- `assert_not_container` — decrypted output is plaintext, never a copy of the
  ciphertext.
- `assert_folder_unchanged` — a *before/after* snapshot proves a failed run
  wrote nothing. This is what makes the wrong-passphrase case a security test
  rather than a copy test: Latch fails at the DEK wrap before touching the
  body, so the folder must be byte-identical afterwards.
- `assert_no_tmp` / `assert_no_staging` — a swept `<outPath>.tmp` and a clean
  app-cache staging dir. For decrypt that temp holds **partial plaintext**, so
  a leftover is a confidentiality bug, not clutter.

## Flows

| Flow | Covers | Depends on |
|---|---|---|
| `00-onboarding` | first-run ladder, the no-recovery acknowledgement | — |
| `01-encrypt-single` | pick → passphrase → options → review → progress → success | — |
| `02-decrypt-single` | container → passphrase → success; exact-byte round trip | 01 |
| `03-wrong-passphrase` | fails fast, writes nothing, container still opens | 01 |
| `04-encrypt-multi` | two files in one batch, one of them non-ASCII | — |
| `05-lock-folder` | `ACTION_OPEN_DOCUMENT_TREE` source; one container per file; non-recursive default | — |
| `06-delete-originals` | verified delete; review screen warns first | — |
| `07-collision` | re-locking the same file never overwrites the first container | 01 |
| `08-downloads-fallback` | unresolvable source → *Use Downloads*: exactly one container lands there | — |
| `09-downloads-cancel` | unresolvable source → destination **Cancel**: nothing is written | — |
| `10-cancel-writes-nothing` | rationale decline → destination Cancel → back on review | — |
| `11-decline-then-downloads` | rationale Cancel → *Use Downloads* is a real choice, not a decline | — |
| `12-picker-backout-then-grant` | Continue → back out of the picker → *Choose folder* reopens it → grant | — |
| `13-remembered-destination` | an unresolvable source is asked once; batch 2 reuses the destination | — |
| `14-decrypt-cancel` | decrypt side of the prompt: Cancel pops back, no plaintext | 01 |
| `15-two-folders-one-grant` | an ancestor grant covers a nested source folder (`subPath`) | — |
| `16-dismiss-on-back-press` | back gesture on the destination dialog = no answer, nothing written | — |
| `17-explicit-output-folder` | a folder chosen up front (`explicitTreeUri`) is used with no prompt | — |
| `18-folder-round-trip` | lock a folder deleting the originals, then unlock it: byte-identical restore | — |
| `19-skip-cannot-bypass-warning` | "Skip" on the tutorial can never skip the no-recovery acknowledgement | — |
| `20-folder-repick` | lock side: repicking replaces the scan; backing out of the picker keeps it | — |
| `21-decrypt-folder-repick` | unlock side of the same question, on its own copy of `_choose` | — |
| `22-success-open-folder` | "Open folder" on both success screens leaves the app and returns to the same screen | — |

Dependencies are satisfied by filename order in a full run. `--only` skips that
ordering, so selecting `02` without `01` will fail — correctly, because there is
no container to decrypt.

The `08`–`17` block is the save-destination matrix. The program has three
answers to "where does output go" — a tree grant, an explicit *Use Downloads*,
or a cancellation — and each flows exercises one edge of that: which picker
entry point produced the source id, which dialog answered, and what the disk
looks like afterwards. Two of them (`13`, `15`) can only be expressed as a
single flow file: `reset_app` clears SharedPreferences *and* SAF grants between
flows, so "remembered across batches" and "covered by an ancestor grant" have
to happen without a reset in between.

## Adding a flow

1. Drop `flows/NN-name.yaml` in, starting with `runFlow: ../subflows/ensure_home.yaml`
   (conditional and idempotent, so it works whether or not onboarding ran).
2. Prefer `id:` selectors. Every one is a `Semantics(identifier:)` in `lib/`;
   text selectors break on any copy change and, for buttons wrapped in a
   labelled `Semantics`, can match a doubled string.
3. Add `asserts/NN-name.sh` and assert something a screenshot cannot tell you.
4. Use fixture names from `lib/common.sh` rather than hard-coding — `asserts/`
   reads the same variables, so a rename stays one edit. The file also reserves
   the `dl-` prefix: those are the only names the suite may delete from public
   Downloads, and the only ones a Downloads assertion looks at. Declaring the
   variable there is all that is needed: `run.sh` derives its `-e` arguments
   from the declarations, and the lint fails if a flow uses a name nobody
   declares.

## Gotchas worth knowing

- **Never rewrite a script the suite is running.** `cp` into `e2e/run.sh`
  while a run is in flight truncates the very file the interpreter is reading
  from, and the run wedges at the end of the new text with no child process and
  no error — it looks exactly like a slow flow. Install changes with `mv` (a new
  inode, so the live fd keeps the old, complete file) and wait for the run to
  finish before touching `lib/common.sh`, `lib/verify.sh` or `lib/fixtures.sh`,
  which are sourced by the running flow. Adding a *new* flow or assert file is
  safe: `run.sh` expands `flows/*.yaml` once at loop entry.
- **A subflow's own `env:` block overrides the caller's `runFlow: env:`.** It is
  not a default and it does not fall back. Maestro turns both into a
  `defineVariables` command and executes the caller's first and the file's own
  second, so the file's value is the one that survives — regardless of what the
  caller passed. That is what made `pick_file.yaml` drive the *internal* picker
  for the three flows that asked for `downloads`, and skip flow 15's descend
  into `bulk/`; renaming the keys would have shadowed the callers just the same.
  So `subflows/pick_file.yaml` deliberately has **no** `env:` block: its
  parameters (`PICK_ROOT`, `PICK_SUBDIR`) are required and every caller passes
  both. Keep parameter names distinct from the suite variables in
  `lib/common.sh` as well — those arrive as `-e NAME=value` and would otherwise
  leak in as an ambient value for any caller that forgot to pass one.
- **The phone is shared with its owner.** A pop-up view window, the notification
  shade, or any app brought to the front covers the picker: its window leaves the
  accessibility tree and the flow fails at the next selector, which reads exactly
  like an app bug. A five-run flow-08 batch on 2026-11-05 lost three runs to one
  Telegram pop-up that stayed open across all of them. So `lib/common.sh` carries
  `require_no_foreign_window`, which reads the **focused** window before the run
  and before every flow, and refuses to start while something outside the app,
  DocumentsUI, the permission dialog or the launcher owns the screen; a failed
  flow also prints its foreground window and appends it to the copied log. Only
  focus is trustworthy — `dumpsys window windows` lists stale windows from
  Settings, the clock and the launcher's edge panel on a perfectly idle phone.
  `E2E_SKIP_WINDOW_GUARD=1` bypasses the check.
- **`pm clear` resets the app, not DocumentsUI.** The system picker remembers
  its own last location independently, which is why `subflows/open_fixtures.yaml`
  always walks from "Show roots" instead of trying to detect where it already
  is, and then *asserts* it arrived by waiting for the `bulk` folder. Folder
  names are always listed in both pick modes; `.latch`-filtered pickers hide
  files, so folder anchors are the stable thing to wait on.
- **A drawer label is on screen twice, and only one of them is the drawer.**
  Every root's name also appears in the picker's breadcrumb
  (`com.google.android.documentsui:id/breadcrumb_text`) for as long as the
  picker sits somewhere under it, so `assertVisible: "Downloads"` passes with
  the drawer shut and nothing tappable on screen — the flow then dies one step
  later on `Tap on "Downloads", id: android:id/title` with *Element not found*.
  Assert and tap on `id: android:id/title` (the drawer row), never bare text.
  `subflows/tap_drawer_root.yaml` owns that rule now.
- **The drawer is scrollable, and a landscape phone fits five rows.** In the
  document picker the roots list starts with the media shortcuts — Recent,
  Images, Videos, Audio, Documents — before the volumes and Downloads, so
  Downloads is row six. `tapOn` does not scroll, and rotation is device state
  the suite does not control (`accelerometer_rotation` is on; the owner moves
  the phone). A five-run flow-08 batch on 2026-11-05 failed 5/5 with the picker
  in landscape, the `Downloads` row below the fold and the breadcrumb satisfying
  the wait. `tap_drawer_root.yaml` swipes at 15% width — inside the drawer —
  because `scrollUntilVisible` swipes the screen centre, which is the content
  grid *behind* the drawer.
  `run.sh` therefore pins `accelerometer_rotation=0` / `user_rotation=0` for the
  run and restores the owner's values on exit. **If the run ends with the phone
  off adb, the restore cannot land** — the phone stays portrait-locked and
  `run.sh` prints the exact command to undo it. (It pins the setting because
  landscape also exposes a real app defect: the passphrase screen overflows and
  hides Continue under the keyboard, backlog BL-017. Pinning is a test-side
  workaround, so landscape is currently untested.)
- **DocumentsUI spends the first `back` walking up a folder level.** One press
  does not dismiss the picker — it goes to the parent folder, leaves the picker
  open, and the app is never reached, so the flow dies several steps later on an
  assertion that names nothing about the cause. Measured depth on API 36: three
  presses from the fixture folder (folder → Download → volume root → gone).
  `subflows/back_out_of_picker.yaml` presses back only while "Show roots" is
  visible, bounded to six. The guard must be picker chrome that exists at *every*
  location: an earlier version used "Use this folder", and that stalls one press
  short — a volume root is not selectable, so DocumentsUI replaces the button
  with a disabled `USE THIS FOLDER` and "Can't use this folder". The loop read
  that as "picker gone" and the caller failed on a screen assertion while the
  hierarchy showed the picker wide open at the root. The bound matters too: the
  press after the picker closes pops one of the app's own routes, which is why it
  is a guard and not "press back six times". The caller still has to assert it
  arrived back in the app — the subflow can only prove the picker is gone, and
  "gone" is also what a crashed activity looks like.
- **`extendedWaitUntil` waits; it never scrolls.** The picker lists directories
  before files, and the fixtures folder grows as a run proceeds (every flow
  leaves containers and restored files behind), so from the third flow onward the
  target file is regularly below the fold. `subflows/pick_file.yaml` therefore
  uses `scrollUntilVisible` (DOWN, `visibilityPercentage: 50`). It is a no-op
  when the element is already on screen, so it costs nothing for the flows whose
  file happens to be at the top. The failure it replaces looked like a missing
  fixture — `"<file>" is visible` timed out while `adb shell ls` showed the file
  sitting right there on disk.
  **Its `timeout` is a swipe budget, not a wall clock**: about 4.7 s per swipe.
  The 20 s it used to carry bought five, and the fifth brought `two-a.txt` into
  view just past the deadline — with the folder larger in suite order than in
  isolation, because every earlier flow leaves containers and restored files
  behind. It is `60000` now. That is also why a `--only` re-run cannot
  reproduce the failure: `push_fixtures` wipes and re-creates the folder, so the
  growth is gone.
- **Never set `centerElement: true` on that scroll.** Centring is a
  post-condition the command has to satisfy, and the last row of the grid cannot
  be centred: the list runs out of scroll first. It then times out reporting
  `No visible element found` with the file *fully on screen* — the most
  misleading failure in this suite, and what alphabetically-last fixtures hit
  every run.
- **`is_pending=1`** — files pushed with `adb push` get a MediaStore row that is
  pending, which hides them from DocumentsUI's Downloads root. `clear_pending`
  handles it; a fixture that "isn't there" is usually this.
- **Collision names** are formed by `resolveNameCollision`, which inserts the
  counter *before* the extension: `alpha.txt` → `alpha_2.txt`, and
  `alpha.txt.latch` → `alpha.txt_2.latch`.
- **`text:` is a full-string regex**, so a fragment needs anchoring — `.*bulk.*`,
  never bare `bulk`. Maestro 2.12.1 compiles it with `IGNORE_CASE`, `MULTILINE`
  **and `DOT_MATCHES_ALL`** (`AndroidDriver.REGEX_OPTIONS`; `Filters.textMatches`
  then calls `Regex.matches`, which is what makes it full-string). So `.` *does*
  cross a newline, and one `.*` spans a multi-line merged label. This is easy to
  get wrong by reading the jar with `strings`: the Kotlin enum constant is spelled
  `DOT_MATCHES_ALL`, so searching for "DOTALL" finds nothing and looks like proof
  that the flag is off. `javap -c` shows it.
- **A `SwitchListTile` merges its title and subtitle into one accessibility
  node**, so the node's text is `"Delete originals afterwards\nEach original is
  removed only after…"` and the bare title never matches. `.*` is enough now that
  the multiline flag is established; `18-folder-round-trip.yaml` still spells it
  `'Delete originals afterwards[\s\S]*'`, which is the same thing without relying
  on the flag. It fails as `No visible element found` with the toggle plainly on
  screen, which reads exactly like a widget that was never built — check the
  hierarchy before suspecting the build.
- **A button that changes role keeps its old `resource-id` unless it is keyed**
  (fixed in `lib/shared/widgets/latch_button.dart`; `test/latch_button_semantics_test.dart`
  pins it). Flutter assigns a changed `Semantics(identifier:)` to the node but
  does not count it as a change worth re-sending (`semantics.dart`'s
  `_isDifferentFromCurrentSemanticAnnotation` omits it), so a reused node keeps
  reporting its previous id to Android. The folder screen's primary button is
  `encrypt_folder_pick` ("Choose a folder") and then `encrypt_folder_continue`
  ("Set a passphrase") at the same position; before the fix the second id was
  simply absent on device while every Dart-side check passed. If an `id:`
  assertion ever fails on a screen whose text is clearly right, suspect this
  before suspecting the build.
- **"Open folder" hands the folder to another app**, so its assertions are about
  coverage, not content: tap it and assert the Latch success screen is *gone*,
  then `back` and assert the same screen came back. Asserting a folder or file
  name there proves nothing — both success screens already print the output's
  own path and filenames, so the assertion would pass even if the intent never
  resolved. `assertNotVisible: ".*No app available.*"` names the actual failure
  when it does not resolve.
  **Getting back needs one press per level of the folder.** `ACTION_VIEW` on a
  folder opens DocumentsUI as a *stack* — volume → Download → `LatchE2E` — not as
  one screen `back` dismisses, so three presses were needed on API 36 and the
  flow's original single press left the user still inside the picker (foreground
  `FilesActivity`, which is what made it look like the app had lost the screen).
  `22-success-open-folder.yaml` sends three, each conditional on the success
  screen still being absent: a shallower stack skips the extras, and an
  unconditional extra would land on the success screen and trigger its
  `PopScope(canPop: false)` → `/home` redirect. This is the picker-stack rule
  above reached through a different entry point.
- **Flutter labels live in `accessibilityText`, not `text`**, in the hierarchy
  JSON. A parser that only reads `text` shows a Flutter window as empty — which
  is a parser bug, not a missing semantics tree.
