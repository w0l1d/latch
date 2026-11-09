#!/usr/bin/env bash
# Post-flow assertions for 05: a folder run makes one ordinary container per
# file, and nothing more.
#
# `assert_only_added` is the whole negative case here. A container that failed
# to relocate (revoked grant, full volume) is moved to Downloads — outside the
# fixture folder — so the expected file is simply absent and the manifest
# comparison fails without needing a Downloads check. The exact expected set
# also proves the non-recursive default: `sub/four.txt` must have no container.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

ONE="${BULK_DIR}/one.txt.latch"
TWO="${BULK_DIR}/two.txt.latch"
THREE="${BULK_DIR}/three.bin.latch"

assert_only_added "$ONE" "$TWO" "$THREE"
assert_v1_container "$ONE"
assert_v1_container "$TWO"
assert_v1_container "$THREE"
# Same-size-or-smaller would mean a copy, not an encryption; and the 64k+1-byte
# file crosses a real secretstream chunk boundary.
assert_larger_than_source "$ONE" "${BULK_DIR}/one.txt"
assert_larger_than_source "$THREE" "${BULK_DIR}/three.bin"

# Sources survive by default — the folder screen's delete toggle was not touched.
assert_exists "${BULK_DIR}/one.txt"
assert_exists "${BULK_DIR}/two.txt"
assert_exists "${BULK_DIR}/three.bin"
assert_absent "${BULK_DIR}/sub/four.txt.latch"

assert_no_tmp
assert_no_staging
