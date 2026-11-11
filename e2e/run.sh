#!/usr/bin/env bash
# Latch on-device UI suite (layer 3).
#
# Runs the Maestro flows against an installed build, then checks the phone's
# filesystem for what the flows cannot see. A flow only knows what the screen
# said; whether a real v1 container landed on disk, whether "keep originals"
# really kept them, and whether a wrong passphrase wrote plaintext before
# failing are facts about files, so they are asserted in `e2e/asserts/`.
#
#   ./e2e/run.sh                    # everything, from a clean fixture folder
#   ./e2e/run.sh --only 01 03       # just those flows (by numeric prefix)
#   ./e2e/run.sh --keep-state       # don't `pm clear` between flows
#   ./e2e/run.sh --no-fixtures      # reuse what is already on the device
#   ./e2e/run.sh --no-detect        # don't probe the picker for the volume name
#
# INTERNAL_ROOT="..." overrides the detected internal-storage label and implies
# --no-detect; the label is OEM-specific, so it is read off the device otherwise.
#
# The run claims the device before touching it (`lib/device_lock.sh`) and exits 2
# if another e2e run, or any other Maestro `test`, already holds it: two runs on
# one phone corrupt each other's results in ways that read as app defects.
#
# Exit status is the number of failed checks (0 = green).
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Noted before common.sh assigns INTERNAL_ROOT its default, so an explicit
# `INTERNAL_ROOT=... ./e2e/run.sh` (or an inherited env) skips detection instead
# of being indistinguishable from the fallback.
ROOT_FROM_ENV=${INTERNAL_ROOT:+1}

# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/fixtures.sh
source "$HERE/lib/fixtures.sh"
# shellcheck source=lib/verify.sh
source "$HERE/lib/verify.sh"
# shellcheck source=lib/device_lock.sh
source "$HERE/lib/device_lock.sh"

ONLY=()
KEEP_STATE=0
PUSH_FIXTURES=1
DETECT_ROOT=1

while (( $# )); do
  case "$1" in
    --only)         shift; while (( $# )) && [[ "$1" != --* ]]; do ONLY+=("$1"); shift; done ;;
    --keep-state)   KEEP_STATE=1; shift ;;
    --no-fixtures)  PUSH_FIXTURES=0; shift ;;
    --no-detect)    DETECT_ROOT=0; shift ;;
    -h|--help)      sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/latch-e2e.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# The flows are written for a portrait phone, and rotation is device state this
# suite does not otherwise control: `accelerometer_rotation` is on by default
# and the owner picks the phone up. In landscape the picker's drawer fits five
# roots instead of six (Downloads is the sixth), and the passphrase screen's
# Continue button goes under a split keyboard — both surface as selector
# failures that read like app defects. Pin portrait for the run and put the
# owner's settings back on exit.
# Where the owner's real orientation lives while this run has it pinned.
ROT_MARKER="${TMPDIR:-/tmp}/latch-e2e-rotation.orig"
# Set only once the pin has actually been written. Without it, a run that dies
# before pinning (no device, locked phone, `require_device` exit 2) would warn
# about failing to undo a change it never made — and the banner is the one
# signal that something really is wrong on the phone.
ROTATION_PINNED=0
restore_rotation() {
  (( ROTATION_PINNED )) || return 0
  local ok=1
  adb shell settings put system user_rotation "${ORIG_USER_ROT:-0}" >/dev/null 2>&1 || ok=0
  adb shell settings put system accelerometer_rotation "${ORIG_ACCEL_ROT:-1}" \
    >/dev/null 2>&1 || ok=0
  # These writes land on the owner's phone, so a failure has to be said out loud
  # rather than swallowed: if the device dropped off adb during the run, it is
  # still pinned to portrait and nothing else will ever put it back.
  #
  # The marker goes only when both writes landed. Deleting it after a failed
  # restore would be worse than never having written it: the next run would read
  # the pinned 0s as the owner's settings, record them as the originals, and
  # "restore" them forever.
  if (( ok )); then
    rm -f "$ROT_MARKER"
  else
    echo "WARNING: could not restore auto-rotation on the device." >&2
    echo "         Put it back once adb reconnects:" >&2
    echo "           adb shell settings put system accelerometer_rotation ${ORIG_ACCEL_ROT:-1}" >&2
    echo "           adb shell settings put system user_rotation ${ORIG_USER_ROT:-0}" >&2
    echo "         (next run will retry from $ROT_MARKER)" >&2
  fi
}

