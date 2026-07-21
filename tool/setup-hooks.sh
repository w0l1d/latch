#!/usr/bin/env bash
#
# Enable the repo's versioned git hooks (.githooks/) for this clone.
# Run once after cloning:  ./tool/setup-hooks.sh
#
# This points git at .githooks instead of .git/hooks, so the hooks are shared
# via the repo and stay in sync. Bypass any hook with --no-verify.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true

echo "✓ Git hooks enabled (core.hooksPath = .githooks)."
echo "  pre-commit → dart format check on staged Dart files"
echo "  pre-push   → format + analyze + tests (LATCH_SKIP_TESTS=1 to skip tests)"
echo "  Bypass any hook in an emergency with --no-verify."
