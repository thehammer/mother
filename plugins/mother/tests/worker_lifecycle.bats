#!/usr/bin/env bats
# worker_lifecycle.bats — real-subprocess coverage of runs.jsonl row writing
# across the worker lifecycle: a job that pauses and resumes (two separate
# supervisor runs sharing one job id / one log file, verifying the second
# run's usage is offset-scoped and doesn't double-count the first run's
# tokens), a cancelled run, and orphan recovery's runner_died row.
#
# Unlike usage.bats/metrics.bats (which drive `mother-usage parse` directly)
# and cost_cap.bats/effort.bats (which drive `mother-run-job` for argv/state
# assertions), these tests drive the real `mother-run-job` / `mother-runner`
# subprocesses end-to-end and assert on the resulting
# $MOTHER_ROOT/metrics/runs.jsonl rows via jq — the same rigor as the rest of
# this suite, per this feature's post-hoc review.

load 'test_helper'

FIXTURES="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd -P)/fixtures/usage"

setup() {
    setup_mother_env

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
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120

    METRICS_FILE="$MOTHER_ROOT/metrics/runs.jsonl"
}

teardown() {
    teardown_mother_env
    rm -rf "${TEST_REPO_DIR:-}"
}

_seed_branch() {
    local branch="$1"
    (
        cd "$TEST_REPO_DIR"
        git checkout -q -B "$branch" main
        git commit -q --allow-empty -m "seed for $branch"
        git checkout -q main
    ) >/dev/null 2>&1
}

# A no_pr, main-dir job with a real seeded commit already ahead of base_ref
# (satisfies the no_pr commit-verification check without needing a PR).
_make_no_pr_job() {
    local id="$1"
    _seed_branch "feature/test-$id"
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
}

