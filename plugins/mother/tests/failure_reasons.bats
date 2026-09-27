#!/usr/bin/env bats
# failure_reasons.bats — one test per `mother-usage classify-exit` rule
# (driven both as a unit, via fixtures, and end-to-end through a real
# mother-run-job run), plus the `_transition`/`_job_transition` "missing
# reason" guard.

load 'test_helper'

FIXTURES="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd -P)/fixtures/usage"
MOTHER_RUN_JOB="$_BIN_DIR/mother-run-job"

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
}

_rates() { echo "$MOTHER_LIB_DIR/rates.json"; }

# ===========================================================================
# One test per classify-exit rule, driven off the fixtures in
# tests/fixtures/usage/ (see that dir's README.md for why each maps to its
# reason).
# ===========================================================================

@test "classify-exit rule: exit 127 -> worker_command_not_found" {
    run mother-usage classify-exit --log "$FIXTURES/corrupt_line.jsonl" --offset 0 --exit-code 127
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "worker_command_not_found" ]
}

@test "classify-exit rule: exit 143 -> worker_sigterm" {
    run mother-usage classify-exit --log "$FIXTURES/corrupt_line.jsonl" --offset 0 --exit-code 143
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "worker_sigterm" ]
}

@test "classify-exit rule: exit 137 -> worker_sigkill" {
    run mother-usage classify-exit --log "$FIXTURES/corrupt_line.jsonl" --offset 0 --exit-code 137
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "worker_sigkill" ]
}

@test "classify-exit rule: other exit >= 128 -> worker_signal_<n>" {
    run mother-usage classify-exit --log "$FIXTURES/corrupt_line.jsonl" --offset 0 --exit-code 139
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "worker_signal_11" ]
}

@test "classify-exit rule: result is_error/api_error_status -> api_error" {
    run mother-usage classify-exit --log "$FIXTURES/result_api_error.jsonl" --offset 0 --exit-code 1
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "api_error" ]
}

@test "classify-exit rule: result subtype error_max_turns -> max_turns" {
    run mother-usage classify-exit --log "$FIXTURES/result_max_turns.jsonl" --offset 0 --exit-code 1
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "max_turns" ]
}

@test "classify-exit rule: result subtype error_during_execution -> execution_error" {
    run mother-usage classify-exit --log "$FIXTURES/result_execution_error.jsonl" --offset 0 --exit-code 1
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "execution_error" ]
}

@test "classify-exit rule: result subtype success but exit != 0 -> nonzero_exit_after_result" {
    run mother-usage classify-exit --log "$FIXTURES/full_run.jsonl" --offset 0 --exit-code 3
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "nonzero_exit_after_result" ]
}

@test "classify-exit rule: no result event, tail matches context-overflow text -> context_overflow" {
    run mother-usage classify-exit --log "$FIXTURES/error_tail_context_overflow.jsonl" --offset 0 --exit-code 1
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "context_overflow" ]
}

@test "classify-exit rule: no result event, tail matches rate-limit text -> rate_limited" {
    run mother-usage classify-exit --log "$FIXTURES/error_tail_rate_limit.jsonl" --offset 0 --exit-code 1
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "rate_limited" ]
}

@test "classify-exit rule: no result event, tail matches overloaded/529 text -> api_overloaded" {
    run mother-usage classify-exit --log "$FIXTURES/error_tail_overloaded.jsonl" --offset 0 --exit-code 1
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "api_overloaded" ]
}

@test "classify-exit rule: no result event, tail matches billing text -> billing" {
    run mother-usage classify-exit --log "$FIXTURES/error_tail_billing.jsonl" --offset 0 --exit-code 1
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "billing" ]
}

@test "classify-exit rule: no result event, no matching tail text -> claude_exit_nonzero (fallback)" {
    run mother-usage classify-exit --log "$FIXTURES/corrupt_line.jsonl" --offset 0 --exit-code 1
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "claude_exit_nonzero" ]
}

