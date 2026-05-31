#!/usr/bin/env bats
# request_types.bats — tests for plugins/mother/lib/request-types.sh
#
# The lib does not exist yet. All tests here should FAIL until the lib is
# implemented. They define the behavioral contract for the request-type
# registry.

load 'test_helper'

_LIB="$_LIB_DIR/request-types.sh"

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# rt_exists — minimum registry coverage

@test "rt_exists: ada:prd is registered" {
    run bash -c "source '$_LIB' && rt_exists ada prd"
    [ "$status" -eq 0 ]
}

@test "rt_exists: ada:plan_feedback is registered" {
    run bash -c "source '$_LIB' && rt_exists ada plan_feedback"
    [ "$status" -eq 0 ]
}

@test "rt_exists: ada:review is registered" {
    run bash -c "source '$_LIB' && rt_exists ada review"
    [ "$status" -eq 0 ]
}

@test "rt_exists: archie:plan is registered" {
    run bash -c "source '$_LIB' && rt_exists archie plan"
    [ "$status" -eq 0 ]
}

@test "rt_exists: archie:review is registered" {
    run bash -c "source '$_LIB' && rt_exists archie review"
    [ "$status" -eq 0 ]
}

@test "rt_exists: perri:review is registered" {
    run bash -c "source '$_LIB' && rt_exists perri review"
    [ "$status" -eq 0 ]
}

@test "rt_exists: redd:test is registered" {
    run bash -c "source '$_LIB' && rt_exists redd test"
    [ "$status" -eq 0 ]
}

@test "rt_exists: cody:implement is registered" {
    run bash -c "source '$_LIB' && rt_exists cody implement"
    [ "$status" -eq 0 ]
}

@test "rt_exists: marty:refactor is registered" {
    run bash -c "source '$_LIB' && rt_exists marty refactor"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# rt_exists — unregistered pair returns non-zero

@test "rt_exists: unregistered pair returns non-zero" {
    run bash -c "source '$_LIB' && rt_exists cody bogus"
    [ "$status" -ne 0 ]
}

@test "rt_exists: entirely unknown agent returns non-zero" {
    run bash -c "source '$_LIB' && rt_exists nobody anything"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# rt_inputs — non-empty for core SDLC types

@test "rt_inputs: redd:test returns non-empty input list" {
    run bash -c "source '$_LIB' && rt_inputs redd test"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_inputs: redd:test input list contains prd" {
    run bash -c "source '$_LIB' && rt_inputs redd test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"prd"* ]]
}

@test "rt_inputs: cody:implement returns non-empty input list" {
    run bash -c "source '$_LIB' && rt_inputs cody implement"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_inputs: marty:refactor returns non-empty input list" {
    run bash -c "source '$_LIB' && rt_inputs marty refactor"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_inputs: archie:review returns non-empty input list" {
    run bash -c "source '$_LIB' && rt_inputs archie review"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_inputs: perri:review returns non-empty input list" {
    run bash -c "source '$_LIB' && rt_inputs perri review"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# rt_contract — non-empty for every minimum-registry entry

@test "rt_contract: ada:prd returns non-empty description" {
    run bash -c "source '$_LIB' && rt_contract ada prd"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_contract: ada:plan_feedback returns non-empty description" {
    run bash -c "source '$_LIB' && rt_contract ada plan_feedback"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_contract: ada:review returns non-empty description" {
    run bash -c "source '$_LIB' && rt_contract ada review"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_contract: archie:plan returns non-empty description" {
    run bash -c "source '$_LIB' && rt_contract archie plan"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_contract: archie:review returns non-empty description" {
    run bash -c "source '$_LIB' && rt_contract archie review"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_contract: perri:review returns non-empty description" {
    run bash -c "source '$_LIB' && rt_contract perri review"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_contract: redd:test returns non-empty description" {
    run bash -c "source '$_LIB' && rt_contract redd test"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_contract: cody:implement returns non-empty description" {
    run bash -c "source '$_LIB' && rt_contract cody implement"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "rt_contract: marty:refactor returns non-empty description" {
    run bash -c "source '$_LIB' && rt_contract marty refactor"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

# ---------------------------------------------------------------------------
# rt_agent_for_phase — phase-to-agent mapping

@test "rt_agent_for_phase redd output contains redd" {
    run bash -c "source '$_LIB' && rt_agent_for_phase redd"
    [ "$status" -eq 0 ]
    [[ "$output" == *"redd"* ]]
}

@test "rt_agent_for_phase cody output contains cody" {
    run bash -c "source '$_LIB' && rt_agent_for_phase cody"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cody"* ]]
}

@test "rt_agent_for_phase marty output contains marty" {
    run bash -c "source '$_LIB' && rt_agent_for_phase marty"
    [ "$status" -eq 0 ]
    [[ "$output" == *"marty"* ]]
}

@test "rt_agent_for_phase bogus returns non-zero" {
    run bash -c "source '$_LIB' && rt_agent_for_phase bogus"
    [ "$status" -ne 0 ]
}
