#!/usr/bin/env bash
# Post-flow assertions for 10: two declines in a row wrote nothing.
#
# The counterpart to 09 from the *resolvable* side: the folder was known, the
# rationale named it, and the user backed out of both prompts. Once that dialog
# completing with `null` meant "Use Downloads", so this is the flow that would
# catch a regression to that behaviour — in Downloads as well as beside the
# original, because the old failure wrote to exactly one of the two.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

assert_folder_unchanged
assert_no_downloads_output "$CANCEL_FILE"
assert_no_tmp
assert_no_staging
