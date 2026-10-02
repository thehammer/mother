#!/usr/bin/env bats
# rwx_sandbox.bats — RWX cloud-sandbox lifecycle around the worker.
#
# Contract under test:
#   - Pre-spawn: when the job's work_dir has .rwx/sandbox.yml, `rwx` is on PATH
#     and MOTHER_RWX_SANDBOX_ENABLED != 0, mother-run-job runs
#     `rwx sandbox reset .rwx/sandbox.yml` (cwd = work_dir) under a watchdog
#     (MOTHER_RWX_RESET_TIMEOUT) and appends an `rwx_sandbox_reset` event whose
#     detail is {action, command, outcome: ok|error|timeout, exit_code,
#     duration_s, output_tail}.
#   - No .rwx/sandbox.yml => nothing at all (no rwx calls, no events).
#     MOTHER_RWX_SANDBOX_ENABLED=0 / rwx missing => a reset event with detail
#     {outcome: "skipped", reason: "disabled"|"no_cli"} and no rwx calls.
#   - Attempt key "<escalation_count>:<retry_count>" is stored on the job as
#     .rwx_sandbox.reset_key. A matching key means resume/continuation/rework:
#     the reset is skipped silently. Stored even when the reset errors/times out.
#   - Post-exit: after EVERY worker exit (before main-dir stash-restore / lock
#     release) `rwx sandbox stop` runs with cwd = work_dir and an
#     `rwx_sandbox_stop` event is appended — only when the gate was ok. If a
#     newer worker owns the job (.worker_pid differs) it is skipped with
#     {outcome: "skipped", reason: "newer_worker"}.
#   - RWX failure/hang/absence never changes the job's terminal state or
#     failure_reason.
#
# Plus unit-style coverage of lib/rwx.sh (mother_rwx_gate / mother_rwx_sandbox)
# and the preamble's RWX section.
#
# Harness: a fake `rwx` in mock-bin appends "<cwd>|<args>|<git branch>" to
# $MOTHER_ROOT/rwx-calls.log. The claude stand-ins append "claude-start" /
# "claude-end" to the same log so ordering is observable.

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
        mkdir -p .rwx
        printf 'base: ubuntu\n' > .rwx/sandbox.yml
        git add .
        git commit -m "init" --allow-empty
    ) >/dev/null 2>&1

    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"

    # Fake rwx. Env knobs (generic, or per-action by suffix _RESET/_STOP/_START;
    # the per-action knob wins):
    #   MOCK_RWX_EXIT    exit code (default 0)
    #   MOCK_RWX_SLEEP   seconds to hang instead of exiting (default 0)
    #   MOCK_RWX_OUTPUT  text printed to stdout
    cat > "$_MOCK_BIN/rwx" <<'RWX'
#!/usr/bin/env bash
action="${2:-}"
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
printf '%s|%s|%s\n' "$(pwd -P)" "$*" "$branch" >> "$MOTHER_ROOT/rwx-calls.log"
upper=$(printf '%s' "$action" | tr 'a-z' 'A-Z')
_pick() {
    local v="MOCK_RWX_${1}_${upper}"
    if [ -n "${!v:-}" ]; then printf '%s' "${!v}"; return; fi
    v="MOCK_RWX_$1"
    printf '%s' "${!v:-$2}"
}
out=$(_pick OUTPUT "")
[ -n "$out" ] && printf '%s\n' "$out"
sl=$(_pick SLEEP 0)
[ "$sl" != "0" ] && exec sleep "$sl"
exit "$(_pick EXIT 0)"
RWX
    chmod +x "$_MOCK_BIN/rwx"

    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120

    RWX_LOG="$MOTHER_ROOT/rwx-calls.log"
}

teardown() {
    # Worktree-isolation cases create sibling dirs of the test repo.
    [ -n "${TEST_REPO_DIR:-}" ] && rm -rf "${TEST_REPO_DIR}"-* 2>/dev/null
    teardown_mother_env
    rm -rf "${TEST_REPO_DIR:-}"
}

