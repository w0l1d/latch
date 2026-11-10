#!/usr/bin/env bash
# Post-flow assertions for 04: two files in one batch, two independent containers.
#
# A batch is where a shared KEK would show up if it were ever misused: both
# containers must still be individually valid v1 files, and (because both get a
# fresh DEK and header regardless of key mode) they must not be identical.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

C2="${FILE2}.latch"
C3="${FILE3}.latch"

assert_v1_container "$C2"
assert_v1_container "$C3"
assert_larger_than_source "$C2" "$FILE2"
assert_larger_than_source "$C3" "$FILE3"

# "Keep the originals" was the choice: both sources survive the batch.
assert_exists "$FILE2"
assert_exists "$FILE3"

assert_distinct "$C2" "$C3"
# Both landed beside their sources and nothing else appeared: a batch that wrote
# a third file, or duplicated one under a collision name, fails here.
assert_only_added "$C2" "$C3"
assert_no_downloads_output "$FILE2"
assert_no_downloads_output "$FILE3"
assert_no_tmp
assert_no_staging
