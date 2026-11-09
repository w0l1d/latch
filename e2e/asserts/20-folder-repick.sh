#!/usr/bin/env bash
# Post-flow assertions for 20: the batch that ran is the folder the summary
# named, and the folder that was replaced was left untouched.
#
# The UI can only say what it *displayed*. A repick that re-rendered the count
# without re-pointing the inventory, or that pointed it at the right folder but
# never dropped the first one, would pass every on-screen assertion. Which
# directories now hold containers settles it.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

B1="${REPICK_B}/b1.txt.latch"
B2="${REPICK_B}/b2.txt.latch"
B3="${REPICK_B}/b3.txt.latch"
B4="${REPICK_B}/b4.txt.latch"

# Exactly the four containers of the second folder. Anything the first folder
# produced would appear here as an extra added file, so this single comparison
# also proves the replaced folder was not locked.
assert_only_added "$B1" "$B2" "$B3" "$B4"

assert_v1_container "$B1"
assert_v1_container "$B2"
assert_v1_container "$B3"
assert_v1_container "$B4"

# The folder that was chosen first must be exactly as it was: sources present,
# no container of any kind.
assert_exists "${REPICK_A}/a1.txt"
assert_exists "${REPICK_A}/a2.txt"
assert_absent "${REPICK_A}/a1.txt.latch"
assert_absent "${REPICK_A}/a2.txt.latch"

# Latch never deletes on its own; the delete toggle was not touched.
assert_exists "${REPICK_B}/b1.txt"
assert_exists "${REPICK_B}/b2.txt"
assert_exists "${REPICK_B}/b3.txt"
assert_exists "${REPICK_B}/b4.txt"

assert_no_tmp
assert_no_staging
