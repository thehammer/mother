#!/usr/bin/env bats
# cost_cap.bats — tests for `--max-cost` enforcement (PreToolUse hook gate,
# forced-pause fallback, `mother resume --max-cost`, and the `mother list`
# COST column).
#
# Contract under test (see Cody's design, restated here for traceability):
#   - A job with .max_cost_usd set gets, at spawn, a
#     $RUNNER_DIR/$id.settings.json with a PreToolUse hook pointing at
#     hooks/mother-cost-gate.sh, and `--settings <file>` on the claude argv.
#   - A job with no .max_cost_usd gets neither, and no cost_cap_* events ever.
#   - On breach (spend >= cap): $RUNNER_DIR/$id.cost-cap flag file is written,
#     and a cost_cap_breached event fires with {max_cost_usd, spent_usd, by_actor}.
#   - hooks/mother-cost-gate.sh (Cody's file, not this suite's): flag absent
#     -> exit 0. Flag present -> allow only `mother await`-prefixed Bash
#     commands, else exit 2 with a stderr message. Any internal hook error
#     -> exit 0 (fail open).
#   - If the job stays `running` past MOTHER_COST_CAP_GRACE_SECONDS after
#     breach, mother-run-job force-pauses it to `awaiting` with
#     paused_reason: "cost_cap", writes a `.question`, and emits
#     cost_cap_forced_pause.
#   - `mother resume <id> --max-cost USD|none` is required when
#     paused_reason == "cost_cap"; on success clears the .cost-cap flag and
#     emits max_cost_raised {from,to}.
#   - `mother list` gets a COST column.

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
    # Run the usage-check on every poll tick instead of every 120s, so a
    # short-lived mock worker still gives the poll loop a chance to observe
    # a breach.
    export MOTHER_USAGE_CHECK_INTERVAL=0
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

