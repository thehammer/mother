#!/usr/bin/env bats
# phase_spawn.bats — tests for W2: phase-aware worker spawning in mother-run-job.
#
# These tests drive the real mother-run-job script with a mock `claude` that
# captures argv and exits immediately. Each test inspects:
#   - $MOCK_CLAUDE_ARGS_FILE  — which flags claude was invoked with
#   - $RUNNER_DIR/$id.prompt.md — the generated spawn prompt
#   - $JOBS_DIR/$id.json — final job state / failure reason
#
# All tests use main-dir isolation + no_pr:true against a real temp git repo
# so the worktree/branch/lock machinery runs without needing a remote.

load 'test_helper'

# ---------------------------------------------------------------------------
# Setup / teardown

setup() {
    setup_mother_env

    # Real git repo for the worker to check out branches in.
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

    # Mock gh (called for PR-branch validation; should be a no-op in tests).
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"

    # Disable posture bias so bishop absence doesn't affect model/effort.
    export MOTHER_POSTURE_ENABLED=0

    # Speed up the poll loop's idle reaper to avoid slow test teardown.
    export MOTHER_IDLE_REAP_SECONDS=30
    export MOTHER_RESULT_GRACE_SECONDS=5
}

teardown() {
    teardown_mother_env
    rm -rf "${TEST_REPO_DIR:-}"
}

# ---------------------------------------------------------------------------
# Helper: run mother-run-job synchronously and capture its exit status.
# bats `run` captures stdout/stderr; we need the files it writes.
_run_job() {
    local id="$1"
    # Clear the args file so each test starts fresh.
    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"
}

# ===========================================================================
# Legacy no-regression
# ===========================================================================

@test "legacy job: claude invoked with a cody agent (cody or mother:cody)" {
    make_job "leg-1" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-leg-1"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/leg-1.md"'"
         | .log_path = "'"$LOGS_DIR/leg-1.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"high","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/leg-1.md"
    touch "$LOGS_DIR/leg-1.log"

    _run_job "leg-1"

    # Agent must be cody or mother:cody (exact form depends on whether user has a
    # personal ~/.claude/agents/cody.md — both are correct resolutions).
    agent=$(mock_claude_flag_value "--agent")
    [[ "$agent" = "cody" ]] || [[ "$agent" = "mother:cody" ]]
}

@test "legacy job: spawn prompt does NOT contain a Request type header" {
    make_job "leg-2" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-leg-2"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/leg-2.md"'"
         | .log_path = "'"$LOGS_DIR/leg-2.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/leg-2.md"
    touch "$LOGS_DIR/leg-2.log"

    _run_job "leg-2"

    prompt=$(read_spawn_prompt "leg-2")
    # Must NOT contain the pipeline request-type header
    [[ "$prompt" != *"# Request type:"* ]]
}

@test "legacy job: effort comes from suggested_config.cody (visible in log)" {
    make_job "leg-3" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-leg-3"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/leg-3.md"'"
         | .log_path = "'"$LOGS_DIR/leg-3.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"xhigh","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/leg-3.md"
    touch "$LOGS_DIR/leg-3.log"

    _run_job "leg-3"

    # The wrapper echoes "=== effort: $worker_effort ===" to the log.
    # effort is NOT passed as a --effort CLI flag; it's exported as MOTHER_EFFORT.
    log_effort=$(grep '=== effort:' "$LOGS_DIR/leg-3.log" 2>/dev/null \
        | sed 's/.*=== effort:[[:space:]]*//' | sed 's/ ===.*//' | head -1)
    [ "$log_effort" = "xhigh" ]
}

# ===========================================================================
# Redd phase
# ===========================================================================

@test "redd phase: claude invoked with a redd agent (redd or mother:redd)" {
    make_pipeline_job "redd-1" "redd"
    _run_job "redd-1"

    agent=$(mock_claude_flag_value "--agent")
    [[ "$agent" = "redd" ]] || [[ "$agent" = "mother:redd" ]]
}

@test "redd phase: effort comes from suggested_config.redd (visible in log)" {
    make_pipeline_job "redd-2" "redd"
    _run_job "redd-2"

    # make_pipeline_job sets redd effort to "high"; effort is in MOTHER_EFFORT / log.
    log_effort=$(grep '=== effort:' "$LOGS_DIR/redd-2.log" 2>/dev/null \
        | sed 's/.*=== effort:[[:space:]]*//' | sed 's/ ===.*//' | head -1)
    [ "$log_effort" = "high" ]
}

