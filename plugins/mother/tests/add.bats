#!/usr/bin/env bats
# add.bats — tests for `mother add` and suggested_config parsing.

load 'test_helper'

setup() {
    setup_mother_env
    # We need a fake git repo for mother add --repo-path
    export FAKE_REPO="$MOTHER_ROOT/testrepo"
    mkdir -p "$FAKE_REPO/.git"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# suggested_config — valid plan

@test "mother add with valid suggested_config succeeds and stores config" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -eq 0 ]
    local id="$output"
    [ -n "$id" ]
    # suggested_config stored on job
    local cfg
    cfg=$(jq -r '.suggested_config // empty' "$JOBS_DIR/$id.json")
    [ -n "$cfg" ]
    # cody model is sonnet
    run jq -r '.suggested_config.cody.model' "$JOBS_DIR/$id.json"
    [ "$output" = "sonnet" ]
}

@test "mother add sets current_tier=tier_0, escalation_count=0, adherence_attempts=0" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -eq 0 ]
    local id="$output"
    run jq -r '.current_tier' "$JOBS_DIR/$id.json"
    [ "$output" = "tier_0" ]
    run jq -r '.escalation_count' "$JOBS_DIR/$id.json"
    [ "$output" = "0" ]
    run jq -r '.adherence_attempts' "$JOBS_DIR/$id.json"
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# suggested_config — missing block

@test "mother add with missing suggested_config fails with clear error" {
    local plan="$MOTHER_ROOT/plan.md"
    cat > "$plan" <<'PLAN'
# Test plan — no suggested_config

## Context
Missing config.

## Target
- **Repo:** testrepo
- **Branch:** feature/test
- **Base:** origin/main

## Files to change
- `foo.sh` — something

## Approach
1. Do it.

## Acceptance criteria
- Works.

## Out of scope
- Nothing.
PLAN

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -ne 0 ]
    [[ "$output" =~ "suggested_config" ]]
}

# ---------------------------------------------------------------------------
# suggested_config — invalid model

@test "mother add with invalid model in suggested_config fails" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan_with_config "$plan" \
'suggested_config:
  cody:
    model: gpt4
    effort: medium
    rationale: "Wrong model."
  redd:
    model: sonnet
    effort: medium
    rationale: "Standard."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard."
  perri:
    model: sonnet
    effort: medium
    rationale: "Standard."'

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -ne 0 ]
    [[ "$output" =~ "model" ]]
}

# ---------------------------------------------------------------------------
# suggested_config — missing rationale

@test "mother add with missing rationale fails" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan_with_config "$plan" \
'suggested_config:
  cody:
    model: sonnet
    effort: medium
  redd:
    model: sonnet
    effort: medium
    rationale: "Standard."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard."
  perri:
    model: sonnet
    effort: medium
    rationale: "Standard."'

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -ne 0 ]
    [[ "$output" =~ "rationale" ]]
}

# ---------------------------------------------------------------------------
# suggested_config — skip: true is valid

@test "mother add with skip: true agent entry succeeds" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan_with_config "$plan" \
'suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Standard."
  redd:
    skip: true
    rationale: "No tests needed for this change."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard."
  perri:
    model: sonnet
    effort: medium
    rationale: "Standard."'

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -eq 0 ]
    local id="$output"
    run jq -r '.suggested_config.redd.skip' "$JOBS_DIR/$id.json"
    [ "$output" = "true" ]
}

# ---------------------------------------------------------------------------
# suggested_config — downgrade guardrail

@test "mother add with haiku model requires downgrade: prefix in rationale" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan_with_config "$plan" \
'suggested_config:
  cody:
    model: haiku
    effort: medium
    rationale: "Just a trivial change."
  redd:
    model: sonnet
    effort: medium
    rationale: "Standard."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard."
  perri:
    model: sonnet
    effort: medium
    rationale: "Standard."'

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -ne 0 ]
    [[ "$output" =~ "downgrade:" ]]
}

@test "mother add with haiku model and downgrade: prefix succeeds" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan_with_config "$plan" \
'suggested_config:
  cody:
    model: haiku
    effort: medium
    rationale: "downgrade: single-file typo fix, haiku is sufficient."
  redd:
    model: sonnet
    effort: medium
    rationale: "Standard."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard."
  perri:
    model: sonnet
    effort: medium
    rationale: "Standard."'

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -eq 0 ]
}
