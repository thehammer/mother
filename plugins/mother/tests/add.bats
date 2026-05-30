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

# ---------------------------------------------------------------------------
# pipeline: block — job kind and initial state

@test "mother add with pipeline block produces job with kind=pipeline and initialized pipeline object" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan_with_config "$plan" \
'pipeline:
  enabled: true
  reviewers:
    - ada
    - archie
    - perri
  cycle_cap: 3
suggested_config:
  cody:
    model: sonnet
    effort: high
    rationale: "Standard implementation work."
  redd:
    model: sonnet
    effort: medium
    rationale: "Standard tests."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor."
  perri:
    model: sonnet
    effort: medium
    rationale: "Standard review."
  ada:
    model: opus
    effort: high
    rationale: "PRD-level review requires thorough analysis."
  archie:
    model: opus
    effort: high
    rationale: "Architecture review requires thorough analysis."'

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -eq 0 ]
    local id="$output"
    [ -n "$id" ]

    assert_job_field "$id" '.kind' "pipeline"
    assert_job_field "$id" '.pipeline.phase' "redd"
    assert_job_field "$id" '.pipeline.review_cycle' "0"
    assert_job_field "$id" '.pipeline.cycle_cap' "3"
    assert_job_field "$id" '.pipeline.findings | length' "0"

    # Reviewers list contains all three expected reviewers
    run jq -r '.pipeline.reviewers | contains(["ada","archie","perri"])' \
        "$JOBS_DIR/$id.json"
    [ "$output" = "true" ]
}

@test "mother add without pipeline block produces job without kind or pipeline key" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -eq 0 ]
    local id="$output"

    assert_job_field "$id" '.kind // "null"' "null"
    assert_job_field "$id" '.pipeline // "null"' "null"
}

@test "mother add with pipeline.enabled false does not produce pipeline job" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan_with_config "$plan" \
'pipeline:
  enabled: false
  reviewers:
    - ada
  cycle_cap: 2
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Standard."
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
    local id="$output"

    assert_job_field "$id" '.kind // "null"' "null"
}

@test "mother add with pipeline plan including ada and archie in suggested_config succeeds" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan_with_config "$plan" \
'pipeline:
  enabled: true
  reviewers:
    - ada
    - archie
  cycle_cap: 2
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Standard implementation."
  redd:
    model: sonnet
    effort: medium
    rationale: "Standard tests."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor."
  perri:
    model: sonnet
    effort: medium
    rationale: "Standard review."
  ada:
    model: opus
    effort: high
    rationale: "Pipeline review requires thorough analysis."
  archie:
    model: opus
    effort: high
    rationale: "Pipeline review requires thorough analysis."'

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/test

    [ "$status" -eq 0 ]
}
