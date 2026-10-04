#!/usr/bin/env bats
# prompt_stdin.bats — every headless `claude` spawn must receive its prompt on
# stdin, never in argv (argv is visible to `ps` and EDR command-line scanners,
# and is subject to E2BIG). mock_claude records argv and stdin separately.

load 'test_helper'

SENTINEL="MOTHER-ARGV-SENTINEL-7f3a"

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
echo "(mock gh output)"
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
    cat > "$_MOCK_BIN/bishop" <<'B'
#!/usr/bin/env bash
[ "${1:-}" = "get" ] && echo normal
exit 0
B
    chmod +x "$_MOCK_BIN/bishop"

    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=30
    export MOTHER_RESULT_GRACE_SECONDS=5
    export MOCK_CLAUDE_STDIN_FILE="$MOTHER_ROOT/mock-claude-stdin"
}

teardown() {
    teardown_mother_env
    rm -rf "${TEST_REPO_DIR:-}"
}

_assert_prompt_on_stdin_only() {
    grep -q "$SENTINEL" "$MOCK_CLAUDE_STDIN_FILE"
    ! grep -q "$SENTINEL" "$MOCK_CLAUDE_ARGS_FILE"
    # -p is a bare flag now: no prompt argument follows it.
    grep -qx -- "-p" "$MOCK_CLAUDE_ARGS_FILE"
}

@test "worker spawn: plan is delivered on stdin, sentinel absent from argv" {
    local id="stdin-worker"
    local branch="feature/test-$id"
    (cd "$TEST_REPO_DIR" && git checkout -q -B "$branch" main \
        && git commit -q --allow-empty -m seed && git checkout -q main) >/dev/null 2>&1
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "'"$branch"'"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"low","rationale":"t"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"t"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"t"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"t"}}'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    printf '\nPlanted: %s\n' "$SENTINEL" >> "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"

    rm -f "$MOCK_CLAUDE_ARGS_FILE" "$MOCK_CLAUDE_STDIN_FILE"
    run mother-run-job "$id"
    _assert_prompt_on_stdin_only
}

@test "review-phase spawn: prompt is delivered on stdin, sentinel absent from argv" {
    export TEST_REPO_DIR
    make_pipeline_job "stdin-rp" "cody"
    printf '\nPlanted: %s\n' "$SENTINEL" >> "$MOTHER_ROOT/plans/stdin-rp.md"
    local merged
    merged=$(jq '.state = "succeeded"' "$JOBS_DIR/stdin-rp.json")
    printf '%s' "$merged" > "$JOBS_DIR/stdin-rp.json"
    export MOCK_CLAUDE_STDOUT=$'```findings\n[]\n```'

    rm -f "$MOCK_CLAUDE_ARGS_FILE" "$MOCK_CLAUDE_STDIN_FILE"
    run mother review-phase "stdin-rp" --reviewer archie
    [ "$status" -eq 0 ]
    _assert_prompt_on_stdin_only
}

@test "adherence-review spawn: prompt is delivered on stdin, sentinel absent from argv" {
    make_job "stdin-adh" "succeeded" \
        '.pr_url = "https://github.com/Carefeed/test/pull/42" | .adherence_attempts = 0
         | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"t"},"redd":{"model":"sonnet","effort":"medium","rationale":"t"},"marty":{"model":"sonnet","effort":"medium","rationale":"t"},"perri":{"model":"sonnet","effort":"medium","rationale":"t"}}'
    local plan_file="$EVENTS_DIR/stdin-adh-plan.md"
    make_plan "$plan_file"
    printf '\nPlanted: %s\n' "$SENTINEL" >> "$plan_file"
    local merged
    merged=$(jq --arg p "$plan_file" '.plan_path = $p' "$JOBS_DIR/stdin-adh.json")
    printf '%s' "$merged" > "$JOBS_DIR/stdin-adh.json"
    export MOCK_CLAUDE_STDOUT=$'ADHERENCE: pass\nNOTES:\nok'

    rm -f "$MOCK_CLAUDE_ARGS_FILE" "$MOCK_CLAUDE_STDIN_FILE"
    run mother adherence-review "stdin-adh"
    [ "$status" -eq 0 ]
    _assert_prompt_on_stdin_only
}