_metrics_rows_for() {
    local job_id="$1"
    grep -F "\"job_id\":\"${job_id}\"" "$METRICS_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test 1: pause -> resume -> succeed, two schema-2 rows, offset-scoped tokens.

@test "two-run job: pause+resume produces two schema-2 runs.jsonl rows, second row's tokens are offset-scoped" {
    local id="lifecycle-two-run"
    _make_no_pr_job "$id"

    # Run 1: emits some tokens, then the "worker" calls `mother await` itself
    # (a real bin/mother invocation — MOTHER_JOB_ID/MOTHER_ROOT are exported
    # into the wrapper's environment, same as a genuine in-worker `mother
    # await` call) and exits 0. This is a custom claude stand-in (not the
    # generic mock_claude shim) because it needs to perform a real side
    # effect, not just record argv / print canned text.
    cat > "$_MOCK_BIN/claude" <<'CLAUDE1'
#!/usr/bin/env bash
cat <<'EOF'
{"type":"assistant","message":{"id":"msg_run1","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
EOF
mother await --question "need clarification before continuing" >/dev/null 2>&1
exit 0
CLAUDE1
    chmod +x "$_MOCK_BIN/claude"

    run mother-run-job "$id"
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/$id.json"
    [ "$output" = "awaiting" ]

    # Exactly one schema-2 row so far.
    run bash -c "grep -F '\"job_id\":\"$id\"' '$METRICS_FILE' | wc -l | tr -d ' '"
    [ "$output" = "1" ]

    local row1 row1_tokens_in row1_tokens_out row1_schema
    row1=$(_metrics_rows_for "$id")
    row1_schema=$(printf '%s' "$row1" | jq -r '.schema')
    row1_tokens_in=$(printf '%s' "$row1" | jq -r '.tokens_in')
    row1_tokens_out=$(printf '%s' "$row1" | jq -r '.tokens_out')
    [ "$row1_schema" = "2" ]
    [ "$row1_tokens_in" = "500" ]
    [ "$row1_tokens_out" = "50" ]

    # Resume: awaiting -> ready.
    run mother resume "$id" "please continue"
    [ "$status" -eq 0 ]
    run jq -r '.state' "$JOBS_DIR/$id.json"
    [ "$output" = "ready" ]

    # Run 2: a distinct claude stand-in emitting DIFFERENT tokens, ending in
    # a real `result` event (success). Shares the same job id and log file
    # as run 1 (mother-run-job appends to the same log_path on resume).
    cat > "$_MOCK_BIN/claude" <<'CLAUDE2'
#!/usr/bin/env bash
cat <<'EOF'
{"type":"assistant","message":{"id":"msg_run2","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":700,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":80}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
exit 0
CLAUDE2
    chmod +x "$_MOCK_BIN/claude"

    run mother-run-job "$id"
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/$id.json"
    [ "$output" = "succeeded" ]

    # Now exactly two schema-2 rows for this job.
    run bash -c "grep -F '\"job_id\":\"$id\"' '$METRICS_FILE' | wc -l | tr -d ' '"
    [ "$output" = "2" ]

    # The SECOND row (most recent) must reflect ONLY run 2's tokens (700/80),
    # not run1+run2 (1200/130) — proving the offset scoping via
    # .current_run.log_offset works across a resume cycle on a shared log file.
    local row2 row2_tokens_in row2_tokens_out row2_schema
    row2=$(_metrics_rows_for "$id" | tail -1)
    row2_schema=$(printf '%s' "$row2" | jq -r '.schema')
    row2_tokens_in=$(printf '%s' "$row2" | jq -r '.tokens_in')
    row2_tokens_out=$(printf '%s' "$row2" | jq -r '.tokens_out')
    [ "$row2_schema" = "2" ]
    [ "$row2_tokens_in" = "700" ]
    [ "$row2_tokens_out" = "80" ]
}

# ---------------------------------------------------------------------------
# Test 2: cancel_requested path writes an outcome:"cancelled" row.

@test "cancelled run: cancel_requested=1 path writes a runs.jsonl row with outcome cancelled" {
    local id="lifecycle-cancelled"
    _make_no_pr_job "$id"

    # Pre-set cancel_requested so the poll loop's first tick (every 2s)
    # observes it and terminates the worker.
    merged=$(jq '.cancel_requested = true' "$JOBS_DIR/$id.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/$id.json"

    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/full_run.jsonl"
    export MOCK_CLAUDE_SLEEP=5

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/$id.json"
    [ "$output" = "cancelled" ]

    run bash -c "grep -F '\"job_id\":\"$id\"' '$METRICS_FILE' | wc -l | tr -d ' '"
    [ "$output" = "1" ]

    local row outcome
    row=$(_metrics_rows_for "$id")
    outcome=$(printf '%s' "$row" | jq -r '.outcome')
    [ "$outcome" = "cancelled" ]
}

# ---------------------------------------------------------------------------
# Test 3: retry/escalate no longer null out actual_cost_usd.

@test "mother retry does not null out a job's actual_cost_usd" {
    local id="lifecycle-retry-cost"
    make_job "$id" "failed" '.actual_cost_usd = 3.50'

    run mother retry "$id" --yes
    [ "$status" -eq 0 ]

    run jq -r '.actual_cost_usd' "$JOBS_DIR/$id.json"
    [ "$output" = "3.5" ] || [ "$output" = "3.50" ]
}

@test "mother escalate does not null out a job's actual_cost_usd" {
    local id="lifecycle-escalate-cost"
    make_job "$id" "failed" '.actual_cost_usd = 7.25 | .escalation_count = 0 | .current_tier = "tier_0"'

    run mother escalate "$id" --yes
    [ "$status" -eq 0 ]

    run jq -r '.actual_cost_usd' "$JOBS_DIR/$id.json"
    [ "$output" = "7.25" ]
}

# ---------------------------------------------------------------------------
# Test 4: orphan recovery writes a runs.jsonl row with failure_reason
# runner_died for a `running` job with a dead worker_pid and
# .current_run.log_offset set.

@test "orphan recovery: writes a runs.jsonl row with failure_reason runner_died" {
    local id="lifecycle-orphan-usage"

    # Guaranteed-dead pid: spawn a trivial subshell and wait for it to exit.
    ( exit 0 ) &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null

    make_job "$id" "running" \
        '.worker_pid = '"$dead_pid"' | .tmux_window = null | .started_at = "2000-01-01T00:00:00Z"
         | .current_run = {"log_offset": 0, "spawned_at": "2000-01-01T00:00:00Z", "session_id": "sess-orphan"}'

    cp "$FIXTURES/full_run.jsonl" "$LOGS_DIR/$id.log"

    # No CHILDREN_DIR entry at all -> _supervisor_alive_for_job reports dead,
    # so this is reaped unconditionally regardless of grace.
    run mother-runner --recover-orphans-tick 0
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/$id.json"
    [ "$output" = "failed" ]
    assert_event_kind "$id" "failed"

    run bash -c "grep -F '\"job_id\":\"$id\"' '$METRICS_FILE' | wc -l | tr -d ' '"
    [ "$output" = "1" ]

    local row failure_reason outcome
    row=$(_metrics_rows_for "$id")
    failure_reason=$(printf '%s' "$row" | jq -r '.failure_reason')
    outcome=$(printf '%s' "$row" | jq -r '.outcome')
    [ "$failure_reason" = "runner_died" ]
    [ "$outcome" = "failed" ]
}
