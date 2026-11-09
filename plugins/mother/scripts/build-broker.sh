#!/usr/bin/env bash
# build-broker.sh — compile the Go IPC broker into a single static binary.
#
# Produces plugins/mother/broker/bin/mother-broker, plus mother-coord and mother-worker (the cluster
# Phase 1 coordinator and worker daemons, cmd/mother-coord and cmd/mother-worker). Called by install.sh and
# CI (run-tests.sh). Safe to run repeatedly. If Go is not installed it prints
# a clear message and exits non-zero — the broker is optional (the daemon runs
# without it when MOTHER_BROKER_ENABLED=0), so callers may choose to tolerate
# a non-zero exit.
#
# Usage:
#   scripts/build-broker.sh
#
# MOTHER_BROKER_DIR overrides the module directory (tests/ci_shards.bats uses a fixture).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
BROKER_DIR="${MOTHER_BROKER_DIR:-$PLUGIN_DIR/broker}"
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
# The cluster daemons (a MOTHER_BROKER_DIR fixture without them builds just the broker).
if [ -d "$BROKER_DIR/cmd/mother-coord" ]; then
    for _d in mother-coord mother-worker; do
        echo "build-broker: compiling $OUT_DIR/$_d"
        ( cd "$BROKER_DIR" && CGO_ENABLED=0 go build -o "$OUT_DIR/$_d" "./cmd/$_d" )
    done
fi
echo "build-broker: done ($(du -h "$OUT" | cut -f1))"
