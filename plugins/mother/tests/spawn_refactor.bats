#!/usr/bin/env bats
# spawn_refactor.bats — contract for extracting mother-run-job's worker
# spawn + poll loop into `_spawn_and_wait <mode> [prompt_file]`
# (mode: fresh | resume), plus `_record_run_usage_for_last_spawn <outcome>
# <run_kind>`.
#
# Sections:
#   1. GOLDEN (HC04-1)  — full-run tests through the real `mother-run-job`
#      that pin today's fresh-spawn behaviour: claude argv, prompt on stdin,
#      current_run fields, worker_spawned event, job-state outcomes. They pass
#      on the pre-refactor code and must keep passing. They assert required
#      keys exist (not exact key sets) so the additive `mode` key is tolerated.
#   2. RED, fresh mode  — the additive `mode: "fresh"` markers.
#   3. RED, resume mode (HC04-2, HC04-3) — drive `_spawn_and_wait resume` and
#      `_record_run_usage_for_last_spawn` directly by sourcing mother-run-job
#      with SOURCE_ONLY=1 inside a child bash (so set -u / globals never leak
#      into bats), against the mock `claude`.
#   4. HC04-4 — resume-mode callers (HC-08) always have a fresh fallback.
#
# Assumptions about the function's environment (the globals a caller of
# `_spawn_and_wait` must have set) are listed at the _rs_run helper below.

load 'test_helper'

MOTHER_RUN_JOB="$_BIN_DIR/mother-run-job"

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
    cat > "$_MOCK_BIN/bishop" <<'B'
#!/usr/bin/env bash
[ "${1:-}" = "get" ] && echo normal
exit 0
B
    chmod +x "$_MOCK_BIN/bishop"

    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=60
    export MOTHER_RESULT_GRACE_SECONDS=30
    # Deterministic argv: fixed agent and a fixed (empty) MCP allowlist.
    export MOTHER_WORKER_AGENT="test-agent"
    export MOTHER_WORKER_MCP_CONFIG="$MOTHER_ROOT/worker-mcp.json"
    echo '{"mcpServers": {}}' > "$MOTHER_WORKER_MCP_CONFIG"
    export MOCK_CLAUDE_STDIN_FILE="$MOTHER_ROOT/mock-claude-stdin"
    METRICS_FILE="$MOTHER_ROOT/metrics/runs.jsonl"
}