# ---------------------------------------------------------------------------
# Helpers

_seed_branch() {
    local branch="$1"
    (
        cd "$TEST_REPO_DIR"
        git checkout -q -B "$branch" main
        git commit -q --allow-empty -m "seed for $branch"
        git checkout -q main
    ) >/dev/null 2>&1
}

_job_filter_common() {
    local id="$1"
    printf '%s' '.repo_path = "'"$TEST_REPO_DIR"'"
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
}

# no_pr main-dir job with a seeded commit ahead of base (can reach succeeded).
# The seeded branch is cut from main AFTER .rwx/sandbox.yml was committed.
# $2 is an optional extra jq filter.
_make_no_pr_job() {
    local id="$1" extra="${2:-.}"
    _seed_branch "feature/test-$id"
    make_job "$id" "ready" \
        ".isolation = \"main-dir\" | $(_job_filter_common "$id") | $extra"
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"
}

# Same, but worktree isolation (a real worktree is created by mother-run-job).
_make_worktree_job() {
    local id="$1"
    _seed_branch "feature/test-$id"
    make_job "$id" "ready" \
        ".isolation = \"worktree\" | $(_job_filter_common "$id")"
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"
}

# Remove .rwx/sandbox.yml from main (call BEFORE creating the job/branch).
_drop_sandbox_config() {
    (
        cd "$TEST_REPO_DIR"
        git rm -q -r .rwx
        git commit -q -m "drop rwx config"
    ) >/dev/null 2>&1
}

# Claude stand-in that succeeds. Brackets its run with markers in the rwx log.
_install_claude_ok() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude-start" >> "$MOTHER_ROOT/rwx-calls.log"
cat <<'EOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
echo "claude-end" >> "$MOTHER_ROOT/rwx-calls.log"
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}

# Claude stand-in that pauses via a real `mother await`, then exits 0.
_install_claude_await() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude-start" >> "$MOTHER_ROOT/rwx-calls.log"
mother await --question "need clarification before continuing" >/dev/null 2>&1
echo "claude-end" >> "$MOTHER_ROOT/rwx-calls.log"
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}

_run_job() {
    run mother-run-job "$1"
    [ "$status" -eq 0 ]
}

# --- rwx call log queries ---------------------------------------------------

_count_lines() {
    local n
    n=$(grep -cF -- "$1" "$RWX_LOG" 2>/dev/null) || true
    echo "${n:-0}"
}
_reset_calls() { _count_lines '|sandbox reset .rwx/sandbox.yml|'; }
_stop_calls()  { _count_lines '|sandbox stop|'; }
_all_rwx_calls() { _count_lines '|sandbox '; }

# Line number of the Nth (default 1st) line containing a fixed string.
_line_of() {
    grep -nF -- "$1" "$RWX_LOG" | sed -n "${2:-1}p" | cut -d: -f1
}

# --- event queries ----------------------------------------------------------

_event_count() {
    jq -c --arg k "$2" 'select(.kind == $k)' "$EVENTS_DIR/$1.jsonl" 2>/dev/null \
        | wc -l | tr -d ' '
}
# _event_field <id> <kind> <nth> <field>   (nth is 1-based; "last" allowed)
_event_field() {
    local id="$1" kind="$2" nth="$3" field="$4" line
    if [ "$nth" = "last" ]; then
        line=$(jq -c --arg k "$kind" 'select(.kind == $k) | .detail' "$EVENTS_DIR/$id.jsonl" | tail -1)
    else
        line=$(jq -c --arg k "$kind" 'select(.kind == $k) | .detail' "$EVENTS_DIR/$id.jsonl" | sed -n "${nth}p")
    fi
    printf '%s' "$line" | jq -r ".$field"
}