# A run stopped by a process-group kill skips every trap, so the phone can still
# be pinned when the next one starts — and `settings get` would then report this
# suite's 0s as if they were the owner's. The marker is the only surviving record
# of what they actually were: restore from it before reading the device at all.
recover_rotation() {
  [[ -f "$ROT_MARKER" ]] || return 0
  local accel user
  read -r accel user < "$ROT_MARKER" || true
  if [[ -z "${accel:-}" ]]; then
    echo "WARNING: $ROT_MARKER is empty; not guessing the orientation." >&2
    echo "         Delete it if the phone's auto-rotation is already correct." >&2
    return 0
  fi
  if adb shell settings put system user_rotation "${user:-0}" >/dev/null 2>&1 \
     && adb shell settings put system accelerometer_rotation "$accel" >/dev/null 2>&1; then
    rm -f "$ROT_MARKER"
    info "orientation: undid the pin a previous aborted run left behind"
  else
    echo "WARNING: could not restore the orientation a previous run left pinned." >&2
    echo "         Put it back once adb reconnects:" >&2
    echo "           adb shell settings put system accelerometer_rotation $accel" >&2
    echo "           adb shell settings put system user_rotation ${user:-0}" >&2
  fi
}
trap 'release_device_lock; restore_rotation; rm -rf "$WORK"' EXIT
# An EXIT trap does NOT run when bash is killed by an untrapped signal. Without
# these, Ctrl-C or a SIGTERM from a supervising process skips the cleanup above
# and leaves the owner's phone pinned to portrait with no warning printed.
# Turning the signals into a normal exit is what makes the EXIT trap a promise.
trap 'exit 130' INT
trap 'exit 143' TERM HUP