@test "redd phase: spawn prompt contains Request type header redd:test" {
    make_pipeline_job "redd-3" "redd"
    _run_job "redd-3"

    prompt=$(read_spawn_prompt "redd-3")
    [[ "$prompt" == *"# Request type: redd:test"* ]]
}

@test "redd phase: spawn prompt contains Plan and Tests sections" {
    make_pipeline_job "redd-4" "redd"
    _run_job "redd-4"

    prompt=$(read_spawn_prompt "redd-4")
    [[ "$prompt" == *"## Plan"* ]]
    [[ "$prompt" == *"## Tests on this branch"* ]]
}

@test "redd phase: pipeline_phase_spawn event emitted with phase=redd" {
    make_pipeline_job "redd-5" "redd"
    _run_job "redd-5"

    assert_event_kind "redd-5" "pipeline_phase_spawn"
    event_phase=$(jq -r 'select(.kind == "pipeline_phase_spawn") | .detail.phase' \
        "$EVENTS_DIR/redd-5.jsonl" 2>/dev/null | head -1)
    [ "$event_phase" = "redd" ]
}

# ===========================================================================
# Cody phase
# ===========================================================================

@test "cody phase: claude invoked with a cody agent (cody or mother:cody)" {
    make_pipeline_job "cody-1" "cody"
    _run_job "cody-1"

    agent=$(mock_claude_flag_value "--agent")
    [[ "$agent" = "cody" ]] || [[ "$agent" = "mother:cody" ]]
}

@test "cody phase: effort comes from suggested_config.cody (visible in log)" {
    make_pipeline_job "cody-2" "cody"
    _run_job "cody-2"

    # make_pipeline_job sets cody effort to "medium"
    log_effort=$(grep '=== effort:' "$LOGS_DIR/cody-2.log" 2>/dev/null \
        | sed 's/.*=== effort:[[:space:]]*//' | sed 's/ ===.*//' | head -1)
    [ "$log_effort" = "medium" ]
}

@test "cody phase: spawn prompt contains Request type header cody:implement" {
    make_pipeline_job "cody-3" "cody"
    _run_job "cody-3"

    prompt=$(read_spawn_prompt "cody-3")
    [[ "$prompt" == *"# Request type: cody:implement"* ]]
}

@test "cody phase: spawn prompt contains Plan and Tests sections" {
    make_pipeline_job "cody-4" "cody"
    _run_job "cody-4"

    prompt=$(read_spawn_prompt "cody-4")
    [[ "$prompt" == *"## Plan"* ]]
    [[ "$prompt" == *"## Tests on this branch"* ]]
}

# ===========================================================================
# Marty phase
# ===========================================================================

@test "marty phase: claude invoked with a marty agent (marty or mother:marty)" {
    make_pipeline_job "marty-1" "marty"
    _run_job "marty-1"

    agent=$(mock_claude_flag_value "--agent")
    [[ "$agent" = "marty" ]] || [[ "$agent" = "mother:marty" ]]
}

@test "marty phase: effort comes from suggested_config.marty (visible in log)" {
    make_pipeline_job "marty-2" "marty"
    _run_job "marty-2"

    # make_pipeline_job sets marty effort to "xhigh" (distinct from cody/redd)
    log_effort=$(grep '=== effort:' "$LOGS_DIR/marty-2.log" 2>/dev/null \
        | sed 's/.*=== effort:[[:space:]]*//' | sed 's/ ===.*//' | head -1)
    [ "$log_effort" = "xhigh" ]
}

@test "marty phase: spawn prompt contains Request type header marty:refactor" {
    make_pipeline_job "marty-3" "marty"
    _run_job "marty-3"

    prompt=$(read_spawn_prompt "marty-3")
    [[ "$prompt" == *"# Request type: marty:refactor"* ]]
}

@test "marty phase: spawn prompt contains Plan, Work-already-on-branch, and Tests sections" {
    make_pipeline_job "marty-4" "marty"
    _run_job "marty-4"

    prompt=$(read_spawn_prompt "marty-4")
    [[ "$prompt" == *"## Plan"* ]]
    [[ "$prompt" == *"## Work already on this branch"* ]]
    [[ "$prompt" == *"## Tests on this branch"* ]]
}

