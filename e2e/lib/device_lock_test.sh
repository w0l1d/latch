#!/usr/bin/env bash
# Regression tests for lib/device_lock.sh — the guard that stops two runs from
# sharing one phone.
#
# It exists because the failure it prevents already happened, and it cost a
# wrong diagnosis: on 2026-11-11 a flow-01 failure that read as an R8/crypto
# regression was a second Claude session running `maestro test` on the same
# device. Two device servers made one die with DeviceServerDiedException, and
# `~/.maestro/tests/<date>_<HHMMSS>` is keyed to the second, so both runs wrote
# one maestro.log and the other run's commands appeared inside this one's.
#
# No device needed: `adb` and `ps` are replaced by functions below. Exit is 2
# for the refusal cases because that is what run.sh must report to a caller.
#
#   ./e2e/lib/device_lock_test.sh

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/common.sh"
# shellcheck source=lib/device_lock.sh
source "$HERE/device_lock.sh"

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/latch-lock-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
export TMPDIR="$TEST_ROOT"

SERIAL="TEST-SERIAL-1"
# shellcheck disable=SC2317  # called by the sourced lib
adb() {
  case "${1:-}" in
    get-serialno) printf '%s\n' "$SERIAL" ;;
    *) return 1 ;;
  esac
}

LOCK=$(device_lock_path)
if [[ "$LOCK" != "$TEST_ROOT/latch-e2e-device-$SERIAL.lock" ]]; then
  echo "FAIL: lock path is not scoped to the serial: $LOCK" >&2
  exit 2
fi
pass "lock path is keyed by the device serial"

write_lock() { # pid host started
  mkdir -p "$LOCK"
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$1" "$2" "$3" > "$LOCK/owner"
}
my_start() { ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//;s/ *$//'; }

# 1. A fresh acquire takes the lock and records this process.
acquire_device_lock
if (( DEVICE_LOCK_HELD )) && [[ -f "$LOCK/owner" ]] \
   && grep -qx "pid=$$" "$LOCK/owner"; then
  pass "fresh acquire: lock held and owner recorded"
else
  fail "fresh acquire: lock not held as this process"
fi
release_device_lock
if [[ -e "$LOCK" ]]; then
  fail "release: lock directory survived"
else
  pass "release: lock directory removed"
fi

# 2. A live owner blocks the next run with exit 2.
sleep 30 &
OWNER=$!
write_lock "$OWNER" "$(hostname)" "$(my_start "$OWNER")"
out=$( ( acquire_device_lock ) 2>&1 ); rc=$?
if (( rc == 2 )) && [[ "$out" == *"another e2e run holds the device"* ]]; then
  pass "live owner: second run refused (exit 2)"
else
  fail "live owner: expected exit 2 and a refusal, got rc=$rc: $out"
fi
kill "$OWNER" 2>/dev/null || true
wait "$OWNER" 2>/dev/null || true
rm -rf "$LOCK"

# 3. A dead pid is a crashed run, not an owner: clear it and continue.
write_lock 999999 "$(hostname)" "$(my_start 999999)"
out=$( ( acquire_device_lock ) 2>&1 ); rc=$?
if (( rc == 0 )) && [[ "$out" == *"clearing a stale lock"* ]]; then
  pass "dead pid: stale lock cleared (exit 0)"
else
  fail "dead pid: expected a clear-and-continue, got rc=$rc: $out"
fi
rm -rf "$LOCK"

# 4. A pid can be reused. An alive pid whose start time disagrees is not the
#    owner, and treating it as one would wedge the suite until that process
#    happens to exit.
sleep 30 &
OWNER=$!
write_lock "$OWNER" "$(hostname)" "Thu Jan  1 00:00:00 1970"
out=$( ( acquire_device_lock ) 2>&1 ); rc=$?
if (( rc == 0 )) && [[ "$out" == *"clearing a stale lock"* ]]; then
  pass "reused pid: stale lock cleared (start time checked)"
else
  fail "reused pid: expected a clear-and-continue, got rc=$rc: $out"
fi
kill "$OWNER" 2>/dev/null || true
wait "$OWNER" 2>/dev/null || true
rm -rf "$LOCK"

# 5. A foreign Maestro CLI is refused: the lock only sees other runs of this
#    script, and this is the collision that actually bit.
# shellcheck disable=SC2317
ps() {
  if [[ "${1:-}" == "-A" ]]; then
    printf '%s\n' "12345 /usr/bin/java -cp lib/* maestro.cli.AppKt test /tmp/t046/flows/01.yaml"
    return 0
  fi
  command ps "$@"
}
out=$( ( require_no_foreign_maestro ) 2>&1 ); rc=$?
if (( rc == 2 )) && [[ "$out" == *"another Maestro run is driving the device"* ]]; then
  pass "foreign maestro test: refused (exit 2)"
else
  fail "foreign maestro test: expected exit 2, got rc=$rc: $out"
fi

# 6. The idle MCP server must not block: it holds no device and is present in
#    every editor session.
# shellcheck disable=SC2317
ps() {
  if [[ "${1:-}" == "-A" ]]; then
    printf '%s\n' "23456 /usr/bin/java -cp lib/* maestro.cli.AppKt mcp"
    return 0
  fi
  command ps "$@"
}
out=$( ( require_no_foreign_maestro ) 2>&1 ); rc=$?
if (( rc == 0 )); then
  pass "idle maestro mcp server: ignored"
else
  fail "idle maestro mcp server: blocked the run (rc=$rc): $out"
fi

# 7. This run's own process is never foreign.
# shellcheck disable=SC2317
ps() {
  if [[ "${1:-}" == "-A" ]]; then
    printf '%s\n' "$$ /usr/bin/java -cp lib/* maestro.cli.AppKt test /tmp/x.yaml"
    return 0
  fi
  command ps "$@"
}
out=$( ( require_no_foreign_maestro ) 2>&1 ); rc=$?
if (( rc == 0 )); then
  pass "own pid: not treated as foreign"
else
  fail "own pid: refused its own process (rc=$rc): $out"
fi

echo
if (( FAILED == 0 )); then
  echo "device_lock: all checks passed"
else
  echo "device_lock: $FAILED check(s) failed"
fi
exit "$FAILED"
