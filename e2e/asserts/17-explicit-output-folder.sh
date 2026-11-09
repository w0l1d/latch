#!/usr/bin/env bash
# Post-flow assertions for 17: a folder chosen on the options screen is where the
# output actually lands.
#
# Two locations are checked, not one. The positive assertion ("a container is in
# the chosen folder") alone would pass even if the app *also* wrote a copy beside
# the source, so the source's own folder is pinned to exactly one new file — the
# one inside the subfolder. `assert_only_added` compares a full recursive
# manifest, which rules out both a duplicate and a stray temp.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

OUT="${BULK_SUBDIR}/${EXP_DST}.latch"

assert_only_added "$OUT"
assert_v1_container "$OUT"
# The whole point of a chosen folder is that the file is not beside its source.
assert_absent "${EXP_DST}.latch"
assert_larger_than_source "$OUT" "$EXP_DST"
# Default options keep the originals — deleting them is a separate opt-in.
assert_exists "$EXP_DST"
assert_no_downloads_output "$EXP_DST"
assert_no_tmp
assert_no_staging