teardown() {
    teardown_mother_env
    rm -rf "${TEST_REPO_DIR:-}"
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# argv of the FIRST recorded claude invocation, space-joined (mock_claude
# writes one arg per line and terminates each invocation with "---").
_first_argv() {
    sed '/^---$/q' "$MOCK_CLAUDE_ARGS_FILE" | sed '$d' | tr '\n' ' ' | sed 's/ $//'
}

# Number of claude invocations recorded.
_invocation_count() {
    grep -c '^---$' "$MOCK_CLAUDE_ARGS_FILE" 2>/dev/null || true
}

# detail object of the Nth (1-based) event of a kind for a job.
_event_detail() {
    local id="$1" kind="$2" n="${3:-1}"
    jq -c --arg k "$kind" 'select(.kind == $k) | .detail' "$EVENTS_DIR/$id.jsonl" \
        | sed -n "${n}p"
}

_file_size() {
    stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# 1. GOLDEN — full-run fresh spawn through the real mother-run-job
# ---------------------------------------------------------------------------

_seed_branch() {
    local branch="$1"
    (
        cd "$TEST_REPO_DIR"
        git checkout -q -B "$branch" main
        git commit -q --allow-empty -m "seed for $branch"
        git checkout -q main
    ) >/dev/null 2>&1
}

# A no_pr, main-dir job with a seeded commit ahead of base (so a clean worker
# exit verifies as succeeded) and a pre-existing, non-empty log (so the
# recorded log_offset is observably non-zero).
# Usage: _make_golden_job <id> [max_cost_usd]
GOLDEN_PRELOG=$'previous run output\n'
_make_golden_job() {
    local id="$1" cap="${2:-null}"
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
    printf '%s' "$GOLDEN_PRELOG" > "$LOGS_DIR/$id.log"
    rm -f "$MOCK_CLAUDE_ARGS_FILE" "$MOCK_CLAUDE_STDIN_FILE"
}

@test "golden: a fresh spawn runs claude with exactly the established argv and the job's own --session-id" {
    local id="gold-argv"
    _make_golden_job "$id"

    run mother-run-job "$id"
    [ "$status" -eq 0 ]

    local sid
    sid=$(jq -r '.session_id' "$JOBS_DIR/$id.json")
    [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]

    [ "$(_invocation_count)" = "1" ]
    [ "$(_first_argv)" = "--dangerously-skip-permissions --agent test-agent --model sonnet --effort medium --strict-mcp-config --mcp-config $MOTHER_WORKER_MCP_CONFIG --session-id $sid -p --output-format stream-json --verbose" ]
}

@test "golden: a fresh spawn never passes --resume" {
    local id="gold-noresume"
    _make_golden_job "$id"

    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    if grep -qx -- "--resume" "$MOCK_CLAUDE_ARGS_FILE"; then
        echo "--resume found on a fresh spawn" >&2; return 1
    fi
}

@test "golden: a job with max_cost_usd gets --settings (pointing at the cost gate) just before --session-id; an uncapped job gets none" {
    local capped="gold-capped" uncapped="gold-uncapped"
    _make_golden_job "$capped" 5.00
    run mother-run-job "$capped"
    [ "$status" -eq 0 ]

    local sid settings
    sid=$(jq -r '.session_id' "$JOBS_DIR/$capped.json")
    settings="$RUNNER_DIR/$capped.settings.json"
    [ "$(_first_argv)" = "--dangerously-skip-permissions --agent test-agent --model sonnet --effort medium --strict-mcp-config --mcp-config $MOTHER_WORKER_MCP_CONFIG --settings $settings --session-id $sid -p --output-format stream-json --verbose" ]
    grep -q "mother-cost-gate.sh" "$settings"

    _make_golden_job "$uncapped"
    run mother-run-job "$uncapped"
    [ "$status" -eq 0 ]
    if _first_argv | grep -q -- "--settings"; then
        echo "--settings present on an uncapped job" >&2; return 1
    fi
}

@test "golden: the worker receives the routing context and plan on stdin" {
    local id="gold-stdin"
    _make_golden_job "$id"

    run mother-run-job "$id"
    [ "$status" -eq 0 ]

    [ -s "$MOCK_CLAUDE_STDIN_FILE" ]
    grep -q "# Mother routing context" "$MOCK_CLAUDE_STDIN_FILE"
    grep -q "^# Test plan" "$MOCK_CLAUDE_STDIN_FILE"
    grep -q "## Acceptance criteria" "$MOCK_CLAUDE_STDIN_FILE"
}

@test "golden: a fresh spawn records current_run with log_offset, spawned_at, session_id and the start-baseline fields" {
    local id="gold-currun"
    _make_golden_job "$id"

    run mother-run-job "$id"
    [ "$status" -eq 0 ]

    local jf="$JOBS_DIR/$id.json"
    run jq -e '.current_run | has("log_offset") and has("spawned_at") and has("session_id")
        and has("head_sha_at_start") and has("remote_ref") and has("remote_sha_at_start")
        and has("pr_url_at_start") and has("had_artifact_at_start")' "$jf"
    [ "$status" -eq 0 ]

    # log_offset is the log's size before this run wrote anything.
    [ "$(jq -r '.current_run.log_offset' "$jf")" = "${#GOLDEN_PRELOG}" ]
    [ "$(jq -r '.current_run.session_id' "$jf")" = "$(jq -r '.session_id' "$jf")" ]
    [ -n "$(jq -r '.current_run.spawned_at // empty' "$jf")" ]
    [ "$(jq -r '.current_run.had_artifact_at_start | type' "$jf")" = "boolean" ]
}

@test "golden: a fresh spawn emits worker_spawned with the worker pid and session_id" {
    local id="gold-event"
    _make_golden_job "$id"

    run mother-run-job "$id"
    [ "$status" -eq 0 ]

    local detail
    detail=$(_event_detail "$id" worker_spawned 1)
    [ -n "$detail" ]
    [ "$(printf '%s' "$detail" | jq -r '.pid | type')" = "number" ]
    [ "$(printf '%s' "$detail" | jq -r '.session_id')" = "$(jq -r '.session_id' "$JOBS_DIR/$id.json")" ]
    [ "$(grep -c '"kind":"worker_spawned"' "$EVENTS_DIR/$id.jsonl")" = "1" ]
}

@test "golden: worker exit 0 with commits on the branch ends the job succeeded and records a worker row" {
    local id="gold-ok"
    _make_golden_job "$id"

    run mother-run-job "$id"
    [ "$status" -eq 0 ]

    assert_job_field "$id" '.state' "succeeded"
    assert_job_field_truthy "$id" '.worker_pid'
    local rows
    rows=$(grep -F "\"job_id\":\"$id\"" "$METRICS_FILE")
    [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = "1" ]
    [ "$(printf '%s' "$rows" | jq -r '.run_kind')" = "worker" ]
    [ "$(printf '%s' "$rows" | jq -r '.outcome')" = "succeeded" ]
}

@test "golden: worker exit non-zero ends the job failed carrying the exit code" {
    local id="gold-fail"
    _make_golden_job "$id"
    export MOCK_CLAUDE_EXIT=3

    run mother-run-job "$id"

    assert_job_field "$id" '.state' "failed"
    run jq -r 'select(.kind == "failed") | .detail.exit_code' "$EVENTS_DIR/$id.jsonl"
    [ "$output" = "3" ]
    local row
    row=$(grep -F "\"job_id\":\"$id\"" "$METRICS_FILE")
    [ "$(printf '%s' "$row" | jq -r '.outcome')" = "failed" ]
}

# ---------------------------------------------------------------------------
# 2. RED — additive `mode: "fresh"` markers on the fresh path
# ---------------------------------------------------------------------------

@test "fresh mode: current_run and worker_spawned are additionally tagged mode=fresh" {
    local id="fresh-mode"
    _make_golden_job "$id"

    run mother-run-job "$id"
    [ "$status" -eq 0 ]

    [ "$(jq -r '.current_run.mode' "$JOBS_DIR/$id.json")" = "fresh" ]
    [ "$(_event_detail "$id" worker_spawned 1 | jq -r '.mode')" = "fresh" ]
}

# ---------------------------------------------------------------------------
# 3. RED — resume mode, driven directly through SOURCE_ONLY=1 sourcing
# ---------------------------------------------------------------------------

# _rs_run <bash-body>
#
# Writes $MOTHER_ROOT/driver.sh and runs it with bats' `run` (so $output
# holds stdout+stderr, $status the exit status). The driver sources
# mother-run-job (SOURCE_ONLY=1), then lib/state.sh and lib/usage.sh,
# re-runs _install_core_job_helpers (state.sh redefines _job_update /
# _atomic_write with a different signature), and sets the globals that the
# real main path has set by the time it reaches the spawn:
#
#   id job_file work_dir log_path repo repo_path branch base_ref isolation
#   kind="" phase="" phase_agent="" phase_request_type=""
#   worker_agent worker_model worker_effort current_tier escalation_count
#   usage_main_actor pr_url=""
#
# These are the only globals the tests provide. Anything else the function
# or _record_run_usage_for_last_spawn needs must be read from the job file,
# defaulted with ${VAR:-...}, or computed inside the function.
#
# The job under test is $RS_ID (see _rs_make_job). Its work_dir is a plain
# directory (no git) and its log is pre-seeded with RS_PRELOG.
RS_ID="rs-job"
RS_SID="S-resume-1234"
RS_PRELOG=$'earlier run output line 1\nearlier run output line 2\n'

# Usage: _rs_make_job [extra-jq-filter]
_rs_make_job() {
    local extra="${1:-.}"
    RS_WORK="$MOTHER_ROOT/rs-work"
    RS_LOG="$LOGS_DIR/$RS_ID.log"
    RS_PROMPT="$MOTHER_ROOT/rs-resume-prompt.md"
    mkdir -p "$RS_WORK" "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$RS_ID.md"
    printf 'PLAN-FILE-ONLY-SENTINEL-91c2\n' >> "$MOTHER_ROOT/plans/$RS_ID.md"
    printf '%s' "$RS_PRELOG" > "$RS_LOG"
    printf 'Gate failed: fix the lint errors.\nSECOND LINE OF RESUME PROMPT\n' > "$RS_PROMPT"
    make_job "$RS_ID" "running" \
        '.session_id = "'"$RS_SID"'"
         | .isolation = "main-dir"
         | .repo_path = "'"$RS_WORK"'"
         | .work_dir = "'"$RS_WORK"'"
         | .plan_path = "'"$MOTHER_ROOT/plans/$RS_ID.md"'"
         | .log_path = "'"$RS_LOG"'"
         | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"t"}}
         | '"$extra"
    rm -f "$MOCK_CLAUDE_ARGS_FILE" "$MOCK_CLAUDE_STDIN_FILE"
}

