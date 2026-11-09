#!/usr/bin/env bash
# Host-side assertions about what the app actually wrote to the phone.
#
# These are deliberately *outside* the UI run: a flow can only tell you what
# the screen said. Whether the container on disk is a real v1 container, whether
# the source survived a "keep originals" run, and whether a cancelled batch left
# nothing behind are all facts about the filesystem, so they are checked here.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Absolute-path primitives. Most assertions are DEV_DIR-relative, but output
# that fell back — or that the user sent there — lands in the public Downloads
# root, so the same questions have to be askable about a path anywhere.
dev_exists_at() { adb shell "[ -e '$1' ]" >/dev/null 2>&1; }
dev_size_at()   { adb shell "stat -c %s '$1' 2>/dev/null" 2>/dev/null | tr -d '\r'; }
dev_sha_at()    { adb exec-out "sha256sum '$1' 2>/dev/null" 2>/dev/null | cut -d' ' -f1 | tr -d '\r'; }

dev_exists() { dev_exists_at "$DEV_DIR/$1"; }
dev_size()   { dev_size_at "$DEV_DIR/$1"; }

# First six bytes as uppercase hex: five magic bytes then the version byte.
# Read with exec-out so nothing is written into the user's Download folder.
dev_head() {
  adb exec-out "dd if='$DEV_DIR/$1' bs=1 count=6 2>/dev/null" 2>/dev/null \
    | xxd -p | tr -d '\n' | tr 'a-f' 'A-F'
}

# A v1 container always starts `LATCH` then 01. This is the same invariant the
# frozen-format tests pin, re-checked against bytes produced by the shipped
# binary on a real device rather than by Dart on a host.
assert_v1_container() {
  local f="$1"
  if ! dev_exists "$f"; then fail "missing container: $f"; return 1; fi
  local head; head=$(dev_head "$f")
  if [[ "$head" == "4C4154434801" ]]; then
    pass "container $f is a v1 container (LATCH + version 01)"
  else
    fail "container $f has head '$head', expected 4C4154434801"
    return 1
  fi
}

assert_exists() {
  if dev_exists "$1"; then pass "exists: $1"; else fail "missing: $1"; fi
}

assert_absent() {
  if dev_exists "$1"; then fail "should not exist: $1"; else pass "absent: $1"; fi
}

# A container must be strictly larger than its plaintext: it carries a 56+ byte
# header, the filename and the secretstream header. A same-size or smaller file
# named .latch would mean the bytes were copied, not encrypted.
assert_larger_than_source() {
  local container="$1" source="$2"
  local c s
  c=$(dev_size "$container"); s=$(dev_size "$source")
  if [[ -z "$c" || -z "$s" ]]; then fail "could not size $container / $source"; return 1; fi
  if (( c > s )); then
    pass "$container (${c}B) larger than $source (${s}B)"
  else
    fail "$container (${c}B) is not larger than $source (${s}B) — not encrypted?"
  fi
}

# Two containers made from files of the same name in different folders must not
# be byte-identical: a shared secretstream header or reused nonce would show up
# here even when both decrypt.
#
# An unreadable file hashes to nothing, and it is tempting to read "nothing ==
# nothing" as two different hashes. That would report "distinct" for two files
# that were never actually compared — a false PASS on a security assertion. So a
# missing hash is a failure, never a pass.
assert_distinct() {
  local a="$1" b="$2"
  local ha hb
  ha=$(dev_sha_at "$DEV_DIR/$a")
  hb=$(dev_sha_at "$DEV_DIR/$b")
  if [[ -z "$ha" || -z "$hb" ]]; then
    fail "could not hash $a / $b — distinctness not established"
  elif [[ "$ha" != "$hb" ]]; then
    pass "$a and $b are distinct ciphertexts"
  else
    fail "$a and $b are byte-identical ($ha) — nonce or header reuse"
  fi
}

# The point of decrypt is fidelity, not "a file appeared": a restored file must
# carry the exact bytes that went in. Compares device-side so the plaintext
# never crosses adb.
assert_same_content() {
  local a="$1" b="$2"
  local ha hb
  ha=$(dev_sha_at "$DEV_DIR/$a")
  hb=$(dev_sha_at "$DEV_DIR/$b")
  if [[ -z "$ha" || -z "$hb" ]]; then
    fail "could not hash $a / $b"
  elif [[ "$ha" == "$hb" ]]; then
    pass "$a and $b have identical content"
  else
    fail "$a and $b differ ($ha vs $hb)"
  fi
}

# Ciphertext must never be mistaken for plaintext. Used on decrypt output: a
# restored file that still starts with the magic bytes means the copy, not the
# decrypt, was written.
assert_not_container() {
  local f="$1"
  if ! dev_exists "$f"; then fail "missing: $f"; return 1; fi
  local head; head=$(dev_head "$f")
  if [[ "$head" == "4C4154434801" ]]; then
    fail "$f is still a v1 container — plaintext was not produced"
  else
    pass "$f is plaintext (head '$head' is not the LATCH magic)"
  fi
}

