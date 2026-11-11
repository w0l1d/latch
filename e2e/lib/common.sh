#!/usr/bin/env bash
# Shared settings for the Latch on-device UI suite.
#
# Everything here is overridable by the environment so the same suite can run
# against a different package (release vs dev) or a different fixture folder.
set -uo pipefail

: "${APP_ID:=dev.walidahdouf.latch.dev}"
: "${FIXTURE_NAME:=LatchE2E}"

# adb path form (no trailing slash). Android's `_data` column stores
# /storage/emulated/0/..., not /sdcard/..., so queries must use this spelling.
: "${DEV_DIR:=/storage/emulated/0/Download/${FIXTURE_NAME}}"

# The public Downloads root — the destination for output that could not be
# written beside its source, or that the user deliberately sent there. It is
# *outside* DEV_DIR, so the before/after fixture snapshot cannot see it: the
# assertions that care about it (and the cleanup) have to name it explicitly.
: "${DOWNLOADS_DIR:=/storage/emulated/0/Download}"

# Stable strings the flows type. Kept here so a copy change is one edit.
: "${PASS:=latch e2e passphrase}"
: "${WRONG_PASS:=definitely not the passphrase}"

# Name of the file the single-file scenarios operate on, and the container the
# encrypt flow is expected to produce from it.
: "${FILE:=alpha.txt}"
: "${CONTAINER:=${FILE}.latch}"

# 04 locks two files in one batch. Both are dedicated to it, so its "2 files
# locked" assertion is not disturbed by containers other flows wrote. The second
# name is deliberately non-ASCII and spaced: it exercises how the picker and the
# container header carry a name that is not ASCII.
: "${FILE2:=gamma.csv}"
: "${FILE3:=unicode café ☐.txt}"

# 06 is the only flow that chooses "delete originals". It must own its victim:
# if any other flow locked beta.md first, "exactly one new file" would fail and
# the deletion assertion would prove nothing.
: "${SACRIFICE:=beta.md}"

# Fixtures whose output does NOT land in the fixture folder. One dedicated name
# per flow is not fussiness: the Downloads-root assertions are exact ("exactly
# one container for this name"), so two flows sharing a fixture would see each
# other's output and neither could assert cleanly. The `dl-` prefix is reserved
# for these, which is what makes cleaning Downloads back up safe.
: "${DL_FILE:=dl-fallback.txt}"          # 08 · unresolvable → Use Downloads
: "${DL_CANCEL_FILE:=dl-cancel.txt}"     # 09 · unresolvable → Cancel
: "${DL_CHOOSE_FILE:=dl-downloads.txt}"  # 11 · rationale Cancel → Use Downloads
: "${DL_A:=dl-remember-a.txt}"           # 13 · remembered destination, batch 1
: "${DL_B:=dl-remember-b.txt}"           # 13 · remembered destination, batch 2

# 10 and 14 are pure negative scenarios: their file must never produce output.
: "${CANCEL_FILE:=cancel-probe.txt}"

# 12 declines the picker the rationale opened and recovers through "Choose
# folder" — its own file, so the assertion is "output landed here" for exactly
# one container.
: "${CHOOSE_FILE:=choose-probe.txt}"

# 15 puts two files from *different* folders in one batch: a top-level fixture
# and one inside `bulk/`, which the LatchE2E grant already covers as an
# ancestor. That is the branch `existingTreeGrantFor` exists for.
#
# The folder is `BULK_SUBDIR`, not `SUBDIR`, on purpose. Suite variables are
# handed to maestro as `-e NAME=value`, so a short name here becomes an ambient
# value inside *every* flow — and `SUBDIR` was the name `pick_file.yaml` used for
# its own parameter. Once that subflow lost its defaults (see the note there),
# a caller that forgot to pass a subfolder would have silently inherited `bulk`
# and descended. Keeping the suite's name distinct from every subflow parameter
# is what makes forgetting fail loudly instead.
: "${TWO_A:=two-a.txt}"
: "${BULK_FILE:=root.txt}"
: "${BULK_SUBDIR:=bulk}"

# 17 picks an output folder on the options screen instead of answering a
# prompt at lock time (`explicitTreeUri`). The chosen folder is `bulk/`, one
# level below the source, so "beside the original" and "in the chosen folder"
# are different, checkable locations.
: "${EXP_DST:=explicit-dst.txt}"

