#!/usr/bin/env bats
# effort.bats — tests for `--effort` passthrough to the real `claude` subprocess.
#
# The contract: whatever effort Mother resolves (from suggested_config, the
# tier ladder on escalation, or an explicit adherence-review override) must
# reach the spawned `claude` process as a literal `--effort <value>` argv
# pair. We assert this ONLY via $MOCK_CLAUDE_ARGS_FILE (mock_claude's argv
# capture) — never by grepping log/prompt text, since MOTHER_EFFORT/log
# banners are a pre-existing, separate mechanism this feature adds to, not
# replaces.

load 'test_helper'

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
    export MOTHER_IDLE_REAP_SECONDS=30
    export MOTHER_RESULT_GRACE_SECONDS=5
}

teardown() {
    teardown_mother_env
    rm -rf "${TEST_REPO_DIR:-}"
}

# Seed a real commit on the job's branch (mirrors phase_spawn.bats's _run_job)
# so the no_pr commit-verification check doesn't fail the job before we get
# to inspect argv.
_seed_branch() {
    local branch="$1"
    (
        cd "$TEST_REPO_DIR"
        git checkout -q -B "$branch" main
        git commit -q --allow-empty -m "seed for $branch"
        git checkout -q main
    ) >/dev/null 2>&1
}

# Assert that a bare flag token appears (or does not appear) anywhere in the
# recorded argv file, independent of what follows it. Distinguishing "flag
# absent" from "flag present with an empty/next-line value" requires looking
# at the raw recorded tokens (one per line, per mock_claude), not
# mock_claude_flag_value (which can't tell "not found" from "found, empty").
_argv_has_flag() {
    local flag="$1"
    grep -qx -- "$flag" "${MOCK_CLAUDE_ARGS_FILE:-/tmp/mock-claude-args}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Legacy (non-pipeline) job: effort from suggested_config.cody

@test "legacy job: --effort low from suggested_config.cody reaches claude argv" {
    local id="leg-effort-low"
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
               "cody":  {"model":"sonnet","effort":"low","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    local effort_val
    effort_val=$(mock_claude_flag_value "--effort")
    [ "$effort_val" = "low" ]
}

# ---------------------------------------------------------------------------
# Escalated job: tier ladder governs, not suggested_config/posture

@test "escalated job at tier_2: --effort xhigh reaches claude argv" {
    local id="leg-effort-esc"
    _seed_branch "feature/test-$id"
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-'"$id"'"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .current_tier = "tier_2"
         | .escalation_count = 1
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"low","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    local effort_val
    effort_val=$(mock_claude_flag_value "--effort")
    [ "$effort_val" = "xhigh" ]
}

# ---------------------------------------------------------------------------
# Pipeline job on the redd phase

@test "pipeline job (redd phase): --effort high reaches claude argv" {
    local id="pipe-effort-redd"
    export TEST_REPO_DIR
    make_pipeline_job "$id" "redd"
    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    # make_pipeline_job sets redd's effort to "high" by default.
    local effort_val
    effort_val=$(mock_claude_flag_value "--effort")
    [ "$effort_val" = "high" ]
}

# ---------------------------------------------------------------------------
# review-phase: --effort from suggested_config.perri

@test "review-phase: --effort high from suggested_config.perri reaches claude argv" {
    local id="pipe-effort-perri"
    export TEST_REPO_DIR="$MOTHER_ROOT/testrepo-$id"
    git init -q "$TEST_REPO_DIR"
    git -C "$TEST_REPO_DIR" config user.email "test@test.com"
    git -C "$TEST_REPO_DIR" config user.name "Test"
    touch "$TEST_REPO_DIR/README.md"
    git -C "$TEST_REPO_DIR" add -A
    git -C "$TEST_REPO_DIR" commit -q -m "init"

    make_pipeline_job "$id" "cody"
    local merged
    merged=$(jq '.state = "succeeded" | .suggested_config.perri = {"model":"sonnet","effort":"high","rationale":"test"}' "$JOBS_DIR/$id.json")
    printf '%s' "$merged" > "$JOBS_DIR/$id.json"

    export MOCK_CLAUDE_STDOUT="Looks fine.

\`\`\`findings
[]
\`\`\`"
    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother review-phase "$id" --reviewer perri

    local effort_val
    effort_val=$(mock_claude_flag_value "--effort")
    [ "$effort_val" = "high" ]
}

# ---------------------------------------------------------------------------
# adherence-review: no MOTHER_ADHERENCE_EFFORT → no --effort flag at all

_make_succeeded_job_for_adherence() {
    local id="$1"
    make_job "$id" "succeeded" \
        '.pr_url = "https://github.com/Carefeed/test/pull/42" | .adherence_attempts = 0 | .adherence_status = null | .adherence_pending = null | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"test"},"redd":{"model":"sonnet","effort":"medium","rationale":"test"},"marty":{"model":"sonnet","effort":"medium","rationale":"test"},"perri":{"model":"sonnet","effort":"medium","rationale":"test"}}'

    local plan_file="$EVENTS_DIR/${id}-plan.md"
    make_plan "$plan_file"
    merged=$(jq --arg p "$plan_file" '.plan_path = $p' "$JOBS_DIR/$id.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/$id.json"
}

@test "adherence-review: no MOTHER_ADHERENCE_EFFORT set -> no --effort flag in argv" {
    local id="adh-effort-none"
    _make_succeeded_job_for_adherence "$id"
    unset MOTHER_ADHERENCE_EFFORT

    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother adherence-review "$id"

    ! _argv_has_flag "--effort"
}

@test "adherence-review: MOTHER_ADHERENCE_EFFORT=high -> --effort high in argv" {
    local id="adh-effort-high"
    _make_succeeded_job_for_adherence "$id"
    export MOTHER_ADHERENCE_EFFORT="high"

    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother adherence-review "$id"

    local effort_val
    effort_val=$(mock_claude_flag_value "--effort")
    [ "$effort_val" = "high" ]
}

# ---------------------------------------------------------------------------
# Invalid effort value -> flag omitted rather than passed through as garbage

@test "invalid effort value on suggested_config.cody -> no --effort flag added" {
    local id="leg-effort-invalid"
    _seed_branch "feature/test-$id"
    # Force an invalid effort value directly onto the job JSON, bypassing
    # `mother add`'s validation (which would reject this at enqueue time) —
    # this simulates a corrupted/hand-edited job record reaching the runner.
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-'"$id"'"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"ludicrous-speed","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    ! _argv_has_flag "--effort"
}

# ---------------------------------------------------------------------------
# MOTHER_WORKER_MCP_SCOPE — mother_claude_extra_args's --strict-mcp-config /
# --mcp-config passthrough (lib/usage.sh). Same argv-only assertion
# discipline as the --effort tests above.

_make_mcp_scope_job() {
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

@test "MOTHER_WORKER_MCP_SCOPE unset (default): --strict-mcp-config and --mcp-config reach claude argv" {
    local id="mcp-scope-default"
    _make_mcp_scope_job "$id"

    unset MOTHER_WORKER_MCP_SCOPE

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    _argv_has_flag "--strict-mcp-config"
    _argv_has_flag "--mcp-config"
}

@test "MOTHER_WORKER_MCP_SCOPE=0: neither --strict-mcp-config nor --mcp-config reach claude argv" {
    local id="mcp-scope-off"
    _make_mcp_scope_job "$id"

    export MOTHER_WORKER_MCP_SCOPE=0

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    ! _argv_has_flag "--strict-mcp-config"
    ! _argv_has_flag "--mcp-config"
}