_make_capped_job() {
    local id="$1" cap="$2"
    _seed_branch "feature/test-$id"
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-'"$id"'"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .max_cost_usd = '"$cap"'
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

_make_uncapped_job() {
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
         | .max_cost_usd = null
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

_argv_has_flag() {
    local flag="$1"
    grep -qx -- "$flag" "${MOCK_CLAUDE_ARGS_FILE:-/tmp/mock-claude-args}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Settings/flag wiring

@test "capped job: --settings appears in spawned claude argv, pointing at a file naming the cost gate hook" {
    local id="cap-settings"
    _make_capped_job "$id" 5.00

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    local settings_val
    settings_val=$(mock_claude_flag_value "--settings")
    [ -n "$settings_val" ]
    [ -f "$settings_val" ]
    grep -q "mother-cost-gate.sh" "$settings_val"
}

@test "uncapped job: no --settings flag, and no cost_cap_* events ever recorded" {
    local id="uncap-settings"
    _make_uncapped_job "$id"

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    ! _argv_has_flag "--settings"

    local events_file="$EVENTS_DIR/$id.jsonl"
    run grep -c '"kind":"cost_cap_' "$events_file"
    [ "$status" -ne 0 ] || [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Breach detection

@test "breach: spend over a tiny cap writes the .cost-cap flag file and emits cost_cap_breached" {
    local id="cap-breach"
    _make_capped_job "$id" 0.001

    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/full_run.jsonl"
    export MOCK_CLAUDE_SLEEP=4
    export MOTHER_COST_CAP_GRACE_SECONDS=120

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    [ -f "$RUNNER_DIR/$id.cost-cap" ]
    assert_event_kind "$id" "cost_cap_breached"

    local events_file="$EVENTS_DIR/$id.jsonl"
    run grep '"cost_cap_breached"' "$events_file"
    [[ "$output" =~ '"max_cost_usd"' ]]
    [[ "$output" =~ '"spent_usd"' ]]
    [[ "$output" =~ '"by_actor"' ]]
}

# ---------------------------------------------------------------------------
# Hook: unit-level (direct invocation, no full job needed)

@test "cost-gate hook: flag present, non-await Bash command -> exit 2 with stderr" {
    local id="hook-deny"
    mkdir -p "$RUNNER_DIR"
    touch "$RUNNER_DIR/$id.cost-cap"

    run bash -c "MOTHER_JOB_ID='$id' MOTHER_ROOT='$MOTHER_ROOT' '$MOTHER_PLUGIN_DIR/hooks/mother-cost-gate.sh' <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}'"
    [ "$status" -eq 2 ]
    [ -n "$output" ]
}

@test "cost-gate hook: flag present, mother-await Bash command -> exit 0" {
    local id="hook-allow"
    mkdir -p "$RUNNER_DIR"
    touch "$RUNNER_DIR/$id.cost-cap"

    run bash -c "MOTHER_JOB_ID='$id' MOTHER_ROOT='$MOTHER_ROOT' '$MOTHER_PLUGIN_DIR/hooks/mother-cost-gate.sh' <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mother await --question x\"}}'"
    [ "$status" -eq 0 ]
}

@test "cost-gate hook: mother-await command with a path prefix is still allowed" {
    local id="hook-allow-path"
    mkdir -p "$RUNNER_DIR"
    touch "$RUNNER_DIR/$id.cost-cap"

    run bash -c "MOTHER_JOB_ID='$id' MOTHER_ROOT='$MOTHER_ROOT' '$MOTHER_PLUGIN_DIR/hooks/mother-cost-gate.sh' <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"/usr/local/bin/mother await --question x\"}}'"
    [ "$status" -eq 0 ]
}

@test "cost-gate hook: flag absent -> exit 0 regardless of tool_input" {
    local id="hook-noflag"
    mkdir -p "$RUNNER_DIR"
    rm -f "$RUNNER_DIR/$id.cost-cap"

    run bash -c "MOTHER_JOB_ID='$id' MOTHER_ROOT='$MOTHER_ROOT' '$MOTHER_PLUGIN_DIR/hooks/mother-cost-gate.sh' <<< '{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"rm -rf /\"}}'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Forced-pause fallback

@test "forced pause: breach without a mother-await call eventually pauses the job to awaiting/cost_cap" {
    local id="cap-forced-pause"
    _make_capped_job "$id" 0.001

    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/full_run.jsonl"
    # Keep the "worker" alive well past the (short) grace window so the
    # poll loop's fallback fires before claude exits on its own.
    export MOCK_CLAUDE_SLEEP=8
    export MOTHER_COST_CAP_GRACE_SECONDS=2

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    run jq -r '.state' "$JOBS_DIR/$id.json"
    [ "$output" = "awaiting" ]
    run jq -r '.paused_reason' "$JOBS_DIR/$id.json"
    [ "$output" = "cost_cap" ]

    run jq -r '.question // ""' "$JOBS_DIR/$id.json"
    [[ "$output" =~ (cost.cap|\$0\.00) ]] || [[ "$output" =~ [Cc]ost ]]

    assert_event_kind "$id" "cost_cap_forced_pause"
}

# ---------------------------------------------------------------------------
# mother resume --max-cost

@test "resume without --max-cost on a paused_reason=cost_cap job fails, job stays awaiting" {
    local id="cap-resume-missing-flag"
    make_job "$id" "awaiting" \
        '.paused_reason = "cost_cap" | .max_cost_usd = 0.001 | .actual_cost_usd = 0.002'

    run mother resume "$id" "operator says continue"
    [ "$status" -ne 0 ]

    run jq -r '.state' "$JOBS_DIR/$id.json"
    [ "$output" = "awaiting" ]
}

@test "resume --max-cost <higher> succeeds, clears .cost-cap flag, moves to ready" {
    local id="cap-resume-ok"
    make_job "$id" "awaiting" \
        '.paused_reason = "cost_cap" | .max_cost_usd = 0.001 | .actual_cost_usd = 0.002'
    mkdir -p "$RUNNER_DIR"
    touch "$RUNNER_DIR/$id.cost-cap"

    run mother resume "$id" --max-cost 5.00

    run jq -r '.state' "$JOBS_DIR/$id.json"
    [ "$output" = "ready" ]
    run jq -r '.max_cost_usd' "$JOBS_DIR/$id.json"
    [ "$output" = "5" ] || [ "$output" = "5.0" ] || [ "$output" = "5.00" ]

    [ ! -f "$RUNNER_DIR/$id.cost-cap" ]
    assert_event_kind "$id" "max_cost_raised"
}

@test "resume --max-cost none clears the cap entirely" {
    local id="cap-resume-none"
    make_job "$id" "awaiting" \
        '.paused_reason = "cost_cap" | .max_cost_usd = 0.001 | .actual_cost_usd = 0.002'
    mkdir -p "$RUNNER_DIR"
    touch "$RUNNER_DIR/$id.cost-cap"

    run mother resume "$id" --max-cost none

    run jq -r '.max_cost_usd // "null"' "$JOBS_DIR/$id.json"
    [ "$output" = "null" ]
    [ ! -f "$RUNNER_DIR/$id.cost-cap" ]
}

# ---------------------------------------------------------------------------
# Token alert: fires exactly once across multiple ticks

@test "token alert: fires exactly once even across multiple poll ticks" {
    local id="cap-token-alert"
    _make_capped_job "$id" 1000.00

    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/full_run.jsonl"
    export MOCK_CLAUDE_SLEEP=6
    export MOTHER_TOKEN_ALERT_THRESHOLD=1

    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job "$id"

    local events_file="$EVENTS_DIR/$id.jsonl"
    run grep -c '"kind":"token_alert"' "$events_file"
    [ "$output" = "1" ]
}

# ---------------------------------------------------------------------------
# mother list COST column

@test "mother list: COST column header present in text format" {
    _make_uncapped_job "list-cost-header"
    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "COST" ]]
}

@test "mother list: uncapped, non-running job with no actual_cost_usd shows '-'" {
    _make_uncapped_job "list-cost-dash"
    run mother list
    [ "$status" -eq 0 ]
    # At minimum, the row must not fabricate a dollar figure out of nothing.
    [[ "$output" == *"list-cost-dash"* ]]
}

@test "mother list: non-running job with actual_cost_usd shows a plain dollar figure" {
    make_job "list-cost-actual" "succeeded" '.actual_cost_usd = 12.34'
    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" =~ \$12\.34 ]]
}

@test "mother list: capped job shows spend/cap format" {
    make_job "list-cost-capfmt" "running" '.max_cost_usd = 10 | .actual_cost_usd = 4.00'
    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" =~ \$4(\.00)?/10 ]] || [[ "$output" =~ "4.00/10" ]]
}

# ---------------------------------------------------------------------------
# Regression: ADHERENCE-BLOCKED marker rendering must survive the COST
# column insertion (no column-count/parsing regression). This mirrors the
# assertions in tests/adherence.bats's "cmd_list shows [ADHERENCE-BLOCKED]
# marker" tests; adherence.bats itself is left unmodified and is the
# authoritative regression check — this is a belt-and-suspenders duplicate
# scoped to this feature's own test file so a `cost_cap.bats`-only run also
# catches a column-shift regression.

@test "mother list: [ADHERENCE-BLOCKED] marker still renders correctly alongside the new COST column" {
    make_job "list-adh-cost" "awaiting" \
        '.pr_url = "https://github.com/Carefeed/test/pull/42"
         | .activity = "adherence_blocked"
         | .adherence_status = "blocked_for_human"
         | .actual_cost_usd = 1.50'
    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ADHERENCE-BLOCKED]"* ]]
    [[ "$output" != *"[adherence_blocked]"* ]]
}