# ── the internal-storage volume's label ────────────────────────────────────
#
# open_fixtures.yaml taps the internal volume in the picker's drawer, and that
# row has no stable name. "Internal storage" is only AOSP's *default*: OEMs
# name the volume after the device, and this Samsung calls an SM-A546B
# "Walid's A54 backup". Waiting for the AOSP string on hardware that renamed it
# produces a selector timeout that reads like a broken picker — which is exactly
# what the first end-to-end run did.
#
# The label cannot be read over adb (a `content query` on the documents
# provider is refused for uid 2000, and DocumentsUI is not exported so `am
# start` cannot reach it), so run.sh opens the picker once and reads it off the
# screen. This default is what remains when that fails, and it is also the value
# you get by setting INTERNAL_ROOT explicitly.
: "${INTERNAL_ROOT:=Internal storage}"


# 05 locks a folder. It owns one so the run cannot race the single-file flows:
# a bulk lock over the fixture root would leave a container beside every source
# they assert about. `sub/` holds a file the default (non-recursive) scan must
# leave alone.
: "${BULK_DIR:=bulk-dir}"

# 18 locks a folder with "delete originals" and then unlocks the result, so it
# needs a folder nothing else writes to: it ends with containers beside restored
# plaintext, a state every other before/after assertion would read as damage.
: "${BULK_DEC_DIR:=bulk-dec}"

# 20 repicks the source folder mid-screen: choosing a second folder must replace
# the scan, and backing out of the picker must leave it alone. Two dedicated
# folders with *different* counts are what makes that checkable — with equal
# counts, "the summary still says 2 files" would pass whether or not anything
# had changed underneath.
: "${REPICK_A:=repick-a}"   # 2 files — chosen first
: "${REPICK_B:=repick-b}"   # 4 files — chosen instead

# 21 is the same repick question on the *decrypt* side, which is a separate
# screen with its own copy of `_choose` — so it can regress independently and
# gets its own folders and its own counts (2 and 3 containers).
: "${DEC_REPICK_A:=dec-repick-a}"   # 2 containers — chosen first
: "${DEC_REPICK_B:=dec-repick-b}"   # 3 containers — chosen instead

repo_root() { cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd; }

require_device() {
  if ! adb get-state >/dev/null 2>&1; then
    echo "FAIL: no device. Connect one and re-run (adb devices)." >&2
    exit 2
  fi
}

# A locked phone turns every flow into a selector timeout, and the first thing
# that breaks is `require_build_with_ids` — which then blames the build. Check
# the precondition the suite cannot satisfy itself, before anything runs.
#
# Only a *secure* keyguard blocks this: a swipe-only lock can be dismissed with
# `wm dismiss-keyguard`, and a device without a lock is already usable. When the
# policy cannot be read at all, the run continues rather than inventing a
# failure — an OEM that renames the field should cost a confusing failure, not
# a suite that refuses to start.
require_unlocked() {
  local policy
  policy=$(adb shell dumpsys window policy 2>/dev/null | tr -d '\r')
  if [[ -z "$policy" ]]; then
    info "could not read the keyguard state; continuing"
    return 0
  fi
  local showing secure
  showing=$(grep -c '^[[:space:]]*showing=true' <<<"$policy" || true)
  secure=$(grep -c '^[[:space:]]*secure=true' <<<"$policy" || true)
  if [[ "$showing" != "0" && "$secure" != "0" ]]; then
    echo "FAIL: the phone is locked with a secure keyguard." >&2
    echo "      Unlock it on the device, then re-run." >&2
    exit 2
  fi
}

# ── foreign-window guard ───────────────────────────────────────────────────
#
# The phone belongs to someone. A Telegram chat opened in a Samsung pop-up
# view, an expanded notification shade, or any app brought to the front while
# a run is in progress covers the picker: DocumentsUI drops out of the
# accessibility tree and the flow fails at the next selector, which reads
# exactly like an app defect. On 2026-11-05 that produced three "flakes" in a
# five-run batch — all one Telegram pop-up window left open on the device.
#
# The suite cannot stop the phone being used, so it checks who owns the screen
# instead of guessing afterwards. Only the *focused* window counts:
# `dumpsys window windows` also lists windows from apps that are not on screen
# (Settings, the clock, the launcher's edge panel), so scanning that list
# refuses to run on a perfectly idle phone.

# stdin: `dumpsys window` output. Prints "pkg/activity", or nothing when no
# window has focus. Kept separate from the adb call so it can be tested
# against a captured dump without a device.
focus_from_dump() {
  local focus
  focus=$(grep -m1 'mCurrentFocus=Window' \
    | sed -E 's/.*Window\{[^ ]* u[0-9]+ ([^}]+)\}.*/\1/')
  if [[ -z "$focus" ]]; then
    # mCurrentFocus=null happens during transitions; the focused *app* is the
    # honest answer there, and is what names a pop-up that has not yet taken
    # focus.
    focus=$(grep -m1 'mFocusedApp=ActivityRecord' \
      | sed -E 's/.*ActivityRecord\{[^ ]* u[0-9]+ ([^ ]+) .*/\1/')
  fi
  printf '%s\n' "$focus"
}

