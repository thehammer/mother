#!/usr/bin/env bash
# run-tests.sh — run the Mother test suite: Go broker tests + bats.
#
# Usage:
#   ./scripts/run-tests.sh [bats options]
#
# Requires bats (brew install bats-core) and, for the broker tests, Go 1.22+.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TESTS_DIR="$PLUGIN_DIR/tests"
BROKER_DIR="$PLUGIN_DIR/broker"

# --- Go broker: build + unit tests ---
if command -v go >/dev/null 2>&1; then
    echo "== building broker =="
    "$SCRIPT_DIR/build-broker.sh"
    echo "== go test ./broker/... =="
    ( cd "$BROKER_DIR" && go test ./... ) || exit 1
else
    echo "warning: go not found — skipping broker build and tests" >&2
fi

# --- bats suite ---
if ! command -v bats >/dev/null 2>&1; then
    echo "error: bats not found. Install with: brew install bats-core" >&2
    exit 1
fi

echo "== bats =="
exec bats "$TESTS_DIR" "$@"
