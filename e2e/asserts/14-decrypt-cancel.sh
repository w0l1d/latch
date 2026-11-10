#!/usr/bin/env bash
# Post-flow assertions for 14: a declined decrypt produced no plaintext at all.
#
# The flow proves the UI returned to the passphrase screen. This proves the
# stronger claim: the fixture folder is byte-identical, so no restored file
# appeared under a collision name either. Downloads is checked separately
# because plaintext dropping there would be invisible to the folder snapshot —
# and would be the worst version of this bug.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

assert_folder_unchanged
assert_exists "$CONTAINER"          # the container is untouched
assert_no_downloads_output "$FILE"
assert_no_tmp
assert_no_staging