_rs_run() {
    local body="$1"
    cat > "$MOTHER_ROOT/driver.sh" <<DRV
set -u
SOURCE_ONLY=1 source "$MOTHER_RUN_JOB"
source "\$MOTHER_LIB_DIR/state.sh"
source "\$MOTHER_LIB_DIR/usage.sh"
_install_core_job_helpers
id="$RS_ID"
job_file="\$JOBS_DIR/\$id.json"
work_dir="$RS_WORK"
log_path="$RS_LOG"
repo="testrepo"; repo_path="$RS_WORK"; branch="feature/test"; base_ref="main"
isolation="main-dir"
kind=""; phase=""; phase_agent=""; phase_request_type=""
worker_agent="test-agent"; worker_model="sonnet"; worker_effort="medium"
current_tier="tier_0"; escalation_count=0
usage_main_actor="cody-main"
pr_url=""
$body
DRV
    run bash "$MOTHER_ROOT/driver.sh"
}

@test "resume: claude is invoked with --resume <job session_id> and no --session-id" {
    _rs_make_job
    _rs_run '_spawn_and_wait resume "'"$RS_PROMPT"'"; echo "rc=$?"'
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]

    [ "$(_invocation_count)" = "1" ]
    local argv
    argv=$(_first_argv)
    [[ "$argv" == *" --resume $RS_SID -p --output-format stream-json --verbose" ]]
    [[ "$argv" == "--dangerously-skip-permissions --agent test-agent --model sonnet "* ]]
    if grep -qx -- "--session-id" "$MOCK_CLAUDE_ARGS_FILE"; then
        echo "--session-id found on a resume spawn" >&2; return 1
    fi
    if _first_argv | grep -q -- "--settings"; then
        echo "--settings present on an uncapped resume" >&2; return 1
    fi
}