# A PATH identical to the current one except that every directory containing an
# `rwx` executable is replaced by a shadow dir of symlinks to everything else in
# it. (The real rwx lives in /opt/homebrew/bin on the dev machine.)
_path_without_rwx() {
    local out="" dir shadow f n=0
    local IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] || continue
        if [ -x "$dir/rwx" ]; then
            n=$((n + 1))
            shadow="$MOTHER_ROOT/shadow-path-$n"
            mkdir -p "$shadow"
            for f in "$dir"/*; do
                [ -e "$f" ] || continue
                [ "${f##*/}" = "rwx" ] && continue
                ln -s "$f" "$shadow/${f##*/}" 2>/dev/null || true
            done
            dir="$shadow"
        fi
        out="${out:+$out:}$dir"
    done
    printf '%s' "$out"
}

# Make `rwx` invisible to this test and everything it spawns.
_hide_rwx() {
    rm -f "$_MOCK_BIN/rwx"
    local sanitized
    sanitized=$(_path_without_rwx)
    export PATH="$sanitized"
    run /bin/bash -c 'command -v rwx'
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# Case 1: no .rwx/sandbox.yml => RWX is entirely invisible.

@test "repo without .rwx/sandbox.yml: no rwx calls, no rwx events, job succeeds" {
    local id="rwx-none"
    _drop_sandbox_config
    _make_no_pr_job "$id"
    _install_claude_ok

    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_all_rwx_calls)" = "0" ]
    [ "$(_event_count "$id" rwx_sandbox_reset)" = "0" ]
    [ "$(_event_count "$id" rwx_sandbox_stop)" = "0" ]
    # Claude did run.
    grep -qF 'claude-start' "$RWX_LOG"
}

# ---------------------------------------------------------------------------
# Case 2: first run — reset before claude, stop after, from the work_dir.

@test "first run: one sandbox reset before claude starts and one sandbox stop after it exits, both from work_dir" {
    local id="rwx-first"
    _make_no_pr_job "$id"
    _install_claude_ok

    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_reset_calls)" = "1" ]
    [ "$(_stop_calls)" = "1" ]

    # Ordering: reset < claude-start < claude-end < stop.
    local l_reset l_start l_end l_stop
    l_reset=$(_line_of '|sandbox reset .rwx/sandbox.yml|')
    l_start=$(_line_of 'claude-start')
    l_end=$(_line_of 'claude-end')
    l_stop=$(_line_of '|sandbox stop|')
    [ "$l_reset" -lt "$l_start" ]
    [ "$l_start" -lt "$l_end" ]
    [ "$l_end" -lt "$l_stop" ]

    # Both calls ran with cwd = the job's work_dir.
    local work_dir real_work_dir
    work_dir=$(jq -r '.work_dir' "$JOBS_DIR/$id.json")
    real_work_dir=$(cd "$work_dir" && pwd -P)
    grep -F '|sandbox reset .rwx/sandbox.yml|' "$RWX_LOG" | head -1 | grep -q "^${real_work_dir}|"
    grep -F '|sandbox stop|' "$RWX_LOG" | head -1 | grep -q "^${real_work_dir}|"

    # Events.
    [ "$(_event_count "$id" rwx_sandbox_reset)" = "1" ]
    [ "$(_event_count "$id" rwx_sandbox_stop)" = "1" ]
    [ "$(_event_field "$id" rwx_sandbox_reset 1 action)" = "reset" ]
    [ "$(_event_field "$id" rwx_sandbox_reset 1 outcome)" = "ok" ]
    [ "$(_event_field "$id" rwx_sandbox_reset 1 exit_code)" = "0" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 1 action)" = "stop" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 1 outcome)" = "ok" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 1 exit_code)" = "0" ]
    # duration_s is numeric; command is recorded.
    run jq -e '.detail | (.duration_s | type) == "number" and (.command | length) > 0' \
        <(jq -c 'select(.kind == "rwx_sandbox_reset")' "$EVENTS_DIR/$id.jsonl")
    [ "$status" -eq 0 ]

    # Attempt key persisted on the job.
    assert_job_field "$id" '.rwx_sandbox.reset_key' '0:0'
    assert_job_field "$id" '.rwx_sandbox.last_reset_outcome' 'ok'
    assert_job_field_truthy "$id" '.rwx_sandbox.reset_at'
}

