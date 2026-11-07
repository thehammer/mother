#!/usr/bin/env bats
# limiter_core.bats — runs the stdlib unittest suite for lib/limiter_core.py (the backpressure
# limiter's pure control law). The behaviour contract lives in limiter_core_test.py.

load 'test_helper'

@test "limiter_core control law: the unittest suite passes" {
    cd "$BATS_TEST_DIRNAME"
    run env PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest -v limiter_core_test
    echo "$output" >&3
    [ "$status" -eq 0 ]
    [[ "$output" != *"FAILED"* ]]
    [[ "$output" == *"OK"* ]]
}