selected() {
  (( ${#ONLY[@]} == 0 )) && return 0
  local want
  for want in "${ONLY[@]}"; do
    [[ "$(basename "$1")" == "$want"* ]] && return 0
  done
  return 1
}

echo "=============================================================="
echo " Latch e2e · device UI suite"
echo " package : $APP_ID"
echo " fixtures: $DEV_DIR"
echo " workdir : $WORK"
echo "=============================================================="

require_device

# Claim the phone before anything reads or writes device state. `recover_rotation`
# and the portrait pin below both `settings put`, so a second run must be stopped
# here, not after it has already changed the owner's orientation.
acquire_device_lock
require_no_foreign_maestro

# Order matters: undo a previous run's leftover pin *before* reading the current
# values. Reading first would record the suite's own 0s as the owner's settings
# and then faithfully restore those on exit.
recover_rotation
ORIG_ACCEL_ROT=$(adb shell settings get system accelerometer_rotation 2>/dev/null | tr -d '\r')
ORIG_USER_ROT=$(adb shell settings get system user_rotation 2>/dev/null | tr -d '\r')

require_unlocked
require_no_foreign_window "before the run"

# See the trap above: the flows assume portrait. Both writes have to land for
# the pin to mean anything, so the flag is set only when they do.
#
# The marker is written first, for the kill that lands between the two `put`s:
# the flag is still 0 then, so nothing would restore anything, and only the
# marker tells the next run what to undo. A marker that cannot be written costs
# the self-healing, not the pin — say so rather than refusing to run landscape.
if ! printf '%s %s\n' "$ORIG_ACCEL_ROT" "$ORIG_USER_ROT" > "$ROT_MARKER" 2>/dev/null; then
  echo "WARNING: could not write $ROT_MARKER; an aborted run will not self-heal." >&2
fi
if adb shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 \
   && adb shell settings put system user_rotation 0 >/dev/null 2>&1; then
  ROTATION_PINNED=1
  info "orientation: pinned to portrait for the run (restored on exit)"
else
  echo "WARNING: could not pin the orientation; the picker and the passphrase" >&2
  echo "         screen behave differently on a phone held sideways." >&2
fi
sleep 1

if ! command -v maestro >/dev/null 2>&1; then
  echo "FAIL: maestro is not on PATH (https://maestro.dev)" >&2
  exit 2
fi
echo "maestro: $(maestro --version 2>/dev/null | tail -n1)"

if ! adb shell pm path "$APP_ID" >/dev/null 2>&1; then
  echo "FAIL: $APP_ID is not installed on the device." >&2
  echo "      Build one with: flutter build apk --debug --android-project-arg devBuild=true" >&2
  exit 2
fi
echo "installed: $(adb shell dumpsys package "$APP_ID" | grep -m1 versionName | tr -d '\r ' | cut -d= -f2)"

if (( PUSH_FIXTURES )); then
  echo
  echo "-- fixtures --"
  build_fixtures "$WORK/fixtures" || { echo "FAIL: fixture build"; exit 2; }
  push_fixtures "$WORK/fixtures"  || { echo "FAIL: fixture push";  exit 2; }
  info "pushed $(find "$WORK/fixtures" -type f | wc -l | tr -d ' ') files"
fi
clean_outputs

require_build_with_ids

# The picker's internal-volume row is named per device, so the flows are given
# the name this device actually shows instead of the AOSP default. Runs after
# `require_build_with_ids` because it drives the app, and before the loop so the
# cost is paid once (the result is cached per device serial).
if (( DETECT_ROOT && ! ROOT_FROM_ENV )); then
  echo
  echo "-- picker --"
  detect_internal_root
else
  echo
  info "internal volume: '$INTERNAL_ROOT' (not detected)"
fi

# Every suite-wide fixture name is declared once, in lib/common.sh, as
# `: "${NAME:=default}"`. The `-e` arguments to Maestro are built from those
# declarations rather than listed a second time here, because the two copies
# drift the moment a fixture is added — and the drift surfaces minutes into an
# on-device run as an unresolved `${NAME}` inside some flow, which is not a
# thing any error message points at.
#
# `e2e/lint-selectors.sh` checks the same invariant from the other side: every
# `${NAME}` a flow uses must be declared here or passed through a `runFlow:
# env:` block.
SUITE_VARS=$(grep -oE '^: "\$\{[A-Za-z_][A-Za-z0-9_]*:=' "$HERE/lib/common.sh" \
              | sed -E 's/^: "\$\{//; s/:=$//')
env_args=()
for v in $SUITE_VARS; do
  env_args+=(-e "$v=${!v}")
done

echo
echo "-- flows --"
for flow in "$HERE"/flows/*.yaml; do
  name=$(basename "$flow" .yaml)
  selected "$name" || continue

  echo
  echo "▶ $name"

  (( KEEP_STATE )) || reset_app

  # A phone picked up mid-run covers the picker, and every later flow becomes a
  # selector timeout that reads like a UI defect. Check before spending a flow.
  require_no_foreign_window "before $name"

  # Snapshot before the UI runs: the only honest baseline for "nothing was
  # written". Exported so the assert script can compare against it.
  E2E_SNAPSHOT="$WORK/before-${name}.txt"
  snapshot_folder > "$E2E_SNAPSHOT"
  export E2E_SNAPSHOT

  # `env_args` is derived once, above, from lib/common.sh's own declarations.
  # Maestro substitutes `${NAME}` only from names it was given, so a variable
  # that exists in common.sh and is referenced by a flow but is missing here
  # does not fall back to a default — it kills the flow on an unresolved
  # variable, one step in, looking like a selector problem.
  if maestro test "$flow" "${env_args[@]}" \
      > "$WORK/${name}.log" 2>&1
  then
    pass "flow completed"
  else
    # Name the window that was on screen. A flow that failed because another
    # app covered the picker is otherwise indistinguishable from a UI defect.
    fg=$(foreground_window)
    fail "flow failed — see $WORK/${name}.log${fg:+ (foreground: $fg)}"
    # Keep the log readable after the trap removes the workdir.
    cp "$WORK/${name}.log" "${TMPDIR:-/tmp}/latch-e2e-${name}.log" 2>/dev/null
    if [[ -n "$fg" && -f "${TMPDIR:-/tmp}/latch-e2e-${name}.log" ]]; then
      printf '\n[suite] foreground at failure: %s\n' "$fg" \
        >> "${TMPDIR:-/tmp}/latch-e2e-${name}.log"
    fi
    echo "          log copied to ${TMPDIR:-/tmp}/latch-e2e-${name}.log"
    echo "          Maestro artifacts: ~/.maestro/tests/"
    continue
  fi

  assert_script="$HERE/asserts/${name}.sh"
  if [[ -f "$assert_script" ]]; then
    # Sourced, not executed: `fail` has to reach this shell's counter, or the
    # suite would exit 0 while printing red lines.
    # shellcheck source=/dev/null
    source "$assert_script"
  else
    info "no host assertions for this flow"
  fi
done

echo
echo "=============================================================="
if (( FAILED == 0 )); then
  echo " RESULT: all checks passed"
else
  echo " RESULT: $FAILED check(s) failed"
fi
echo "=============================================================="
exit "$FAILED"