@test "worktree isolation: reset and stop run from the job's worktree" {
    local id="rwx-worktree"
    _make_worktree_job "$id"
    _install_claude_ok

    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_reset_calls)" = "1" ]
    [ "$(_stop_calls)" = "1" ]

    local work_dir real_work_dir
    work_dir=$(jq -r '.work_dir' "$JOBS_DIR/$id.json")
    [ -d "$work_dir" ] || skip "worktree was torn down before assertion"
    real_work_dir=$(cd "$work_dir" && pwd -P)
    [ "$real_work_dir" != "$(cd "$TEST_REPO_DIR" && pwd -P)" ]
    grep -F '|sandbox reset .rwx/sandbox.yml|' "$RWX_LOG" | head -1 | grep -q "^${real_work_dir}|"
    grep -F '|sandbox stop|' "$RWX_LOG" | head -1 | grep -q "^${real_work_dir}|"
}

# ---------------------------------------------------------------------------
# Case 3: resume after awaiting => no second reset; a stop after each worker exit.

@test "resume after awaiting: one reset total, one stop per worker exit" {
    local id="rwx-resume"
    _make_no_pr_job "$id"

    # Run 1: worker pauses via `mother await`.
    _install_claude_await
    _run_job "$id"
    assert_job_field "$id" '.state' 'awaiting'
    [ "$(_reset_calls)" = "1" ]
    # Stop runs after EVERY worker exit — including one that ends in awaiting.
    [ "$(_stop_calls)" = "1" ]
    [ "$(_event_count "$id" rwx_sandbox_stop)" = "1" ]

    # Operator answers; run 2 finishes.
    run mother resume "$id" "please continue"
    [ "$status" -eq 0 ]
    _install_claude_ok
    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_reset_calls)" = "1" ]
    [ "$(_stop_calls)" = "2" ]
    [ "$(_event_count "$id" rwx_sandbox_reset)" = "1" ]
    [ "$(_event_count "$id" rwx_sandbox_stop)" = "2" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 2 outcome)" = "ok" ]
    assert_job_field "$id" '.rwx_sandbox.reset_key' '0:0'
}

@test "a job whose attempt key already matches skips the reset silently but still stops" {
    local id="rwx-key-match"
    _make_no_pr_job "$id" '.rwx_sandbox = {reset_key: "0:0", reset_at: "2026-01-01T00:00:00Z", last_reset_outcome: "ok"}'
    _install_claude_ok

    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_reset_calls)" = "0" ]
    [ "$(_event_count "$id" rwx_sandbox_reset)" = "0" ]
    [ "$(_stop_calls)" = "1" ]
    [ "$(_event_count "$id" rwx_sandbox_stop)" = "1" ]
}

# ---------------------------------------------------------------------------
# Case 4: a new attempt (escalation / retry) resets again.

@test "after escalation_count is bumped, the next run resets the sandbox again" {
    local id="rwx-escalated"
    _make_no_pr_job "$id"

    _install_claude_await
    _run_job "$id"
    assert_job_field "$id" '.state' 'awaiting'
    [ "$(_reset_calls)" = "1" ]

    # A new attempt: escalation bumps the counter before the next run.
    local merged
    merged=$(jq '.escalation_count = 1' "$JOBS_DIR/$id.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/$id.json"
    run mother resume "$id" "go on"
    [ "$status" -eq 0 ]

    _install_claude_ok
    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_reset_calls)" = "2" ]
    [ "$(_stop_calls)" = "2" ]
    [ "$(_event_count "$id" rwx_sandbox_reset)" = "2" ]
    assert_job_field "$id" '.rwx_sandbox.reset_key' '1:0'
}

