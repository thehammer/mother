#!/usr/bin/env bats
# adherence.bats — tests for `mother adherence-review` and the adherence loop.

load 'test_helper'

setup() {
    setup_mother_env

    # Install a mock `gh` command that returns canned output.
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
# Mock gh: returns empty output for any command.
echo "(mock gh output)"
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"

    # Install a mock `archie` agent (invoked as `claude --agent archie ...`).
    # We intercept this via mock_claude which records args, then we configure
    # MOCK_CLAUDE_STDOUT to return the verdict.
    export MOCK_CLAUDE_ARGS_FILE="$MOTHER_ROOT/mock-claude-args"
}

teardown() {
    teardown_mother_env
}

# Helper: make a succeeded job with a PR URL and a plan file.
_make_succeeded_job() {
    local id="$1"
    make_job "$id" "succeeded" \
        '.pr_url = "https://github.com/Carefeed/test/pull/42" | .adherence_attempts = 0 | .adherence_status = null | .adherence_pending = null | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"test"},"redd":{"model":"sonnet","effort":"medium","rationale":"test"},"marty":{"model":"sonnet","effort":"medium","rationale":"test"},"perri":{"model":"sonnet","effort":"medium","rationale":"test"}}'

    # Create a fake plan file.
    local plan_file="$EVENTS_DIR/${id}-plan.md"
    cat > "$plan_file" <<'PLAN'
# Test plan

## Context
A test plan.

## Target
- **Repo:** testrepo
- **Branch:** feature/test

## Files to change
- `foo.sh` — add something

## Approach
1. Do the thing.

## Acceptance criteria
- It works.

## Out of scope
- Nothing.
PLAN

    # Update plan_path on the job.
    merged=$(jq --arg p "$plan_file" '.plan_path = $p' "$JOBS_DIR/$id.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/$id.json"
}

# ---------------------------------------------------------------------------
# Pass verdict

@test "adherence-review: pass verdict stores passed status, job unchanged" {
    _make_succeeded_job "job-pass"

    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."

    run mother adherence-review "job-pass"
    [ "$status" -eq 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-pass.json"
    [ "$output" = "passed" ]
    run jq -r '.state' "$JOBS_DIR/job-pass.json"
    [ "$output" = "succeeded" ]
    run jq -r '.adherence_attempts' "$JOBS_DIR/job-pass.json"
    [ "$output" = "1" ]

    assert_event_kind "job-pass" "adherence_reviewed"
}

# ---------------------------------------------------------------------------
# Fail verdict — first attempt

@test "adherence-review: fail on first attempt -> failed_first status, state unchanged, attempts=1, notes stored" {
    _make_succeeded_job "job-fail1"

    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
The PR skipped the acceptance criterion about updating the README."

    run mother adherence-review "job-fail1"
    [ "$status" -ne 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-fail1.json"
    [ "$output" = "failed_first" ]
    # State stays succeeded; the runner re-queues with activity=cody_rework on next pickup.
    run jq -r '.state' "$JOBS_DIR/job-fail1.json"
    [ "$output" = "succeeded" ]
    run jq -r '.adherence_attempts' "$JOBS_DIR/job-fail1.json"
    [ "$output" = "1" ]

    # Notes stored as pending_answer for next Cody run.
    run jq -r '.pending_answer // ""' "$JOBS_DIR/job-fail1.json"
    [ -n "$output" ]

    assert_event_kind "job-fail1" "adherence_reviewed"
}

# ---------------------------------------------------------------------------
# Fail verdict — second attempt

@test "adherence-review: fail on second attempt -> blocked_for_human" {
    _make_succeeded_job "job-fail2"
    # Simulate first failure already happened.
    merged=$(jq '.adherence_attempts = 1 | .adherence_status = "failed_first"' "$JOBS_DIR/job-fail2.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/job-fail2.json"

    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
Still drifted. Please review manually."

    run mother adherence-review "job-fail2"
    [ "$status" -ne 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-fail2.json"
    [ "$output" = "blocked_for_human" ]
    run jq -r '.adherence_attempts' "$JOBS_DIR/job-fail2.json"
    [ "$output" = "2" ]
}

# ---------------------------------------------------------------------------
# cmd_list displays [ADHERENCE-BLOCKED] marker

@test "cmd_list shows adherence_blocked activity in state column for blocked jobs" {
    _make_succeeded_job "job-blocked"
    # Second-fail transitions job to awaiting with activity=adherence_blocked.
    merged=$(jq '.state = "awaiting" | .activity = "adherence_blocked" | .adherence_status = "blocked_for_human"' "$JOBS_DIR/job-blocked.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/job-blocked.json"

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "adherence_blocked" ]]
}

# ---------------------------------------------------------------------------
# Kill switch

@test "MOTHER_ADHERENCE_ENABLED=0 disables adherence review" {
    _make_succeeded_job "job-no-adh"
    # Mark as pending.
    merged=$(jq '.adherence_pending = true' "$JOBS_DIR/job-no-adh.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/job-no-adh.json"

    (
        export MOTHER_ROOT JOBS_DIR EVENTS_DIR
        MOTHER_BIN_DIR="$_BIN_DIR"
        MOTHER_LIB_DIR="$_LIB_DIR"
        source "$_LIB_DIR/state.sh"
        MOTHER_ADHERENCE_ENABLED=0
        _log() { true; }
        _ADHERENCE_LOCK="$RUNNER_DIR/adherence-review.lockdir"

        _run_adherence_pending() {
            [ "$MOTHER_ADHERENCE_ENABLED" = "1" ] || return 0
            mother adherence-review "job-no-adh"
        }
        _run_adherence_pending
    )

    # adherence_status should still be null (not reviewed).
    run jq -r '.adherence_status // "null"' "$JOBS_DIR/job-no-adh.json"
    [ "$output" = "null" ]
}