@test "resume: the prompt file's exact contents are delivered on stdin, with no plan or preamble layered on" {
    _rs_make_job
    _rs_run '_spawn_and_wait resume "'"$RS_PROMPT"'"'
    [ "$status" -eq 0 ]

    cmp "$RS_PROMPT" "$MOCK_CLAUDE_STDIN_FILE"
    if grep -q "PLAN-FILE-ONLY-SENTINEL-91c2" "$MOCK_CLAUDE_STDIN_FILE"; then
        echo "plan text leaked into the resume prompt" >&2; return 1
    fi
}

@test "resume: a pending operator answer is left unconsumed" {
    _rs_make_job '.pending_answer = "OPERATOR-ANSWER" | .question = "OPERATOR-QUESTION"'
    _rs_run '_spawn_and_wait resume "'"$RS_PROMPT"'"'
    [ "$status" -eq 0 ]

    assert_job_field "$RS_ID" '.pending_answer' "OPERATOR-ANSWER"
    assert_job_field "$RS_ID" '.question' "OPERATOR-QUESTION"
    if grep -q '"kind":"resumed_from_input"' "$EVENTS_DIR/$RS_ID.jsonl" 2>/dev/null; then
        echo "resume spawn consumed the pending answer" >&2; return 1
    fi
}

@test "resume: current_run and worker_spawned describe the new run (mode=resume, new log_offset, same session_id)" {
    _rs_make_job
    _rs_run '_spawn_and_wait resume "'"$RS_PROMPT"'"'
    [ "$status" -eq 0 ]

    local jf="$JOBS_DIR/$RS_ID.json"
    [ "$(jq -r '.current_run.mode' "$jf")" = "resume" ]
    [ "$(jq -r '.current_run.log_offset' "$jf")" = "${#RS_PRELOG}" ]
    [ "$(jq -r '.current_run.session_id' "$jf")" = "$RS_SID" ]
    [ -n "$(jq -r '.current_run.spawned_at // empty' "$jf")" ]
    run jq -e '.current_run | has("head_sha_at_start") and has("remote_ref") and has("remote_sha_at_start")
        and has("pr_url_at_start") and has("had_artifact_at_start")' "$jf"
    [ "$status" -eq 0 ]
    assert_job_field_truthy "$RS_ID" '.worker_pid'

    local detail
    detail=$(_event_detail "$RS_ID" worker_spawned 1)
    [ "$(printf '%s' "$detail" | jq -r '.mode')" = "resume" ]
    [ "$(printf '%s' "$detail" | jq -r '.session_id')" = "$RS_SID" ]
    [ "$(printf '%s' "$detail" | jq -r '.pid | type')" = "number" ]
}