@test "after retry_count is bumped, the next run resets the sandbox again" {
    local id="rwx-retried"
    _make_no_pr_job "$id"

    _install_claude_await
    _run_job "$id"
    assert_job_field "$id" '.state' 'awaiting'
    [ "$(_reset_calls)" = "1" ]

    local merged
    merged=$(jq '.retry_count = 1' "$JOBS_DIR/$id.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/$id.json"
    run mother resume "$id" "go on"
    [ "$status" -eq 0 ]

    _install_claude_ok
    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_reset_calls)" = "2" ]
    assert_job_field "$id" '.rwx_sandbox.reset_key' '0:1'
}

# ---------------------------------------------------------------------------
# Case 5: rwx failing never changes the job's outcome.

@test "rwx exiting 1 on reset and stop is recorded as error and the job still succeeds" {
    local id="rwx-errors"
    _make_no_pr_job "$id"
    _install_claude_ok
    export MOCK_RWX_EXIT=1
    export MOCK_RWX_OUTPUT="boom: sandbox backend unavailable"

    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    assert_job_field "$id" '.failure_reason // "none"' 'none'
    [ "$(_event_field "$id" rwx_sandbox_reset 1 outcome)" = "error" ]
    [ "$(_event_field "$id" rwx_sandbox_reset 1 exit_code)" = "1" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 1 outcome)" = "error" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 1 exit_code)" = "1" ]
    # Output is surfaced for the operator.
    [[ "$(_event_field "$id" rwx_sandbox_reset 1 output_tail)" == *"sandbox backend unavailable"* ]]
    # The worker still ran after the failed reset.
    grep -qF 'claude-start' "$RWX_LOG"
    # Key is stored even though the reset errored (no reset storm on resume).
    assert_job_field "$id" '.rwx_sandbox.reset_key' '0:0'
    assert_job_field "$id" '.rwx_sandbox.last_reset_outcome' 'error'
}

# ---------------------------------------------------------------------------
# Case 6: a hung rwx is bounded by the watchdog.

@test "hung rwx reset times out, the worker still spawns, and the run is not held hostage" {
    local id="rwx-hang"
    _make_no_pr_job "$id"
    _install_claude_ok
    export MOCK_RWX_SLEEP=30
    export MOTHER_RWX_RESET_TIMEOUT=2
    export MOTHER_RWX_STOP_TIMEOUT=2

    local t0 t1
    t0=$(date +%s)
    _run_job "$id"
    t1=$(date +%s)

    [ $((t1 - t0)) -lt 25 ]
    assert_job_field "$id" '.state' 'succeeded'
    assert_job_field "$id" '.failure_reason // "none"' 'none'
    [ "$(_event_field "$id" rwx_sandbox_reset 1 outcome)" = "timeout" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 1 outcome)" = "timeout" ]
    grep -qF 'claude-start' "$RWX_LOG"
    grep -qF 'claude-end' "$RWX_LOG"
    assert_job_field "$id" '.rwx_sandbox.reset_key' '0:0'
    assert_job_field "$id" '.rwx_sandbox.last_reset_outcome' 'timeout'
}

# ---------------------------------------------------------------------------
# Case 7: kill switches.

@test "MOTHER_RWX_SANDBOX_ENABLED=0: no rwx calls, reset recorded as skipped/disabled, job succeeds" {
    local id="rwx-disabled"
    _make_no_pr_job "$id"
    _install_claude_ok
    export MOTHER_RWX_SANDBOX_ENABLED=0

    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_all_rwx_calls)" = "0" ]
    [ "$(_event_count "$id" rwx_sandbox_reset)" = "1" ]
    [ "$(_event_field "$id" rwx_sandbox_reset 1 outcome)" = "skipped" ]
    [ "$(_event_field "$id" rwx_sandbox_reset 1 reason)" = "disabled" ]
    # No stop when the gate wasn't open.
    [ "$(_event_count "$id" rwx_sandbox_stop)" = "0" ]
}

