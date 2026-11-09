#!/usr/bin/env bash
# Post-flow assertions for 21: the unlock that ran is the folder the summary
# named, and the folder that was replaced was never unlocked.
#
# The restored names carry a collision counter (`y1.txt` -> `y1_2.txt`) because
# the originals are still on disk; that is not incidental. It gives the suite a
# plaintext to compare against, so "the unlock really decrypted" is checked
# against the original bytes rather than against a hash the host guessed.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

# Setup locked two folders, then the unlock restored only the second one.
assert_only_added \
  "${DEC_REPICK_A}/x1.txt.latch" \
  "${DEC_REPICK_A}/x2.txt.latch" \
  "${DEC_REPICK_B}/y1.txt.latch" \
  "${DEC_REPICK_B}/y2.txt.latch" \
  "${DEC_REPICK_B}/y3.txt.latch" \
  "${DEC_REPICK_B}/y1_2.txt" \
  "${DEC_REPICK_B}/y2_2.txt" \
  "${DEC_REPICK_B}/y3_2.txt"

# The replaced folder kept its containers and produced no plaintext: had the
# repick appended instead of replacing, or had the scan survived a backout in
# the wrong shape, its two files would have been unlocked as well.
assert_v1_container "${DEC_REPICK_A}/x1.txt.latch"
assert_v1_container "${DEC_REPICK_A}/x2.txt.latch"
assert_absent "${DEC_REPICK_A}/x1_2.txt"
assert_absent "${DEC_REPICK_A}/x2_2.txt"

# The restored files are plaintext, not copies of the ciphertext, and they match
# the originals byte for byte.
assert_not_container "${DEC_REPICK_B}/y1_2.txt"
assert_not_container "${DEC_REPICK_B}/y2_2.txt"
assert_not_container "${DEC_REPICK_B}/y3_2.txt"
assert_same_content "${DEC_REPICK_B}/y1.txt" "${DEC_REPICK_B}/y1_2.txt"
assert_same_content "${DEC_REPICK_B}/y2.txt" "${DEC_REPICK_B}/y2_2.txt"
assert_same_content "${DEC_REPICK_B}/y3.txt" "${DEC_REPICK_B}/y3_2.txt"

# Containers are kept by default — the "delete locked files" toggle was not
# touched, so the second folder still holds them.
assert_exists "${DEC_REPICK_B}/y1.txt.latch"
assert_exists "${DEC_REPICK_B}/y2.txt.latch"
assert_exists "${DEC_REPICK_B}/y3.txt.latch"

assert_no_tmp
assert_no_staging