assert_size_above() {
  local f="$1" min="$2"
  local s; s=$(dev_size "$f")
  if [[ -z "$s" ]]; then fail "could not size $f"; return 1; fi
  if (( s > min )); then pass "$f is ${s}B (> ${min}B)"
  else fail "$f is ${s}B, expected more than ${min}B"; fi
}

# A cancelled or failed batch must leave no `.tmp` behind. For decrypt that temp
# holds partial plaintext, so a leftover is a confidentiality bug, not clutter.
#
# Downloads is swept too, for the flows whose destination is there: the staging
# area is app-private, but `relocateStagedOutputs` writes into the tree via
# `createInTree`, and a failure part-way through must not leave a half-written
# `.tmp` where the user browses. Only the suite's own `dl-` names are matched,
# so no unrelated file in the user's Downloads folder is ever examined.
assert_no_tmp() {
  local leftovers
  leftovers=$(adb shell "find '$DEV_DIR' -name '*.tmp' 2>/dev/null" | tr -d '\r')
  if [[ -n "$leftovers" ]]; then
    fail "leftover temp files: $leftovers"
  else
    pass "no .tmp files left behind"
  fi
  leftovers=$(adb shell "find '$DOWNLOADS_DIR' -maxdepth 1 -name 'dl-*.tmp' 2>/dev/null" | tr -d '\r')
  if [[ -n "$leftovers" ]]; then fail "leftover Downloads temp files: $leftovers"
  else pass "no .tmp files left in Downloads"; fi
}

# The worker stages into app-private cache on Android and sweeps it on exit.
# Only readable on a debuggable build (`run-as`), so this is a no-op elsewhere.
assert_no_staging() {
  if ! adb shell "run-as $APP_ID true" >/dev/null 2>&1; then
    info "skipping cache staging check (not a debuggable build)"
    return 0
  fi
  # The staging *directories* legitimately outlive a run: `SafSource.sweep`
  # removes each run's own subfolder, not the parent, and the worker empties
  # `latch_stage` rather than deleting it. Their *contents* are what must not
  # survive — staged copies are the user's plaintext — so this asserts on files
  # and ignores the empty directories rather than reading a correctly-swept run
  # as a leak.
  local staged
  staged=$(adb shell "run-as $APP_ID sh -c 'find cache/latch_src cache/latch_stage -type f 2>/dev/null'" 2>/dev/null | tr -d '\r')
  if [[ -z "$staged" ]]; then
    pass "crypto staging cache is clean"
  else
    fail "staged plaintext left behind: $(echo "$staged" | tr '\n' ' ')"
  fi
  # Anything else in `cache/` belongs to someone other than the crypto worker —
  # `file_picker` keeps its own copy of a document the user handed it, for
  # instance. Reported so it stays visible, but not failed: this suite asserts
  # on the app's staging, and a plugin's private cache is not that.
  local other
  other=$(adb shell "run-as $APP_ID sh -c 'ls cache 2>/dev/null'" 2>/dev/null | tr -d '\r' |
    grep -vE '^(latch_src|latch_stage)$' || true)
  if [[ -n "$other" ]]; then
    info "cache also holds (not crypto staging, not asserted): $(echo "$other" | tr '\n' ' ')"
  fi
}

# --- the Downloads root -------------------------------------------------------
#
# Output that could not be written beside its source, or that the user chose to
# send there, lands in public Downloads — outside the fixture folder and so
# outside the before/after snapshot. These helpers make both directions of that
# claim checkable: "it really is there" and "nothing at all was written".

# No file whose name contains $1 exists directly in Downloads. The negative
# scenarios need this: a cancelled batch that quietly dumped ciphertext in
# Downloads would pass a fixture-folder-only check.
assert_no_downloads_output() {
  local needle="$1" found
  found=$(adb shell "ls '$DOWNLOADS_DIR' 2>/dev/null" 2>/dev/null | tr -d '\r' \
    | grep -F -- "$needle" || true)
  if [[ -z "$found" ]]; then
    pass "no '$needle' output in Downloads"
  else
    fail "unexpected output in Downloads: $(echo "$found" | tr '\n' ' ')"
  fi
}