@test "resume: a job with max_cost_usd keeps the cost-cap --settings on the resumed claude" {
    _rs_make_job '.max_cost_usd = 5'
    _rs_run '_spawn_and_wait resume "'"$RS_PROMPT"'"'
    [ "$status" -eq 0 ]

    local settings
    settings=$(mock_claude_flag_value "--settings")
    [ -n "$settings" ]
    [ -f "$settings" ]
    grep -q "mother-cost-gate.sh" "$settings"
    [[ "$(_first_argv)" == *" --resume $RS_SID "* ]]
}

# A claude stand-in for the two-call tests. Call 1: emits one assistant turn
# (500 in / 50 out) and exits 0 immediately. Call 2: emits a different turn
# (70 in / 7 out), keeps running for ${MOCK_SECOND_SLEEP:-0}s, then touches
# $MOCK_DONE_FILE and exits 7.
_install_two_call_claude() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$@" >> "$MOCK_CLAUDE_ARGS_FILE"; echo "---" >> "$MOCK_CLAUDE_ARGS_FILE"
n=$(cat "$MOCK_COUNTER_FILE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$MOCK_COUNTER_FILE"
if [ "$n" = "1" ]; then
    echo '{"type":"assistant","message":{"id":"msg_call1","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}'
    exit 0
fi
echo '{"type":"assistant","message":{"id":"msg_call2","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":70,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":7}}}'
sleep "${MOCK_SECOND_SLEEP:-0}"
touch "$MOCK_DONE_FILE"
exit 7
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    export MOCK_COUNTER_FILE="$MOTHER_ROOT/mock-counter"
    export MOCK_DONE_FILE="$MOTHER_ROOT/mock-second-done"
    rm -f "$MOCK_COUNTER_FILE" "$MOCK_DONE_FILE"
}

@test "resume: a second call waits for its own worker and its own exit code, never the first call's marker" {
    _rs_make_job
    _install_two_call_claude
    export MOCK_SECOND_SLEEP=3

    _rs_run '
_spawn_and_wait resume "'"$RS_PROMPT"'"
echo "first_exit_code=$exit_code"
sleep 1
_spawn_and_wait resume "'"$RS_PROMPT"'"
echo "second_exit_code=$exit_code"
[ -f "'"$MOCK_DONE_FILE"'" ] && echo "second_worker_finished=yes" || echo "second_worker_finished=no"
'
    [ "$status" -eq 0 ]
    [[ "$output" == *"first_exit_code=0"* ]]
    # A stale first-call marker would return immediately with exit code 0
    # while the second worker was still running.
    [[ "$output" == *"second_exit_code=7"* ]]
    [[ "$output" == *"second_worker_finished=yes"* ]]
    [ "$(_invocation_count)" = "2" ]
}

@test "resume: each call starts its own log_offset where the previous call's output ended" {
    _rs_make_job
    _install_two_call_claude

    _rs_run '
_spawn_and_wait resume "'"$RS_PROMPT"'"
echo "offset1=$log_offset_at_spawn"
sleep 1
echo "size_after_first=$(stat -f %z "$log_path" 2>/dev/null || stat -c %s "$log_path")"
_spawn_and_wait resume "'"$RS_PROMPT"'"
echo "offset2=$log_offset_at_spawn"
'
    [ "$status" -eq 0 ]
    local offset1 size1 offset2
    offset1=$(printf '%s\n' "$output" | sed -n 's/^offset1=//p')
    size1=$(printf '%s\n' "$output" | sed -n 's/^size_after_first=//p')
    offset2=$(printf '%s\n' "$output" | sed -n 's/^offset2=//p')

    [ "$offset1" = "${#RS_PRELOG}" ]
    [ "$size1" -gt "$offset1" ]
    [ "$offset2" = "$size1" ]
    # current_run mirrors the most recent spawn.
    [ "$(jq -r '.current_run.log_offset' "$JOBS_DIR/$RS_ID.json")" = "$size1" ]
    # Two spawns, two worker_spawned events, distinct pids.
    [ "$(grep -c '"kind":"worker_spawned"' "$EVENTS_DIR/$RS_ID.jsonl")" = "2" ]
    [ "$(_event_detail "$RS_ID" worker_spawned 1 | jq -r '.pid')" != "$(_event_detail "$RS_ID" worker_spawned 2 | jq -r '.pid')" ]
}

