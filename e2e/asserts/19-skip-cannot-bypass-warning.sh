#!/usr/bin/env bash
# Post-flow assertions for 19: onboarding finished through the gate, the app
# remembers it, and nothing on disk moved.
#
# The interesting fact is not "home is visible" — the flow said that. It is that
# `onboarding_complete` is written by the acknowledgement step, not handed out
# by Skip. The prefs file is app-private, so it is read through `run-as`, which
# only works on a debuggable build (the dev APK this suite targets). On anything
# else the check is skipped rather than failed: running the suite against a
# release build is legitimate, and it should not report a defect it cannot see.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../lib/verify.sh"

prefs=$(adb shell "run-as $APP_ID cat shared_prefs/FlutterSharedPreferences.xml" 2>/dev/null | tr -d '\r')

if [[ -z "$prefs" ]]; then
  info "cannot read app prefs (not a debuggable build); skipping the onboarding flag check"
elif grep -q 'name="flutter.onboarding_complete"' <<<"$prefs"; then
  pass "onboarding_complete is persisted after the acknowledgement"
else
  fail "onboarding_complete was never written — onboarding did not finish"
fi

# Onboarding opens no files, so the fixture folder must be byte-identical to
# the pre-run snapshot. Passing no names to assert_only_added is the strongest
# form of that: zero differences of any kind.
assert_only_added
assert_no_staging