@test "rwx not installed: no rwx calls, reset recorded as skipped/no_cli, job succeeds" {
    local id="rwx-nocli"
    _make_no_pr_job "$id"
    _install_claude_ok
    _hide_rwx

    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_all_rwx_calls)" = "0" ]
    [ "$(_event_count "$id" rwx_sandbox_reset)" = "1" ]
    [ "$(_event_field "$id" rwx_sandbox_reset 1 outcome)" = "skipped" ]
    [ "$(_event_field "$id" rwx_sandbox_reset 1 reason)" = "no_cli" ]
    [ "$(_event_count "$id" rwx_sandbox_stop)" = "0" ]
}

# ---------------------------------------------------------------------------
# Case 8: a stale supervisor must not stop a sandbox a newer worker owns.

@test "stale supervisor: stop is skipped as newer_worker when the job's worker_pid changed" {
    local id="rwx-stale"
    _make_no_pr_job "$id"

    # The worker simulates "a resume spawned a newer supervisor/worker" by
    # rewriting the job's worker_pid before it exits.
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude-start" >> "$MOTHER_ROOT/rwx-calls.log"
jf="$MOTHER_ROOT/jobs/$MOTHER_JOB_ID.json"
tmp=$(jq '.worker_pid = 999999' "$jf") && printf '%s' "$tmp" > "$jf"
cat <<'EOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
echo "claude-end" >> "$MOTHER_ROOT/rwx-calls.log"
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"

    # The supervisor exits as a stale supervisor; only the stop behaviour is
    # asserted (not exit status or terminal state).
    run mother-run-job "$id"

    [ "$(_reset_calls)" = "1" ]
    [ "$(_stop_calls)" = "0" ]
    [ "$(_event_count "$id" rwx_sandbox_stop)" = "1" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 1 outcome)" = "skipped" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 1 reason)" = "newer_worker" ]
}

# ---------------------------------------------------------------------------
# Case 9: main-dir isolation with a dirty operator tree.

@test "main-dir with a dirty operator checkout: reset and stop run on the job branch, then the operator's tree is restored" {
    local id="rwx-maindir-dirty"
    _make_no_pr_job "$id"
    _install_claude_ok

    # Operator is sitting on main with an uncommitted tracked-file edit.
    echo "operator-edit" >> "$TEST_REPO_DIR/README.md"
    [ "$(git -C "$TEST_REPO_DIR" rev-parse --abbrev-ref HEAD)" = "main" ]

    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_reset_calls)" = "1" ]
    [ "$(_stop_calls)" = "1" ]

    # Both rwx calls saw the JOB's branch checked out, not the operator's.
    local reset_line stop_line
    reset_line=$(grep -F '|sandbox reset .rwx/sandbox.yml|' "$RWX_LOG" | head -1)
    stop_line=$(grep -F '|sandbox stop|' "$RWX_LOG" | head -1)
    [ "${reset_line##*|}" = "feature/test-$id" ]
    [ "${stop_line##*|}" = "feature/test-$id" ]

    # Sanity: the operator's tree came back afterwards.
    [ "$(git -C "$TEST_REPO_DIR" rev-parse --abbrev-ref HEAD)" = "main" ]
    grep -q 'operator-edit' "$TEST_REPO_DIR/README.md"
}

# ===========================================================================
# lib/rwx.sh — unit-style coverage (sourced under set -u, MOTHER_RWX_* unset).

# Run a snippet in a fresh bash with lib/rwx.sh sourced under `set -u`.
# Only MOTHER_RWX_SANDBOX_ENABLED is cleared; tests export timeouts as needed.
_rwx_sh() {
    /bin/bash -c '
        set -u
        # A test may export a timeout knob; only the kill switch is forced unset.
        unset MOTHER_RWX_SANDBOX_ENABLED
        source "'"$_LIB_DIR"'/rwx.sh"
        '"$1"
}

