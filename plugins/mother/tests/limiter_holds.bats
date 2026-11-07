#!/usr/bin/env bats
# limiter_holds.bats — boundary holds on running jobs (L4). Under an enforcing limiter, a job the limiter
# wants held stops at its next boundary (before its next tool call via the PreToolUse hook, or before the
# supervisor spawns the next claude process); nothing is cut off mid-request. A hold that outlasts
# MOTHER_LIMITER_HOLD_GRACE_S with a quiet log gives the worker up and parks the job as awaiting/limiter_hold.
#
# Covers L4-1 .. L4-10 and L4-12 (the Go half of L4-11 lives in broker/broker_test.go). The worker is
# tests/mock_claude in turn mode (MOCK_CLAUDE_TURNS), which runs the PreToolUse hooks from the --settings
# file between scripted turns and writes a marker file while a turn is in flight.

load 'test_helper'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/limiter"
HOOK="$_PLUGIN_DIR/hooks/mother-limiter-hold.sh"

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME" "$MOTHER_ROOT/limiter" "$RUNNER_DIR/children"
    unset MOTHER_LIMITER_MODE MOTHER_LIMITER_HOLD_GRACE_S MOTHER_LIMITER_QUIET_S MOTHER_JOB_ID
    export MOTHER_POSTURE_ENABLED=0 MOTHER_MIN_FREE_GB=0 MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_IDLE_REAP_SECONDS=120 MOTHER_RESULT_GRACE_SECONDS=120 MOTHER_USAGE_CHECK_INTERVAL=3600
    export MOTHER_QUOTA_CAP_5H_PCT=95
    export MOTHER_LIMITER_HOOK_POLL_S=0.2
    export MOCK_CLAUDE_TURN_LOG="$MOTHER_ROOT/turns.log"
    export MOCK_CLAUDE_PID_FILE="$MOTHER_ROOT/mock.pids"
    export MOCK_CLAUDE_TURN_MARKER="$MOTHER_ROOT/turn.marker"
    TEST_REPO_DIR="$(mktemp -d)"
    (
        cd "$TEST_REPO_DIR"
        git init -q -b main 2>/dev/null || git init -q
        git config user.email t@example.com; git config user.name T
        echo x > README.md; git add .; git commit -q -m init
    ) >/dev/null 2>&1
    printf '#!/usr/bin/env bash\nexit 0\n' > "$_MOCK_BIN/gh"; chmod +x "$_MOCK_BIN/gh"
    BG_PIDS=""
}

