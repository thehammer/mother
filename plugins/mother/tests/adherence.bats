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

@test "adherence-review: fail on first attempt -> adherence_rework, attempts=1, notes stored" {
    _make_succeeded_job "job-fail1"

    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
The PR skipped the acceptance criterion about updating the README."

    run mother adherence-review "job-fail1"
    [ "$status" -ne 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-fail1.json"
    [ "$output" = "failed_first" ]
    run jq -r '.state' "$JOBS_DIR/job-fail1.json"
    [ "$output" = "adherence_rework" ]
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

@test "cmd_list shows [ADHERENCE-BLOCKED] marker for blocked jobs" {
    _make_succeeded_job "job-blocked"
    merged=$(jq '.adherence_status = "blocked_for_human"' "$JOBS_DIR/job-blocked.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/job-blocked.json"

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ADHERENCE-BLOCKED" ]]
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

# ---------------------------------------------------------------------------
# Backward compatibility: non-pipeline job uses legacy ADHERENCE: pass/fail path

@test "adherence-review: non-pipeline job still parses ADHERENCE: pass and sets adherence_status=passed" {
    _make_succeeded_job "job-legacy-pass"

    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."

    run mother adherence-review "job-legacy-pass"
    [ "$status" -eq 0 ]

    # Legacy path: adherence_status=passed, adherence_reviewed event emitted.
    run jq -r '.adherence_status' "$JOBS_DIR/job-legacy-pass.json"
    [ "$output" = "passed" ]

    assert_event_kind "job-legacy-pass" "adherence_reviewed"

    # Must NOT emit a "reviewed" event (that's the pipeline path).
    local events_file="$EVENTS_DIR/job-legacy-pass.jsonl"
    run grep '"reviewed"' "$events_file"
    [ "$status" -ne 0 ]
}

@test "adherence-review: non-pipeline job ADHERENCE: fail produces adherence_reviewed event (not reviewed)" {
    _make_succeeded_job "job-legacy-fail"

    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
The PR missed the README update."

    run mother adherence-review "job-legacy-fail"
    [ "$status" -ne 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-legacy-fail.json"
    [ "$output" = "failed_first" ]

    assert_event_kind "job-legacy-fail" "adherence_reviewed"

    # Must NOT emit a "reviewed" event.
    local events_file="$EVENTS_DIR/job-legacy-fail.jsonl"
    run grep '"reviewed"' "$events_file"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Pipeline job delegation

# Helper: make a succeeded pipeline job.
_make_succeeded_pipeline_job() {
    local id="$1"

    export TEST_REPO_DIR="$MOTHER_ROOT/testrepo-${id}"
    git init -q "$TEST_REPO_DIR"
    git -C "$TEST_REPO_DIR" config user.email "test@test.com"
    git -C "$TEST_REPO_DIR" config user.name "Test"
    touch "$TEST_REPO_DIR/README.md"
    git -C "$TEST_REPO_DIR" add -A
    git -C "$TEST_REPO_DIR" commit -q -m "init"

    make_pipeline_job "$id" "cody"
    local merged
    merged=$(jq '.state = "succeeded"' "$JOBS_DIR/$id.json")
    printf '%s' "$merged" > "$JOBS_DIR/$id.json"
}

@test "adherence-review: pipeline job delegates to findings path (emits reviewed, not adherence_reviewed)" {
    _make_succeeded_pipeline_job "job-pipe-adh1"

    export MOCK_CLAUDE_STDOUT="I have reviewed the implementation.

\`\`\`findings
[]
\`\`\`"

    run mother adherence-review "job-pipe-adh1"
    [ "$status" -eq 0 ]

    # Should emit a "reviewed" event with reviewer=archie.
    assert_event_kind "job-pipe-adh1" "reviewed"

    local events_file="$EVENTS_DIR/job-pipe-adh1.jsonl"
    run grep '"reviewed"' "$events_file"
    [[ "$output" =~ '"reviewer":"archie"' ]]

    # Must NOT emit the legacy "adherence_reviewed" event.
    run grep '"adherence_reviewed"' "$events_file"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# mother-runner's automatic loop (as opposed to calling `mother
# adherence-review` directly, which the tests above exercise).
#
# Regression coverage for two bugs found 2026-08-20:
#
# 1. `adherence-review.lockdir` is a bare mkdir lock with no owner/TTL. If
#    mother-runner dies between mkdir and rmdir (crash, kill -9, machine
#    sleep), the lockdir is left behind and every future `mkdir` in
#    `_run_adherence_pending` fails forever — silently disabling all
#    automatic adherence review with no error anywhere. This happened in
#    production from 2026-05-20 to 2026-08-20: every "automatic" adherence
#    review in that window was actually a human running `mother
#    adherence-review <id>` by hand. Fix: `_recover_stale_locks`, run once
#    at daemon startup after `_singleton_guard` confirms we're the only
#    instance alive.
#
# 2. `if "$MOTHER_BIN_DIR/mother" adherence-review "$id" 2>&1 | while read
#    ...; then` tests the exit status of the `while read` loop (last
#    command in the pipeline), not `mother adherence-review`'s, because
#    mother-runner does not set `pipefail`. The loop's body (`_log`)
#    virtually always succeeds, so the `if` almost always took the pass
#    branch regardless of the real verdict — meaning even on the one
#    occasion the lock wasn't stuck, a `failed_first` verdict would never
#    have triggered the cody_rework requeue. Fix: branch on
#    `${PIPESTATUS[0]}` instead of the pipeline's own exit status.

@test "adherence loop: stale lockdir from a dead instance is cleared at startup" {
    mkdir -p "$RUNNER_DIR/adherence-review.lockdir"

    run mother-runner --recover-stale-locks-tick
    [ "$status" -eq 0 ]

    [ ! -d "$RUNNER_DIR/adherence-review.lockdir" ]
}

@test "adherence loop: stale pipeline-driver lockdir is also cleared at startup" {
    mkdir -p "$RUNNER_DIR/pipeline-driver.lockdir"

    run mother-runner --recover-stale-locks-tick
    [ "$status" -eq 0 ]

    [ ! -d "$RUNNER_DIR/pipeline-driver.lockdir" ]
}

@test "adherence loop: marks a succeeded PR job pending, then reviews and requeues on fail" {
    _make_succeeded_job "job-loop-fail"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
Drifted from the plan."

    # A single _run_adherence_pending call both marks newly-succeeded PR jobs
    # pending and (lock permitting) reviews one of them, so one tick here
    # covers the full mark -> review -> requeue path.
    run mother-runner --adherence-tick
    [ "$status" -eq 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-loop-fail.json"
    [ "$output" = "failed_first" ]
    run jq -r '.state' "$JOBS_DIR/job-loop-fail.json"
    [ "$output" = "ready" ]
    run jq -r '.activity' "$JOBS_DIR/job-loop-fail.json"
    [ "$output" = "cody_rework" ]

    assert_event_kind "job-loop-fail" "adherence_rework_kicked"
}

@test "adherence loop: reviews and leaves state alone on pass" {
    _make_succeeded_job "job-loop-pass"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."

    run mother-runner --adherence-tick
    [ "$status" -eq 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-loop-pass.json"
    [ "$output" = "passed" ]
    run jq -r '.state' "$JOBS_DIR/job-loop-pass.json"
    [ "$output" = "succeeded" ]

    local events_file="$EVENTS_DIR/job-loop-pass.jsonl"
    run grep '"adherence_rework_kicked"' "$events_file"
    [ "$status" -ne 0 ]
}

@test "adherence-review: pipeline job persists findings under reviewer_findings.archie" {
    _make_succeeded_pipeline_job "job-pipe-adh2"

    export MOCK_CLAUDE_STDOUT="Here are my findings.

\`\`\`findings
[
  {
    \"id\": \"f1\",
    \"target\": \"cody\",
    \"severity\": \"advisory\",
    \"summary\": \"Minor cleanup\",
    \"detail\": \"Clean up the helper.\",
    \"location\": \"lib/foo.sh:10\"
  }
]
\`\`\`"

    run mother adherence-review "job-pipe-adh2"
    [ "$status" -eq 0 ]

    run jq -r '.pipeline.reviewer_findings.archie | length' "$JOBS_DIR/job-pipe-adh2.json"
    [ "$output" = "1" ]

    run jq -r '.pipeline.reviewer_findings.archie[0].reviewer' "$JOBS_DIR/job-pipe-adh2.json"
    [ "$output" = "archie" ]
}
