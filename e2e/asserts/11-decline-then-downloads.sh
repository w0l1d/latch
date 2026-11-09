#!/usr/bin/env bash
# Post-flow assertions for 11: rationale declined, Downloads chosen.
#
# The mixed answer. Two things must both hold, and a flow that checked only the
# screen would miss the second: Downloads holds the container, *and* the source
# folder was left alone. Writing both places would be the worst outcome — the
# user got what they asked for and an unexpected container as well.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

assert_downloads_container "$DL_CHOOSE_FILE"
assert_folder_unchanged
assert_no_tmp
assert_no_staging
