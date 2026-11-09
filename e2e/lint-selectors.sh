#!/usr/bin/env bash
# Offline lint: every `id:` a flow taps must exist in lib/, and every `${VAR}` a
# flow references must actually be supplied when Maestro runs it.
#
# This is the one e2e check that needs no device. A flow that taps an id the
# build no longer declares fails on-device as a selector timeout, which reads
# like a flaky device rather than a renamed widget — and it costs a full run to
# find out. Catching it here takes a second.
#
# Identifiers reach Semantics through three different spellings, all of which
# this accepts:
#   Semantics(identifier: 'home_encrypt')      — declared directly
#   LatchButton(semanticsId: 'home_encrypt')   — forwarded by the shared button
#   _OptionCard(id: 'encrypt_options_keep')    — forwarded by a local widget
# Missing one of them reports a correct build as broken, so any new widget that
# grows its own id prop must be added to DECL below.
#
#   ./e2e/lint-selectors.sh        # exits non-zero if any id is undeclared
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

# Prop names that end up as Semantics(identifier:). Keep alphabetised.
DECL='(identifier|semanticsId|id)'

# The ids flows select that the app is expected to declare. Anything containing
# `:` or `/` is a framework id from outside Latch — `android:id/title` and
# `com.android.documentsui:id/…` are how the flows drive the system folder
# picker — so it can never appear in lib/ and says nothing about app coverage.
# Counting them made a correct build report as broken the moment a flow used one.
flow_ids() {
  grep -rhoE 'id: "[^"]+"' "$HERE/flows" "$HERE/subflows" \
    | sed 's/id: "//; s/"$//' | grep -vE '[:/]' | sort -u
}

missing=0
while read -r id; do
  [[ -z "$id" ]] && continue
  if ! grep -rqE "${DECL}: *['\"]${id}['\"]" "$ROOT/lib"; then
    echo "MISSING  $id   (no Semantics identifier in lib/)" >&2
    missing=$((missing + 1))
  fi
done < <(flow_ids)

used=$(flow_ids | wc -l | tr -d ' ')

if (( missing )); then
  echo "FAIL: $missing of $used flow id selector(s) are not declared in lib/" >&2
  exit 1
fi
echo "OK: all $used flow id selector(s) exist in lib/"

# --- flow variables ----------------------------------------------------------
#
# Maestro substitutes `${NAME}` from its `-e` arguments; a name nobody passed is
# not an empty string or a default, it is a flow that dies on an unresolved
# variable — which reads like a broken selector on the first line that uses it.
# The suite-wide names are declared once, in lib/common.sh, and run.sh derives
# its `-e` list from exactly those declarations. So a name referenced in a flow
# is legitimate only if it is declared there, or is a *subflow parameter* passed
# through a `runFlow: env:` block (PICK_ROOT, PICK_SUBDIR, FILE).
#
# Subflow parameters are always passed by every caller, never defaulted inside
# the subflow: a file-level `env:` block in a subflow *overrides* the caller's
# `runFlow: env:` rather than falling back to it (Maestro runs the caller's
# defineVariables first and the file's own last), so a default there silently
# shadows whatever the caller asked for. See subflows/pick_file.yaml.
#
# This is checked here rather than trusted because adding a fixture variable is
# a two-file edit in the best case and one file in the easy mistake: declaring
# `REPICK_A` in common.sh and referencing it in a flow reads as done, and the
# omission only appears minutes into an on-device run.
declared_vars=$(grep -oE '^: "\$\{[A-Za-z_][A-Za-z0-9_]*:=' "$HERE/lib/common.sh" \
                 | sed -E 's/^: "\$\{//; s/:=$//' | sort -u)

# Keys of `env:` blocks in the flows and subflows. Every one is SCREAMING_SNAKE,
# which is what distinguishes them from YAML keys like `id:`/`text:`.
env_keys=$(grep -rhoE '^[[:space:]]+[A-Z][A-Z0-9_]*:' "$HERE/flows" "$HERE/subflows" \
             | tr -d ' :' | sort -u)

ref_vars=$(grep -rhoE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$HERE/flows" "$HERE/subflows" \
             | sed -E 's/^\$\{//; s/\}$//' | sort -u)

undeclared=$(comm -23 <(echo "$ref_vars") <(printf '%s\n%s\n' "$declared_vars" "$env_keys" | sort -u))
if [[ -n "$undeclared" ]]; then
  echo "FAIL: flow(s) reference variables nothing supplies:" >&2
  echo "$undeclared" | sed 's/^/          /' >&2
  echo "      Declare them in lib/common.sh (suite-wide) or pass them in a" >&2
  echo "      \`runFlow: env:\` block (subflow parameter)." >&2
  exit 1
fi
echo "OK: every \${VAR} a flow uses is either declared in common.sh or a subflow parameter"

# Informational only: identifiers the app declares that no flow exercises. These
# are not failures — some are deliberately unreachable in the suite — but a
# screen whose ids are all unused is a UI path with no coverage at all.
declared=$(grep -rhoE "${DECL}: *['\"][a-z0-9_]+['\"]" "$ROOT/lib" \
             | sed -E "s/.*['\"]([a-z0-9_]+)['\"]/\1/" | sort -u)
unused=$(comm -23 <(echo "$declared") <(flow_ids))
if [[ -n "$unused" ]]; then
  echo
  echo "Unexercised identifiers (no flow taps these):"
  echo "$unused" | sed 's/^/  - /'
fi
