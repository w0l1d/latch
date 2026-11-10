#!/usr/bin/env bash
# Post-flow assertions for 01: a plaintext file was locked in place.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

assert_v1_container "$CONTAINER"
assert_larger_than_source "$CONTAINER" "$FILE"
assert_exists "$FILE"          # "keep the originals" was the choice
# Exactly one new file: a duplicated write would leave a second container under
# a collision name, which the existence checks above would not notice.
assert_only_added "$CONTAINER"
assert_no_downloads_output "$FILE"
assert_no_tmp
assert_no_staging
