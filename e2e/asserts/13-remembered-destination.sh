#!/usr/bin/env bash
# Post-flow assertions for 13: two batches, one remembered destination.
#
# Both containers must be beside each other in the fixture folder — the second
# batch used the remembered grant without asking. Distinctness is the extra
# claim here: two separate batches, two separate DEKs and headers, so byte
# equality would mean state leaked from one batch into the next.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

A="${DL_A}.latch"
B="${DL_B}.latch"

assert_only_added "$A" "$B"
assert_v1_container "$A"
assert_v1_container "$B"
assert_distinct "$A" "$B"

# Neither batch fell back: the remembered value is the granted folder, and a
# silenced prompt that wrote to Downloads instead would show up here.
assert_no_downloads_output "dl-remember"
assert_no_tmp
assert_no_staging