@test "resume usage: _record_run_usage_for_last_spawn writes a separate, offset-scoped row with the caller's run_kind" {
    _rs_make_job
    _install_two_call_claude

    _rs_run '
_spawn_and_wait resume "'"$RS_PROMPT"'"
_record_run_usage_for_last_spawn succeeded worker
sleep 1
_spawn_and_wait resume "'"$RS_PROMPT"'"
_record_run_usage_for_last_spawn failed gate_fix
'
    [ "$status" -eq 0 ]

    local rows
    rows=$(grep -F "\"job_id\":\"$RS_ID\"" "$METRICS_FILE")
    [ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = "2" ]

    local row1 row2
    row1=$(printf '%s\n' "$rows" | sed -n 1p)
    row2=$(printf '%s\n' "$rows" | sed -n 2p)
    [ "$(printf '%s' "$row1" | jq -r '.run_kind')" = "worker" ]
    [ "$(printf '%s' "$row1" | jq -r '.outcome')" = "succeeded" ]
    [ "$(printf '%s' "$row2" | jq -r '.run_kind')" = "gate_fix" ]
    [ "$(printf '%s' "$row2" | jq -r '.outcome')" = "failed" ]
    # Each row covers only its own run's tokens (not the cumulative log).
    [ "$(printf '%s' "$row1" | jq -r '.tokens_in')" = "500" ]
    [ "$(printf '%s' "$row1" | jq -r '.tokens_out')" = "50" ]
    [ "$(printf '%s' "$row2" | jq -r '.tokens_in')" = "70" ]
    [ "$(printf '%s' "$row2" | jq -r '.tokens_out')" = "7" ]
    # Schema-2 rows, same as every other usage row.
    [ "$(printf '%s' "$row2" | jq -r '.schema')" = "2" ]
}

@test "resume: a job with no session_id fails clearly and spawns nothing" {
    _rs_make_job 'del(.session_id)'
    _rs_run '( _spawn_and_wait resume "'"$RS_PROMPT"'" ); echo "rc=$?"'

    [[ "$output" == *"rc="* ]]
    [[ "$output" != *"rc=0"* ]]
    # Must fail because the function rejected the call, not because it is undefined.
    [[ "$output" != *"command not found"* ]]
    [[ "$output" == *[Ss]ession* ]]
    [ ! -s "$MOCK_CLAUDE_ARGS_FILE" ]
    if grep -q '"kind":"worker_spawned"' "$EVENTS_DIR/$RS_ID.jsonl" 2>/dev/null; then
        echo "worker_spawned emitted although nothing should have spawned" >&2; return 1
    fi
    [ "$(jq -r '.current_run // empty' "$JOBS_DIR/$RS_ID.json")" = "" ]
}

@test "resume: a missing prompt file fails clearly and spawns nothing" {
    _rs_make_job
    _rs_run '( _spawn_and_wait resume "'"$MOTHER_ROOT"'/does-not-exist.md" ); echo "rc=$?"'

    [[ "$output" == *"rc="* ]]
    [[ "$output" != *"rc=0"* ]]
    # Must fail because the function rejected the call, not because it is undefined.
    [[ "$output" != *"command not found"* ]]
    [ ! -s "$MOCK_CLAUDE_ARGS_FILE" ]
    if grep -q '"kind":"worker_spawned"' "$EVENTS_DIR/$RS_ID.jsonl" 2>/dev/null; then
        echo "worker_spawned emitted although nothing should have spawned" >&2; return 1
    fi
}

# ---------------------------------------------------------------------------
# 4. HC04-4 — resume mode is used, but never without a fresh fallback
# (HC-08 added the callers: gate-fix turns and gate-hold guidance resumes.)
# ---------------------------------------------------------------------------

@test "every _spawn_and_wait resume call in mother-run-job is followed by a fresh-fallback check" {
    # Executable lines only (comments dropped); function definitions excluded.
    local calls resumes checks
    calls=$(grep -vE '^[[:space:]]*#' "$MOTHER_RUN_JOB" \
        | grep -E '(^|[^_[:alnum:]])_spawn_and_wait[[:space:]]' \
        | grep -vE '_spawn_and_wait[[:space:]]*\(\)|function[[:space:]]+_spawn_and_wait' || true)
    printf '%s\n' "$calls" | grep -Eq '_spawn_and_wait[[:space:]]+fresh([[:space:]]|$|;|&)'
    resumes=$(printf '%s\n' "$calls" | grep -c '_spawn_and_wait[[:space:]]\+resume' || true)
    checks=$(grep -vE '^[[:space:]]*#' "$MOTHER_RUN_JOB" \
        | grep -E '_gates_spawn_failed_immediately[[:space:]]+"' | grep -vc '()' || true)
    [ "$resumes" -ge 1 ]
    [ "$resumes" = "$checks" ]
}