# Packages that may legitimately own focus at a flow boundary: the app, the
# picker the flows drive, the system permission dialog, and the launcher (a
# `pm clear` leaves the device on the home screen). `com.android.systemui` is
# deliberately absent — the shade and the keyguard are the two states we are
# here to catch.
window_is_expected() {
  case "$1" in
    "$APP_ID"|com.google.android.documentsui|com.android.permissioncontroller) return 0 ;;
    com.android.launcher3|com.google.android.apps.nexuslauncher|\
    com.sec.android.app.launcher|com.miui.home|com.huawei.android.launcher) return 0 ;;
  esac
  return 1
}

# Checked before the suite and before every flow. A foreign window is not
# transient — it stays until a human closes it — so retry briefly to let a
# just-finished gesture settle, then refuse rather than run blind.
foreground_window() {
  adb shell dumpsys window 2>/dev/null | tr -d '\r' | focus_from_dump
}

require_no_foreign_window() {
  local phase=${1:-before the run} focus pkg tries=0 dismiss_tried=0
  if [[ "${E2E_SKIP_WINDOW_GUARD:-0}" == "1" ]]; then
    info "window guard: skipped (E2E_SKIP_WINDOW_GUARD=1)"
    return 0
  fi
  while :; do
    focus=$(foreground_window)
    if [[ -z "$focus" ]]; then
      info "window guard: no focused window $phase; continuing"
      return 0
    fi
    pkg=${focus%%/*}
    window_is_expected "$pkg" && return 0
    # A swipe-only keyguard is dismissible and is not the user's doing; the
    # secure case was already refused by require_unlocked.
    if [[ "$pkg" == "com.android.systemui" && "$dismiss_tried" == "0" ]]; then
      dismiss_tried=1
      adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
      sleep 1
      continue
    fi
    (( tries >= 3 )) && break
    tries=$((tries + 1))
    sleep 1
  done
  if [[ "$pkg" == "com.android.systemui" ]]; then
    echo "FAIL: the notification shade is open $phase — $focus" >&2
    echo "      Swipe it closed on the device, then re-run." >&2
  else
    echo "FAIL: another app owns the screen $phase — $focus" >&2
    echo "      Everything behind it is invisible to the flows, so they fail at" >&2
    echo "      the next selector and look like an app bug. Close pop-up /" >&2
    echo "      split-screen windows and other apps, then re-run." >&2
  fi
  echo "      (E2E_SKIP_WINDOW_GUARD=1 bypasses this check.)" >&2
  exit 2
}

# The suite depends on Flutter `Semantics(identifier:)` values existing in the
# build under test. Rather than guess, check one known id is present.
#
# The app must be in the foreground while this runs: `uiautomator dump` reports
# the window that is actually on screen, and called before any flow that window
# is the launcher. Probing there found no Latch ids in a perfectly good build and
# warned on every run — a check that always cries wolf stops being read.
require_build_with_ids() {
  adb shell monkey -p "$APP_ID" -c android.intent.category.LAUNCHER 1 \
    >/dev/null 2>&1 || true
  # Flutter needs a moment to attach its semantics tree after the first frame.
  #
  # Poll on CONTENT, not on the dump succeeding. `uiautomator dump` exits 0 as
  # soon as it captures a frame, and on a warm start that frame is the splash —
  # right package, no semantics yet. Breaking on the first successful dump read
  # that splash as "this build has no identifiers" and printed the warning on
  # every run, while the 23 flows that followed drove `id:` selectors with no
  # misses. A probe that always cries wolf is worse than none: it teaches the
  # reader to skip the one warning that would matter.
  local tries=0 dumped=0
  local xml="${TMPDIR:-/tmp}/_latch_probe.xml"
  local probe='resource-id="home_encrypt"\|resource-id="onboarding_get_started"'
  while (( tries < 15 )); do
    sleep 1
    if adb shell uiautomator dump /sdcard/_latch_probe.xml >/dev/null 2>&1 \
       && adb pull /sdcard/_latch_probe.xml "$xml" >/dev/null 2>&1; then
      dumped=1
      grep -q "$probe" "$xml" 2>/dev/null && break
    fi
    tries=$((tries + 1))
  done
  adb shell rm -f /sdcard/_latch_probe.xml >/dev/null 2>&1
  # Leave the device as we found it: every flow starts from `pm clear` anyway,
  # but a foreground app here would race the first flow's own launchApp. Before
  # every early return, not after them — the probe launched the app itself, so
  # each of the bail-outs below would otherwise leave it on screen.
  adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  if (( ! dumped )); then
    echo "WARN: could not probe the view tree; skipping identifier check"
    return 0
  fi
  # The dump can succeed while showing something else entirely — a secure
  # keyguard, the launcher, another app. Warning "no test identifiers" in that
  # case blamed a perfectly good build for a window that never belonged to it,
  # so check the dump is the app's before reading anything into its absence.
  if ! grep -q "package=\"$APP_ID\"" "$xml" 2>/dev/null; then
    echo "WARN: could not see the app's window to probe it (locked screen or" >&2
    echo "      launch race). Skipping the identifier check; flows will fail" >&2
    echo "      loudly if the build really is missing them." >&2
    return 0
  fi
  if grep -q "$probe" "$xml" 2>/dev/null; then
    info "build exposes test identifiers (probed on the running app)"
  else
    echo "WARN: this build exposes no test identifiers. Flows will fall back to" >&2
    echo "      text selectors; rebuild with the current lib/ to get stable ids." >&2
  fi
}

# ── internal-storage volume detection ──────────────────────────────────────
#
# Reads the picker drawer's first volume row (see INTERNAL_ROOT above for why
# the name cannot be assumed). Writes the result to a per-device cache so a
# repeated run pays the ~15 s probe once, not once per flow — the label changes
# only when the phone is renamed, and the serial keying means a different device
# never inherits it.
#
# Every failure path falls back to the current INTERNAL_ROOT and returns 0. This
# is deliberately not a hard failure: a device whose picker misbehaves should
# fail in the flow that actually needs the picker, naming the selector it could
# not find, rather than abort a whole run at a pre-flight step.
internal_root_cache() {
  # `adb get-serialno` prints a bare serial; command substitution strips the
  # trailing newline. No device → "unknown", which still caches something
  # rather than writing to a path like "latch-e2e-internal-root-".
  local serial
  serial=$(adb get-serialno 2>/dev/null) || serial=""
  printf '%s/latch-e2e-internal-root-%s' "${TMPDIR:-/tmp}" "${serial:-unknown}"
}

detect_internal_root() {
  local cache dump probe
  cache=$(internal_root_cache)
  probe="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/subflows/detect_internal_root.yaml"
  dump="${TMPDIR:-/tmp}/latch-e2e-drawer.xml"

  if [[ -s "$cache" ]]; then
    INTERNAL_ROOT=$(<"$cache")
    info "internal volume: '$INTERNAL_ROOT' (remembered for this device)"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    info "internal volume: '$INTERNAL_ROOT' (python3 missing; cannot read the drawer)"
    return 0
  fi

  info "internal volume: detecting (opens the folder picker once)"
  if ! maestro test "$probe" -e APP_ID="$APP_ID" \
       >"${TMPDIR:-/tmp}/latch-e2e-detect.log" 2>&1; then
    info "internal volume: '$INTERNAL_ROOT' (probe failed; log: ${TMPDIR:-/tmp}/latch-e2e-detect.log)"
    _detect_cleanup
    return 0
  fi

  local label=""
  if adb shell uiautomator dump /sdcard/_latch_drawer.xml >/dev/null 2>&1; then
    if adb pull /sdcard/_latch_drawer.xml "$dump" >/dev/null 2>&1; then
      label=$(python3 -I "$(dirname "${BASH_SOURCE[0]}")/root_label.py" "$dump" 2>/dev/null) || label=""
    fi
    adb shell rm -f /sdcard/_latch_drawer.xml >/dev/null 2>&1 || true
  fi
  _detect_cleanup

  if [[ -n "$label" ]]; then
    INTERNAL_ROOT="$label"
    printf '%s' "$INTERNAL_ROOT" > "$cache"
    info "internal volume: '$INTERNAL_ROOT'"
  else
    # Not a silent fallback: say which string the flows will now look for, so a
    # timeout in open_fixtures.yaml is traceable to this line.
    info "internal volume: '$INTERNAL_ROOT' (drawer unreadable; using the AOSP name)"
  fi
  return 0
}

# Both the probe's success and failure paths leave a picker in the foreground.
# Stopping both packages is what makes the next step's `launchApp` deterministic:
# a leftover DocumentsUI covers the app, and a leftover app resumes into the
# picker instead of Home.
_detect_cleanup() {
  adb shell am force-stop "$APP_ID" >/dev/null 2>&1 || true
  adb shell am force-stop com.google.android.documentsui >/dev/null 2>&1 || true
}

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }
info() { printf '  ----  %s\n' "$1"; }

# Not a plain assignment: assert scripts re-source this file, and resetting the
# counter there would silently drop every earlier failure from the total.
: "${FAILED:=0}"
