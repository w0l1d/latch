#!/usr/bin/env bash
# Post-flow assertions for 02: the container restored the original bytes.
#
# `alpha.txt` still exists (flow 01 kept it), so the restored file lands under a
# collision name — `resolveNameCollision` inserts the counter *before* the
# extension, which turns `alpha.txt` into `alpha_2.txt`. That naming is the part
# most likely to drift, hence asserting the exact name rather than globbing.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

RESTORED="alpha_2.txt"

assert_exists "$CONTAINER"          # decrypt never consumes the container
assert_exists "$RESTORED"
assert_not_container "$RESTORED"    # plaintext, not a copy of the ciphertext
assert_same_content "$RESTORED" "$FILE"
# One restoration, not several: a retry loop or a double relocation would leave
# `alpha_3.txt` and friends beside it.
assert_only_added "$RESTORED"
assert_no_downloads_output "$FILE"
assert_no_tmp
assert_no_staging
