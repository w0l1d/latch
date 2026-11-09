#!/usr/bin/env bash
# Post-flow assertions for 16: a back-press on the dialog wrote nothing.
#
# Identical in substance to 10 — the two flows differ only in how the dialog was
# left — but kept separate so a regression in one gesture path cannot hide
# behind a pass in the other.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

assert_folder_unchanged
assert_no_downloads_output "$CANCEL_FILE"
assert_no_tmp
assert_no_staging
