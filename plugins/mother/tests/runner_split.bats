#!/usr/bin/env bats
# runner_split.bats — the runner dispatches through the coordinator and the local worker (cluster P1-5).
#
# Black-box contract. Everything is observed through files, events and CLI output; nothing here reads the
# runner's, coordinator's or worker's internals.
#
#   MOTHER_DISPATCH_MODE   legacy (default) | worker; also a config.env key. Anything else => legacy plus one
#                          stderr line. `mother-runner --publish-config-tick` writes runner/effective-config.json
#                          with additive dispatch_mode / dispatch_mode_source (env | config file | default).
#   Per job                dispatch_via "worker" goes through the worker even in legacy mode, "legacy" stays
#                          legacy even in worker mode. `mother add --via-worker` / plan `via_worker: true` set it.
#   Worker mode            the runner starts mother-coord (pidfile runner/coord.pid, socket runner/coord/worker.sock)
#                          and the local worker (mother-worker --id local --root $MOTHER_WORKER_ROOT/local, pidfile
#                          runner/worker-local.pid). Legacy mode with no worker-path job starts neither.
#                          Dispatch = the runner's `running` transition (spawned_by daemon) then runner/dispatch/<job>.json;
#                          the coordinator leases it (runner/leases/<job>.json) and no children/ entry exists.
#                          Slots = children + leases in offered|active. dispatch-last.json gains leased and mode.
#                          A released lease with end_reason succeeded is finalized by the runner through
#                          `coord_apply.sh --finalize`: succeeded only when the final commit is on the remote branch
#                          (else failed / unpushed_commit + needs_attention + audit line). A lost lease => failed
#                          worker_lost. Draining the runner stops the coordinator, not the worker.
#
# World. One test = one temp tree (setup_mother_env). The "current" world is $MOTHER_ROOT itself; the legacy
# comparison world is $MOTHER_ROOT/worlds/legacy with its own runner. Every job has its own repo + bare origin
# (main-dir jobs on one repo would serialise on the workspace lock). `claude` is a scriptable stand-in whose
# behaviour files live in $RS_CLAUDE_DIR. Every daemon is stopped in teardown by EXACT pid (or the worker's
# recorded process group): nothing is ever killed by pattern. The worker root is $MOTHER_WORKER_ROOT, a temp
# dir from setup_mother_env; the real ~/.mother and ~/.mother-worker are never touched (HOME is hermetic).

bats_require_minimum_version 1.5.0
load 'test_helper'
load 'gh_mock'

setup() {
    setup_mother_env
    unset MOTHER_GATES_ENABLED MOTHER_PHI_REPOS MOTHER_JOB_ID MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR \
          MOTHER_LIVE_ROOT MOTHER_DISPATCH_MODE GH_MOCK_FAIL_DRAFT
    export MOTHER_POSTURE_ENABLED=0 MOTHER_POLL_INTERVAL=1 MOTHER_CONCURRENCY=3
    export MOTHER_NOTIFY_ENABLED=0 MOTHER_BACKUP_ENABLED=0 MOTHER_BROKER_ENABLED=0 MOTHER_LIMITER_MODE=off
    export MOTHER_ADHERENCE_ENABLED=0 MOTHER_PROGRESS_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120 MOTHER_RESULT_GRACE_SECONDS=120
    export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com" \
           GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com" \
           GIT_AUTHOR_DATE="2026-10-01T00:00:00Z" GIT_COMMITTER_DATE="2026-10-01T00:00:00Z"
    export _MOTHER_TEST_REAL_HOME="${_MOTHER_TEST_REAL_HOME:-$HOME}"
    mkdir -p "$MOTHER_ROOT/fake-home"
    export HOME="$MOTHER_ROOT/fake-home"

    RS_C="$MOTHER_ROOT"
    RS_L="$MOTHER_ROOT/worlds/legacy"
    RS_WROOT="$MOTHER_WORKER_ROOT/local"
    RS_PIDS="$MOTHER_ROOT/rs-pids"
    : > "$RS_PIDS"
    export RS_CLAUDE_DIR="$MOTHER_ROOT/claude"
    mkdir -p "$RS_CLAUDE_DIR"
    _rs_install_claude
}

