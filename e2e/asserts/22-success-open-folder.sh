#!/usr/bin/env bash
# Post-flow assertions for 22: opening the folder is read-only.
#
# The interesting property is a negative one. `openFolder` hands the folder to
# DocumentsUI — a *different* app, with its own write access through the same
# grant — so if anything in the path rewrote or moved the output, it shows up
# here as a changed set of files rather than as a wrong screenshot.
#
# Names are read off the snapshot diff instead of being hard-coded. In suite
# order the folder still holds the container and restored copy that earlier
# flows left behind, so this flow's outputs take collision suffixes
# (`alpha.txt_3.latch`, `alpha_3.txt`) that move with every full run; fixed
# names pass only in isolation, where `push_fixtures` has just wiped the folder.
#
# Hard-coding them was wrong twice over. It failed the 2026-11-09 suite run on
# names the *app* got right, and — worse — `assert_same_content alpha_2.txt`
# was passing against the stale file an earlier flow had left, so the fidelity
# line was green without this flow having produced anything it compared. What
# is stable, and what the assertion is really about, is the shape of the
# addition: exactly two files, one v1 container and one plaintext copy of the
# source, and nothing created, removed or rewritten besides.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

# The source survives: locking it is a read of `alpha.txt`, never a move.
assert_exists "$FILE"

before="${E2E_SNAPSHOT:-}"
if [[ -z "$before" || ! -f "$before" ]]; then
  fail "no pre-run snapshot to compare against"
else
  after=$(mktemp "${TMPDIR:-/tmp}/latch-e2e-after.XXXXXX")
  diff=$(mktemp "${TMPDIR:-/tmp}/latch-e2e-diff.XXXXXX")
  snapshot_folder > "$after"
  _folder_diff "$before" "$after" "$diff" || true

  # DEV_DIR-relative, "./" stripped so the names match what the other
  # assertions take.
  added=$(awk -F'\t' '$1 == "added" { sub(/^\.\//, "", $2); print $2 }' "$diff" |
    sort)
  other=$(awk -F'\t' '$1 != "added"' "$diff")

  # A removed or rewritten file is the failure this flow exists to catch, so it
  # is reported on its own rather than folded into the count below.
  if [[ -n "$other" ]]; then
    fail "opening the folder changed the fixture folder beyond creating output:"
    printf '%s\n' "$other" | sed 's/^/          /'
  fi

  count=$(printf '%s\n' "$added" | grep -c .)
  if (( count != 2 )); then
    fail "expected exactly 2 files added, got ${count}: $(printf '%s' "$added" | tr '\n' ' ')"
  else
    pass "exactly 2 files added, nothing else changed"
    container=$(printf '%s\n' "$added" | grep '\.latch$')
    restored=$(printf '%s\n' "$added" | grep -v '\.latch$')
    if [[ -z "$container" || -z "$restored" ]]; then
      fail "expected one .latch container and one restored plaintext — got: $(printf '%s' "$added" | tr '\n' ' ')"
    else
      # The lock produced one container beside its original...
      assert_v1_container "$container"
      assert_larger_than_source "$container" "$FILE"
      # ...and the unlock restored the same bytes under a collision name,
      # because the original is still there.
      assert_not_container "$restored"
      assert_same_content "$restored" "$FILE"
    fi
  fi

  rm -f "$after" "$diff"
fi