_sandbox_dir() {
    local d="$MOTHER_ROOT/sbx"
    mkdir -p "$d/.rwx"
    printf 'base: ubuntu\n' > "$d/.rwx/sandbox.yml"
    (cd "$d" && pwd -P)
}

@test "mother_rwx_gate: ok when config present, enabled, and rwx on PATH" {
    local d; d=$(_sandbox_dir)
    run _rwx_sh 'mother_rwx_gate "'"$d"'"'
    [ "$status" -eq 0 ]
    [ "$output" = "ok" ]
}

@test "mother_rwx_gate: no_config when .rwx/sandbox.yml is absent" {
    local d="$MOTHER_ROOT/plain"; mkdir -p "$d"
    run _rwx_sh 'mother_rwx_gate "'"$d"'"'
    [ "$status" -ne 0 ]
    [ "$output" = "no_config" ]
}

@test "mother_rwx_gate: disabled when MOTHER_RWX_SANDBOX_ENABLED=0" {
    local d; d=$(_sandbox_dir)
    run _rwx_sh 'MOTHER_RWX_SANDBOX_ENABLED=0 mother_rwx_gate "'"$d"'"'
    [ "$status" -ne 0 ]
    [ "$output" = "disabled" ]
}

@test "mother_rwx_gate: no_cli when rwx is not on PATH" {
    local d; d=$(_sandbox_dir)
    _hide_rwx
    run _rwx_sh 'mother_rwx_gate "'"$d"'"'
    [ "$status" -ne 0 ]
    [ "$output" = "no_cli" ]
}

@test "mother_rwx_sandbox reset: runs rwx sandbox reset from the dir and echoes one JSON object with the documented keys" {
    local d; d=$(_sandbox_dir)
    run _rwx_sh 'mother_rwx_sandbox reset "'"$d"'"'
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
    printf '%s' "$output" | jq -e '
        type == "object"
        and has("action") and has("command") and has("outcome")
        and has("exit_code") and has("duration_s") and has("output_tail")
        and .action == "reset" and .outcome == "ok" and .exit_code == 0
        and (.duration_s | type) == "number"
        and (.command | contains("sandbox reset"))' >/dev/null
    grep -qF "${d}|sandbox reset .rwx/sandbox.yml|" "$RWX_LOG"
}

@test "mother_rwx_sandbox stop: runs rwx sandbox stop from the dir" {
    local d; d=$(_sandbox_dir)
    run _rwx_sh 'mother_rwx_sandbox stop "'"$d"'"'
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.action == "stop" and .outcome == "ok" and (.command | contains("sandbox stop"))' >/dev/null
    grep -qF "${d}|sandbox stop|" "$RWX_LOG"
}

@test "mother_rwx_sandbox: always returns 0 and reports outcome error with the real exit code" {
    local d; d=$(_sandbox_dir)
    export MOCK_RWX_EXIT=3
    run _rwx_sh 'mother_rwx_sandbox stop "'"$d"'"; echo "rc=$?" >&2'
    [ "$status" -eq 0 ]
    printf '%s' "$output" | grep -v '^rc=' | jq -e '.outcome == "error" and .exit_code == 3' >/dev/null
}

@test "mother_rwx_sandbox: a hung rwx is killed by the watchdog and reported as timeout" {
    local d; d=$(_sandbox_dir)
    export MOCK_RWX_SLEEP=30
    export MOTHER_RWX_RESET_TIMEOUT=1
    local t0 t1
    t0=$(date +%s)
    run _rwx_sh 'mother_rwx_sandbox reset "'"$d"'"'
    t1=$(date +%s)
    [ "$status" -eq 0 ]
    [ $((t1 - t0)) -lt 15 ]
    printf '%s' "$output" | jq -e '.outcome == "timeout"' >/dev/null
}

