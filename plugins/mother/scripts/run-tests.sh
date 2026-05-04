#!/usr/bin/env bash
# run-tests.sh — run the Mother bats test suite.
#
# Usage:
#   ./scripts/run-tests.sh [bats options]
#
# Requires bats (brew install bats-core).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TESTS_DIR="$PLUGIN_DIR/tests"

if ! command -v bats >/dev/null 2>&1; then
    echo "error: bats not found. Install with: brew install bats-core" >&2
    exit 1
fi

exec bats "$TESTS_DIR" "$@"
