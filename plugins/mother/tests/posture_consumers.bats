#!/usr/bin/env bats
# posture_consumers.bats — Bishop's renamed labels reach the spawn clamp.
# `Pump the brakes` must clamp a fresh spawn to tier_0 (sonnet/medium) even when
# the plan suggests opus/high; `Ease up` is normal and leaves the plan's choice
# alone. (Lens selection under the same labels: review_wave.bats.)

load 'test_helper'

setup() {
    setup_mother_env
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
    cat > "$_MOCK_BIN/bishop" <<'B'
#!/usr/bin/env bash
if [ "${1:-}" = "get" ] && [ "${2:-}" = "posture" ]; then
    printf '%s\n' "${MOCK_BISHOP_POSTURE:-Cruise}"
fi
exit 0
B
    chmod +x "$_MOCK_BIN/bishop"
    export MOTHER_POSTURE_ENABLED=1
    export MOTHER_IDLE_REAP_SECONDS=60
    export MOTHER_RESULT_GRACE_SECONDS=30
    export MOTHER_WORKER_AGENT="test-agent"
    export MOTHER_WORKER_MCP_CONFIG="$MOTHER_ROOT/worker-mcp.json"
    echo '{"mcpServers": {}}' > "$MOTHER_WORKER_MCP_CONFIG"
}

teardown() {
    teardown_mother_env
    rm -rf "${TEST_REPO_DIR:-}"
}

_pc_job() {
    local id="$1"
    (
        cd "$TEST_REPO_DIR"
        git checkout -q -B "feature/test-$id" main
        git commit -q --allow-empty -m "seed"
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
               "cody":  {"model":"opus","effort":"high","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    echo "previous" > "$LOGS_DIR/$id.log"
    rm -f "$MOCK_CLAUDE_ARGS_FILE"
}

_pc_argv() { sed '/^---$/q' "$MOCK_CLAUDE_ARGS_FILE" | sed '$d' | tr '\n' ' '; }

@test "spawn: 'Pump the brakes' clamps a fresh spawn to tier_0 (sonnet/medium)" {
    export MOCK_BISHOP_POSTURE="Pump the brakes"
    _pc_job pc-brakes
    run mother-run-job pc-brakes
    [ "$status" -eq 0 ]
    _pc_argv | grep -q -- "--model sonnet --effort medium"
    jq -e 'select(.kind == "posture_bias_applied") | .detail | select(.posture == "conservative" and .action == "clamp" and .new_tier == "tier_0")' \
        "$EVENTS_DIR/pc-brakes.jsonl" >/dev/null
}

@test "spawn: 'Ease up' is normal: no clamp, the plan's opus/high stands" {
    export MOCK_BISHOP_POSTURE="Ease up"
    _pc_job pc-ease
    run mother-run-job pc-ease
    [ "$status" -eq 0 ]
    _pc_argv | grep -q -- "--model opus --effort high"
    ! grep -q '"kind":"posture_bias_applied"' "$EVENTS_DIR/pc-ease.jsonl"
}
