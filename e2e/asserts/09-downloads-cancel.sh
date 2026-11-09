#!/usr/bin/env bash
# Post-flow assertions for 09: declining the destination question wrote nothing.
#
# The flow proves the batch popped back to the review screen. That is what the
# user saw; this is what the phone holds. Both halves are needed: a UI that
# stopped but left a staged file, or a silent Downloads write the screen never
# mentioned, would each pass a screen-only check.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

assert_folder_unchanged
# Downloads is the destination this scenario *declines*, so it is the one place
# a silent fallback would appear — the fixture-folder comparison cannot see it.
assert_no_downloads_output "$DL_CANCEL_FILE"
assert_no_tmp
assert_no_staging