@test "mother_rwx_sandbox: output_tail drops the rwx upgrade banner" {
    local d; d=$(_sandbox_dir)
    export MOCK_RWX_OUTPUT=$'A new release of rwx is available: 3.0.0 -> 3.1.0\nsandbox reset complete'
    run _rwx_sh 'mother_rwx_sandbox reset "'"$d"'"'
    [ "$status" -eq 0 ]
    local tail_text
    tail_text=$(printf '%s' "$output" | jq -r '.output_tail')
    [[ "$tail_text" == *"sandbox reset complete"* ]]
    [[ "$tail_text" != *"A new release of rwx is available"* ]]
}

@test "mother_rwx_sandbox: output_tail is at most 300 characters" {
    local d; d=$(_sandbox_dir)
    export MOCK_RWX_OUTPUT="$(head -c 1500 /dev/zero | tr '\0' 'x')"
    run _rwx_sh 'mother_rwx_sandbox reset "'"$d"'"'
    [ "$status" -eq 0 ]
    local n
    n=$(printf '%s' "$output" | jq -r '.output_tail | length')
    [ "$n" -gt 0 ]
    [ "$n" -le 300 ]
}

@test "mother_rwx_sandbox reset: a failing reset is an error and never falls back to sandbox start" {
    local d; d=$(_sandbox_dir)
    export MOCK_RWX_EXIT_RESET=1
    export MOCK_RWX_OUTPUT_RESET="error: No sandbox found for this branch"
    run _rwx_sh 'mother_rwx_sandbox reset "'"$d"'"'
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.action == "reset" and .outcome == "error" and .exit_code == 1' >/dev/null
    [ "$(_count_lines '|sandbox reset ')" = "1" ]
    ! grep -qF '|sandbox start' "$RWX_LOG"
}

@test "mother_rwx_sandbox stop: non-zero exit with 'No sandbox found' counts as ok (exit_code preserved)" {
    local d; d=$(_sandbox_dir)
    export MOCK_RWX_EXIT_STOP=1
    export MOCK_RWX_OUTPUT_STOP="Error: No sandbox found for branch feature/x"
    run _rwx_sh 'mother_rwx_sandbox stop "'"$d"'"'
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.action == "stop" and .outcome == "ok" and .exit_code == 1' >/dev/null
}

@test "mother_rwx_sandbox stop: any other non-zero exit is an error" {
    local d; d=$(_sandbox_dir)
    export MOCK_RWX_EXIT_STOP=1
    export MOCK_RWX_OUTPUT_STOP="Error: permission denied"
    run _rwx_sh 'mother_rwx_sandbox stop "'"$d"'"'
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.outcome == "error" and .exit_code == 1' >/dev/null
}

@test "job whose sandbox idled out before stop: stop event is ok and the job still succeeds" {
    local id="rwx-stop-idled"
    _make_no_pr_job "$id"
    _install_claude_ok
    export MOCK_RWX_EXIT_STOP=1
    export MOCK_RWX_OUTPUT_STOP="Error: No sandbox found for branch feature/test-$id"

    _run_job "$id"

    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_event_field "$id" rwx_sandbox_stop 1 outcome)" = "ok" ]
    [ "$(_event_field "$id" rwx_sandbox_stop 1 exit_code)" = "1" ]
}

# ===========================================================================
# Preamble

@test "preamble has an RWX sandboxes section after 'Containers and test infrastructure'" {
    local pre="$_PLUGIN_DIR/templates/preamble.md"
    local l_containers l_rwx
    l_containers=$(grep -nF '## Containers and test infrastructure' "$pre" | head -1 | cut -d: -f1)
    l_rwx=$(grep -nF '## RWX sandboxes (tests off the laptop)' "$pre" | head -1 | cut -d: -f1)
    [ -n "$l_containers" ]
    [ -n "$l_rwx" ]
    [ "$l_rwx" -gt "$l_containers" ]
}