# ===========================================================================
# End-to-end: driving a real mother-run-job with MOCK_CLAUDE_EXIT=1 and a
# tail matching "overloaded" produces a failed event with detail.reason ==
# "api_overloaded". This is the load-bearing integration point: mother-run-job
# must actually call classify-exit and thread its reason into the failed
# event's detail, not just leave classify-exit as a standalone tool nobody
# wires up.
# ===========================================================================

@test "mother-run-job: MOCK_CLAUDE_EXIT=1 + overloaded tail -> failed event reason=api_overloaded" {
    export TEST_REPO_DIR
    TEST_REPO_DIR="$(mktemp -d)"
    (
        cd "$TEST_REPO_DIR"
        git init -b main 2>/dev/null || git init && git checkout -b main 2>/dev/null || true
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        git add .
        git commit -m "init" --allow-empty
    ) >/dev/null 2>&1
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=30
    export MOTHER_RESULT_GRACE_SECONDS=5

    local id="fr-e2e-overloaded"
    (
        cd "$TEST_REPO_DIR"
        git checkout -q -B "feature/test-$id" main
        git commit -q --allow-empty -m "seed for $id"
        git checkout -q main
    ) >/dev/null 2>&1

    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-'"$id"'"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"

    export MOCK_CLAUDE_EXIT=1
    export MOCK_CLAUDE_STDOUT="Error: Overloaded (529)"

    run mother-run-job "$id"

    state=$(jq -r '.state' "$JOBS_DIR/$id.json")
    [ "$state" = "failed" ]

    reason=$(jq -r 'select(.kind=="failed") | .detail.reason' "$EVENTS_DIR/$id.jsonl" 2>/dev/null | head -1)
    [ "$reason" = "api_overloaded" ]

    rm -rf "$TEST_REPO_DIR"
}

# ===========================================================================
# _transition / _job_transition guard: a failed transition with no reason
# in its detail must default detail.reason to "unspecified" and also emit a
# separate failure_reason_missing event, so a code path that forgets to pass
# a reason is loud rather than silently producing an unattributed failure.
#
# _transition lives in bin/mother-run-job; sourcing it with SOURCE_ONLY=1
# requires _transition (and its dependencies: state.sh's _atomic_write /
# _with_lock, and the iso_now wrapper) to be defined BEFORE the
# `[ "${SOURCE_ONLY:-}" = "1" ] && return 0` guard — same precedent already
# established for _job_owner_repo_from_url, _scrape_pr_url_filtered, etc.
# (see pr_url_capture.bats). As of this writing _transition is defined AFTER
# that guard, so this test is expected to fail for exactly that reason until
# Cody relocates it (or the guard) to match.
# ===========================================================================

@test "_transition failed with no reason in detail defaults to reason=unspecified and emits failure_reason_missing" {
    SOURCE_ONLY=1 source "$MOTHER_RUN_JOB" 2>/dev/null || true

    id="fr-guard-1"
    job_file="$JOBS_DIR/$id.json"
    make_job "$id" "running"

    run _transition failed '{}'

    reason=$(jq -r 'select(.kind=="failed") | .detail.reason' "$EVENTS_DIR/$id.jsonl" 2>/dev/null | head -1)
    [ "$reason" = "unspecified" ]

    assert_event_kind "$id" "failure_reason_missing"
}

@test "_transition failed with an explicit reason passes it through unchanged, no failure_reason_missing event" {
    SOURCE_ONLY=1 source "$MOTHER_RUN_JOB" 2>/dev/null || true

    id="fr-guard-2"
    job_file="$JOBS_DIR/$id.json"
    make_job "$id" "running"

    run _transition failed "$(jq -nc '{reason: "no_commits_on_branch"}')"

    reason=$(jq -r 'select(.kind=="failed") | .detail.reason' "$EVENTS_DIR/$id.jsonl" 2>/dev/null | head -1)
    [ "$reason" = "no_commits_on_branch" ]

    local events_file="$EVENTS_DIR/$id.jsonl"
    run grep '"failure_reason_missing"' "$events_file"
    [ "$status" -ne 0 ]
}
