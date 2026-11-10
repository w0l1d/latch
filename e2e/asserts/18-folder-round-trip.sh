#!/usr/bin/env bash
# Post-flow assertions for 18: a folder locked with "delete originals" and then
# unlocked restores the original bytes.
#
# `assert_only_added` carries more weight here than anywhere else in the suite.
# It compares the whole recursive manifest *by hash*, so a restored file whose
# bytes differ from the pre-flow snapshot is reported as `changed` and fails —
# without the original ever having to survive on disk to be compared against.
# That is what makes this a round-trip assertion rather than "a file appeared".
#
# It is also the negative case for `nested/d3.txt`: a container or a restored
# copy appearing there would be an unexpected addition, so neither scan
# descending into subfolders is checked by the same comparison.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

D1_LOCKED="${BULK_DEC_DIR}/d1.txt.latch"
D2_LOCKED="${BULK_DEC_DIR}/d2.txt.latch"

assert_only_added "$D1_LOCKED" "$D2_LOCKED"

# Keeping the containers is the default on the unlock screen — "Delete locked
# files afterwards" was left off, so both must still be there.
assert_v1_container "$D1_LOCKED"
assert_v1_container "$D2_LOCKED"
assert_exists "$D1_LOCKED"
assert_exists "$D2_LOCKED"

# The restored plaintext is present again. Its *content* is already covered by
# the hash comparison above; these make a missing file name itself rather than
# appearing as a bare `removed` line in the diff.
assert_exists "${BULK_DEC_DIR}/d1.txt"
assert_exists "${BULK_DEC_DIR}/d2.txt"

# Same-size-or-smaller would mean a copy, not an encryption.
assert_larger_than_source "$D1_LOCKED" "${BULK_DEC_DIR}/d1.txt"

# The non-recursive witness, restated in the positive: the nested file is still
# plaintext and never got a container of its own.
assert_exists "${BULK_DEC_DIR}/nested/d3.txt"
assert_not_container "${BULK_DEC_DIR}/nested/d3.txt"

assert_no_tmp
assert_no_staging
