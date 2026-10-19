#!/usr/bin/env bats
# mother_watchdog_run: a command's own result wins over a watchdog that fired at the boundary.

load 'test_helper'

setup() {
    PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORK="$(mktemp -d)"
    # shellcheck disable=SC1091
    . "$PLUGIN/lib/proc.sh"
    # Production scripts run under set -u only; bats' errexit would trip on the killed watchdog's wait status.
    set +e
}

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
}

@test "a command that completes reports done with its exit code" {
    mother_watchdog_run 30 "$WORK/p" "$WORK" bash -c 'exit 3'
    [ "$MOTHER_WD_OUTCOME" = "done" ]
    [ "$MOTHER_WD_RC" = "3" ]
}

@test "a command that outlives the budget reports timeout" {
    mother_watchdog_run 1 "$WORK/p" "$WORK" sleep 30
    [ "$MOTHER_WD_OUTCOME" = "timeout" ]
    [ "$MOTHER_WD_RC" = "124" ]
}

@test "when both .rc and .timeout exist the completed result wins" {
    # The command finishes and the watchdog's marker lands at the same boundary.
    mother_watchdog_run 30 "$WORK/p" "$WORK" bash -c ': >"$0.timeout"; exit 0' "$WORK/p"
    [ "$MOTHER_WD_OUTCOME" = "done" ]
    [ "$MOTHER_WD_RC" = "0" ]
}
