#!/usr/bin/env bash
# Regression tests for lib/root_label.py — the one piece of the suite whose
# failure mode is a *misleading* pass/fail rather than a crash.
#
# This exists because the suite already failed this way once. `open_fixtures`
# waited for "Internal storage", which is the string AOSP uses and this
# Samsung does not: the label there is "Walid's A54 backup". The suite reported
# a selector timeout, which reads exactly like a broken picker, and the actual
# cause — a hard-coded name for something the platform lets the OEM rename —
# only surfaced after dumping the drawer by hand.
#
# So the label is now read off the device, and reading it is tested here.
# No device needed: the two interesting dumps are *real* uiautomator output
# (trimmed to the roots_list subtree) captured from the two picker modes on the
# Samsung, so the fixtures cannot drift into testing an assumption.
#
#   ./e2e/lib/root_label_test.sh
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$HERE/common.sh"

PARSER="$HERE/root_label.py"
DATA="$HERE/testdata"

# Without this, every "must be refused" case below would pass for the wrong
# reason: a missing interpreter exits non-zero too, and the suite would report
# five green checks while the parser never ran.
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not on PATH; cannot exercise the drawer parser" >&2
  exit 2
fi

run_parser() {
  # -I: the dump is device output; keep it out of module resolution.
  python3 -I "$PARSER" "$1" 2>/dev/null
}

# 1. The real folder-picker drawer. The label is device-named, not AOSP's —
#    this is the exact case the old hard-coded selector got wrong.
label=$(run_parser "$DATA/tree-drawer.xml")
if [[ "$label" == "Walid's A54 backup" ]]; then
  pass "folder-picker drawer: reads the OEM volume name ($label)"
else
  fail "folder-picker drawer: expected \"Walid's A54 backup\", got \"$label\""
fi

# 2. The real document-picker drawer. Its first row is "Recent", a shortcut —
#    tapping it as a volume would route the flow through the wrong provider and
#    produce a plausible-looking but wrong document id. Must be refused.
if run_parser "$DATA/document-drawer.xml" >/dev/null; then
  fail "document-picker drawer: accepted \"Recent\" as a volume label"
else
  pass "document-picker drawer: refused (shortcut row, not a volume)"
fi

# 3. Drawer open, nothing listed yet. Refusing is the only safe answer: the
#    alternative is passing an empty string into a tapOn.
if run_parser "$DATA/empty-drawer.xml" >/dev/null; then
  fail "empty drawer: produced a label from an empty roots_list"
else
  pass "empty drawer: refused (no titled row)"
fi

# 4. A DTD is never part of a dump.
if run_parser "$DATA/dtd-drawer.xml" >/dev/null; then
  fail "DTD-bearing dump: parsed anyway"
else
  pass "DTD-bearing dump: refused before parsing"
fi

# 5. A missing file must fail the same way, not raise a traceback into the
#    caller's log where run.sh would read it as an unexplained crash.
if run_parser "$DATA/does-not-exist.xml" >/dev/null; then
  fail "missing file: produced a label"
else
  pass "missing file: refused"
fi

echo
if (( FAILED == 0 )); then
  echo "root_label: all checks passed"
else
  echo "root_label: $FAILED check(s) failed"
fi
exit "$FAILED"
