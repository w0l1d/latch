#!/usr/bin/env bash
# Post-flow assertions for 15: one grant covered two folders.
#
# The containers must be in their own source folders — top level and inside
# `bulk/` — not both in the granted root. That distinction is the point of
# `subPath`: a grant on `LatchE2E` that ignored the nested path would put
# `root.txt.latch` beside `two-a.txt.latch`, and the mirrored layout the user
# sees in the folder would be silently flattened.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

TOP="${TWO_A}.latch"
NESTED="${BULK_SUBDIR}/${BULK_FILE}.latch"

assert_only_added "$TOP" "$NESTED"
assert_v1_container "$TOP"
assert_v1_container "$NESTED"
assert_distinct "$TOP" "$NESTED"
assert_exists "$TWO_A"
assert_exists "${BULK_SUBDIR}/${BULK_FILE}"

# Never asked a second time — so never allowed to settle for Downloads either.
assert_no_downloads_output "$TWO_A"
assert_no_downloads_output "$BULK_FILE"
assert_no_tmp
assert_no_staging
