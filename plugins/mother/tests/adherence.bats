#!/usr/bin/env bats
# adherence.bats — tests for `mother adherence-review` and the adherence loop.

load 'test_helper'

FIXTURES="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd -P)/fixtures/usage"

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
# Real stream-json result-event parsing (as opposed to the plaintext
# MOCK_CLAUDE_STDOUT shortcut the rest of this file uses) + the resulting
# runs.jsonl row's shape.

@test "adherence-review: stream-json pass verdict writes one runs.jsonl row with stage adherence, verdict, and cost" {
    _make_succeeded_job "job-stream-pass"
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/adherence_pass_stream.jsonl"

    run mother adherence-review "job-stream-pass"
    [ "$status" -eq 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-stream-pass.json"
    [ "$output" = "passed" ]

    local metrics_file="$MOTHER_ROOT/metrics/runs.jsonl"
    [ -f "$metrics_file" ]
    run bash -c "grep -F '\"job_id\":\"job-stream-pass\"' '$metrics_file' | wc -l | tr -d ' '"
    [ "$output" = "1" ]

    local row stage verdict cost
    row=$(grep -F '"job_id":"job-stream-pass"' "$metrics_file")
    stage=$(printf '%s' "$row" | jq -r '.stage')
    verdict=$(printf '%s' "$row" | jq -r '.verdict')
    cost=$(printf '%s' "$row" | jq -r '.cost_usd')
    [ "$stage" = "adherence" ]
    [ "$verdict" = "pass" ]
    [ -n "$cost" ] && [ "$cost" != "null" ]
    awk -v c="$cost" 'BEGIN { exit !(c > 0) }'
}

@test "adherence-review: conservative posture forces sonnet, row records posture_clamped:true" {
    _make_succeeded_job "job-posture-clamp"

    # Conservative posture -> archie_model clamps from opus to sonnet.
    cat > "$_MOCK_BIN/bishop" <<'BISHOP'
#!/usr/bin/env bash
if [ "${1:-}" = "get" ] && [ "${2:-}" = "posture" ]; then
    echo "conservative"
fi
exit 0
BISHOP
    chmod +x "$_MOCK_BIN/bishop"

    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/adherence_pass_stream.jsonl"

    run mother adherence-review "job-posture-clamp"
    [ "$status" -eq 0 ]

    # The spawned claude argv must have actually requested sonnet, not just
    # the metrics row saying so.
    local argv_model
    argv_model=$(mock_claude_flag_value "--model")
    [ "$argv_model" = "sonnet" ]

    local metrics_file="$MOTHER_ROOT/metrics/runs.jsonl"
    local row model posture_clamped
    row=$(grep -F '"job_id":"job-posture-clamp"' "$metrics_file")
    model=$(printf '%s' "$row" | jq -r '.model')
    posture_clamped=$(printf '%s' "$row" | jq -r '.posture_clamped')
    [ "$model" = "sonnet" ]
    [ "$posture_clamped" = "true" ]
}

# ---------------------------------------------------------------------------
# Fail verdict — first attempt

@test "adherence-review: fail on first attempt -> failed_first, attempts=1, notes stored, state left to the runner" {
    _make_succeeded_job "job-fail1"

    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
The PR skipped the acceptance criterion about updating the README."

    run mother adherence-review "job-fail1"
    [ "$status" -ne 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-fail1.json"
    [ "$output" = "failed_first" ]
    run jq -r '.adherence_attempts' "$JOBS_DIR/job-fail1.json"
    [ "$output" = "1" ]

    # cmd_adherence_review records the verdict only — it deliberately does
    # not transition the job. The requeue (state=ready, activity=cody_rework)
    # is the daemon's job: see _run_adherence_pending in mother-runner,
    # covered by "adherence loop: marks a succeeded PR job pending, then
    # reviews and requeues on fail" further down this file. An earlier design
    # folded this into a single dedicated job `state` value for the rework
    # case; it was superseded by today's state+activity split and never
    # existed in shipped code.
    run jq -r '.state' "$JOBS_DIR/job-fail1.json"
    [ "$output" = "succeeded" ]
    run jq -r '.activity // ""' "$JOBS_DIR/job-fail1.json"
    [ "$output" = "" ]

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

@test "cmd_list: ADHERENCE-BLOCKED marker replaces the activity bracket" {
    _make_succeeded_job "job-blocked2"
    merged=$(jq '.state = "awaiting" | .activity = "adherence_blocked" | .adherence_status = "blocked_for_human"' "$JOBS_DIR/job-blocked2.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/job-blocked2.json"

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ADHERENCE-BLOCKED]"* ]]
    # Not rendered twice: the uppercase marker stands in for the activity.
    [[ "$output" != *"[adherence_blocked]"* ]]
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

# ---------------------------------------------------------------------------
# Merged PR — skip instead of requeuing rework onto a dead branch
#
# Regression test for a real incident, 2026-08-31: U4's PR (admin-portal
# #4398) was merged by a human before this automatic loop's next tick
# reviewed it. The loop doesn't run continuously — one review per tick,
# serialized by lock — so a human merging faster than the next tick is the
# normal case, not an edge case. Adherence review found real problems and
# (on the code path this test guards) would have re-queued Cody for rework,
# pushing more commits onto a branch that no longer accepts them: exactly
# the mechanism that produced the admin-portal#60 duplicate-PR mess.

@test "adherence loop: PR already merged → skips review, does not requeue rework" {
    _make_succeeded_job "job-loop-merged"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
Drifted from the plan."

    # Override the default no-op gh mock: this PR is merged.
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    echo "MERGED"
    exit 0
fi
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"

    run mother-runner --adherence-tick
    [ "$status" -eq 0 ]

    # Must NOT requeue rework onto the dead branch.
    run jq -r '.state' "$JOBS_DIR/job-loop-merged.json"
    [ "$output" = "succeeded" ]
    run jq -r '.activity' "$JOBS_DIR/job-loop-merged.json"
    [ "$output" != "cody_rework" ]
    run jq -r '.adherence_status' "$JOBS_DIR/job-loop-merged.json"
    [ "$output" = "skipped_pr_merged" ]
    run jq -r '.adherence_pending' "$JOBS_DIR/job-loop-merged.json"
    [ "$output" = "false" ]

    local events_file="$EVENTS_DIR/job-loop-merged.jsonl"
    run grep '"adherence_rework_kicked"' "$events_file"
    [ "$status" -ne 0 ]
    assert_event_kind "job-loop-merged" "adherence_skipped"
}

@test "adherence loop: PR not merged (gh mock returns OPEN) → reviews as normal" {
    _make_succeeded_job "job-loop-open"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
Drifted from the plan."

    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "pr" ] && [ "$2" = "view" ]; then
    echo "OPEN"
    exit 0
fi
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"

    run mother-runner --adherence-tick
    [ "$status" -eq 0 ]

    # Unaffected by the merged-PR check: normal fail-first behavior.
    run jq -r '.adherence_status' "$JOBS_DIR/job-loop-open.json"
    [ "$output" = "failed_first" ]
    run jq -r '.activity' "$JOBS_DIR/job-loop-open.json"
    [ "$output" = "cody_rework" ]
    assert_event_kind "job-loop-open" "adherence_rework_kicked"
}

# ---------------------------------------------------------------------------
# Notes containing backslashes / quotes / $() / backticks / newlines must
# persist verbatim. Incident: jq-filter interpolation of Archie's notes failed
# to compile on `\d`, `\u`, `\x41`, `\'`, so the job file was never updated and
# the runner re-reviewed the same job forever.

# Writes a verdict file ($1 = pass|fail) with hostile notes; sets $NASTY_NOTES.
_write_nasty_verdict() {
    local verdict="$1"
    local nasty_file="$MOTHER_ROOT/nasty-notes.txt"
    cat > "$nasty_file" <<'NOTES'
Duration regex `\d+m\d+s` is wrong; also `\u` and `\x41` and \' and \\ here.
He said "quoted" and `backticks` and $(echo pwned) and $HOME.
Last line after a blank line:

end.
NOTES
    NASTY_NOTES=$(cat "$nasty_file")
    {
        printf 'ADHERENCE: %s\nNOTES:\n' "$verdict"
        cat "$nasty_file"
    } > "$MOTHER_ROOT/nasty-verdict.txt"
    export MOCK_CLAUDE_STDOUT_FILE="$MOTHER_ROOT/nasty-verdict.txt"
}

@test "adherence-review: pass with backslash-laden notes persists passed status and exact notes" {
    _make_succeeded_job "job-nasty-pass"
    _write_nasty_verdict pass

    run mother adherence-review "job-nasty-pass"
    [ "$status" -eq 0 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-nasty-pass.json"
    [ "$output" = "passed" ]
    run jq -r '.adherence_pending' "$JOBS_DIR/job-nasty-pass.json"
    [ "$output" = "false" ]
    run jq -r '.adherence_attempts' "$JOBS_DIR/job-nasty-pass.json"
    [ "$output" = "1" ]

    local stored; stored=$(jq -j '.adherence_notes' "$JOBS_DIR/job-nasty-pass.json")
    [ "$stored" = "$NASTY_NOTES" ]
}

@test "adherence-review: first fail with backslash-laden notes persists failed_first, notes and pending_answer exact" {
    _make_succeeded_job "job-nasty-fail1"
    _write_nasty_verdict fail

    run mother adherence-review "job-nasty-fail1"
    [ "$status" -eq 1 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-nasty-fail1.json"
    [ "$output" = "failed_first" ]
    run jq -r '.adherence_attempts' "$JOBS_DIR/job-nasty-fail1.json"
    [ "$output" = "1" ]

    local notes answer
    notes=$(jq -j '.adherence_notes' "$JOBS_DIR/job-nasty-fail1.json")
    answer=$(jq -j '.pending_answer' "$JOBS_DIR/job-nasty-fail1.json")
    [ "$notes" = "$NASTY_NOTES" ]
    [ "$answer" = "$NASTY_NOTES" ]
}

@test "adherence-review: second fail with backslash-laden notes blocks for human with exact notes" {
    _make_succeeded_job "job-nasty-fail2"
    merged=$(jq '.adherence_attempts = 1 | .adherence_status = "failed_first"' "$JOBS_DIR/job-nasty-fail2.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/job-nasty-fail2.json"
    _write_nasty_verdict fail

    run mother adherence-review "job-nasty-fail2"
    [ "$status" -eq 1 ]

    run jq -r '.adherence_status' "$JOBS_DIR/job-nasty-fail2.json"
    [ "$output" = "blocked_for_human" ]
    run jq -r '.state' "$JOBS_DIR/job-nasty-fail2.json"
    [ "$output" = "awaiting" ]
    run jq -r '.adherence_attempts' "$JOBS_DIR/job-nasty-fail2.json"
    [ "$output" = "2" ]

    local notes; notes=$(jq -j '.adherence_notes' "$JOBS_DIR/job-nasty-fail2.json")
    [ "$notes" = "$NASTY_NOTES" ]
}

@test "adherence-review: exits non-zero and does not claim PASS when job state cannot be written" {
    [ "$(id -u)" -ne 0 ] || skip "root ignores directory permissions"
    _make_succeeded_job "job-nowrite"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."

    # Read-only jobs dir: the atomic write's temp file cannot be created.
    chmod 555 "$JOBS_DIR"
    run mother adherence-review "job-nowrite"
    local rc="$status" out="$output"
    chmod 755 "$JOBS_DIR"

    [ "$rc" -ne 0 ]
    [[ "$out" != *"adherence review: PASS"* ]]

    run jq -r '.adherence_status' "$JOBS_DIR/job-nowrite.json"
    [ "$output" = "null" ]
}

# ---------------------------------------------------------------------------
# Runner circuit breaker: if a review "succeeds" but never records a result,
# the loop must give up after a few tries. Terminal state contract:
# adherence_pending == false and adherence_status == "error".

@test "adherence loop: review that never persists is retried a bounded number of times, then abandoned" {
    _make_succeeded_job "job-loop-stuck"

    # Stub CLI: counts invocations, claims success, persists nothing.
    local stub_dir="$MOTHER_ROOT/stub-bin"
    local count_file="$MOTHER_ROOT/review-count"
    mkdir -p "$stub_dir"
    : > "$count_file"
    cat > "$stub_dir/mother" <<STUB
#!/usr/bin/env bash
echo x >> "$count_file"
echo "\$2: adherence review: PASS"
exit 0
STUB
    chmod +x "$stub_dir/mother"
    export MOTHER_BIN_DIR="$stub_dir"

    local i
    for i in 1 2 3 4 5 6 7 8; do
        run mother-runner --adherence-tick
        [ "$status" -eq 0 ]
    done

    local calls; calls=$(wc -l < "$count_file" | tr -d ' ')
    [ "$calls" -ge 1 ]
    [ "$calls" -le 3 ]

    run jq -r '.adherence_pending' "$JOBS_DIR/job-loop-stuck.json"
    [ "$output" = "false" ]
    run jq -r '.adherence_status' "$JOBS_DIR/job-loop-stuck.json"
    [ "$output" = "error" ]
}
