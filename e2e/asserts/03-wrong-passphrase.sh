#!/usr/bin/env bash
# Post-flow assertions for 03: a wrong passphrase is a no-op on disk.
#
# This is the security-critical negative case. The flow proves the app *said*
# "Wrong passphrase"; only the folder snapshot can prove it did not write
# plaintext first and fail afterwards. Latch's design fails at the DEK wrap
# before the body is touched, so the folder must be byte-identical.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

assert_folder_unchanged
assert_v1_container "$CONTAINER"    # still opens, still intact
# The flow answered "Use Downloads" so crypto could reach the DEK unwrap. The
# unwrap failing is what must stop the write — no plaintext may appear at the
# destination the user did name either, or "fails before touching the body"
# would only be true of the source folder.
assert_no_downloads_output "$FILE"
assert_no_tmp
assert_no_staging