# Exactly one container in Downloads for $1, and it really is a v1 container.
# "Exactly one" is the load-bearing half: a second copy would mean the app
# wrote the file twice, which no single-file patch should ever do.
assert_downloads_container() {
  local stem="$1"
  local listing names count name head
  listing=$(adb shell "ls '$DOWNLOADS_DIR' 2>/dev/null" 2>/dev/null | tr -d '\r' \
    | grep -F -- "$stem.latch" | sort || true)
  if [[ -z "$listing" ]]; then
    fail "no container for $stem in Downloads"
    return 1
  fi
  count=$(printf '%s\n' "$listing" | grep -c .)
  if (( count != 1 )); then
    fail "expected exactly one $stem.latch in Downloads, found $count:"
    printf '%s\n' "$listing" | sed 's/^/          /'
    return 1
  fi
  name="$listing"
  head=$(adb exec-out "dd if='$DOWNLOADS_DIR/$name' bs=1 count=6 2>/dev/null" 2>/dev/null \
    | xxd -p | tr -d '\n' | tr 'a-f' 'A-F')
  if [[ "$head" == "4C4154434801" ]]; then
    pass "Downloads holds exactly one v1 container for $stem ($name)"
  else
    fail "$DOWNLOADS_DIR/$name has head '$head', expected 4C4154434801"
  fi
}

# Every scenario starts from a known state. `pm clear` is what makes the
# onboarding flow meaningful — otherwise a previously-completed onboarding
# silently turns the first flow into a no-op that always PASSes.
reset_app() {
  adb shell pm clear "$APP_ID" >/dev/null 2>&1
  adb shell am force-stop "$APP_ID" >/dev/null 2>&1
}

# --- before/after folder snapshots -------------------------------------------
#
# A flow asserting "the screen showed an error" proves nothing about the disk.
# The strongest statement a negative scenario can make is "the folder is byte
# for byte what it was", which needs a manifest taken *before* the UI runs.
# run.sh takes one per flow and exports it as E2E_SNAPSHOT.

# Sorted "path<TAB>sha256" for every file under the fixture folder, recursive.
# Paths are relative ("./bulk/root.txt") so the manifest is comparable between
# runs regardless of how the folder is mounted.
snapshot_folder() {
  adb shell "cd '$DEV_DIR' && find . -type f 2>/dev/null | sort \
    | while read -r f; do printf '%s\t%s\n' \"\$f\" \"\$(sha256sum \"\$f\" | cut -d' ' -f1)\"; done" \
    2>/dev/null | tr -d '\r'
}

# Added / removed / modified, written to a temp file as three tab-separated
# buckets. Returns non-zero when there is any difference at all.
_folder_diff() {
  local before="$1" after="$2" out="$3"
  awk -F'\t' -v OFS='\t' '
    FNR==NR { old[$1]=$2; next }
    { seen[$1]=1
      if (!($1 in old))        print "added",   $1
      else if (old[$1] != $2)  { print "changed", $1; drop[$1]=1 } }
    END { for (n in old) if (!(n in seen)) print "removed", n }
  ' "$before" "$after" | sort > "$out"
  [[ -s "$out" ]]
}

assert_folder_unchanged() {
  local before="${1:-${E2E_SNAPSHOT:-}}"
  if [[ -z "$before" || ! -f "$before" ]]; then
    fail "no pre-run snapshot to compare against"
    return 1
  fi
  local after diff
  after=$(mktemp "${TMPDIR:-/tmp}/latch-e2e-after.XXXXXX")
  diff=$(mktemp "${TMPDIR:-/tmp}/latch-e2e-diff.XXXXXX")
  snapshot_folder > "$after"

  if _folder_diff "$before" "$after" "$diff"; then
    fail "fixture folder changed:"
    while IFS=$'\t' read -r kind path; do
      printf '          %-8s %s\n' "$kind" "$path"
    done < "$diff" | sed 's/^/  /'
  else
    pass "fixture folder is unchanged (nothing created, deleted or modified)"
  fi
  rm -f "$after" "$diff"
}

# Only the named files were added, and nothing was touched: for scenarios that
# legitimately write a known set of outputs (a batch spanning two folders writes
# one container into each) but must leave everything else alone. Names are
# DEV_DIR-relative; `bulk/root.txt.latch` is a subfolder, not a path to expand.
#
# The baseline is always the run.sh snapshot. It used to be an optional leading
# argument, which made `assert_only_added "$name"` silently treat the *file
# name* as the snapshot path and fail with "no pre-run snapshot" — a call shape
# that looked right and could never pass. Names are now the only arguments.
assert_only_added() {
  local before="${E2E_SNAPSHOT:-}"
  if [[ -z "$before" || ! -f "$before" ]]; then
    fail "no pre-run snapshot to compare against"
    return 1
  fi
  local after diff
  after=$(mktemp "${TMPDIR:-/tmp}/latch-e2e-after.XXXXXX")
  diff=$(mktemp "${TMPDIR:-/tmp}/latch-e2e-diff.XXXXXX")
  snapshot_folder > "$after"
  _folder_diff "$before" "$after" "$diff"

  local expected got
  expected=$(for want in "$@"; do printf 'added\t./%s\n' "$want"; done | sort)
  got=$(sort "$diff")
  if [[ "$got" == "$expected" ]]; then
    pass "exactly the expected new file(s), nothing else changed"
  else
    fail "expected only $* to be added — actual differences:"
    sed 's/^/          /' "$diff"
  fi
  rm -f "$after" "$diff"
}
