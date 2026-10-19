#!/usr/bin/env bats
# mother_watchdog_run: a watchdog kill is always reported as a timeout (never as the
# killed command's exit code), and a command that finished first is reported done.

load 'test_helper'

setup() {
    PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    WORK="$(mktemp -d)"
    # shellcheck disable=SC1091
    . "$PLUGIN/lib/proc.sh"
}

# Production scripts run under set -u only; bats' errexit would trip on the
# killed watchdog's wait status. Disable errexit only around the call, so the
# assertions after it still fail the test (a setup-wide `set +e` made every
# assertion in this file vacuous).
_wd() { set +e; mother_watchdog_run "$@"; set -e; }

teardown() {
    [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"
}

@test "a command that completes reports done with its exit code" {
    _wd 30 "$WORK/p" "$WORK" bash -c 'exit 3'
    [ "$MOTHER_WD_OUTCOME" = "done" ]
    [ "$MOTHER_WD_RC" = "3" ]
}

@test "a command that outlives the budget reports timeout" {
    _wd 1 "$WORK/p" "$WORK" sleep 30
    [ "$MOTHER_WD_OUTCOME" = "timeout" ]
    [ "$MOTHER_WD_RC" = "124" ]
}

@test "when both .timeout and .rc exist the timeout wins (a killed shell can write .rc on its way down)" {
    _wd 30 "$WORK/p" "$WORK" bash -c ': >"$0.timeout"; exit 0' "$WORK/p"
    [ "$MOTHER_WD_OUTCOME" = "timeout" ]
    [ "$MOTHER_WD_RC" = "124" ]
}

# The real gate shape: a shell function running `bash -c` with more than one
# statement, so there is an intermediate shell between the watchdog and the
# sleeping process. Killing it must never surface as "done" with a non-zero code.
_multi_hop() { bash -c "true; sleep 10"; }

@test "a multi-hop command killed at the budget is always reported as timeout, never done" {
    local i bad=0
    for i in $(seq 1 15); do
        _wd 1 "$WORK/p$i" "$WORK" _multi_hop
        if [ "$MOTHER_WD_OUTCOME" != "timeout" ] || [ "$MOTHER_WD_RC" != "124" ]; then
            bad=$((bad + 1)); echo "run $i: $MOTHER_WD_OUTCOME rc=$MOTHER_WD_RC"
        fi
    done
    [ "$bad" -eq 0 ]
}

@test "the watchdog does not declare a timeout for a command that already finished" {
    # .rc is written before the watchdog wakes; the watchdog must leave it alone.
    _wd 2 "$WORK/p" "$WORK" bash -c 'exit 0'
    [ "$MOTHER_WD_OUTCOME" = "done" ]
    [ ! -e "$WORK/p.timeout" ]
}
