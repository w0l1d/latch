#!/usr/bin/env bash
# Post-flow assertions for 08: an unresolvable source, answered with Downloads.
#
# The UI said it saved to Downloads; this checks that the claim is true and
# complete. "Exactly one container" matters because a second copy would mean the
# batch wrote the file twice; `assert_folder_unchanged` matters because the app
# must not have *also* dropped something beside a source it claimed it could not
# place.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

assert_downloads_container "$DL_FILE"
assert_folder_unchanged
assert_no_tmp
assert_no_staging
