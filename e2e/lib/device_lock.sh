# Device ownership for the e2e runner.
#
# One adb device can be driven by several processes at once, and nothing in adb
# or Maestro objects. The damage is silent and looks like an app defect:
#
#   - two `maestro.android` device servers on the same serial race the same
#     screen, and one of them dies with
#     `DeviceServerDiedException: … UNAVAILABLE` after a few hundred ms;
#   - `~/.maestro/tests/<YYYY-MM-DD_HHMMSS>` is keyed to the *second*, so two
#     runs started in the same second write into the same `maestro.log` and the
#     other run's commands appear inside "this" run's log.
#
# Both were observed on 2026-11-11 (see .claude/BACKLOG.md BL-035): a flow-01
# failure that read as an R8/crypto regression was a second session on the same
# device. So the runner claims the device before touching it.
#
# `mkdir` is the atomic primitive — `flock` is not standard on macOS. The lock
# directory records the owner's pid, host and process start time; a pid alone
# cannot tell a live owner from an unrelated process that inherited its number,
# so the start time is compared before a lock is called stale.

# The caller runs under `set -u`; both are read by the EXIT trap even when the
# run dies before acquiring anything.
: "${DEVICE_LOCK_DIR:=}"
: "${DEVICE_LOCK_HELD:=0}"

# Sets DEVICE_LOCK_DIR. `adb get-serialno` honours ANDROID_SERIAL, so two phones
# get two locks and can still be driven in parallel.
device_lock_path() {
  local serial
  serial=$(adb get-serialno 2>/dev/null | tr -d '\r')
  printf '%s/latch-e2e-device-%s.lock' "${TMPDIR:-/tmp}" "${serial:-unknown}"
}

# True when the recorded owner is still the process it claims to be.
lock_owner_alive() {
  local pid=$1 host=$2 started=$3
  # A lock from another machine cannot be checked here; assume it is live.
  [[ "$host" == "$(hostname)" ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 1
  [[ "$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//;s/ *$//')" == "$started" ]]
}

_lock_info() {
  if declare -F info >/dev/null; then info "$1"; else echo "  ----  $1"; fi
}

# Exit 2 (the suite's precondition code) when the device is taken. Never waits:
# a suite that silently queues on someone else's run is a suite that reports a
# duration nobody can explain.
acquire_device_lock() {
  DEVICE_LOCK_DIR=$(device_lock_path)
  if [[ ! -w "$(dirname "$DEVICE_LOCK_DIR")" ]]; then
    echo "WARNING: cannot create $DEVICE_LOCK_DIR; running without the device lock." >&2
    return 0
  fi

  local attempt pid host started
  for attempt in 1 2; do
    if mkdir "$DEVICE_LOCK_DIR" 2>/dev/null; then
      DEVICE_LOCK_HELD=1
      {
        printf 'pid=%s\n' "$$"
        printf 'host=%s\n' "$(hostname)"
        printf 'started=%s\n' "$(ps -o lstart= -p $$ 2>/dev/null | sed 's/^ *//;s/ *$//')"
      } > "$DEVICE_LOCK_DIR/owner" 2>/dev/null || true
      return 0
    fi

    pid=$(sed -n 's/^pid=//p' "$DEVICE_LOCK_DIR/owner" 2>/dev/null)
    host=$(sed -n 's/^host=//p' "$DEVICE_LOCK_DIR/owner" 2>/dev/null)
    started=$(sed -n 's/^started=//p' "$DEVICE_LOCK_DIR/owner" 2>/dev/null)

    # The winner is between `mkdir` and its first write; give it a beat rather
    # than reading a live lock as stale.
    if [[ -z "$pid" ]] && (( attempt == 1 )); then
      sleep 1
      continue
    fi

    if [[ -n "$pid" ]] && lock_owner_alive "$pid" "${host:-}" "${started:-}"; then
      echo "FAIL: another e2e run holds the device ($DEVICE_LOCK_DIR)." >&2
      echo "      owner: pid $pid on ${host:-?}${started:+ since $started}" >&2
      echo "      Two runs on one device corrupt each other's results." >&2
      echo "      Wait for it to finish. If it is truly gone, delete that" >&2
      echo "      directory and re-run." >&2
      exit 2
    fi

    _lock_info "device lock: clearing a stale lock left by pid ${pid:-?}"
    rm -rf "$DEVICE_LOCK_DIR"
  done

  echo "FAIL: could not acquire $DEVICE_LOCK_DIR (another run started concurrently)." >&2
  exit 2
}

# Only remove the directory this run created: a stale-clear that raced another
# run must not delete the next owner's lock.
release_device_lock() {
  (( DEVICE_LOCK_HELD )) || return 0
  if [[ "$(sed -n 's/^pid=//p' "$DEVICE_LOCK_DIR/owner" 2>/dev/null)" == "$$" ]]; then
    rm -rf "$DEVICE_LOCK_DIR"
  fi
  DEVICE_LOCK_HELD=0
}

# The lock only sees other runs of *this* script. A Maestro CLI started by
# something else still drives the same phone, so refuse while one is running.
# `maestro test` is the CLI form; the idle MCP server (`AppKt mcp`) must not
# count, or every editor session would block the suite forever.
require_no_foreign_maestro() {
  local line pid cmd
  while IFS= read -r line; do
    pid=${line%% *}
    cmd=${line#* }
    [[ "$pid" == "$$" ]] && continue
    [[ "$cmd" == *"maestro.cli.AppKt mcp"* ]] && continue
    [[ "$cmd" == *"maestro.cli.AppKt test"* ]] || continue
    echo "FAIL: another Maestro run is driving the device (pid $pid)." >&2
    echo "      $cmd" >&2
    echo "      Two device servers on one serial kill each other mid-run." >&2
    echo "      Wait for it to finish, then re-run." >&2
    exit 2
  done < <(ps -A -o pid=,command= 2>/dev/null)
}