# Stop everything this test started, by exact pid / recorded process group only: runners first (so nothing is
# restarted), then coordinators, worker daemons, worker groups and supervisors recorded in children/.
teardown() {
    local kind n r f
    for r in "${RS_C:-/nonexistent}" "${RS_L:-/nonexistent}"; do
        _rs_kill_pid "$(_rs_pidfile_val "$r/runner/runner.pid")"
    done
    if [ -f "${RS_PIDS:-/nonexistent}" ]; then
        while read -r kind n; do
            case "$kind" in P) _rs_kill_pid "$n" ;; esac
        done < "$RS_PIDS"
    fi
    for r in "${RS_C:-/nonexistent}" "${RS_L:-/nonexistent}"; do
        _rs_kill_pid "$(_rs_pidfile_val "$r/runner/coord.pid")"
        _rs_kill_pid "$(_rs_pidfile_val "$r/runner/coord/coord.pid")"
        _rs_kill_pid "$(_rs_pidfile_val "$r/runner/worker-local.pid")"
        for f in "$r"/runner/children/*.json; do
            [ -f "$f" ] && _rs_kill_pid "$(jq -r '.pid // empty' "$f" 2>/dev/null)"
        done
    done
    if [ -f "${RS_WROOT:-/nonexistent}/worker.pid" ]; then
        read -r n kind < "$RS_WROOT/worker.pid" || true
        _rs_kill_pid "$n"
        _rs_kill_group "$kind"
    fi
    # The worker root carries the .mother-worker-live marker safe_rm_tree refuses; the root lives inside this
    # test's own temp tree, so (only) the markers are removed before the tree is.
    rm -f "${RS_WROOT:-/nonexistent}/.mother-worker-live" "${MOTHER_WORKER_ROOT:-/nonexistent}/.mother-worker-live"
    teardown_mother_env
}

# The scriptable worker. Behaviour file for invocation n: $RS_CLAUDE_DIR/behave.<n>; per-branch (slashes as _):
# $RS_CLAUDE_DIR/behave-b.<branch>. Defaults: push the branch, print a result event, sleep $RS_CLAUDE_DIR/default-sleep
# seconds (else 3), exit 0. A behave file may set PUSH, SLEEP, EXIT and call _mkpr (registers a gh PR fixture).
_rs_install_claude() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
ROOT="${RS_CLAUDE_DIR:-}"
[ -n "$ROOT" ] || exit 97
n=$(( $(cat "$ROOT/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$ROOT/count"
cat > /dev/null
PUSH=1; EXIT=0; SLEEP=$(cat "$ROOT/default-sleep" 2>/dev/null || echo 3)
BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
_mkpr() {
    local r="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}" url="https://github.com/test/rs/pull/$$" k
    mkdir -p "$r/gh/pr" "$r/gh/pr-list"
    k=$(printf '%s' "$url" | tr -c 'a-zA-Z0-9' '_')
    jq -nc --arg h "$BR" '{state:"OPEN",headRefName:$h,commits:[],isDraft:false,body:""}' > "$r/gh/pr/$k.json"
    k=$(printf '%s' "$BR" | tr -c 'a-zA-Z0-9' '_')
    jq -nc --arg u "$url" '[{url:$u}]' > "$r/gh/pr-list/$k.json"
}
bk=$(printf '%s' "$BR" | tr -c 'a-zA-Z0-9' '_')
[ -f "$ROOT/behave-b.$bk" ] && . "$ROOT/behave-b.$bk"
[ -f "$ROOT/behave.$n" ] && . "$ROOT/behave.$n"
if [ "$PUSH" = "1" ]; then
    git push -q origin "HEAD:refs/heads/$BR" >/dev/null 2>&1 || true
fi
cat <<'EOF'
{"type":"assistant","message":{"id":"msg_rs","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":200}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.004,"modelUsage":{"claude-sonnet-5":{"costUSD":0.004,"inputTokens":1000,"outputTokens":200}}}
EOF
[ "$SLEEP" = "0" ] || sleep "$SLEEP"
exit "$EXIT"
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}

# _rs_behave <id> <var=value>... — behaviour for the job's branch (applies to every invocation on it).
_rs_behave() {
    local id="$1" bk; shift
    bk=$(printf '%s' "feature/rs-$id" | tr -c 'a-zA-Z0-9' '_')
    printf '%s\n' "$@" >> "$RS_CLAUDE_DIR/behave-b.$bk"
}

# ---------------------------------------------------------------------------
# Utilities

_rs_wait_for() {
    local t="$1" i=0 max
    shift
    max=$(( t * 4 ))
    while [ "$i" -lt "$max" ]; do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 0.25
        i=$(( i + 1 ))
    done
    "$@" >/dev/null 2>&1
}

_rs_dump() {
    local r f
    for r in "$RS_C" "$RS_L"; do
        [ -d "$r" ] || continue
        echo "--- $r runner.out" >&2;  tail -n 30 "$r/runner.out" >&2 2>/dev/null || true
        echo "--- $r leases" >&2;      cat "$r"/runner/leases/*.json >&2 2>/dev/null || true
        echo "--- $r audit" >&2;       cat "$r/runner/leases/audit.jsonl" >&2 2>/dev/null || true
        echo "--- $r dispatch-last" >&2; cat "$r/runner/dispatch-last.json" >&2 2>/dev/null || true
        for f in "$r"/jobs/*.json; do [ -f "$f" ] && jq -c '{id,state,activity,paused_reason,failure_reason}' "$f" >&2; done
        for f in "$r"/events/*.jsonl; do [ -f "$f" ] && { echo "--- $f" >&2; jq -c '[.ts,.kind,.detail.reason]' "$f" >&2 2>/dev/null | tail -n 25; }; done
    done
    true
}

_rs_must() {
    local t="$1" what="$2"
    shift 2
    if ! _rs_wait_for "$t" "$@"; then
        echo "timed out after ${t}s waiting for: $what" >&2
        _rs_dump
        return 1
    fi
}

_rs_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 1 ]; }
_rs_alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1; [ -n "$s" ] && [[ "$s" != Z* ]]; }
_rs_dead() { ! _rs_alive "$1"; }
_rs_note() { printf '%s %s\n' "$1" "$2" >> "$RS_PIDS"; }
_rs_pidfile_val() { { cat "$1" 2>/dev/null || true; } | awk '{print $1}' | tr -dc '0-9'; }

_rs_kill_pid() {
    _rs_num "${1:-}" || return 0
    kill -9 "$1" 2>/dev/null || true
    _rs_wait_for 5 _rs_dead "$1" || true
}

# Exact process group only, never our own.
_rs_kill_group() {
    local mine
    _rs_num "${1:-}" || return 0
    mine=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    [ "$1" != "$mine" ] || return 0
    kill -9 -- "-$1" 2>/dev/null || true
}

_rs_now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
_rs_iso_ms() { perl -MTime::Local=timegm -e '$ARGV[0]=~/^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)(?:\.(\d+))?/ or exit 1; printf "%d", timegm($6,$5,$4,$3,$2-1,$1)*1000 + substr(($7//"0")."00",0,3)' "$1"; }

# ---------------------------------------------------------------------------
# Worlds

_rs_export_root() {
    local r="$1"
    export MOTHER_ROOT="$r"
    export JOBS_DIR="$r/jobs" EVENTS_DIR="$r/events" LOGS_DIR="$r/logs" DRAFTS_DIR="$r/drafts" \
           CURSORS_DIR="$r/cursors" RUNNER_DIR="$r/runner" ARCHIVE_DIR="$r/archive" \
           TEARDOWN_DIR="$r/teardown-pending"
    mkdir -p "$JOBS_DIR" "$EVENTS_DIR" "$LOGS_DIR" "$DRAFTS_DIR" "$CURSORS_DIR" "$RUNNER_DIR" \
             "$ARCHIVE_DIR" "$TEARDOWN_DIR"
}

# _rs_in_world <root> <cmd...> — run <cmd> as a plain process on <root>, in a subshell.
_rs_in_world() {
    local root="$1"
    shift
    ( _rs_export_root "$root"; unset MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR; "$@" )
}

# _rs_job_here <id> [extra-jq] — (call through _rs_in_world) a git repo + bare origin of its own, a plan, a log and a
# ready main-dir no_pr job with an unpushed feature commit on branch feature/rs-<id>.
_rs_job_here() {
    local id="$1" extra="${2:-.}"
    local repo="$MOTHER_ROOT/work/repo-$id" origin="$MOTHER_ROOT/origin-$id.git" branch="feature/rs-$id"
    mkdir -p "$repo"
    git init -q --bare "$origin"
    (
        cd "$repo" || exit 1
        git init -q
        git symbolic-ref HEAD refs/heads/main
        echo "# repo" > README.md
        git add .
        git commit -q -m "init"
        git remote add origin "$origin"
        git push -q -u origin main
        git checkout -q -B "$branch" origin/main
        mkdir -p app
        echo '<?php' > app/Foo.php
        git add app/Foo.php
        git commit -q -m "feature work for $branch"
        git checkout -q main
    ) >/dev/null 2>&1
    make_plan "$EVENTS_DIR/$id-plan.md"
    touch "$LOGS_DIR/$id.log"
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo = "repo-'"$id"'"
         | .repo_path = "'"$repo"'"
         | .base_ref = "origin/main"
         | .branch = "'"$branch"'"
         | .plan_path = "'"$EVENTS_DIR/$id-plan.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .no_pr = true
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }
         | '"$extra"
}

# _rs_job <root> <id> [extra-jq]
_rs_job() { local r="$1"; shift; _rs_in_world "$r" _rs_job_here "$@"; }

# _rs_runner <root> <legacy|worker|unset> [VAR=value...] — start mother-runner in the background on <root>. Its exact
# pid is noted for teardown.
_rs_runner() {
    local root="$1" mode="$2"
    shift 2
    mkdir -p "$root"
    (
        _rs_export_root "$root"
        unset MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR MOTHER_DISPATCH_MODE
        [ "$mode" = "unset" ] || export MOTHER_DISPATCH_MODE="$mode"
        cd / || exit 1
        exec env "$@" mother-runner
    ) >> "$root/runner.out" 2>&1 3>&- &
    _rs_note P "$!"
    disown "$!" 2>/dev/null || true
    _rs_must 20 "runner pid file" test -s "$root/runner/runner.pid"
}

_rs_runner_pid() { _rs_pidfile_val "$1/runner/runner.pid"; }

# _rs_runner_stop <root> — SIGTERM (drain) the runner by its exact pid and wait for it to exit.
_rs_runner_stop() {
    local p; p=$(_rs_runner_pid "$1")
    _rs_num "$p" || return 1
    kill -TERM "$p"
    _rs_must 60 "runner to drain and exit" _rs_dead "$p"
}

# Observations (all take the world root first)
_rs_state() { jq -r '.state // empty' "$1/jobs/$2.json" 2>/dev/null; }
_rs_state_is() { [ "$(_rs_state "$1" "$2")" = "$3" ]; }
_rs_field() { jq -r ".$3 // empty" "$1/jobs/$2.json" 2>/dev/null; }
_rs_lease_file() { printf '%s/runner/leases/%s.json' "$1" "$2"; }
_rs_lease_exists() { [ -f "$(_rs_lease_file "$1" "$2")" ]; }
_rs_lease_state() { jq -r '.state // empty' "$(_rs_lease_file "$1" "$2")" 2>/dev/null; }
_rs_lease_is() { [ "$(_rs_lease_state "$1" "$2")" = "$3" ]; }
_rs_child_for() {
    local f
    for f in "$1"/runner/children/*.json; do
        [ -f "$f" ] && [ "$(jq -r '.job_id // empty' "$f" 2>/dev/null)" = "$2" ] && return 0
    done
    return 1
}
_rs_leased_now() {
    find "$1/runner/leases" -maxdepth 1 -name '*.json' -type f 2>/dev/null \
        | while read -r f; do jq -r '.state // empty' "$f" 2>/dev/null; done \
        | grep -c -E '^(offered|active)$' || true
}
_rs_claude_started() { [ -s "$RS_CLAUDE_DIR/count" ]; }
_rs_event_has() { jq -e -s --arg k "$3" 'map(select(.kind == $k)) | length > 0' "$1/events/$2.jsonl" >/dev/null 2>&1; }
_rs_event_reason_has() {
    jq -e -s --arg r "$3" 'map(select((.detail.reason // "") == $r)) | length > 0' "$1/events/$2.jsonl" >/dev/null 2>&1
}
_rs_coord_pid() {
    local p; p=$(_rs_pidfile_val "$1/runner/coord.pid")
    [ -n "$p" ] || p=$(_rs_pidfile_val "$1/runner/coord/coord.pid")
    printf '%s' "$p"
}
_rs_worker_pid() { _rs_pidfile_val "$1/runner/worker-local.pid"; }
_rs_no_daemons() {
    local r="$1" p
    [ ! -e "$r/runner/coord.pid" ] && [ ! -e "$r/runner/coord/coord.pid" ] && [ ! -e "$r/runner/worker-local.pid" ] || return 1
    [ ! -e "$RS_WROOT" ] || return 1
    p=$(_rs_coord_pid "$r"); [ -z "$p" ]
}
_rs_worker_connected() {
    ( _rs_export_root "$1"; mother workers --json 2>/dev/null \
        | jq -e '[.workers[]? | select(.id == "local" and .connected == true)] | length == 1' >/dev/null )
}
_rs_all_succeeded() { local id; for id in "$@"; do _rs_state_is "$RS_C" "$id" succeeded || return 1; done; }

# Run a mother CLI command in a world.
_rs_mother() { local r="$1"; shift; ( _rs_export_root "$r"; mother "$@" ); }

# ===========================================================================
# 1. Legacy is the default

@test "legacy is the default: a job forks mother-run-job as today, no coordinator or worker exists, effective-config says legacy/default" {
    local id="rs-legacy"
    _rs_job "$RS_C" "$id"
    echo 5 > "$RS_CLAUDE_DIR/default-sleep"
    _rs_runner "$RS_C" unset

    _rs_must 30 "a children/ entry for the job (legacy fork)" _rs_child_for "$RS_C" "$id"
    ! _rs_lease_exists "$RS_C" "$id"
    _rs_must 60 "the job to succeed" _rs_state_is "$RS_C" "$id" succeeded
    _rs_no_daemons "$RS_C"
    [ "$(cat "$RS_CLAUDE_DIR/count")" = "1" ]

    run _rs_in_world "$RS_C" mother-runner --publish-config-tick
    [ "$status" -eq 0 ]
    [ "$(jq -r .dispatch_mode "$RS_C/runner/effective-config.json")" = "legacy" ]
    [ "$(jq -r .dispatch_mode_source "$RS_C/runner/effective-config.json")" = "default" ]
}

@test "an unrecognised MOTHER_DISPATCH_MODE falls back to legacy with exactly one stderr line" {
    run --separate-stderr env MOTHER_DISPATCH_MODE=banana MOTHER_ROOT="$RS_C" RUNNER_DIR="$RS_C/runner" mother-runner --publish-config-tick
    [ "$status" -eq 0 ]
    [ "$(jq -r .dispatch_mode "$RS_C/runner/effective-config.json")" = "legacy" ]
    [ "$(printf '%s\n' "$stderr" | grep -c .)" = "1" ]
    printf '%s' "$stderr" | grep -qi 'dispatch'
}

@test "dispatch mode is read from the environment first, then config.env, and reported with its source" {
    printf 'MOTHER_DISPATCH_MODE=worker\n' > "$RS_C/config.env"
    run env MOTHER_ROOT="$RS_C" RUNNER_DIR="$RS_C/runner" mother-runner --publish-config-tick
    [ "$status" -eq 0 ]
    [ "$(jq -r .dispatch_mode "$RS_C/runner/effective-config.json")" = "worker" ]
    [ "$(jq -r .dispatch_mode_source "$RS_C/runner/effective-config.json")" = "config file" ]

    run env MOTHER_DISPATCH_MODE=legacy MOTHER_ROOT="$RS_C" RUNNER_DIR="$RS_C/runner" mother-runner --publish-config-tick
    [ "$status" -eq 0 ]
    [ "$(jq -r .dispatch_mode "$RS_C/runner/effective-config.json")" = "legacy" ]
    [ "$(jq -r .dispatch_mode_source "$RS_C/runner/effective-config.json")" = "env" ]
}

# ===========================================================================
# 2. Worker mode end to end, equal to legacy

@test "worker mode: a job goes ready -> running -> succeeded and leaves the same job, event kinds and log as a legacy run" {
    local id="rs-e2e" t="$BATS_TEST_TMPDIR"
    echo 6 > "$RS_CLAUDE_DIR/default-sleep"

    # The legacy run of the same scenario, in its own world with its own runner.
    mkdir -p "$RS_L"
    _rs_job "$RS_L" "$id"
    _rs_runner "$RS_L" legacy
    _rs_must 90 "legacy job to succeed" _rs_state_is "$RS_L" "$id" succeeded
    _rs_runner_stop "$RS_L"

    _rs_job "$RS_C" "$id"
    _rs_runner "$RS_C" worker
    _rs_must 30 "the job to be running" _rs_state_is "$RS_C" "$id" running
    _rs_must 30 "the job to have a lease" _rs_lease_exists "$RS_C" "$id"
    [ "$(_rs_lease_state "$RS_C" "$id")" != "" ]
    ! _rs_child_for "$RS_C" "$id"

    # `mother workers --json` lists the local laptop worker, with the job while it runs.
    _rs_must 20 "local worker to be connected" _rs_worker_connected "$RS_C"
    run _rs_mother "$RS_C" workers --json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '[.workers[] | select(.id == "local")] | length')" = "1" ]
    [ "$(printf '%s' "$output" | jq -r '.workers[] | select(.id == "local") | .kind')" = "laptop" ]
    [ "$(printf '%s' "$output" | jq -r '.workers[] | select(.id == "local") | .data_classes | sort | join(",")')" = "company,personal,phi" ]
    _rs_must 20 "the job to be listed on the worker" bash -c \
        'cd /; MOTHER_ROOT="$1" mother workers --json | jq -e --arg id "$2" "[.workers[] | select(.id == \"local\") | .jobs | tostring | contains(\$id)] | any" >/dev/null' _ "$RS_C" "$id"
    run _rs_mother "$RS_C" status "$id"
    [[ "$output" =~ worker:\ local\ \(lease\ e[0-9]+,\ hb\ [0-9]+s\ ago\) ]]

    _rs_must 90 "the job to succeed through the worker" _rs_state_is "$RS_C" "$id" succeeded

    jq -S '{state, branch, no_pr, failure_reason: (.failure_reason // null), pr_url: (.pr_url // null)}' "$RS_L/jobs/$id.json" > "$t/l.job"
    jq -S '{state, branch, no_pr, failure_reason: (.failure_reason // null), pr_url: (.pr_url // null)}' "$RS_C/jobs/$id.json" > "$t/c.job"
    diff -u "$t/l.job" "$t/c.job"
    jq -s '[.[] | select(.kind != "final_result_observed") | .kind]' "$RS_L/events/$id.jsonl" > "$t/l.events"
    jq -s '[.[] | select(.kind != "final_result_observed") | .kind]' "$RS_C/events/$id.jsonl" > "$t/c.events"
    diff -u "$t/l.events" "$t/c.events"
    grep -q '"type":"result"' "$RS_C/logs/$id.log"
    grep -q "=== mother job $id starting" "$RS_C/logs/$id.log"
    grep -q "=== mother job $id starting" "$RS_L/logs/$id.log"
    [ "$(cat "$RS_CLAUDE_DIR/count")" = "2" ]
}

# ===========================================================================
# 3. Per-job burn-in flag and escape hatch

@test "legacy mode: a dispatch_via worker job goes through the worker while a plain job still forks legacy" {
    local plain="rs-plain" via="rs-via"
    echo 8 > "$RS_CLAUDE_DIR/default-sleep"
    _rs_job "$RS_C" "$plain"
    _rs_job "$RS_C" "$via" '.dispatch_via = "worker"'
    _rs_runner "$RS_C" unset

    _rs_must 40 "the via-worker job to be leased" _rs_lease_exists "$RS_C" "$via"
    _rs_must 40 "the plain job to be forked legacy" _rs_child_for "$RS_C" "$plain"
    ! _rs_lease_exists "$RS_C" "$plain"
    ! _rs_child_for "$RS_C" "$via"
    _rs_must 90 "both jobs to succeed" _rs_all_succeeded "$plain" "$via"
}

@test "worker mode: a dispatch_via legacy job is forked as before while a plain job goes through the worker" {
    local plain="rs-wplain" legacy="rs-wlegacy"
    echo 8 > "$RS_CLAUDE_DIR/default-sleep"
    _rs_job "$RS_C" "$plain"
    _rs_job "$RS_C" "$legacy" '.dispatch_via = "legacy"'
    _rs_runner "$RS_C" worker

    _rs_must 40 "the plain job to be leased" _rs_lease_exists "$RS_C" "$plain"
    _rs_must 40 "the legacy-pinned job to be forked" _rs_child_for "$RS_C" "$legacy"
    ! _rs_lease_exists "$RS_C" "$legacy"
    ! _rs_child_for "$RS_C" "$plain"
    _rs_must 90 "both jobs to succeed" _rs_all_succeeded "$plain" "$legacy"
}

# ===========================================================================
# 4. Concurrency

@test "worker mode honours MOTHER_CONCURRENCY: never more than 2 leases offered|active at once, all three jobs succeed" {
    local ids="rs-c1 rs-c2 rs-c3" id n max=0 i
    echo 5 > "$RS_CLAUDE_DIR/default-sleep"
    for id in $ids; do _rs_job "$RS_C" "$id"; done
    _rs_runner "$RS_C" worker MOTHER_CONCURRENCY=2

    for i in $(seq 1 600); do
        n=$(_rs_leased_now "$RS_C")
        [ "$n" -le 2 ] || { echo "saw $n leases offered|active at once" >&2; _rs_dump; return 1; }
        [ "$n" -le "$max" ] || max="$n"
        _rs_all_succeeded $ids && break
        sleep 0.25
    done
    _rs_all_succeeded $ids || { _rs_dump; return 1; }
    [ "$max" -eq 2 ]
    [ "$(jq -r '.leased // empty' "$RS_C/runner/dispatch-last.json")" != "" ]
    [ "$(jq -r '.mode' "$RS_C/runner/dispatch-last.json")" = "worker" ]
}

# ===========================================================================
# 5. Dispatch latency does not regress

# _rs_latency_run <root> <mode> <outfile> — five jobs, one at a time; per job the ms from the `running` event to the
# banner line appearing in the canonical log.
_rs_latency_run() {
    local root="$1" mode="$2" out="$3" i id t0 t1
    : > "$out"
    echo 0 > "$RS_CLAUDE_DIR/default-sleep"
    _rs_runner "$root" "$mode"
    if [ "$mode" = "worker" ]; then
        _rs_must 40 "local worker connected" _rs_worker_connected "$root"
    fi
    for i in 1 2 3 4 5; do
        id="rs-lat-$mode-$i"
        _rs_job "$root" "$id"
        t1=$(perl -MTime::HiRes=time,sleep -e '
            my ($f, $pat, $max) = @ARGV; my $end = time + $max;
            while (time < $end) {
                if (open(my $h, "<", $f)) { local $/; my $c = <$h>; if (defined $c && index($c, $pat) >= 0) { printf "%d", time*1000; exit 0 } }
                sleep 0.02;
            }
            exit 1' "$root/logs/$id.log" "=== mother job $id starting" 60) || { echo "no banner for $id" >&2; _rs_dump; return 1; }
        _rs_must 60 "$id to succeed" _rs_state_is "$root" "$id" succeeded
        t0=$(_rs_iso_ms "$(jq -r -s 'map(select(.kind == "running")) | .[0].ts' "$root/events/$id.jsonl")")
        echo $(( t1 - t0 )) >> "$out"
    done
    _rs_runner_stop "$root"
}

@test "dispatch latency: worker-mode median is within 1.0 s and max within 2.0 s of the legacy run (ready -> banner in the canonical log)" {
    local t="$BATS_TEST_TMPDIR" lmed lmax wmed wmax
    mkdir -p "$RS_L"
    _rs_latency_run "$RS_L" legacy "$t/legacy.ms"
    _rs_latency_run "$RS_C" worker "$t/worker.ms"
    lmed=$(sort -n "$t/legacy.ms" | sed -n 3p); lmax=$(sort -n "$t/legacy.ms" | tail -n 1)
    wmed=$(sort -n "$t/worker.ms" | sed -n 3p); wmax=$(sort -n "$t/worker.ms" | tail -n 1)
    echo "# dispatch latency ms: legacy median=$lmed max=$lmax (all: $(tr '\n' ' ' < "$t/legacy.ms"))" >&3
    echo "# dispatch latency ms: worker median=$wmed max=$wmax (all: $(tr '\n' ' ' < "$t/worker.ms"))" >&3
    echo "legacy median=$lmed max=$lmax; worker median=$wmed max=$wmax" >&2
    [ "$wmed" -le $(( lmed + 1000 )) ]
    [ "$wmax" -le $(( lmax + 2000 )) ]
}

# ===========================================================================
# 6. Runner restart (MC-16)

@test "runner drain stops the coordinator but not the worker: the job keeps running and the restarted runner finalizes it" {
    local id="rs-restart" rp wp
    echo 12 > "$RS_CLAUDE_DIR/default-sleep"
    _rs_job "$RS_C" "$id"
    _rs_runner "$RS_C" worker
    _rs_must 40 "the job's claude to start" _rs_claude_started
    _rs_must 30 "the job to be running with a lease" _rs_lease_exists "$RS_C" "$id"
    _rs_must 30 "worker pid file" test -s "$RS_C/runner/worker-local.pid"
    wp=$(_rs_worker_pid "$RS_C")
    _rs_num "$wp"
    local cp; cp=$(_rs_coord_pid "$RS_C")
    _rs_num "$cp"

    rp=$(_rs_runner_pid "$RS_C")
    _rs_runner_stop "$RS_C"
    _rs_must 20 "the coordinator to stop with the runner" _rs_dead "$cp"
    _rs_alive "$wp"
    _rs_state_is "$RS_C" "$id" running

    _rs_runner "$RS_C" worker
    _rs_must 90 "the job to succeed after the runner restarted" _rs_state_is "$RS_C" "$id" succeeded
    [ "$(cat "$RS_CLAUDE_DIR/count")" = "1" ]
    ! _rs_event_has "$RS_C" "$id" runner_died
    ! _rs_event_reason_has "$RS_C" "$id" runner_died
    ! _rs_event_has "$RS_C" "$id" worker_lost
    ! _rs_event_reason_has "$RS_C" "$id" worker_lost
    [ "$(_rs_field "$RS_C" "$id" failure_reason)" = "" ]
}

# ===========================================================================
# 7. Lost lease

@test "worker tree killed: the lease is lost, the canonical job fails worker_lost with usage recorded, and failure routing sees it" {
    local id="rs-lost" wpid wpgid sup supgid g
    echo 60 > "$RS_CLAUDE_DIR/default-sleep"
    _rs_job "$RS_C" "$id"
    # Freeze the outcome at `failed` (no escalation or reconcile): the test judges the failure itself.
    _rs_runner "$RS_C" worker MOTHER_LEASE_TTL_S=6 MOTHER_ESCALATION_ENABLED=0 MOTHER_RECONCILE_ENABLED=0
    _rs_must 40 "the job's claude to start" _rs_claude_started
    _rs_must 30 "the lease to be active" _rs_lease_is "$RS_C" "$id" active

    _rs_must 20 "worker.pid" test -s "$RS_WROOT/worker.pid"
    _rs_must 20 "the supervisor to be tracked by the worker" bash -c 'ls "$1"/children/*.json >/dev/null 2>&1' _ "$RS_WROOT"
    read -r wpid wpgid < "$RS_WROOT/worker.pid"
    _rs_num "$wpgid"
    sup=$(jq -r '.pid' "$RS_WROOT"/children/*.json | head -n 1)
    _rs_num "$sup"
    # The whole worker tree dies at once: the daemon's group, and the supervisor with its own group. (A surviving
    # supervisor would be re-adopted by the worker the runner restarts, which is the designed non-loss path.)
    supgid=$(ps -o pgid= -p "$sup" | tr -d ' ')
    kill -9 -- "-$wpgid" 2>/dev/null || true
    for g in "$supgid"; do
        [ "$g" != "$(ps -o pgid= -p $$ | tr -d ' ')" ] && [ "$g" != "$(ps -o pgid= -p "$(_rs_runner_pid "$RS_C")" | tr -d ' ')" ] \
            && kill -9 -- "-$g" 2>/dev/null || true
    done
    kill -9 "$sup" 2>/dev/null || true

    _rs_must 60 "a failed event with reason worker_lost" _rs_event_reason_has "$RS_C" "$id" worker_lost
    _rs_must 20 "the job to be failed" _rs_state_is "$RS_C" "$id" failed
    [ "$(_rs_field "$RS_C" "$id" failure_reason)" = "worker_lost" ]
    jq -e -s 'map(select(.kind == "failed" and .detail.reason == "worker_lost")) | length == 1' "$RS_C/events/$id.jsonl" >/dev/null
    jq -e -s 'map(select(.detail.reason == "worker_lost" and (.detail.worker // "") != "" and (.detail.lease_epoch != null))) | length >= 1' \
        "$RS_C/events/$id.jsonl" >/dev/null
    grep -qF "\"job_id\":\"$id\"" "$RS_C/metrics/runs.jsonl"
    _rs_must 30 "a failure_routed event" _rs_event_has "$RS_C" "$id" failure_routed
    ! _rs_state_is "$RS_C" "$id" running
}

# ===========================================================================
# 8. Quota gate in worker mode

@test "worker mode quota gate: over the cap no new lease is granted and a running leased job pauses to awaiting; reopening the gate releases the waiting job" {
    local a="rs-qa" b="rs-qb" pct
    echo 3 > "$RS_CLAUDE_DIR/default-sleep"
    _rs_behave "$a" SLEEP=40
    _rs_job "$RS_C" "$a"
    _rs_runner "$RS_C" worker
    _rs_must 40 "A's claude to start" _rs_claude_started
    _rs_must 30 "A to hold a lease" _rs_lease_exists "$RS_C" "$a"
    _rs_state_is "$RS_C" "$a" running

    # Usage jumps over the cap (fresh feed, both windows 95%); a second job arrives.
    jq -nc --argjson r "$(( $(date +%s) + 3600 ))" \
        '{posture: "Cruise", stale_input: false, five_hour: {used_pct: 95, resets_at: $r}, seven_day: {used_pct: 95, resets_at: $r}}' \
        > "$MOTHER_BISHOP_POSTURE_FILE"
    _rs_job "$RS_C" "$b"

    # The running leased job is paused (pause_requested reaches the worker through the downlink): awaiting, quota_*.
    _rs_must 60 "A to pause to awaiting" _rs_state_is "$RS_C" "$a" awaiting
    case "$(_rs_field "$RS_C" "$a" paused_reason)" in quota_*) ;; *) echo "paused_reason=$(_rs_field "$RS_C" "$a" paused_reason)" >&2; return 1 ;; esac

    # B stays ready with no lease while the gate is shut.
    sleep 4
    _rs_state_is "$RS_C" "$b" ready
    ! _rs_lease_exists "$RS_C" "$b"

    # Open the gate: B is leased and succeeds.
    # (The gate file is what `mother quota off` writes; the CLI itself refuses callers inside a Mother job.)
    jq -nc '{state: "off", changed_at: "2026-11-08T12:00:00.000Z", changed_by: "cli"}' > "$RS_C/quota-gate.json"
    _rs_must 60 "B to be leased once the gate is open" _rs_lease_exists "$RS_C" "$b"
    _rs_must 90 "B to succeed" _rs_state_is "$RS_C" "$b" succeeded
}

# ===========================================================================
# 9. Success must be verified against the remote

@test "an unverified success is refused: the worker finished but the final commit is not on origin, so the job is not succeeded (unpushed_commit)" {
    local id="rs-unpushed"
    echo 2 > "$RS_CLAUDE_DIR/default-sleep"
    # A normal PR job (not no_pr): the stand-in registers a PR for its branch, makes its commit local, never pushes.
    _rs_behave "$id" PUSH=0 _mkpr
    _rs_job "$RS_C" "$id" '.no_pr = false'
    _rs_runner "$RS_C" worker MOTHER_ESCALATION_ENABLED=0 MOTHER_RECONCILE_ENABLED=0 MOTHER_FAILURE_ROUTING_ENABLED=0

    _rs_must 90 "the job to leave running" bash -c \
        'cd /; s=$(jq -r .state "$1/jobs/$2.json"); [ "$s" != running ] && [ "$s" != ready ]' _ "$RS_C" "$id"
    sleep 3
    [ "$(_rs_state "$RS_C" "$id")" != "succeeded" ]
    # The remote never got the branch.
    run git -C "$RS_C/work/repo-$id" ls-remote --heads origin "feature/rs-$id"
    [ -z "$output" ]
    # The reason is recorded: failure_reason, an attention flag, or the failed event.
    local why
    why="$(_rs_field "$RS_C" "$id" failure_reason) $(jq -r '.needs_attention.reason // empty' "$RS_C/jobs/$id.json") $(jq -r '[.[]?.detail.reason? // empty] | join(" ")' <(jq -s . "$RS_C/events/$id.jsonl"))"
    [[ "$why" == *unpushed_commit* ]] || { echo "no unpushed_commit reason: $why" >&2; _rs_dump; return 1; }
}

# ===========================================================================
# 10. Cancel

@test "mother cancel on a running worker-mode job gives cancelled within 10 s" {
    local id="rs-cancel" i
    echo 40 > "$RS_CLAUDE_DIR/default-sleep"
    _rs_job "$RS_C" "$id"
    _rs_runner "$RS_C" worker
    _rs_must 40 "the job's claude to start" _rs_claude_started
    _rs_must 30 "the job to be running" _rs_state_is "$RS_C" "$id" running
    _rs_lease_exists "$RS_C" "$id"

    run _rs_mother "$RS_C" cancel "$id"
    [ "$status" -eq 0 ]
    _rs_must 10 "the job to be cancelled" _rs_state_is "$RS_C" "$id" cancelled
}

# ===========================================================================
# 11. CLI

@test "mother workers with no coordinator running says so and exits 0" {
    run _rs_mother "$RS_C" workers
    [ "$status" -eq 0 ]
    [[ "$output" == *"coordinator not running (dispatch mode: legacy)"* ]]
}

@test "mother status shows 'waiting: <reason>' for a ready job whose dispatch request carries a wait_reason" {
    local id="rs-wait"
    _rs_job "$RS_C" "$id"
    mkdir -p "$RS_C/runner/dispatch"
    jq -nc --arg j "$id" '{job: $j, requested_at: "2026-11-08T12:00:00.000Z", wait_reason: "no_worker_connected"}' \
        > "$RS_C/runner/dispatch/$id.json"
    run _rs_mother "$RS_C" status "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"waiting: no_worker_connected"* ]]
}

_rs_add() {
    local br="$1"; shift
    ( _rs_export_root "$RS_C"; mother add --plan-file "$RS_C/plan.md" --repo testrepo --repo-path "$RS_C/testrepo" --branch "$br" "$@" )
}

@test "mother add --via-worker and plan via_worker: true store dispatch_via worker; no other job key is added" {
    local plain via viaplan keys_plain keys_via
    git init -q "$RS_C/testrepo"
    make_plan "$RS_C/plan.md"
    run --separate-stderr _rs_add feature/plain
    [ "$status" -eq 0 ]; plain="$output"
    run --separate-stderr _rs_add feature/via --via-worker
    [ "$status" -eq 0 ]; via="$output"
    make_plan_with_config "$RS_C/plan.md" 'suggested_config:
  cody: {model: sonnet, effort: medium, rationale: "x"}
  redd: {model: sonnet, effort: medium, rationale: "x"}
  marty: {model: sonnet, effort: medium, rationale: "x"}
  perri: {model: sonnet, effort: medium, rationale: "x"}
via_worker: true'
    run --separate-stderr _rs_add feature/viaplan
    [ "$status" -eq 0 ]; viaplan="$output"

    [ "$(jq -r '.dispatch_via // "none"' "$JOBS_DIR/$via.json")" = "worker" ]
    [ "$(jq -r '.dispatch_via // "none"' "$JOBS_DIR/$viaplan.json")" = "worker" ]
    case "$(jq -r '.dispatch_via // "none"' "$JOBS_DIR/$plain.json")" in none|legacy) ;; *) return 1 ;; esac

    keys_plain=$(jq -r 'keys[]' "$JOBS_DIR/$plain.json" | grep -vx dispatch_via | sort)
    keys_via=$(jq -r 'keys[]' "$JOBS_DIR/$via.json" | sort)
    [ "$keys_via" = "$(printf '%s\ndispatch_via\n' "$keys_plain" | sort)" ]
    [ "$(jq -r 'keys[]' "$JOBS_DIR/$viaplan.json" | sort)" = "$keys_via" ]
}

# ===========================================================================
# 12. Finalize verification (coord_apply.sh --finalize)

# _rs_fin_seed <id> <pushed:0|1> [extra-jq for the canonical job] — a canonical job (running) in $RS_C with a
# released/succeeded lease and a succeeded worker mirror; the branch's commit is pushed to origin only when <pushed>.
_rs_fin_seed() {
    local id="$1" pushed="$2" extra="${3:-.}" repo br
    _rs_job "$RS_C" "$id" ".no_pr = false | .state = \"running\" | $extra"
    repo="$RS_C/work/repo-$id"; br="feature/rs-$id"
    [ "$pushed" != "1" ] || git -C "$repo" push -q origin "refs/heads/$br:refs/heads/$br"
    mkdir -p "$RS_C/runner/leases" "$MOTHER_WORKER_ROOT/local/jobs"
    jq -nc '{lease_id: "L1", epoch: 1, worker_id: "local", state: "released", end_reason: "succeeded",
             offered_at: "2026-11-08T12:00:00.000Z", ended_at: "2026-11-08T12:01:00.000Z"}' \
        > "$RS_C/runner/leases/$id.json"
    jq --arg u "https://github.com/test/rs/pull/7" \
        '.state = "succeeded" | .pr_url = (if .no_pr then null else $u end) | .exit_code = 0 | .final_result_at = "2026-11-08T12:01:00.000Z"' \
        "$RS_C/jobs/$id.json" > "$MOTHER_WORKER_ROOT/local/jobs/$id.json"
    ( _rs_export_root "$RS_C"; gh_mock_install; gh_mock_set_pr "https://github.com/test/rs/pull/7" OPEN "$br" ) >/dev/null 2>&1
}

_rs_finalize() {
    run --separate-stderr _rs_in_world "$RS_C" "$_LIB_DIR/coord_apply.sh" --finalize "$RS_C" "$1"
    echo "finalize $1: status=$status stdout=$output stderr=$stderr" >&2
}

@test "finalize: released/succeeded with the final commit on origin makes the canonical job succeeded" {
    local id="rs-fin-ok"
    _rs_fin_seed "$id" 1
    _rs_finalize "$id"
    [ "$status" -eq 0 ]
    [ "$(_rs_state "$RS_C" "$id")" = "succeeded" ]
    [ "$(jq -r '.failure_reason // "null"' "$RS_C/jobs/$id.json")" = "null" ]
    [ -n "$(jq -r '.finished_at // empty' "$RS_C/jobs/$id.json")" ]
}

@test "finalize: the final commit missing from origin fails the job unpushed_commit with an audit line, never succeeded" {
    local id="rs-fin-unpushed"
    _rs_fin_seed "$id" 0
    _rs_finalize "$id"
    # Handled either way (0), or reported as refused (3); never "nothing to do" (1) and never a crash.
    [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
    [ "$(_rs_state "$RS_C" "$id")" = "failed" ]
    [ "$(_rs_field "$RS_C" "$id" failure_reason)" = "unpushed_commit" ]
    [ "$(_rs_field "$RS_C" "$id" needs_attention.reason)" = "unpushed_commit" ]
    jq -e -s --arg j "$id" 'map(select(.job == $j)) | length >= 1' "$RS_C/runner/leases/audit.jsonl" >/dev/null
}

@test "finalize: a no_pr job with no pr_url is accepted without a remote check" {
    local id="rs-fin-nopr"
    _rs_fin_seed "$id" 0 '.no_pr = true'
    _rs_finalize "$id"
    [ "$status" -eq 0 ]
    [ "$(_rs_state "$RS_C" "$id")" = "succeeded" ]
}

@test "finalize: a job that is already terminal or has a cancel requested is left untouched (exit 1)" {
    local id before st
    for st in succeeded failed cancelled; do
        id="rs-fin-$st"
        _rs_fin_seed "$id" 1 ".state = \"$st\""
        before=$(jq -S . "$RS_C/jobs/$id.json")
        _rs_finalize "$id"
        [ "$status" -eq 1 ]
        [ "$(jq -S . "$RS_C/jobs/$id.json")" = "$before" ]
    done
    id="rs-fin-cancelreq"
    _rs_fin_seed "$id" 1 '.cancel_requested = true'
    before=$(jq -S . "$RS_C/jobs/$id.json")
    _rs_finalize "$id"
    [ "$status" -eq 1 ]
    [ "$(jq -S . "$RS_C/jobs/$id.json")" = "$before" ]
}
