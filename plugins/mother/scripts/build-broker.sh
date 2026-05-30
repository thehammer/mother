#!/usr/bin/env bash
# build-broker.sh — compile the Go IPC broker into a single static binary.
#
# Produces plugins/mother/broker/bin/mother-broker. Called by install.sh and
# CI (run-tests.sh). Safe to run repeatedly. If Go is not installed it prints
# a clear message and exits non-zero — the broker is optional (the daemon runs
# without it when MOTHER_BROKER_ENABLED=0), so callers may choose to tolerate
# a non-zero exit.
#
# Usage:
#   scripts/build-broker.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BROKER_DIR="$PLUGIN_DIR/broker"
OUT_DIR="$BROKER_DIR/bin"
OUT="$OUT_DIR/mother-broker"

if ! command -v go >/dev/null 2>&1; then
    echo "build-broker: go not found on PATH. Install Go 1.22+ to build the broker." >&2
    echo "              (the daemon runs without it when MOTHER_BROKER_ENABLED=0)" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"

echo "build-broker: compiling $OUT"
( cd "$BROKER_DIR" && CGO_ENABLED=0 go build -o "$OUT" . )
echo "build-broker: done ($(du -h "$OUT" | cut -f1))"
