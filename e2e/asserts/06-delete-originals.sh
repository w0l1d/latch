#!/usr/bin/env bash
# Post-flow assertions for 06: "delete originals" removed the plaintext — and
# only after the container was verified.
#
# Deletion is the one irreversible action in the app, and it is gated on a
# verified decrypt-compare of the new container. So the container must exist,
# must be a real v1 container, and must be big enough to actually carry the
# source (a 56-byte header stub would verify nothing). The original must be
# gone.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

SAC="${SACRIFICE}.latch"

assert_absent "$SACRIFICE"
assert_v1_container "$SAC"
# beta.md is ~1.5 KB; the header alone is ~56 B plus the filename. Requiring
# >1 KB means the body is really in there.
assert_size_above "$SAC" 1024
# The container is the *only* copy now, so it must not have been sent anywhere
# else as well: a second copy would be one more place the plaintext-shaped file
# shows up, and the deletion would no longer mean what it says.
assert_absent "${SACRIFICE}_2.latch"
assert_no_downloads_output "$SACRIFICE"
assert_no_tmp
assert_no_staging