# ===========================================================================
# Non-spawnable phase guard
# ===========================================================================

@test "review phase: job fails fast with non_spawnable_phase, claude not invoked" {
    make_pipeline_job "review-1" "review"
    _run_job "review-1"

    # Job must be in failed state
    state=$(jq -r '.state' "$JOBS_DIR/review-1.json")
    [ "$state" = "failed" ]

    reason=$(jq -r '.failed_reason.reason // empty' "$JOBS_DIR/review-1.json" 2>/dev/null || \
             jq -r 'last(.detail.reason? // empty)' "$EVENTS_DIR/review-1.jsonl" 2>/dev/null | tail -1)
    # Check the failed event carries the right reason
    failed_reason=$(jq -r 'select(.kind=="failed") | .detail.reason' \
        "$EVENTS_DIR/review-1.jsonl" 2>/dev/null | head -1)
    [ "$failed_reason" = "non_spawnable_phase" ]

    # Claude must NOT have been invoked
    [ ! -f "$MOCK_CLAUDE_ARGS_FILE" ]
}

@test "done phase: job fails fast with non_spawnable_phase, claude not invoked" {
    make_pipeline_job "done-1" "done"
    _run_job "done-1"

    state=$(jq -r '.state' "$JOBS_DIR/done-1.json")
    [ "$state" = "failed" ]

    failed_reason=$(jq -r 'select(.kind=="failed") | .detail.reason' \
        "$EVENTS_DIR/done-1.jsonl" 2>/dev/null | head -1)
    [ "$failed_reason" = "non_spawnable_phase" ]

    [ ! -f "$MOCK_CLAUDE_ARGS_FILE" ]
}

@test "unknown phase: job fails fast with non_spawnable_phase, claude not invoked" {
    make_pipeline_job "bogus-1" "bogus"
    _run_job "bogus-1"

    state=$(jq -r '.state' "$JOBS_DIR/bogus-1.json")
    [ "$state" = "failed" ]

    [ ! -f "$MOCK_CLAUDE_ARGS_FILE" ]
}

# ===========================================================================
# Metrics stage field
# ===========================================================================

@test "redd phase: metrics runs.jsonl stage is 'redd'" {
    make_pipeline_job "redd-metrics" "redd"
    _run_job "redd-metrics"

    stage=$(jq -r '.stage' "$MOTHER_ROOT/metrics/runs.jsonl" 2>/dev/null | head -1)
    [ "$stage" = "redd" ]
}

@test "legacy job: metrics runs.jsonl stage is 'cody'" {
    make_job "leg-metrics" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-leg-metrics"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/leg-metrics.md"'"
         | .log_path = "'"$LOGS_DIR/leg-metrics.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/leg-metrics.md"
    touch "$LOGS_DIR/leg-metrics.log"

    _run_job "leg-metrics"

    stage=$(jq -r '.stage' "$MOTHER_ROOT/metrics/runs.jsonl" 2>/dev/null | head -1)
    [ "$stage" = "cody" ]
}

# ===========================================================================
# Findings rendered only when targeted
# ===========================================================================

@test "cody phase with findings: findings targeted at cody appear in prompt" {
    # Add a finding targeted at cody to the pipeline job.
    make_pipeline_job "findings-cody" "cody" \
        '.pipeline.findings = [
            {"target":"cody","severity":"blocking","summary":"Missing error handling","detail":"No try-catch around DB call","location":"src/db.php:42"},
            {"target":"redd","severity":"advisory","summary":"Test coverage low","detail":"Only 30% coverage","location":"tests/"}
         ]'
    _run_job "findings-cody"

    # findings input is not declared by cody:implement in W1, so no findings
    # section is rendered — the cody-targeted finding is NOT in the prompt.
    # (This verifies W2 respects rt_inputs boundaries; W3/W4 may add findings
    # to cody:implement inputs if the protocol evolves.)
    prompt=$(read_spawn_prompt "findings-cody")
    # Verify prompt is non-empty and contains the request type header
    [[ "$prompt" == *"# Request type: cody:implement"* ]]
    # Verify the redd-targeted finding does NOT appear (it targets redd, not cody)
    [[ "$prompt" != *"Test coverage low"* ]]
}