teardown() {
    local p
    for p in $BG_PIDS; do kill "$p" 2>/dev/null || true; done
    teardown_mother_env
    rm -rf "${TEST_REPO_DIR:-}"
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_now() { date +%s; }
_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_ms() { /usr/bin/perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

_wait_for() {   # <timeout s> <command...> — poll every 0.2 s
    local t="$1" i=0; shift
    while [ "$i" -lt $((t * 5)) ]; do
        "$@" >/dev/null 2>&1 && return 0
        sleep 0.2; i=$((i + 1))
    done
    return 1
}

_jf() { jq -r "$2" "$JOBS_DIR/$1.json"; }
_has_event() { [ -f "$EVENTS_DIR/$1.jsonl" ] && jq -e --arg k "$2" 'select(.kind == $k)' "$EVENTS_DIR/$1.jsonl" >/dev/null 2>&1 && return 0; return 1; }
_ev() { jq -c --arg k "$2" 'select(.kind == $k) | .detail' "$EVENTS_DIR/$1.jsonl" 2>/dev/null | tail -1; }
_job_state_is() { [ "$(_jf "$1" .state)" = "$2" ]; }
_hold_flag() { jq -nc --arg c "${2:-backoff}" --arg r "${3:-provider rate limit}" --arg s "$(_iso)" '{code: $c, reason: $r, since: $s}' > "$RUNNER_DIR/$1.hold"; }
_turn_log_has() { grep -q "$1" "$MOCK_CLAUDE_TURN_LOG" 2>/dev/null; }
_mode() { jq -nc --arg m "$1" '{mode: $m, changed_at: "2026-11-06T00:00:00.000Z", changed_by: "cli"}' > "$MOTHER_ROOT/limiter/mode.json"; }

_make_job() {   # <id> [extra jq]
    local id="$1" extra="${2:-.}" branch="feature/test-$1"
    ( cd "$TEST_REPO_DIR" && git checkout -q -B "$branch" main && git commit -q --allow-empty -m "seed" && git checkout -q main ) >/dev/null 2>&1
    mkdir -p "$MOTHER_ROOT/plans"; make_plan "$MOTHER_ROOT/plans/$id.md"
    make_job "$id" ready ".isolation = \"main-dir\" | .repo_path = \"$TEST_REPO_DIR\" | .base_ref = \"main\"
        | .branch = \"$branch\" | .no_pr = true | .plan_path = \"$MOTHER_ROOT/plans/$id.md\"
        | .log_path = \"$LOGS_DIR/$id.log\" | .data_class = \"personal\"
        | .suggested_config = {cody: {model: \"sonnet\", effort: \"medium\"}, redd: {model: \"sonnet\", effort: \"medium\"},
                               marty: {model: \"sonnet\", effort: \"medium\"}, perri: {model: \"sonnet\", effort: \"medium\"}}
        | ($extra)"
    touch "$LOGS_DIR/$id.log"
}

_start_job() {   # run the supervisor in the background
    mother-run-job "$1" >"$MOTHER_ROOT/run-$1.out" 2>&1 3>&- &
    BG_PIDS="$BG_PIDS $!"
    SUP_PID=$!
}

_marker_present() { [ -f "$MOCK_CLAUDE_TURN_MARKER" ]; }
_supervisor_gone() { ! kill -0 "$SUP_PID" 2>/dev/null; }
_mock_pids() { sort -u "$MOCK_CLAUDE_PID_FILE" 2>/dev/null | grep -c .; }

# A fresh enforce-mode limiter state: mode file + state.json (the runner's `enforcing` test).
_enforcing_state() {   # <running rows json> [admit json]
    _mode enforce
    jq -nc --argjson run "${1:-[]}" --argjson admit "${2:-[]}" \
        '{v: 1, mode: "enforce", allowed: 2, ceiling: 4, admit: $admit, running: $run, ready: []}' \
        > "$MOTHER_ROOT/limiter/state.json"
}

_bishop() {
    jq -nc --argjson p5 "$1" --argjson r5 "$(( $(_now) + 3600 ))" --argjson r7 "$(( $(_now) + 86400 ))" \
        '{posture: "Cruise", stale_input: false, five_hour: {used_pct: $p5, resets_at: $r5}, seven_day: {used_pct: 10, resets_at: $r7}}' \
        > "$MOTHER_BISHOP_POSTURE_FILE"
}

_register_child() { printf '{"job_id":"%s"}\n' "$1" > "$RUNNER_DIR/children/$2.json"; }

# ===========================================================================
# L4-10  the hold hook
# ===========================================================================

@test "L4-10: hook without a flag file exits 0 within 100 ms, silently, writing nothing" {
    export MOTHER_JOB_ID=nojob
    local t0 t1 out best=999999 i
    # Best of five: the bound is about the code path, not about a busy CI machine's scheduler.
    for i in 1 2 3 4 5; do
        t0=$(_ms)
        out=$(printf '{"tool_name":"Bash"}' | "$HOOK" 2>&1; echo "rc=$?")
        t1=$(_ms)
        [ "$out" = "rc=0" ]
        [ $((t1 - t0)) -ge "$best" ] || best=$((t1 - t0))
    done
    [ "$best" -lt 100 ]
    [ ! -e "$RUNNER_DIR/nojob.held" ]
}

@test "L4-10: hook exits 0 on malformed input, with no MOTHER_JOB_ID, and on a garbage hook max" {
    run bash -c 'printf "{not json" | "$1"' _ "$HOOK"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    export MOTHER_JOB_ID=nojob MOTHER_LIMITER_HOOK_MAX_S=banana
    run bash -c 'printf "\001\002 garbage" | "$1"' _ "$HOOK"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    unset MOTHER_LIMITER_HOOK_MAX_S
    export MOTHER_ROOT="/nonexistent/$$" MOTHER_LIVE_ROOT=""
    run "$HOOK" </dev/null
    [ "$status" -eq 0 ]
}

@test "hook: with a flag it writes .held {at, pid}, waits, and on release removes .held and exits 0" {
    export MOTHER_JOB_ID=hj
    _hold_flag hj
    "$HOOK" </dev/null >"$MOTHER_ROOT/hook.out" 2>&1 &
    local hp=$!; BG_PIDS="$BG_PIDS $hp"
    _wait_for 5 test -f "$RUNNER_DIR/hj.held"
    [ "$(jq -r .pid "$RUNNER_DIR/hj.held")" = "$hp" ]
    [ "$(jq -r '.at | type' "$RUNNER_DIR/hj.held")" = "number" ]
    sleep 0.6
    kill -0 "$hp"                       # still parked
    rm -f "$RUNNER_DIR/hj.hold"
    _wait_for 5 bash -c "! kill -0 $hp"
    wait "$hp"
    [ ! -e "$RUNNER_DIR/hj.held" ]
    [ ! -s "$MOTHER_ROOT/hook.out" ]
}

@test "hook: fails open once MOTHER_LIMITER_HOOK_MAX_S has elapsed, even with the flag still there" {
    export MOTHER_JOB_ID=hj MOTHER_LIMITER_HOOK_MAX_S=2
    _hold_flag hj
    local t0 t1
    t0=$(_now)
    run "$HOOK" </dev/null
    t1=$(_now)
    [ "$status" -eq 0 ]
    [ $((t1 - t0)) -ge 2 ]; [ $((t1 - t0)) -lt 6 ]
    [ ! -e "$RUNNER_DIR/hj.held" ]
}

@test "settings: the job-scoped settings file carries the hold hook (timeout grace+300, max env grace+240) and the cost gate when capped" {
    export MOTHER_LIMITER_HOLD_GRACE_S=100
    _make_job sj '.max_cost_usd = 5'
    MOCK_CLAUDE_STDOUT='' run mother-run-job sj
    local f="$RUNNER_DIR/sj.settings.json"
    [ -f "$f" ]
    [ "$(jq -r '.hooks.PreToolUse[0].hooks | length' "$f")" = "2" ]
    jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f" | grep -q 'mother-cost-gate.sh'
    jq -r '.hooks.PreToolUse[0].hooks[1].command' "$f" | grep -q 'MOTHER_LIMITER_HOOK_MAX_S=340 .*mother-limiter-hold.sh'
    [ "$(jq -r '.hooks.PreToolUse[0].hooks[1].timeout' "$f")" = "400" ]
    grep -qx -- "--settings" "$MOCK_CLAUDE_ARGS_FILE"
}

@test "settings: limiter mode off writes no hold hook and no settings file for an uncapped job" {
    export MOTHER_LIMITER_MODE=off
    _make_job oj
    run mother-run-job oj
    [ ! -e "$RUNNER_DIR/oj.settings.json" ]
    ! grep -qx -- "--settings" "$MOCK_CLAUDE_ARGS_FILE"
}

# ===========================================================================
# L4-1 / L4-2  hold at the next tool-call boundary; release continues the same worker
# ===========================================================================

@test "L4-1: a hold requested mid-turn never terminates the worker; it parks at the next boundary and the events show held" {
    export MOCK_CLAUDE_TURNS=3 MOCK_CLAUDE_TURN_SLEEP=3
    _make_job hj1
    _start_job hj1
    _wait_for 10 _marker_present
    _hold_flag hj1 backoff "provider rate limit: concurrency cut to 2"      # mid-turn
    sleep 1
    _marker_present                                                          # the turn is still running...
    ! _turn_log_has "^term"                                                  # ...and nothing was terminated
    _wait_for 15 _has_event hj1 held
    [ "$(_ev hj1 held | jq -r .code)" = "backoff" ]
    [ "$(_ev hj1 held | jq -r .reason)" = "provider rate limit: concurrency cut to 2" ]
    [ "$(_ev hj1 held | jq -r .boundary)" = "tool" ]
    [ "$(_jf hj1 .limiter_hold.at_boundary)" = "true" ]
    [ "$(_jf hj1 .limiter_hold.code)" = "backoff" ]
    ! _marker_present                                                        # parked between turns, not in one
    grep -q "hook_start 2" "$MOCK_CLAUDE_TURN_LOG"
    ! grep -q "turn_start 2" "$MOCK_CLAUDE_TURN_LOG"
    rm -f "$RUNNER_DIR/hj1.hold"
    _wait_for 20 _supervisor_gone
    ! _turn_log_has "^term"
}

@test "L4-2: a hold released before the grace period lets the same worker continue (same pid), hold_released is appended and limiter_hold cleared" {
    export MOCK_CLAUDE_TURNS=3 MOCK_CLAUDE_TURN_SLEEP=1 MOTHER_LIMITER_HOLD_GRACE_S=300
    _make_job hj2
    _hold_flag_after_start() { _wait_for 10 _marker_present; _hold_flag hj2; }
    _start_job hj2
    _hold_flag_after_start
    _wait_for 15 _has_event hj2 held
    rm -f "$RUNNER_DIR/hj2.hold"
    _wait_for 15 _has_event hj2 hold_released
    [ "$(_ev hj2 hold_released | jq -r '.held_s | type')" = "number" ]
    [ "$(_jf hj2 '.limiter_hold // "null"')" = "null" ]
    _wait_for 20 _supervisor_gone
    [ "$(_mock_pids)" = "1" ]
    [ "$(grep -c '^turn_end' "$MOCK_CLAUDE_TURN_LOG")" = "3" ]
    ! _has_event hj2 paused_for_limiter
}

# ===========================================================================
# L4-3  give-up after the grace period
# ===========================================================================

@test "L4-3: a hold past the grace period with a quiet log parks the job awaiting/limiter_hold, appends paused_for_limiter and stops the worker" {
    export MOCK_CLAUDE_TURNS=3 MOCK_CLAUDE_TURN_SLEEP=1 MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1
    _make_job hj3
    _start_job hj3
    _wait_for 10 _marker_present
    _hold_flag hj3 backoff "provider rate limit"
    _wait_for 30 _job_state_is hj3 awaiting
    [ "$(_jf hj3 .paused_reason)" = "limiter_hold" ]
    [ "$(_jf hj3 .question)" = "Held by the limiter: provider rate limit. Mother resumes it automatically when the limiter admits it." ]
    [ "$(_jf hj3 '.limiter_hold // "null"')" = "null" ]
    _wait_for 10 _has_event hj3 paused_for_limiter
    [ "$(_ev hj3 paused_for_limiter | jq -r .code)" = "backoff" ]
    [ "$(_ev hj3 paused_for_limiter | jq -r '.held_s >= 2')" = "true" ]
    _wait_for 20 _supervisor_gone
    ! kill -0 "$(tail -1 "$MOCK_CLAUDE_PID_FILE")" 2>/dev/null          # the parked worker is gone
    ! grep -q "turn_start 3" "$MOCK_CLAUDE_TURN_LOG"
    [ ! -e "$RUNNER_DIR/hj3.held" ]
}

@test "L4-3: when the log is not quiet the give-up is deferred (hold_giveup_deferred) and the worker keeps waiting" {
    export MOCK_CLAUDE_TURNS=2 MOCK_CLAUDE_TURN_SLEEP=1 MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1000
    _make_job hj3b
    _start_job hj3b
    _wait_for 10 _marker_present
    _hold_flag hj3b
    _wait_for 30 _has_event hj3b hold_giveup_deferred
    [ "$(_jf hj3b .state)" = "running" ]
    kill -0 "$SUP_PID"
    rm -f "$RUNNER_DIR/hj3b.hold"
    _wait_for 20 _supervisor_gone
    [ "$(_mock_pids)" = "1" ]
    ! _has_event hj3b paused_for_limiter
}

# ===========================================================================
# L4-4  auto-resume of a limiter_hold job
# ===========================================================================

_parked() {   # <id> — an awaiting/limiter_hold job with a session
    make_job "$1" awaiting '.paused_reason = "limiter_hold" | .session_id = "sess-1234" | .paused_at = "2026-11-06T00:00:00Z"
        | .question = "Held by the limiter: x." | .data_class = "personal"'
}

@test "L4-4: a limiter_hold job stays awaiting until its id is on the limiter's admit list, then goes ready with its session" {
    _parked lh1
    _enforcing_state '[]' '["someone-else"]'
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1
    [ "$(_jf lh1 .state)" = "awaiting" ]
    _enforcing_state '[]' '["lh1"]'
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1
    [ "$(_jf lh1 .state)" = "ready" ]
    [ "$(_jf lh1 .pending_answer)" = "The limiter released this job — continue from where you left off." ]
    [ "$(_jf lh1 .resume_session_id)" = "sess-1234" ]
    [ "$(_jf lh1 .paused_reason)" = "null" ]
    [ "$(_ev lh1 auto_resumed | jq -r .from_paused_reason)" = "limiter_hold" ]
    [ "$(_ev lh1 auto_resumed | jq -r .reason)" = "limiter_admitted" ]
}

@test "L4-4: never while the old supervisor is alive" {
    _parked lh2
    _enforcing_state '[]' '["lh2"]'
    _register_child lh2 $$
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1
    [ "$(_jf lh2 .state)" = "awaiting" ]
    rm -f "$RUNNER_DIR/children/$$.json"
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1
    [ "$(_jf lh2 .state)" = "ready" ]
}

@test "L4-4: a limiter that is no longer enforcing releases the job at once (bet B6)" {
    _parked lh3
    _mode observe
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1
    [ "$(_jf lh3 .state)" = "ready" ]
    [ "$(_ev lh3 auto_resumed | jq -r .reason)" = "limiter_not_enforcing" ]
}

@test "L4-4: the released job's worker re-enters its session with --resume and the release note as the prompt" {
    export MOCK_CLAUDE_STDIN_FILE="$MOTHER_ROOT/stdin.txt"
    # A result event: without one a clean exit looks like a resume that never started (fresh fallback).
    export MOCK_CLAUDE_STDOUT='{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
    _make_job lh4 '.session_id = "sess-4444" | .resume_session_id = "sess-4444" | .resume_kind = "limiter_hold"
        | .pending_answer = "The limiter released this job — continue from where you left off."'
    run mother-run-job lh4
    grep -qx -- "--resume" "$MOCK_CLAUDE_ARGS_FILE"
    grep -qx -- "sess-4444" "$MOCK_CLAUDE_ARGS_FILE"
    ! grep -qx -- "--session-id" "$MOCK_CLAUDE_ARGS_FILE"
    grep -q "Mother released your limiter hold" "$MOCK_CLAUDE_STDIN_FILE"
    grep -q "continue from where you left off" "$MOCK_CLAUDE_STDIN_FILE"
    [ "$(_jf lh4 '.resume_kind // "null"')" = "null" ]
}

@test "L4-4: answering a limiter_hold job by hand with mother resume works" {
    _parked lh5
    run mother resume lh5 "go on"
    [ "$status" -eq 0 ]
    [ "$(_jf lh5 .state)" = "ready" ]
    [ "$(_jf lh5 .pending_answer)" = "go on" ]
}

# ===========================================================================
# L4-5 / L4-6  which running jobs the runner holds
# ===========================================================================

_running() {   # <id> <class> <started> [extra jq]
    make_job "$1" running ".data_class = \"$2\" | .started_at = \"$3\" | .repo_path = \"$MOTHER_ROOT\" | (${4:-.})"
}

@test "L4-5: after a distress cut from 4 to 2 the two personal jobs get .hold within one runner pass; no company job is held" {
    _mode enforce; _bishop 10
    _running c1 company 2026-11-01T00:00:01Z; _running c2 company 2026-11-01T00:00:02Z
    _running p1 personal 2026-11-01T00:00:03Z; _running p2 personal 2026-11-01T00:00:04Z
    local j; for j in c1 c2 p1 p2; do : > "$LOGS_DIR/$j.log"; done
    export MOTHER_CONCURRENCY=4
    env MOTHER_LIMITER_INTERVAL=0 mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    ls "$RUNNER_DIR"/*.hold 2>/dev/null | wc -l | grep -qx 0 || [ "$(ls "$RUNNER_DIR"/*.hold 2>/dev/null | wc -l | tr -d ' ')" = "0" ]
    cat "$FIXTURES/api_retry_429.jsonl" >> "$LOGS_DIR/c1.log"
    env MOTHER_LIMITER_INTERVAL=0 mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ "$(jq -r .allowed "$MOTHER_ROOT/limiter/state.json")" = "2" ]
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ -f "$RUNNER_DIR/p1.hold" ]; [ -f "$RUNNER_DIR/p2.hold" ]
    [ ! -e "$RUNNER_DIR/c1.hold" ]; [ ! -e "$RUNNER_DIR/c2.hold" ]
    [ "$(jq -r .code "$RUNNER_DIR/p2.hold")" = "backoff" ]
    [ -n "$(jq -r .reason "$RUNNER_DIR/p2.hold")" ]
}

@test "L4-5: with four company jobs running the two newest are held" {
    _mode enforce; _bishop 10
    local i; for i in 1 2 3 4; do _running "c$i" company "2026-11-01T00:00:0${i}Z"; : > "$LOGS_DIR/c$i.log"; done
    export MOTHER_CONCURRENCY=4
    env MOTHER_LIMITER_INTERVAL=0 mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    cat "$FIXTURES/api_retry_429.jsonl" >> "$LOGS_DIR/c1.log"
    env MOTHER_LIMITER_INTERVAL=0 mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/c1.hold" ]; [ ! -e "$RUNNER_DIR/c2.hold" ]
    [ -f "$RUNNER_DIR/c3.hold" ]; [ -f "$RUNNER_DIR/c4.hold" ]
}

_rows() { jq -nc "$1"; }

@test "L4-6: interactive demand with the reserve projected to be breached holds personal running jobs, never company ones" {
    _running p1 personal 2026-11-01T00:00:01Z; _running c1 company 2026-11-01T00:00:02Z
    _enforcing_state "$(_rows '[{id:"p1",class:"personal",would_hold:false,would_preempt:true,advisory:false,hold:{code:"interactive_personal",reason:"interactive demand is high"}},
                                {id:"c1",class:"company",would_hold:false,would_preempt:false,advisory:false}]')"
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ "$(jq -r .code "$RUNNER_DIR/p1.hold")" = "interactive_personal" ]
    [ ! -e "$RUNNER_DIR/c1.hold" ]
}

@test "L4-6: nothing is held when demand is high but the reserve is not projected to be breached" {
    _running p1 personal 2026-11-01T00:00:01Z
    _enforcing_state "$(_rows '[{id:"p1",class:"personal",would_hold:false,would_preempt:false,advisory:false}]')"
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/p1.hold" ]
}

@test "holds: exemptions: cancel_requested, final_result_at, awaiting, force_start (interactive only), advisory pre-emption" {
    _running a personal 2026-11-01T00:00:01Z '.cancel_requested = true'
    _running b personal 2026-11-01T00:00:02Z '.final_result_at = "2026-11-06T00:00:00Z"'
    make_job c awaiting '.data_class = "personal"'
    _running d personal 2026-11-01T00:00:04Z '.force_start = true'
    _running e personal 2026-11-01T00:00:05Z '.force_start = true'
    _running f personal 2026-11-01T00:00:06Z
    local pre='would_hold:false,would_preempt:true,advisory:false,hold:{code:"interactive_personal",reason:"r"}'
    _enforcing_state "$(_rows "[{id:\"a\",$pre},{id:\"b\",$pre},{id:\"c\",$pre},{id:\"d\",$pre},
        {id:\"e\",would_hold:true,would_preempt:false,advisory:false,hold:{code:\"backoff\",reason:\"r\"}},
        {id:\"f\",would_hold:false,would_preempt:true,advisory:true,hold:{code:\"interactive_personal\",reason:\"r\"}}]")"
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/a.hold" ]; [ ! -e "$RUNNER_DIR/b.hold" ]; [ ! -e "$RUNNER_DIR/c.hold" ]
    [ ! -e "$RUNNER_DIR/d.hold" ]                       # force_start: exempt from interactive pre-emption
    [ -f "$RUNNER_DIR/e.hold" ]                         # ...but not from a distress hold
    [ ! -e "$RUNNER_DIR/f.hold" ]                       # advisory pre-emption (quota gate off) never holds
}

@test "holds: a flag is rewritten only when the code or reason changed, and removed when the job is no longer listed" {
    _running p1 personal 2026-11-01T00:00:01Z
    local row='{id:"p1",would_hold:true,would_preempt:false,advisory:false,hold:{code:"backoff",reason:"r1"}}'
    _enforcing_state "$(_rows "[$row]")"
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    local since; since=$(jq -r .since "$RUNNER_DIR/p1.hold")
    sleep 1.1
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ "$(jq -r .since "$RUNNER_DIR/p1.hold")" = "$since" ]
    _enforcing_state '[{"id":"p1","would_hold":false,"would_preempt":false,"advisory":false}]'
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/p1.hold" ]
}

# ===========================================================================
# L4-9  leaving enforce, or a stale limiter, releases every hold within one runner pass
# ===========================================================================

@test "L4-9: switching to observe removes every .hold on the next pass, and a held worker continues (same pid)" {
    export MOCK_CLAUDE_TURNS=3 MOCK_CLAUDE_TURN_SLEEP=1 MOTHER_LIMITER_HOLD_GRACE_S=300
    _make_job hj9
    _start_job hj9
    _wait_for 10 _marker_present
    _enforcing_state '[]'
    _hold_flag hj9
    _wait_for 15 _has_event hj9 held
    _mode observe
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/hj9.hold" ]
    _wait_for 15 _has_event hj9 hold_released
    _wait_for 20 _supervisor_gone
    [ "$(_mock_pids)" = "1" ]
    [ "$(grep -c '^turn_end' "$MOCK_CLAUDE_TURN_LOG")" = "3" ]
}

@test "L4-9: a stale limiter state (bet B6) removes every .hold" {
    _running p1 personal 2026-11-01T00:00:01Z
    _enforcing_state '[{"id":"p1","would_hold":true,"would_preempt":false,"advisory":false,"hold":{"code":"backoff","reason":"r"}}]'
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ -f "$RUNNER_DIR/p1.hold" ]
    /usr/bin/perl -e 'my $t = time - 3600; utime($t, $t, $ARGV[0])' "$MOTHER_ROOT/limiter/state.json"
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/p1.hold" ]
    _enforcing_state '[{"id":"p1","would_hold":true,"would_preempt":false,"advisory":false,"hold":{"code":"backoff","reason":"r"}}]'
    _hold_flag p1
    echo '{"at":1,"why":"x"}' > "$RUNNER_DIR/limiter-fault.json"
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/p1.hold" ]
}

# ===========================================================================
# L4-7  quota gate under enforce: hold at the boundary instead of killing
# ===========================================================================

@test "L4-7: under enforce the quota pause writes a quota_* .hold, keeps auto_resume_at and does not set pause_requested" {
    _bishop 99
    _running q1 personal 2026-11-01T00:00:01Z
    _enforcing_state '[]'
    _register_child q1 $$
    mother-runner --pause-tick 3>&- >/dev/null 2>&1
    [ "$(jq -r .code "$RUNNER_DIR/q1.hold")" = "quota_5h" ]
    [ "$(_jf q1 '.pause_requested // false')" = "false" ]
    [ "$(_jf q1 '.auto_resume_at > 0')" = "true" ]
    # an enforcing pass leaves a still-over-cap quota hold alone...
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ -f "$RUNNER_DIR/q1.hold" ]
    # ...and the gate coming back under cap removes it
    _bishop 10
    mother-runner --holds-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/q1.hold" ]
}

@test "L4-7: outside enforce the quota pause is unchanged (pause_requested, no .hold)" {
    _bishop 99
    _running q2 personal 2026-11-01T00:00:01Z
    _mode observe
    _register_child q2 $$
    mother-runner --pause-tick 3>&- >/dev/null 2>&1
    [ "$(_jf q2 .pause_requested)" = "true" ]
    [ ! -e "$RUNNER_DIR/q2.hold" ]
}

@test "L4-7: a quota hold mid-turn kills nothing; after grace the worker parks with paused_reason quota_5h, which auto-resume handles" {
    export MOCK_CLAUDE_TURNS=3 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1
    _bishop 99
    _make_job hq
    _start_job hq
    _wait_for 10 _marker_present
    _enforcing_state '[]'
    _register_child hq $$
    mother-runner --pause-tick 3>&- >/dev/null 2>&1
    [ -f "$RUNNER_DIR/hq.hold" ]
    _marker_present
    ! _turn_log_has "^term"
    _wait_for 40 _job_state_is hq awaiting
    [ "$(_jf hq .paused_reason)" = "quota_5h" ]
    [ "$(_jf hq '.auto_resume_at > 0')" = "true" ]
    _wait_for 10 _has_event hq paused_for_quota   # the state is written first, the event just after
    ! _has_event hq paused_for_limiter
    _wait_for 20 _supervisor_gone
    # the worker was never cut off inside a turn
    [ "$(grep -c '^term in_turn=yes' "$MOCK_CLAUDE_TURN_LOG")" = "0" ]
    # the existing auto-resume releases it once the window has reset
    rm -f "$RUNNER_DIR/children/$$.json" "$RUNNER_DIR/hq.hold"
    _bishop 10
    jq '.auto_resume_at = 1' "$JOBS_DIR/hq.json" > "$JOBS_DIR/hq.json.new" && mv "$JOBS_DIR/hq.json.new" "$JOBS_DIR/hq.json"
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1
    [ "$(_jf hq .state)" = "ready" ]
}

# ===========================================================================
# L4-8  phase boundary: no claude process starts while a hold is on
# ===========================================================================

@test "L4-8: with .hold present at spawn time no claude process starts until release; held {boundary: phase} is appended" {
    _make_job ph
    _hold_flag ph backoff "provider rate limit"
    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    _start_job ph
    _wait_for 15 _has_event ph held
    [ "$(_ev ph held | jq -r .boundary)" = "phase" ]
    sleep 3
    [ ! -e "$MOCK_CLAUDE_ARGS_FILE" ]                    # nothing started
    rm -f "$RUNNER_DIR/ph.hold"
    _wait_for 20 _supervisor_gone
    [ -e "$MOCK_CLAUDE_ARGS_FILE" ]
    _has_event ph hold_released
    [ "$(_jf ph '.limiter_hold // "null"')" = "null" ]
}

@test "L4-8: a phase-boundary hold past the grace period parks the job awaiting/limiter_hold without spawning anything" {
    export MOTHER_LIMITER_HOLD_GRACE_S=2
    _make_job ph2
    _hold_flag ph2 backoff "provider rate limit"
    rm -f "$MOCK_CLAUDE_ARGS_FILE"
    run mother-run-job ph2
    [ "$status" -eq 0 ]
    [ "$(_jf ph2 .state)" = "awaiting" ]
    [ "$(_jf ph2 .paused_reason)" = "limiter_hold" ]
    [ ! -e "$MOCK_CLAUDE_ARGS_FILE" ]
    [ "$(_ev ph2 paused_for_limiter | jq -r .boundary)" = "phase" ]
}

# ===========================================================================
# L4-12  surfaces
# ===========================================================================

@test "L4-12: mother status shows [HELD <code>] with the reason and time held; mother list shows [HELD]" {
    make_job sh1 running '.limiter_hold = {code: "backoff", reason: "provider rate limit", since: "2026-11-06T00:00:00Z", boundary_since: "2026-11-06T00:00:00Z", at_boundary: true}'
    export MOTHER_LIMITER_HOLD_GRACE_S=600
    run mother status sh1
    [ "$status" -eq 0 ]
    [[ "$output" == *"⏸ [HELD backoff] provider rate limit (at boundary since "*"m; gives up worker after 10m)"* ]]
    run mother list
    [[ "$output" == *"[HELD]"* ]]
    make_job sh2 running '.limiter_hold = null'
    run mother status sh2
    [[ "$output" != *"[HELD"* ]]
}

@test "L4-12: the status overview lists limiter_hold as auto-resuming" {
    _parked sh3
    run mother status
    [[ "$output" == *"sh3"*"limiter_hold (auto-resumes)"* ]]
}

# ===========================================================================
# PR #113 review fix-ups: never terminate a worker mid-request
# ===========================================================================

_held_exists() { [ -f "$RUNNER_DIR/$1.held" ]; }
_held_pid() { jq -r .pid "$RUNNER_DIR/$1.held"; }
_in_turn_terms() { grep -c '^term in_turn=yes' "$MOCK_CLAUDE_TURN_LOG" 2>/dev/null || true; }

@test "fix1: the hook expires before the supervisor's grace: no termination, the job keeps running" {
    # hook max (2 s) < grace (3 s): the worker is released by the hook, so the supervisor must not park it
    export MOCK_CLAUDE_TURNS=3 MOCK_CLAUDE_TURN_SLEEP=3 MOTHER_LIMITER_HOLD_GRACE_S=3 MOTHER_LIMITER_QUIET_S=1 MOTHER_LIMITER_HOOK_MAX_S=2
    _make_job fx1
    _start_job fx1
    _wait_for 10 _marker_present
    _hold_flag fx1 backoff "cut"
    _wait_for 30 _supervisor_gone
    [ "$(_in_turn_terms)" = "0" ]
    ! _turn_log_has "^term"
    [ "$(grep -c '^turn_end' "$MOCK_CLAUDE_TURN_LOG")" = "3" ]
    ! _has_event fx1 paused_for_limiter
}

@test "fix1: .held removed (hook stopped) while the supervisor waits: no termination mid-turn; the next boundary parks" {
    # NB: a guard, not a regression test: it also passes on the pre-fix head (the stale-boundary fix covers it).
    export MOCK_CLAUDE_TURNS=4 MOCK_CLAUDE_TURN_SLEEP=5 MOTHER_LIMITER_HOLD_GRACE_S=4 MOTHER_LIMITER_QUIET_S=1
    _make_job fx2
    _start_job fx2
    _wait_for 10 _marker_present
    _hold_flag fx2 backoff "cut"
    _wait_for 20 _held_exists fx2
    local hp; hp=$(_held_pid fx2)
    kill "$hp"                                   # the hook stops holding; .held goes with it
    _wait_for 5 bash -c "! [ -f '$RUNNER_DIR/fx2.held' ]"
    # the worker is now in a turn; the supervisor must not give it up here
    sleep 6
    [ "$(_in_turn_terms)" = "0" ]
    # the next real boundary (a fresh .held) parks the job at a boundary
    _wait_for 40 _job_state_is fx2 awaiting
    _wait_for 10 _turn_log_has "^term in_turn=no"
    [ "$(_in_turn_terms)" = "0" ]
}

@test "fix1: .hold removed and re-written within one poll with a dead hook: no park until a fresh .held" {
    export MOCK_CLAUDE_TURNS=4 MOCK_CLAUDE_TURN_SLEEP=5 MOTHER_LIMITER_HOLD_GRACE_S=4 MOTHER_LIMITER_QUIET_S=1
    _make_job fx3
    _start_job fx3
    _wait_for 10 _marker_present
    _hold_flag fx3 backoff "cut"
    _wait_for 20 _held_exists fx3
    local hp; hp=$(_held_pid fx3)
    kill -9 "$hp"                                # leaves a stale .held behind
    rm -f "$RUNNER_DIR/fx3.hold"; _hold_flag fx3 backoff "cut"   # flap, faster than the supervisor's poll
    sleep 6
    [ "$(_in_turn_terms)" = "0" ]
    [ "$(_jf fx3 .state)" = "running" ]
    _wait_for 40 _job_state_is fx3 awaiting
    [ "$(_in_turn_terms)" = "0" ]
}

_park_exists() { [ -f "$RUNNER_DIR/$1.park" ]; }
_turn_starts() { grep -c '^turn_start' "$MOCK_CLAUDE_TURN_LOG" 2>/dev/null || true; }

@test "round2-1: a park whose state write fails stops nothing, records nothing, and the job stays running" {
    export MOCK_CLAUDE_TURNS=3 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=5 MOTHER_LIMITER_QUIET_S=1
    _make_job r21
    _start_job r21
    _wait_for 10 _marker_present
    _hold_flag r21 backoff "cut"
    _wait_for 20 _has_event r21 held
    # the supervisor's atomic write goes through <job>.json.tmp.<its pid>: a directory there makes every write fail at once
    mkdir "$JOBS_DIR/r21.json.tmp.$SUP_PID"
    sleep 10                                     # grace passes; each park attempt fails to write
    [ "$(_jf r21 .state)" = "running" ]
    ! _has_event r21 paused_for_limiter
    ! _turn_log_has "^term"
    kill -0 "$SUP_PID"
    # (and with the write path healthy again the very same hold parks normally)
    rmdir "$JOBS_DIR/r21.json.tmp.$SUP_PID"
    _wait_for 40 _job_state_is r21 awaiting
    _wait_for 10 _turn_log_has "^term in_turn=no"
    [ "$(_in_turn_terms)" = "0" ]
    _wait_for 10 _has_event r21 paused_for_limiter
}

@test "round2-2a: .hold removed after .park is written: the hook keeps blocking and the kill lands only on a blocked worker" {
    export MOCK_CLAUDE_TURNS=4 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1 MOTHER_TEST_PARK_DELAY_S=4
    _make_job r22
    _start_job r22
    _wait_for 10 _marker_present
    _hold_flag r22 backoff "cut"
    _wait_for 30 _park_exists r22
    local before; before=$(_turn_starts)
    rm -f "$RUNNER_DIR/r22.hold"                 # the runner withdraws the hold inside the check-then-kill window
    sleep 2
    _held_exists r22                             # the hook is still blocking the tool call
    [ "$(_turn_starts)" = "$before" ]            # the worker did not start another turn
    [ "$(_jf r22 .state)" = "running" ]
    _wait_for 20 _job_state_is r22 awaiting
    _wait_for 10 _turn_log_has "^term in_turn=no"
    [ "$(_in_turn_terms)" = "0" ]
    [ "$(_turn_starts)" = "$before" ]
    _wait_for 20 _supervisor_gone
    [ ! -e "$RUNNER_DIR/r22.park" ]
}

@test "round2-2b: a stale .park from a dead supervisor does not block a later worker" {
    export MOTHER_JOB_ID=pj
    _hold_flag pj
    sh -c 'exit 0' & local dead=$!; wait "$dead"
    printf '{"pid": %s, "at": %s}\n' "$dead" "$(_now)" > "$RUNNER_DIR/pj.park"
    "$HOOK" </dev/null >"$MOTHER_ROOT/hook.out" 2>&1 &
    local hp=$!; BG_PIDS="$BG_PIDS $hp"
    _wait_for 5 test -f "$RUNNER_DIR/pj.held"
    rm -f "$RUNNER_DIR/pj.hold"
    _wait_for 5 bash -c "! kill -0 $hp"           # released on the next poll despite the stale park
    wait "$hp"
    [ ! -e "$RUNNER_DIR/pj.held" ]
    [ ! -s "$MOTHER_ROOT/hook.out" ]
}

@test "round2-2c: the hook's max wait elapsing after .park does not release the worker; removing .park does" {
    export MOTHER_JOB_ID=pj MOTHER_LIMITER_HOOK_MAX_S=2 MOTHER_LIMITER_HOOK_PARK_CAP_S=30
    _hold_flag pj
    sleep 60 & local sup=$!; BG_PIDS="$BG_PIDS $sup"     # stands in for the live supervisor
    "$HOOK" </dev/null >"$MOTHER_ROOT/hook.out" 2>&1 &
    local hp=$!; BG_PIDS="$BG_PIDS $hp"
    _wait_for 5 test -f "$RUNNER_DIR/pj.held"
    printf '{"pid": %s, "at": %s}\n' "$sup" "$(_now)" > "$RUNNER_DIR/pj.park"
    sleep 3.5                                            # max (2 s) has passed
    kill -0 "$hp"
    [ -f "$RUNNER_DIR/pj.held" ]
    rm -f "$RUNNER_DIR/pj.hold"
    sleep 1
    kill -0 "$hp"                                        # .hold gone too: still blocking
    rm -f "$RUNNER_DIR/pj.park"
    _wait_for 5 bash -c "! kill -0 $hp"
    wait "$hp"
    [ ! -e "$RUNNER_DIR/pj.held" ]
}

@test "round2-2c: the park extension is bounded: the hook fails open at max + PARK_CAP_S even with a live .park" {
    export MOTHER_JOB_ID=pj MOTHER_LIMITER_HOOK_MAX_S=1 MOTHER_LIMITER_HOOK_PARK_CAP_S=2
    _hold_flag pj
    sleep 30 & local sup=$!; BG_PIDS="$BG_PIDS $sup"
    printf '{"pid": %s, "at": %s}\n' "$sup" "$(_now)" > "$RUNNER_DIR/pj.park"
    local t0 t1; t0=$(_now)
    run "$HOOK" </dev/null
    t1=$(_now)
    [ "$status" -eq 0 ]
    [ $((t1 - t0)) -ge 3 ]; [ $((t1 - t0)) -lt 8 ]
    [ ! -e "$RUNNER_DIR/pj.held" ]
}

@test "fix3: a hold that changed from backoff to quota_* before the park parks as a quota pause" {
    export MOCK_CLAUDE_TURNS=3 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=4 MOTHER_LIMITER_QUIET_S=1
    _make_job fx4
    _start_job fx4
    _wait_for 10 _marker_present
    _hold_flag fx4 backoff "cut"
    _wait_for 20 _has_event fx4 held
    _hold_flag fx4 quota_5h "quota cap reached"
    _wait_for 40 _job_state_is fx4 awaiting
    [ "$(_jf fx4 .paused_reason)" = "quota_5h" ]
    _wait_for 10 _has_event fx4 paused_for_quota
    ! _has_event fx4 paused_for_limiter
}

@test "fix2: a cancel taken under the job lock while a limiter resume is pending leaves the job cancelled" {
    _parked fx5
    _enforcing_state '[]' '["fx5"]'
    mkdir "$JOBS_DIR/fx5.json.lockdir"           # the lock the cancel holds
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1 &
    local rp=$!
    BG_PIDS="$BG_PIDS $rp"
    sleep 0.5
    jq '.state = "cancelled" | .paused_reason = null' "$JOBS_DIR/fx5.json" > "$JOBS_DIR/fx5.json.new" && mv "$JOBS_DIR/fx5.json.new" "$JOBS_DIR/fx5.json"
    rmdir "$JOBS_DIR/fx5.json.lockdir"
    wait "$rp" || true
    [ "$(_jf fx5 .state)" = "cancelled" ]
    ! _has_event fx5 auto_resumed
}

@test "fix5: a runner restart while a job is held resumes it exactly once, with its session" {
    _parked fx6
    _enforcing_state '[]' '["fx6"]'
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1   # a restarted runner's first pass
    [ "$(_jf fx6 .state)" = "ready" ]
    [ "$(_jf fx6 .resume_session_id)" = "sess-1234" ]
    [ "$(_jf fx6 .resume_count)" = "1" ]
    [ "$(grep -c '"auto_resumed"' "$EVENTS_DIR/fx6.jsonl")" = "1" ]
}

@test "fix5: mother cancel of a held awaiting job cancels it, and the runner never resumes it" {
    _parked fx7
    run mother cancel fx7
    [ "$status" -eq 0 ]
    [ "$(_jf fx7 .state)" = "cancelled" ]
    _enforcing_state '[]' '["fx7"]'
    mother-runner --auto-resume-tick 3>&- >/dev/null 2>&1
    [ "$(_jf fx7 .state)" = "cancelled" ]
}

@test "fix4: a failing hold hook never blocks a tool call (unwritable .held, missing root, unwritable dir), in any mode" {
    export MOTHER_JOB_ID=hj
    _hold_flag hj
    chmod 500 "$RUNNER_DIR"
    run "$HOOK" </dev/null
    chmod 700 "$RUNNER_DIR"
    [ "$status" -eq 0 ]; [ -z "$output" ]
    MOTHER_ROOT=/nonexistent-guard-x run "$HOOK" </dev/null
    [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "hook: TERM removes only its own .held and leaves nothing behind" {
    export MOTHER_JOB_ID=hj
    _hold_flag hj
    "$HOOK" </dev/null >/dev/null 2>&1 &
    local hp=$!; BG_PIDS="$BG_PIDS $hp"
    _wait_for 5 test -f "$RUNNER_DIR/hj.held"
    printf '{"at": 1, "pid": 999999}\n' > "$RUNNER_DIR/hj.held"      # a later worker's hook took the marker over
    kill "$hp"; wait "$hp" 2>/dev/null || true
    [ -f "$RUNNER_DIR/hj.held" ]
}

# ===========================================================================
# round3: in-flight tool calls — never terminate a worker with a tool call running
# ===========================================================================
# The hold hook records each call as $RUNNER_DIR/<job>.calls/<tool_use_id>.json {state, pid, at}; the
# PostToolUse hook (`mother-limiter-hold.sh post`) removes it. The supervisor parks only when some call is
# blocked in a live hook of the worker and none is running.

_call_file() { echo "$RUNNER_DIR/$1.calls/$2.json"; }
_call_state() { jq -r .state "$(_call_file "$1" "$2")" 2>/dev/null; }
_call_state_is() { [ "$(_call_state "$1" "$2")" = "$3" ]; }
_call_gone() { [ ! -e "$(_call_file "$1" "$2")" ]; }
_dead_pid() { sh -c 'exit 0' & local d=$!; wait "$d"; echo "$d"; }
_put_call() {   # <job> <tool_use_id> <state> [at] — a record whose hook is dead (a tool executing after its hook passed)
    mkdir -p "$RUNNER_DIR/$1.calls"
    printf '{"state": "%s", "pid": %s, "at": %s}\n' "$3" "$(_dead_pid)" "${4:-$(_now)}" > "$(_call_file "$1" "$2")"
}
_tool_json() { printf '{"tool_name":"Bash","tool_use_id":"%s","tool_input":{"command":"true"}}' "$1"; }

@test "round3-1a: the hook marks its call blocked (with its own pid) while blocking and running once released" {
    export MOTHER_JOB_ID=cj
    _hold_flag cj
    _tool_json toolu_u1 | "$HOOK" >/dev/null 2>&1 &
    local hp=$!; BG_PIDS="$BG_PIDS $hp"
    _wait_for 5 _call_state_is cj toolu_u1 blocked
    [ "$(jq -r .pid "$(_call_file cj toolu_u1)")" = "$hp" ]
    [[ "$(jq -r .at "$(_call_file cj toolu_u1)")" =~ ^[0-9]+$ ]]
    rm -f "$RUNNER_DIR/cj.hold"
    _wait_for 5 bash -c "! kill -0 $hp"
    wait "$hp"
    [ "$(_call_state cj toolu_u1)" = "running" ]       # the tool now executes; only PostToolUse clears it
}

@test "round3-1b: with no .hold the hook still leaves a running record and exits fast" {
    export MOTHER_JOB_ID=cj
    local t0 t1; t0=$(_ms)
    _tool_json toolu_u2 | "$HOOK"
    t1=$(_ms)
    [ $((t1 - t0)) -lt 1500 ]
    [ "$(_call_state cj toolu_u2)" = "running" ]
    [ "$(jq -r .pid "$(_call_file cj toolu_u2)")" -gt 0 ]
}

@test "round3-1c: post removes the call record, only that one" {
    export MOTHER_JOB_ID=cj
    _tool_json toolu_a | "$HOOK"
    _tool_json toolu_b | "$HOOK"
    [ -f "$(_call_file cj toolu_a)" ]; [ -f "$(_call_file cj toolu_b)" ]
    _tool_json toolu_a | "$HOOK" post
    _call_gone cj toolu_a
    [ -f "$(_call_file cj toolu_b)" ]
    run bash -c "printf '%s' '{\"tool_use_id\":\"toolu_zzz\"}' | '$HOOK' post"    # unknown id: harmless
    [ "$status" -eq 0 ]; [ -z "$output" ]
}

@test "round3-1d: input without a tool_use_id writes no record, in either hook mode" {
    export MOTHER_JOB_ID=cj
    printf '%s' '{"tool_name":"Bash"}' | "$HOOK"
    "$HOOK" </dev/null
    printf '%s' '{"tool_name":"Bash"}' | "$HOOK" post
    [ -z "$(ls -A "$RUNNER_DIR/cj.calls" 2>/dev/null)" ]
}

@test "round3-2: a parallel call that passed its hook and is still running blocks the park; its PostToolUse lets the park proceed" {
    export MOCK_CLAUDE_TURNS=4 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=3 MOTHER_LIMITER_QUIET_S=1
    _make_job r3p
    _start_job r3p
    _wait_for 10 _marker_present
    _put_call r3p toolu_par running                # call A: hook passed, tool still executing
    _hold_flag r3p backoff "cut"
    _wait_for 30 _has_event r3p hold_giveup_deferred
    [ "$(_ev r3p hold_giveup_deferred | jq -r .reason)" = "tool_call_in_flight" ]
    sleep 5                                        # well past grace, quiet log
    [ "$(_jf r3p .state)" = "running" ]
    ! _has_event r3p paused_for_limiter
    ! _turn_log_has "^term"
    kill -0 "$SUP_PID"
    # call A finishes: its PostToolUse hook removes the record
    MOTHER_JOB_ID=r3p bash -c "$(printf '%q' "$HOOK") post" <<< "$(_tool_json toolu_par)"
    _call_gone r3p toolu_par
    _wait_for 40 _job_state_is r3p awaiting
    [ "$(_jf r3p .paused_reason)" = "limiter_hold" ]
    _wait_for 10 _turn_log_has "^term in_turn=no"
    [ "$(_in_turn_terms)" = "0" ]
    _wait_for 10 _has_event r3p paused_for_limiter
}

@test "round3-3: a long-running subagent (Task) call in flight blocks the park indefinitely" {
    export MOCK_CLAUDE_TURNS=4 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1
    _make_job r3t
    _start_job r3t
    _wait_for 10 _marker_present
    _put_call r3t toolu_task running
    _hold_flag r3t backoff "cut"
    _wait_for 30 _has_event r3t hold_giveup_deferred
    sleep 10
    [ "$(_jf r3t .state)" = "running" ]
    ! _has_event r3t paused_for_limiter
    ! _turn_log_has "^term"
    [ -f "$(_call_file r3t toolu_task)" ]
}

@test "round3-4a: a running record with a dead hook older than MOTHER_LIMITER_CALL_STALE_S is discarded and does not block parking" {
    export MOCK_CLAUDE_TURNS=4 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1 MOTHER_LIMITER_CALL_STALE_S=2
    _make_job r3s
    _start_job r3s
    _wait_for 10 _marker_present
    _put_call r3s toolu_lost running $(( $(_now) - 100 ))   # its PostToolUse was lost long ago
    _hold_flag r3s backoff "cut"
    _wait_for 40 _job_state_is r3s awaiting
    _wait_for 10 _turn_log_has "^term in_turn=no"
    [ "$(_in_turn_terms)" = "0" ]
    _call_gone r3s toolu_lost
}

@test "round3-4b: the same dead-hook record, not yet stale, does block parking" {
    export MOCK_CLAUDE_TURNS=4 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1 MOTHER_LIMITER_CALL_STALE_S=3600
    _make_job r3f
    _start_job r3f
    _wait_for 10 _marker_present
    _put_call r3f toolu_lost running $(( $(_now) - 100 ))
    _hold_flag r3f backoff "cut"
    _wait_for 30 _has_event r3f hold_giveup_deferred
    sleep 6
    [ "$(_jf r3f .state)" = "running" ]
    ! _turn_log_has "^term"
    [ -f "$(_call_file r3f toolu_lost)" ]
}

@test "round3-5: a stale .park and stale .calls entries are cleared at worker spawn and do not affect a later park" {
    export MOCK_CLAUDE_TURNS=4 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1
    _make_job r3w
    printf '{"pid": %s, "at": %s}\n' "$(_dead_pid)" "$(_now)" > "$RUNNER_DIR/r3w.park"
    _put_call r3w toolu_old running
    _put_call r3w toolu_old2 blocked
    _start_job r3w
    _wait_for 10 _marker_present
    [ ! -e "$RUNNER_DIR/r3w.park" ]
    _call_gone r3w toolu_old
    _call_gone r3w toolu_old2
    _hold_flag r3w backoff "cut"
    _wait_for 40 _job_state_is r3w awaiting       # the stale running entry did not stop the park
    _wait_for 10 _turn_log_has "^term in_turn=no"
    [ "$(_in_turn_terms)" = "0" ]
}

@test "round3-6: a call that starts during the park window aborts the park: nothing killed, job running, .park removed" {
    export MOCK_CLAUDE_TURNS=4 MOCK_CLAUDE_TURN_SLEEP=2 MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1 MOTHER_TEST_PARK_DELAY_S=4
    _make_job r3a
    _start_job r3a
    _wait_for 10 _marker_present
    _hold_flag r3a backoff "cut"
    _wait_for 30 _park_exists r3a
    _put_call r3a toolu_late running               # a parallel call began inside the window
    _wait_for 15 bash -c "! [ -f '$RUNNER_DIR/r3a.park' ]"
    [ "$(_jf r3a .state)" = "running" ]
    ! _turn_log_has "^term"
    ! _has_event r3a paused_for_limiter
    kill -0 "$SUP_PID"
}

@test "round3-7: the settings file wires PostToolUse and PostToolUseFailure to the hook's post mode; mode off has neither" {
    export MOTHER_LIMITER_HOLD_GRACE_S=100
    _make_job ps '.max_cost_usd = 5'
    MOCK_CLAUDE_STDOUT='' run mother-run-job ps
    local f="$RUNNER_DIR/ps.settings.json" ev
    [ -f "$f" ]
    for ev in PostToolUse PostToolUseFailure; do
        [ "$(jq -r --arg e "$ev" '.hooks[$e][0].hooks[0].type' "$f")" = "command" ]
        jq -r --arg e "$ev" '.hooks[$e][0].hooks[0].command' "$f" | grep -Eq 'mother-limiter-hold\.sh.* post$'
    done
    export MOTHER_LIMITER_MODE=off
    _make_job pso '.max_cost_usd = 5'
    MOCK_CLAUDE_STDOUT='' run mother-run-job pso
    f="$RUNNER_DIR/pso.settings.json"
    [ -f "$f" ]
    [ "$(jq -r '.hooks.PostToolUse // "none"' "$f")" = "none" ]
    [ "$(jq -r '.hooks.PostToolUseFailure // "none"' "$f")" = "none" ]
}
