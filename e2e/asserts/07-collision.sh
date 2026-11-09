#!/usr/bin/env bash
# Post-flow assertions for 07: locking the same file twice never overwrites.
#
# Flow 01 wrote `alpha.txt.latch`. Re-locking `alpha.txt` must land on a
# collision name (`alpha.txt_2.latch` — the counter goes before the extension),
# not replace the first container. Overwriting would destroy the only copy of
# that container's key material: the plaintext survives, but anyone holding the
# old container is left with an unopenable file.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

SECOND="alpha.txt_2.latch"

assert_exists "$CONTAINER"
assert_exists "$SECOND"
assert_v1_container "$SECOND"
assert_distinct "$CONTAINER" "$SECOND"

# The third slot must not have been used: exactly one extra container appeared.
assert_absent "alpha.txt_3.latch"
# Only the collision container is new. Anything else — a Downloads copy of the
# same file, a staged temp — means the second lock wrote more than once.
assert_only_added "$SECOND"
assert_no_downloads_output "$FILE"
assert_no_tmp
assert_no_staging
