#!/usr/bin/env bash
# Post-flow assertions for 12: backing out of the picker, then granting properly.
#
# The recovery must land the output where the user originally wanted it — beside
# the original — not merely somewhere acceptable. So this asserts both
# directions: one container in the fixture folder, and nothing in Downloads. A
# flow that only checked "success appeared" would pass an app that quietly
# settled for Downloads after the first decline.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

OUT="${CHOOSE_FILE}.latch"

assert_only_added "$OUT"
assert_v1_container "$OUT"
assert_larger_than_source "$OUT" "$CHOOSE_FILE"
assert_exists "$CHOOSE_FILE"          # "keep the originals" was the choice
assert_no_downloads_output "$CHOOSE_FILE"
assert_no_tmp
assert_no_staging
