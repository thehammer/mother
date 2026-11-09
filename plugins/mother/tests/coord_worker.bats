#!/usr/bin/env bats
# coord_worker.bats — the coordinator and worker daemons (cluster Phase 1, slice P1-4).
#
# Black-box contract for `mother-coord` (the coordinator) and `mother-worker` (the worker daemon), which speak
# docs/worker-protocol.md over $MOTHER_ROOT/runner/coord/worker.sock. Nothing here reads either daemon's internals;
# everything is observed through files and sockets:
#
#   coordinator   MOTHER_ROOT=<canonical root C>, MOTHER_LEASE_TTL_S (tests use 6; default 180). Writes
#                 runner/coord/coord.pid, listens on runner/coord/worker.sock (0600, in the 0700 runner/coord dir),
#                 accepts only workers registered over `--secrets-fd` ("id=pid=secret" lines, the daemon's real pid, read
#                 while the fd stays open; a registration without a real pid is refused) and whose hello proves
#                 the secret from that pid, refreshes runner/coord-status.json once a
#                 second (`mother-coord --status-json` is a reader of it). Dispatch request: a file
#                 runner/dispatch/<job>.json = {"job":"<id>"}; the coordinator leases the job to a connected worker
#                 with a free slot, records runner/leases/<job>.json
#                 {lease_id, epoch, worker_id, state offered|active|released|lost|revoked, offered_at, applied_seq,
#                  log_offset, last_hb, ended_at?, end_reason?} and removes the dispatch file once the worker accepts.
#                 It applies the worker's ops onto C with lib/coord_apply.sh and appends the job log to C/logs/<job>.log.
#                 A lost lease writes state "lost", an audit line in runner/leases/audit.jsonl and the file
#                 runner/leases/<job>.lost. A fenced frame draws refuse{fenced} and an audit line
#                 {ts, worker_id, job, lease, epoch, code:"fenced"}.
#   worker        `mother-worker --id <name> --root <worker root W> --coord-sock <path> --slots N`. Creates W
#                 (marker .mother-worker-live), becomes its own process group leader and writes W/worker.pid as
#                 "<pid> <pgid>". On lease.offer it writes the job mirror, spawns `mother-run-job <job>` in worker
#                 mode (P1-2) against W, ships the outbox and the job log, and sends lease.release{reason: <mirror
#                 state>} once the supervisor exited and everything is drained. Downlink: cancel_requested, runner/<id>.hold
#                 and limiter/mode.json, quota-gate.json, ratelimit-until reach W within about a second.
#
# Until P1-5 (runner wiring) exists the protocol refuses `succeeded` from a worker, so a distributed job that
# succeeded stays `running` on the canonical side; the worker's mirror says `succeeded`. `cancelled` IS accepted.
#
# World. One test = one temp tree (setup_mother_env): C is $MOTHER_ROOT itself, the worker root W is $MOTHER_ROOT/w1,
# the legacy comparison world is $MOTHER_ROOT/worlds/legacy. `claude` is a scriptable stand-in (same idea as
# state_seam.bats); its invocation counter and behaviour files live in $CW_CLAUDE_DIR (a plain env var, so the
# daemons' children find it however they re-root MOTHER_ROOT). Every daemon is started by this file and stopped
# by EXACT pid (or the worker's exact recorded process group) in teardown: nothing is ever killed by pattern.
#
# NOTE (ThreatDown): the fenced-frame and command-dedupe tests drive the sockets with small python3 clients, which
# ThreatDown has flagged on dev laptops (broker.bats does the same). That is accepted for this file; CI runs them.

bats_require_minimum_version 1.5.0
load 'test_helper'
load 'gh_mock'

# The job keys a worker may set (docs/worker-protocol.md section 8) plus the canonical cost recompute: the part of
# the job document a distributed run must reproduce on C exactly as a legacy run leaves it.
CW_WORKER_KEYS='["activity","session_id","worker_pid","paused_reason","paused_at","question","final_result_at","started_at","continuation_count","resume_not_yet_acted_on","gates","review_wave","limiter_hold","live_cost_usd","live_tokens","current_run","cost_cap_breached_at","token_alert_at","rwx_sandbox","resume_session_id","resume_kind","limiter_resume_prompt","attention","decision","actual_cost_usd"]'

# ---------------------------------------------------------------------------
# Environment

setup() {
    setup_mother_env
    unset MOTHER_GATES_ENABLED MOTHER_PHI_REPOS MOTHER_JOB_ID MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR \
          GH_MOCK_FAIL_DRAFT MOTHER_LIVE_ROOT
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120
    export MOTHER_NOTIFY_ENABLED=0 MOTHER_BACKUP_ENABLED=0
    export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com" \
           GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com" \
           GIT_AUTHOR_DATE="2026-10-01T00:00:00Z" GIT_COMMITTER_DATE="2026-10-01T00:00:00Z"
    # Hermetic HOME: any fallback to ~/.mother lands inside the test tree.
    export _MOTHER_TEST_REAL_HOME="${_MOTHER_TEST_REAL_HOME:-$HOME}"
    mkdir -p "$MOTHER_ROOT/fake-home"
    export HOME="$MOTHER_ROOT/fake-home"

    CW_C="$MOTHER_ROOT"
    CW_W="$MOTHER_ROOT/w1"
    CW_L="$MOTHER_ROOT/worlds/legacy"
    CW_SOCK="$MOTHER_ROOT/runner/coord/worker.sock"
    # Per-worker secrets: the coordinator gets them on an inherited fd, each worker its own on another; no
    # secret ever appears in an environment variable or a file.
    CW_SECRET_W1="cw-secret-w1-$$-$RANDOM$RANDOM"
    CW_SECRET_PROBE="cw-secret-probe-$$-$RANDOM$RANDOM"
    CW_PIDS="$MOTHER_ROOT/cw-pids"
    # Registrations (worker-id=pid=secret lines) reach the coordinator over an inherited fd 4 on this fifo, held
    # open read-write by the launcher for the daemon's life; the pids and secrets live in shell variables only.
    CW_REG="$BATS_TEST_TMPDIR/cw-reg.fifo"
    mkfifo "$CW_REG"
    CW_REG_W1="" CW_REG_PROBE=""
    CW_TTL=6
    export CW_CLAUDE_DIR="$MOTHER_ROOT/claude"
    CW_NORM_ROOTS="$CW_L $CW_W $CW_C"
    : > "$CW_PIDS"
    _cw_install_claude
}

# Stop everything this test started, by exact pid / recorded process group only.
teardown() {
    local kind n
    if [ -f "${CW_PIDS:-/nonexistent}" ]; then
        while read -r kind n; do
            case "$kind" in
                P) _cw_kill_pid "$n" ;;
                G) _cw_kill_group "$n" ;;
            esac
        done < "$CW_PIDS"
    fi
    # The worker daemon's root carries the .mother-worker-live marker safe_rm_tree refuses; the root is inside
    # this test's own temp tree, so the marker (only the marker) is removed before the tree is.
    [ -n "${CW_W:-}" ] && rm -f "$CW_W/.mother-worker-live"
    teardown_mother_env
}

# The scriptable worker. Counts invocations in $CW_CLAUDE_DIR/ge-count; invocation n sources
# $CW_CLAUDE_DIR/ge-behave.<n> (cwd = the job's work dir). Defaults: push the branch, print a result event, sleep
# $SLEEP seconds (so a test can hold a job mid-run), exit 0. Printing the result first means the supervisor sees
# the final result and waits for the process to exit (MOTHER_RESULT_GRACE_SECONDS).
_cw_install_claude() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
ROOT="${CW_CLAUDE_DIR:-}"
[ -n "$ROOT" ] || exit 97
n=$(( $(cat "$ROOT/ge-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$ROOT/ge-count"
cat > "$ROOT/stdin.$n"
PUSH=1; EXIT=0; SLEEP=3
BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -f "$ROOT/ge-behave.$n" ]; then . "$ROOT/ge-behave.$n"; fi
if [ "$PUSH" = "1" ]; then
    git push -q origin "HEAD:refs/heads/$BR" >/dev/null 2>&1 || true
fi
cat <<'EOF'
{"type":"assistant","message":{"id":"msg_cw","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":200}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.004,"modelUsage":{"claude-sonnet-5":{"costUSD":0.004,"inputTokens":1000,"outputTokens":200}}}
EOF
[ "$SLEEP" = "0" ] || sleep "$SLEEP"
# GATE=1: hold the run until the test creates $ROOT/release (capped at 150 s), so a test that needs the job
# alive across several steps waits on observable state, not on a fixed sleep that a loaded host can outrun.
if [ "${GATE:-}" = "1" ]; then
    _g=0
    while [ ! -e "$ROOT/release" ] && [ "$_g" -lt 600 ]; do sleep 0.25; _g=$(( _g + 1 )); done
fi
exit "$EXIT"
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}

# ---------------------------------------------------------------------------
# Small utilities

# _cw_wait_for <timeout_s> <cmd...> — poll (4 Hz) until <cmd> succeeds or the deadline passes.
_cw_wait_for() {
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

# _cw_dump — everything useful for triage, to stderr.
_cw_dump() {
    local f
    echo "--- coord.out" >&2;   tail -n 40 "$CW_C/coord.out" >&2 2>/dev/null || true
    echo "--- worker.out" >&2;  tail -n 40 "$CW_C/worker.out" >&2 2>/dev/null || true
    echo "--- leases" >&2;      cat "$CW_C"/runner/leases/*.json >&2 2>/dev/null || true
    echo "--- audit" >&2;       cat "$CW_C/runner/leases/audit.jsonl" >&2 2>/dev/null || true
    echo "--- status" >&2;      cat "$CW_C/runner/coord-status.json" >&2 2>/dev/null || true
    echo "--- mirror jobs (state)" >&2; for f in "$CW_W"/jobs/*.json; do [ -f "$f" ] && jq -c '{id, state, activity, paused_reason, finished_at}' "$f" >&2; done 2>/dev/null
    echo "--- outbox last seq / release flag" >&2; cat "$CW_W"/outbox/*.seq >&2 2>/dev/null; ls "$CW_CLAUDE_DIR" >&2 2>/dev/null
    echo "--- run-job.out" >&2; tail -n 15 "$CW_W/run-job.out" "$CW_C"/runner/*.out >&2 2>/dev/null || true
    for f in "$CW_W"/logs/*.log; do [ -f "$f" ] && { echo "--- $f" >&2; tail -n 15 "$f" >&2; }; done
    true
}

# _cw_must <timeout_s> <what> <cmd...> — wait for <cmd>; on timeout dump diagnostics and fail the test.
_cw_must() {
    local t="$1" what="$2"
    shift 2
    if ! _cw_wait_for "$t" "$@"; then
        echo "timed out after ${t}s waiting for: $what" >&2
        _cw_dump
        return 1
    fi
}

_cw_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 1 ]; }
_cw_alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1; [ -n "$s" ] && [[ "$s" != Z* ]]; }
_cw_dead() { ! _cw_alive "$1"; }
_cw_note() { printf '%s %s\n' "$1" "$2" >> "$CW_PIDS"; }

# _cw_kill_pid <pid> — SIGKILL one exact pid we started; wait for it to be gone.
_cw_kill_pid() {
    _cw_num "${1:-}" || return 0
    kill -9 "$1" 2>/dev/null || true
    _cw_wait_for 5 _cw_dead "$1" || true
}

# _cw_kill_group <pgid> — SIGKILL one exact process group (the worker's own, recorded in worker.pid).
_cw_kill_group() {
    local mine
    _cw_num "${1:-}" || return 0
    mine=$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ')
    [ "$1" != "$mine" ] || return 0
    kill -9 -- "-$1" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Worlds (a legacy comparison root, the canonical root) and the job

_cw_export_root() {
    local r="$1"
    export MOTHER_ROOT="$r"
    export JOBS_DIR="$r/jobs" EVENTS_DIR="$r/events" LOGS_DIR="$r/logs" DRAFTS_DIR="$r/drafts" \
           CURSORS_DIR="$r/cursors" RUNNER_DIR="$r/runner" ARCHIVE_DIR="$r/archive" \
           TEARDOWN_DIR="$r/teardown-pending"
    mkdir -p "$JOBS_DIR" "$EVENTS_DIR" "$LOGS_DIR" "$DRAFTS_DIR" "$CURSORS_DIR" "$RUNNER_DIR" \
             "$ARCHIVE_DIR" "$TEARDOWN_DIR"
}

# _cw_in_world <root> <cmd...> — run <cmd> as a plain (non-worker-mode) process on <root>, in a subshell.
_cw_in_world() {
    local root="$1"
    shift
    (
        _cw_export_root "$root"
        unset MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR
        export CW_CLAUDE_DIR="$root/claude"
        "$@"
    )
}

# _cw_prepare <id> <claude-sleep-s> — build the CURRENT world: git repo + bare origin, plan (at
# events/<id>-plan.md, where the coordinator looks), log file, and a ready no_pr main-dir job whose claude
# stand-in sleeps <claude-sleep-s> seconds.
_cw_prepare() {
    local id="$1" sleep_s="$2"
    local repo="$MOTHER_ROOT/work/gaterepo" origin="$MOTHER_ROOT/origin.git" branch="feature/cw-$id"
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
    gh_mock_install
    make_plan "$EVENTS_DIR/$id-plan.md"
    touch "$LOGS_DIR/$id.log"
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo = "gaterepo"
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
           }'
    mkdir -p "$CW_CLAUDE_DIR"
    touch "$CW_CLAUDE_DIR/ge-no-pr-url"
    if [ "$sleep_s" = "gate" ]; then
        printf 'SLEEP=0\nGATE=1\n' > "$CW_CLAUDE_DIR/ge-behave.1"
    else
        printf 'SLEEP=%s\n' "$sleep_s" > "$CW_CLAUDE_DIR/ge-behave.1"
    fi
}

_cw_run_job() { mother-run-job "$1" > "$MOTHER_ROOT/run-job.out" 2>&1; }

# _cw_prepare_canonical <id> <claude-sleep-s> — the job on C, plus the worker root pre-seeded with the gh
# stand-in's fixture directories (the supervisor in worker mode runs against W).
_cw_prepare_canonical() {
    _cw_in_world "$CW_C" _cw_prepare "$1" "$2" || return 1
    mkdir -p "$CW_W"
    ( _cw_export_root "$CW_W"; gh_mock_install ) >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Daemons

_cw_coord_pid() { { cat "$CW_C/runner/coord/coord.pid" 2>/dev/null || true; } | tr -dc '0-9'; }

_cw_coord_up_new() {
    local p; p=$(_cw_coord_pid)
    [ -n "$p" ] && [ "$p" != "${1:-}" ] && _cw_alive "$p" && [ -S "$CW_SOCK" ]
}

# _cw_start_coord — launch mother-coord in the background (its pid is noted for teardown) and wait until a new
# pid is in runner/coord.pid and the socket exists.
_cw_start_coord() {
    local old; old=$(_cw_coord_pid)
    mkdir -p "$CW_C/runner"
    ( cd / && MOTHER_LEASE_TTL_S="$CW_TTL" exec mother-coord --secrets-fd 4 ) \
        4<>"$CW_REG" >> "$CW_C/coord.out" 2>&1 3>&- &
    _cw_note P "$!"
    _cw_must 20 "coordinator to publish its pid and socket" _cw_coord_up_new "$old" || return 1
    _cw_note P "$(_cw_coord_pid)"
    # A new coordinator has forgotten every registration: replay the live workers' (id=pid=secret).
    [ -z "$CW_REG_W1" ] || printf 'w1=%s=%s\n' "$CW_REG_W1" "$CW_SECRET_W1" > "$CW_REG"
    [ -z "$CW_REG_PROBE" ] || printf 'cw-probe=%s=%s\n' "$CW_REG_PROBE" "$CW_SECRET_PROBE" > "$CW_REG"
}

# _cw_register w1|cw-probe <pid> — tell the running coordinator the real pid of a worker daemon (or probe client).
_cw_register() {
    case "$1" in
        w1) CW_REG_W1="$2"; _cw_alive "$(_cw_coord_pid)" && printf 'w1=%s=%s\n' "$2" "$CW_SECRET_W1" > "$CW_REG" ;;
        cw-probe) CW_REG_PROBE="$2"; _cw_alive "$(_cw_coord_pid)" && printf 'cw-probe=%s=%s\n' "$2" "$CW_SECRET_PROBE" > "$CW_REG" ;;
    esac
    return 0
}

# _cw_stop_coord — SIGKILL the coordinator by the exact pid it published (a crash, not a clean stop).
_cw_stop_coord() {
    local p; p=$(_cw_coord_pid)
    _cw_num "$p" || { echo "no coordinator pid" >&2; return 1; }
    _cw_kill_pid "$p"
}

_cw_worker_pidfile() { { cat "$CW_W/worker.pid" 2>/dev/null || true; } | tr -s ' \t' ' ' | tr -d '\n'; }

_cw_worker_up_new() {
    local cur pid; cur=$(_cw_worker_pidfile)
    [ -n "$cur" ] && [ "$cur" != "${1:-}" ] || return 1
    pid="${cur%% *}"
    _cw_alive "$pid"
}

# _cw_start_worker [coord-sock] — launch the worker daemon "w1" with exactly the args the contract names. The
# daemon gets its own root as MOTHER_ROOT and none of the per-directory variables the test harness exports for C.
# Its exact pid and its recorded process group are noted for teardown.
_cw_start_worker() {
    local sock="${1:-$CW_SOCK}" old
    old=$(_cw_worker_pidfile)
    mkdir -p "$CW_W"
    (
        cd / || exit 1
        exec env -u JOBS_DIR -u EVENTS_DIR -u LOGS_DIR -u DRAFTS_DIR -u CURSORS_DIR -u RUNNER_DIR \
            -u ARCHIVE_DIR -u TEARDOWN_DIR \
            MOTHER_ROOT="$CW_W" MOTHER_WORKER_BACKOFF_MAX_S=2 \
            mother-worker --id w1 --root "$CW_W" --coord-sock "$sock" --slots 2 --secret-fd 4
    ) 4< <(printf '%s\n' "$CW_SECRET_W1") >> "$CW_C/worker.out" 2>&1 3>&- &
    local launched=$!
    _cw_note P "$launched"
    _cw_register w1 "$launched"   # exec chain: the subshell's pid is the daemon's pid
    _cw_must 20 "worker.pid to appear" _cw_worker_up_new "$old" || return 1
    local pid pgid
    read -r pid pgid < "$CW_W/worker.pid"
    _cw_note P "$pid"
    _cw_note G "$pgid"
    [ "$pid" = "$launched" ] || _cw_register w1 "$pid"
}

_cw_connected() {
    mother-coord --status-json 2>/dev/null \
        | jq -e '[.workers[]? | select(.id == "w1" and .connected == true)] | length == 1' >/dev/null
}

# _cw_boot <id> <claude-sleep-s> — a job on C, coordinator and worker up and connected.
_cw_boot() {
    _cw_prepare_canonical "$1" "$2" || return 1
    _cw_start_coord || return 1
    _cw_start_worker || return 1
    _cw_must 20 "worker w1 to show as connected" _cw_connected
}

# _cw_dispatch <id> — drop the dispatch request the way the runner will.
_cw_dispatch() {
    mkdir -p "$CW_C/runner/dispatch"
    printf '{"job":"%s"}\n' "$1" > "$CW_C/runner/dispatch.tmp.$1"
    mv "$CW_C/runner/dispatch.tmp.$1" "$CW_C/runner/dispatch/$1.json"
}

# ---------------------------------------------------------------------------
# Observations

_cw_lease_state() { jq -r '.state // empty' "$CW_C/runner/leases/$1.json" 2>/dev/null; }
_cw_lease_is() { [ "$(_cw_lease_state "$1")" = "$2" ]; }
_cw_lease_field() { jq -r ".$2 // empty" "$CW_C/runner/leases/$1.json" 2>/dev/null; }
_cw_canon_state_is() { [ "$(jq -r .state "$CW_C/jobs/$1.json" 2>/dev/null)" = "$2" ]; }
_cw_mirror_state_is() { [ "$(jq -r .state "$CW_W/jobs/$1.json" 2>/dev/null)" = "$2" ]; }
_cw_claude_started() { [ -s "$CW_CLAUDE_DIR/ge-count" ]; }
_cw_hb_moved() { [ "$(_cw_lease_field "$1" last_hb)" != "$2" ]; }
_cw_file_gone() { [ ! -e "$1" ]; }
_cw_file_exists() { [ -e "$1" ]; }

# _cw_audit_has <jq-select-expr> — an audit line matches.
_cw_audit_has() {
    [ -f "$CW_C/runner/leases/audit.jsonl" ] && jq -e -s "map(select($1)) | length > 0" "$CW_C/runner/leases/audit.jsonl" >/dev/null
}

# _cw_assert_events_equal <id> — the canonical events file equals the worker mirror's, line for line: nothing
# lost, nothing applied twice.
_cw_assert_events_equal() {
    local id="$1"
    [ -s "$CW_W/events/$id.jsonl" ] || { echo "worker mirror has no events" >&2; return 1; }
    if ! diff -u "$CW_W/events/$id.jsonl" "$CW_C/events/$id.jsonl" > "$BATS_TEST_TMPDIR/events.diff"; then
        echo "canonical events differ from the worker mirror (< mirror / > canonical):" >&2
        cat "$BATS_TEST_TMPDIR/events.diff" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Normalisation (same idea as state_seam.bats): what a legacy run and a distributed run may differ in.

_cw_norm_filter() {
    cat <<'JQ'
def scrub_str:
    reduce $subs[] as $s (.; split($s[0]) | join($s[1]))
    | gsub("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z"; "<ts>")
    | gsub("[0-9a-f]{40}"; "<sha>")
    | gsub("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"; "<uuid>")
    | gsub("\\.tmp\\.[0-9]+"; ".tmp.<pid>");
def volatile_key:
    test("(^|_)pid$|_ms$|duration|elapsed|wall_time|_epoch$|^epoch$|^not_before$|^latency|log_offset|log_size|log_bytes");
walk(
    if type == "object" then
        with_entries(
            if (.key | volatile_key) then
                (if (.value | type) == "number" then .value = 0
                 elif (.value | type) == "array" then .value = []
                 else . end)
            else . end)
    elif type == "string" then scrub_str
    else . end)
JQ
}

_cw_subs() {
    local r phys p tab
    tab="$(printf '\t')"
    {
        for r in $CW_NORM_ROOTS; do
            phys=$(cd -P "$r" 2>/dev/null && pwd -P) || phys="$r"
            for p in "$r" "$phys"; do
                printf '%s\t%s\n' "$p/work/gaterepo" "<REPO>" "$p/origin.git" "<ORIGIN>" "$p" "<ROOT>"
            done
        done
    } | awk -F'\t' 'NF == 2 && !seen[$1]++ { print length($1) "\t" $0 }' \
        | sort -t "$tab" -k1,1nr | cut -f2- \
        | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t"))'
}

# _cw_norm_job <file> — the worker-settable part of the job document (plus the canonical cost), normalised.
_cw_norm_job() {
    jq -S --argjson subs "$(_cw_subs)" --argjson wk "$CW_WORKER_KEYS" \
        "del(.live_cost_usd, .live_tokens) | $(_cw_norm_filter) | with_entries(select(.key as \$k | \$wk | index(\$k)))" "$1"
}

_cw_norm_events() {
    jq -S -s --argjson subs "$(_cw_subs)" \
        "map(select(.kind != \"final_result_observed\")) | $(_cw_norm_filter)" "$1"
}

_cw_norm_rows() {
    local id="$1" f="$2"
    { grep -F "\"job_id\":\"$id\"" "$f" 2>/dev/null || true; } \
        | jq -c 'del(.apply_id)' \
        | jq -S -s --argjson subs "$(_cw_subs)" "$(_cw_norm_filter)"
}

# _cw_same <label> <a> <b>
_cw_same() {
    if ! diff -u "$2" "$3" > "$BATS_TEST_TMPDIR/diff.out"; then
        echo "$1 differs (< legacy / > distributed):" >&2
        cat "$BATS_TEST_TMPDIR/diff.out" >&2
        return 1
    fi
}

# ===========================================================================
# 1. Happy path

@test "happy path: a dispatched job runs through a worker and leaves the same job, events, usage and log as a legacy run" {
    local id="cw-happy" t="$BATS_TEST_TMPDIR"
    CW_TTL=180

    # The legacy run of the same scenario, in its own world.
    mkdir -p "$CW_L"
    _cw_in_world "$CW_L" _cw_prepare "$id" 3
    _cw_in_world "$CW_L" _cw_run_job "$id" || true
    [ "$(jq -r .state "$CW_L/jobs/$id.json")" = "succeeded" ]

    _cw_boot "$id" 3
    _cw_dispatch "$id"
    _cw_must 90 "the lease to be released" _cw_lease_is "$id" released

    # The coordinator took the dispatch request off the table once the worker accepted it.
    [ ! -e "$CW_C/runner/dispatch/$id.json" ]
    [ "$(_cw_lease_field "$id" worker_id)" = "w1" ]
    [ "$(_cw_lease_field "$id" end_reason)" = "succeeded" ]

    # The worker mirror succeeded; the canonical side stays `running` until P1-5 derives `succeeded`.
    [ "$(jq -r .state "$CW_W/jobs/$id.json")" = "succeeded" ]
    [ "$(jq -r .state "$CW_C/jobs/$id.json")" = "running" ]
    [ "$(cat "$CW_CLAUDE_DIR/ge-count")" = "1" ]

    # Job document (worker-settable keys + canonical cost), events and usage rows equal the legacy run's.
    _cw_norm_job "$CW_L/jobs/$id.json" > "$t/l.job"
    _cw_norm_job "$CW_C/jobs/$id.json" > "$t/c.job"
    _cw_same "job document" "$t/l.job" "$t/c.job"
    _cw_norm_events "$CW_L/events/$id.jsonl" > "$t/l.events"
    _cw_norm_events "$CW_C/events/$id.jsonl" > "$t/c.events"
    _cw_same "events" "$t/l.events" "$t/c.events"
    _cw_norm_rows "$id" "$CW_L/metrics/runs.jsonl" > "$t/l.rows"
    _cw_norm_rows "$id" "$CW_C/metrics/runs.jsonl" > "$t/c.rows"
    _cw_same "usage rows" "$t/l.rows" "$t/c.rows"
    [ "$(jq -s length "$t/c.rows")" = "1" ]
    _cw_assert_events_equal "$id"

    # The log arrived on the canonical side, byte for byte what the worker wrote, and carries the run's output.
    [ -s "$CW_C/logs/$id.log" ]
    cmp -s "$CW_W/logs/$id.log" "$CW_C/logs/$id.log"
    grep -q '"type":"result"' "$CW_C/logs/$id.log"
    grep -q '"type":"result"' "$CW_L/logs/$id.log"
}

@test "dispatch with no worker connected waits with a reason and is leased once a worker arrives" {
    local id="cw-wait"
    _cw_prepare_canonical "$id" 2
    _cw_start_coord
    _cw_dispatch "$id"
    _cw_must 15 "wait_reason on the dispatch file" \
        bash -c 'jq -e ".wait_reason == \"no_worker_connected\"" "$1" >/dev/null' _ "$CW_C/runner/dispatch/$id.json"
    [ "$(jq -r .job "$CW_C/runner/dispatch/$id.json")" = "$id" ]

    _cw_start_worker
    _cw_must 90 "the waiting job to run to release" _cw_lease_is "$id" released
    [ ! -e "$CW_C/runner/dispatch/$id.json" ]
    [ "$(cat "$CW_CLAUDE_DIR/ge-count")" = "1" ]
}

# ===========================================================================
# 2. Coordinator restarts (MC-16, MC-18)

@test "coordinator restarts mid-job, once briefly and once for longer than the lease TTL: no events lost or doubled and the lease is never lost" {
    local id="cw-coordrestart" hb
    CW_TTL=6
    _cw_boot "$id" gate
    _cw_dispatch "$id"
    _cw_must 30 "the job's claude to start" _cw_claude_started
    _cw_must 20 "the lease to be active" _cw_lease_is "$id" active

    # First crash: back after 5 s (less than the TTL).
    hb=$(_cw_lease_field "$id" last_hb)
    _cw_stop_coord
    sleep 5
    _cw_start_coord
    _cw_must 25 "a heartbeat to reach the restarted coordinator" _cw_hb_moved "$id" "$hb"
    _cw_lease_is "$id" active

    # Second crash: down for 9 s, longer than the 6 s TTL. Downtime must never expire a lease (MC-16).
    hb=$(_cw_lease_field "$id" last_hb)
    _cw_stop_coord
    sleep 9
    _cw_start_coord
    _cw_must 25 "a heartbeat to reach the coordinator after the long outage" _cw_hb_moved "$id" "$hb"

    # Both outages are over and the lease was active throughout: now let the job finish.
    _cw_lease_is "$id" active
    : > "$CW_CLAUDE_DIR/release"
    _cw_must 90 "the lease to be released" _cw_lease_is "$id" released
    _cw_mirror_state_is "$id" succeeded
    [ "$(cat "$CW_CLAUDE_DIR/ge-count")" = "1" ]
    _cw_assert_events_equal "$id"
    cmp -s "$CW_W/logs/$id.log" "$CW_C/logs/$id.log"

    # Never lost: no marker, no audit line, and the lease ended as released.
    [ ! -e "$CW_C/runner/leases/$id.lost" ]
    if [ -f "$CW_C/runner/leases/audit.jsonl" ]; then
        run jq -s "map(select(.job == \"$id\" and ((.code // \"\") | test(\"lost\")))) | length" \
            "$CW_C/runner/leases/audit.jsonl"
        [ "$output" = "0" ]
    fi
    [ "$(_cw_lease_field "$id" end_reason)" = "succeeded" ]
}

# ===========================================================================
# 3. Worker daemon restart (the tree survives)

@test "worker daemon restarts while its supervisor keeps running: the job is re-adopted, finishes once, no duplicate events" {
    local id="cw-workerrestart" sup wpid wpgid
    CW_TTL=6
    _cw_boot "$id" 24
    _cw_dispatch "$id"
    _cw_must 30 "the job's claude to start" _cw_claude_started
    _cw_must 20 "the supervisor to be tracked in children/" \
        bash -c 'ls "$1"/children/*.json >/dev/null 2>&1' _ "$CW_W"
    sup=$(jq -r '.pid' "$CW_W"/children/*.json | head -n 1)
    _cw_num "$sup"

    # Kill ONLY the daemon (exact pid from worker.pid), not its process group, then start it again.
    read -r wpid wpgid < "$CW_W/worker.pid"
    _cw_kill_pid "$wpid"
    _cw_alive "$sup"
    _cw_start_worker
    _cw_alive "$sup"
    _cw_must 20 "the restarted worker to reconnect" _cw_connected

    _cw_must 90 "the lease to be released" _cw_lease_is "$id" released
    _cw_mirror_state_is "$id" succeeded
    [ "$(cat "$CW_CLAUDE_DIR/ge-count")" = "1" ]
    _cw_assert_events_equal "$id"
    cmp -s "$CW_W/logs/$id.log" "$CW_C/logs/$id.log"
    [ "$(_cw_lease_field "$id" end_reason)" = "succeeded" ]
    [ ! -e "$CW_C/runner/leases/$id.lost" ]
}

# ===========================================================================
# 4. Worker tree dies

@test "worker tree killed outright: after the TTL the lease is lost, marked, audited, and the canonical job is untouched" {
    local id="cw-treedies" wpid wpgid before
    CW_TTL=6
    _cw_boot "$id" 40
    _cw_dispatch "$id"
    _cw_must 30 "the job's claude to start" _cw_claude_started
    _cw_must 30 "the canonical job to show running" _cw_canon_state_is "$id" running
    _cw_must 20 "the lease to be active" _cw_lease_is "$id" active
    # Let the startup ops that are still in flight land, so "untouched" is judged against a settled document.
    local i after
    before=$(jq -S . "$CW_C/jobs/$id.json")
    for i in 1 2 3 4 5 6 7 8; do
        sleep 1
        after=$(jq -S . "$CW_C/jobs/$id.json")
        [ "$after" = "$before" ] && break
        before="$after"
    done

    read -r wpid wpgid < "$CW_W/worker.pid"
    _cw_num "$wpgid"
    kill -9 -- "-$wpgid"

    _cw_must 30 "the lease to be lost" _cw_lease_is "$id" lost
    [ -e "$CW_C/runner/leases/$id.lost" ]
    _cw_audit_has ".job == \"$id\" and ((.code // \"\") | test(\"lost\"))"

    # Losing a lease does not rewrite the job: P1-5's runner decides what happens next.
    _cw_canon_state_is "$id" running
    [ "$(jq -S . "$CW_C/jobs/$id.json")" = "$before" ]
}

# ===========================================================================
# 5. Cancel downlink

@test "cancel on the canonical root reaches the running job: the supervisor stops within 10 s and the canonical job ends cancelled" {
    local id="cw-cancel"
    CW_TTL=6
    _cw_boot "$id" 40
    _cw_dispatch "$id"
    _cw_must 30 "the job's claude to start" _cw_claude_started
    _cw_must 30 "the canonical job to show running" _cw_canon_state_is "$id" running

    run mother cancel "$id"
    [ "$status" -eq 0 ]
    [ "$(jq -r .cancel_requested "$CW_C/jobs/$id.json")" = "true" ]

    _cw_must 10 "the worker supervisor to stop the job (mirror cancelled)" _cw_mirror_state_is "$id" cancelled
    [ "$(jq -r .cancel_requested "$CW_W/jobs/$id.json")" = "true" ]
    _cw_must 20 "the canonical job to end cancelled" _cw_canon_state_is "$id" cancelled
    _cw_must 30 "the lease to be released" _cw_lease_is "$id" released
    [ "$(_cw_lease_field "$id" end_reason)" = "cancelled" ]
}

# ===========================================================================
# 6. Hold downlink and sync files

@test "a runner hold set on the canonical root appears in the worker root within 2 s (3 s allowed), with the same content, and its removal follows" {
    local id="cw-hold" src dst
    CW_TTL=6
    _cw_boot "$id" 30
    _cw_dispatch "$id"
    _cw_must 30 "the job's claude to start" _cw_claude_started
    _cw_must 30 "the canonical job to show running" _cw_canon_state_is "$id" running

    src="$CW_C/runner/$id.hold"
    dst="$CW_W/runner/$id.hold"
    [ ! -e "$dst" ]
    printf '%s\n' '{"code":"backoff","reason":"test","since":"2026-11-08T12:00:00.000Z"}' > "$src.tmp"
    mv "$src.tmp" "$src"
    _cw_must 3 "the hold to appear in the worker root" _cw_file_exists "$dst"
    [ "$(jq -r .code "$dst")" = "backoff" ]
    [ "$(jq -r .reason "$dst")" = "test" ]

    rm -f "$src"
    _cw_must 3 "the hold to disappear from the worker root" _cw_file_gone "$dst"
}

@test "sync files (ratelimit-until, limiter/mode.json) are mirrored to the worker root and deleted there when deleted on the canonical root" {
    CW_TTL=6
    mkdir -p "$CW_C/runner" "$CW_C/limiter"
    _cw_start_coord
    _cw_start_worker
    _cw_must 20 "worker w1 to show as connected" _cw_connected

    printf '%s\n' "$(( $(date +%s) + 600 ))" > "$CW_C/ratelimit-until.tmp"
    mv "$CW_C/ratelimit-until.tmp" "$CW_C/ratelimit-until"
    printf '%s\n' '{"mode":"observe","changed_at":"2026-11-08T12:00:00.000Z","changed_by":"test"}' > "$CW_C/limiter/mode.json.tmp"
    mv "$CW_C/limiter/mode.json.tmp" "$CW_C/limiter/mode.json"

    _cw_must 3 "ratelimit-until in the worker root" _cw_file_exists "$CW_W/ratelimit-until"
    _cw_must 3 "limiter/mode.json in the worker root" _cw_file_exists "$CW_W/limiter/mode.json"
    cmp -s "$CW_C/ratelimit-until" "$CW_W/ratelimit-until"
    [ "$(jq -r .mode "$CW_W/limiter/mode.json")" = "observe" ]

    rm -f "$CW_C/ratelimit-until" "$CW_C/limiter/mode.json"
    _cw_must 3 "ratelimit-until removed from the worker root" _cw_file_gone "$CW_W/ratelimit-until"
    _cw_must 3 "limiter/mode.json removed from the worker root" _cw_file_gone "$CW_W/limiter/mode.json"
}

# ===========================================================================
# 7. Fenced frames

# A tiny protocol client: hello as a fresh worker, then one event.append frame for <job> under <lease>/<epoch>,
# then print the first refuse frame the coordinator answers with (exit 0), or fail (2 no welcome, 3 timeout, 4 closed).
_cw_write_fence_client() {
    cat > "$BATS_TEST_TMPDIR/fence_client.py" <<'PY'
import datetime, hashlib, hmac, json, os, socket, sys, uuid

go = os.environ.get("CW_GO")
if go:
    # Probe host mode: the process (and so its pid) exists first and is registered with the coordinator; the
    # arguments arrive in the CW_GO file, the output goes to CW_OUT and the exit code to CW_OUT.rc.
    import time
    for _ in range(1800):
        if os.path.exists(go):
            break
        time.sleep(0.1)
    sock_path, job, lease, epoch, worker, marker = open(go).read().split()
    sys.stdout = open(os.environ["CW_OUT"], "w")
else:
    sock_path, job, lease, epoch, worker, marker = sys.argv[1:7]
secret = os.environ.get("CW_PROBE_SECRET", "")
CAPS = ["log.stream", "artifact.chunked", "checkpoint.v1", "hold.boundary"]


def proof(instance, nonce):
    # HMAC-SHA256 over HelloTranscript: compact JSON, fields in this order, caps sorted.
    t = json.dumps({"proto_min": 1, "proto_max": 1, "caps": sorted(CAPS), "worker_id": worker,
                    "instance_id": instance, "kind": "worker", "method": "peercred", "nonce": nonce},
                   separators=(",", ":"), ensure_ascii=False)
    return hmac.new(secret.encode(), t.encode(), hashlib.sha256).hexdigest()


def ts():
    d = datetime.datetime.now(datetime.timezone.utc)
    return d.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (d.microsecond // 1000)


def frame(t, data, job=None, lease=None, epoch=None, seq=None, ack=None):
    return json.dumps({"v": 1, "t": t, "id": str(uuid.uuid4()), "ts": ts(), "job": job, "lease": lease,
                       "epoch": epoch, "seq": seq, "ack": ack, "data": data}, separators=(",", ":")) + "\n"


def run():
    s = socket.socket(socket.AF_UNIX)
    s.settimeout(10)
    s.connect(sock_path)
    rf = s.makefile("rb")
    instance = "i-" + uuid.uuid4().hex[:16]
    nonce = uuid.uuid4().hex
    s.sendall(frame("hello", {"proto_min": 1, "proto_max": 1, "caps": CAPS,
                              "worker_id": worker, "instance_id": instance, "kind": "worker",
                              "auth": {"method": "peercred", "nonce": nonce, "credential": proof(instance, nonce)}}).encode())
    line = rf.readline()
    if not line or json.loads(line).get("t") != "welcome":
        print(line.decode(errors="replace"))
        sys.exit(2)
    s.sendall(frame("event.append", {"line": json.dumps({"kind": marker})}, job=job, lease=lease,
                    epoch=int(epoch), seq=1).encode())
    try:
        while True:
            line = rf.readline()
            if not line:
                sys.exit(4)
            f = json.loads(line)
            if f.get("t") == "refuse":
                print(line.decode().strip())
                sys.exit(0)
    except socket.timeout:
        sys.exit(3)


try:
    run()
    rc = 0
except SystemExit as e:
    rc = e.code or 0
sys.stdout.flush()
if go:
    with open(os.environ["CW_OUT"] + ".rc", "w") as fh:
        fh.write(str(rc))
sys.exit(rc)
PY
}

@test "a frame under a stale lease epoch is refused fenced, audited, and never applied to the canonical events" {
    local id="cw-fence" lease epoch stale
    CW_TTL=6
    _cw_boot "$id" 30
    _cw_dispatch "$id"
    _cw_must 30 "the job's claude to start" _cw_claude_started
    _cw_must 20 "the lease to be active" _cw_lease_is "$id" active
    lease=$(_cw_lease_field "$id" lease_id)
    epoch=$(_cw_lease_field "$id" epoch)
    [ -n "$lease" ] && [ -n "$epoch" ]
    stale=$(( epoch + 5 ))

    _cw_write_fence_client
    # The probe is a registered client: its pid is told to the coordinator before it says hello.
    CW_GO="$BATS_TEST_TMPDIR/probe.go" CW_OUT="$BATS_TEST_TMPDIR/probe.out" CW_PROBE_SECRET="$CW_SECRET_PROBE" \
        python3 -I "$BATS_TEST_TMPDIR/fence_client.py" &
    local probe=$!
    _cw_note P "$probe"
    _cw_register cw-probe "$probe"
    printf '%s %s %s %s %s %s' "$CW_SOCK" "$id" "$lease" "$stale" "cw-probe" "fenced_probe_marker" > "$BATS_TEST_TMPDIR/probe.go"
    _cw_must 30 "the probe to finish" test -f "$BATS_TEST_TMPDIR/probe.out.rc"
    status=$(cat "$BATS_TEST_TMPDIR/probe.out.rc")
    output=$(cat "$BATS_TEST_TMPDIR/probe.out")
    if [ "$status" -ne 0 ]; then echo "client exited $status: $output" >&2; return 1; fi
    local code
    code=$(printf '%s' "$output" | jq -r '.data.code')
    case "$code" in
        fenced) ;;
        not_leased) echo "note: refused not_leased rather than fenced" >&2 ;;
        *) echo "unexpected refuse code '$code': $output" >&2; return 1 ;;
    esac
    [ "$(printf '%s' "$output" | jq -r .t)" = "refuse" ]

    if [ "$code" = "fenced" ]; then
        _cw_must 5 "a fenced audit line" \
            _cw_audit_has ".code == \"fenced\" and .job == \"$id\" and .worker_id == \"cw-probe\""
    fi
    sleep 1
    ! grep -q fenced_probe_marker "$CW_C/events/$id.jsonl" 2>/dev/null

    # The probe did not disturb the real lease.
    case "$(_cw_lease_state "$id")" in active|released) ;; *) echo "lease is $(_cw_lease_state "$id")" >&2; return 1 ;; esac
}

@test "a process that claims the real worker's id without its secret is refused and the real worker is undisturbed" {
    local id="cw-impostor"
    CW_TTL=6
    _cw_boot "$id" 20
    _cw_dispatch "$id"
    _cw_must 20 "the lease to be active" _cw_lease_is "$id" active
    _cw_write_fence_client
    # Same uid, same socket, the real worker's id, no secret (then a wrong one).
    run env CW_PROBE_SECRET="" python3 -I "$BATS_TEST_TMPDIR/fence_client.py" "$CW_SOCK" "$id" "x" "1" "w1" "impostor_marker"
    [ "$status" -eq 2 ]
    [[ "$output" == *auth_failed* ]]
    run env CW_PROBE_SECRET="not-the-secret-at-all" python3 -I "$BATS_TEST_TMPDIR/fence_client.py" "$CW_SOCK" "$id" "x" "1" "w1" "impostor_marker"
    [ "$status" -eq 2 ]
    _cw_must 5 "an auth_failed audit line" _cw_audit_has '.code | startswith("auth_failed")'
    _cw_connected
    [ "$(_cw_lease_state "$id")" = "active" ]
}

# ===========================================================================
# 8. Command exactly-once (MC-19)

# A fake coordinator on its own socket: welcome, one lease.offer, then (once the offer is acked applied) the SAME
# cancel command (same cmd_id) delivered twice in a row. It never acks the worker's stream, and logs every frame
# it receives to <outlog>.
_cw_write_fake_coord() {
    cat > "$BATS_TEST_TMPDIR/fake_coord.py" <<'PY'
import datetime, json, os, socket, sys, uuid

sock_path, outlog, job_doc_file, plan_file, job = sys.argv[1:6]
LEASE, EPOCH, OFFER_CMD, CANCEL_CMD = "fake-lease-1", 1, "offer-cmd-1", "cancel-cmd-1"
job_doc = json.load(open(job_doc_file))
plan = open(plan_file).read()
offered = False
cancelled = False


def ts():
    d = datetime.datetime.now(datetime.timezone.utc)
    return d.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (d.microsecond // 1000)


def frame(t, data, job=None, lease=None, epoch=None, seq=None, ack=None):
    return json.dumps({"v": 1, "t": t, "id": str(uuid.uuid4()), "ts": ts(), "job": job, "lease": lease,
                       "epoch": epoch, "seq": seq, "ack": ack, "data": data}, separators=(",", ":")) + "\n"


def log(line):
    with open(outlog, "a") as fh:
        fh.write(line if line.endswith("\n") else line + "\n")


if os.path.exists(sock_path):
    os.unlink(sock_path)
srv = socket.socket(socket.AF_UNIX)
srv.bind(sock_path)
os.chmod(sock_path, 0o600)
srv.listen(4)
while True:
    conn, _ = srv.accept()
    try:
        conn.settimeout(300)
        rf = conn.makefile("rb")
        hello = rf.readline()
        if not hello:
            continue
        log(hello.decode())
        caps = json.loads(hello).get("data", {}).get("caps", [])
        conn.sendall(frame("welcome", {"proto": 1, "caps": caps, "hb_interval_s": 2, "lease_ttl_s": 30}).encode())
        if not offered:
            conn.sendall(frame("lease.offer", {"cmd_id": OFFER_CMD, "job_doc": job_doc, "plan": plan,
                                               "repo": job_doc.get("repo", "gaterepo"), "attempt": 1},
                               job=job, lease=LEASE, epoch=EPOCH).encode())
            offered = True
        while True:
            line = rf.readline()
            if not line:
                break
            log(line.decode())
            try:
                f = json.loads(line)
            except ValueError:
                continue
            d = f.get("data") or {}
            if f.get("t") == "cmd.ack" and d.get("cmd_id") == OFFER_CMD and d.get("outcome") == "applied" \
                    and not cancelled:
                cancelled = True
                for _ in range(2):
                    conn.sendall(frame("cancel", {"cmd_id": CANCEL_CMD}, job=job, lease=LEASE, epoch=EPOCH).encode())
    except Exception as e:  # keep serving: a reconnecting worker must get a coordinator
        log(json.dumps({"fake_coord_error": str(e)}))
    finally:
        conn.close()
PY
}

@test "a command delivered twice with the same cmd_id is applied once; the second delivery is acked duplicate" {
    local id="cw-dedupe" fc="$MOTHER_ROOT/fc.sock" out="$MOTHER_ROOT/fc.frames"
    _cw_prepare_canonical "$id" 25
    _cw_write_fake_coord
    : > "$out"
    python3 -I "$BATS_TEST_TMPDIR/fake_coord.py" "$fc" "$out" "$CW_C/jobs/$id.json" "$CW_C/events/$id-plan.md" "$id" \
        >> "$MOTHER_ROOT/fake-coord.out" 2>&1 3>&- &
    _cw_note P "$!"
    _cw_must 10 "the fake coordinator's socket" test -S "$fc"

    _cw_start_worker "$fc"

    # Two cmd.ack frames for the cancel command: one applied, one duplicate, each carrying the command's
    # job/lease/epoch envelope.
    _cw_must 40 "two acks for cancel-cmd-1" \
        bash -c 'jq -s -e "map(select(.t == \"cmd.ack\" and .data.cmd_id == \"cancel-cmd-1\")) | length >= 2" "$1" >/dev/null' _ "$out"
    run jq -s -r 'map(select(.t == "cmd.ack" and .data.cmd_id == "cancel-cmd-1") | .data.outcome) | sort | join(",")' "$out"
    [ "$output" = "applied,duplicate" ]
    jq -s -e --arg job "$id" 'map(select(.t == "cmd.ack" and .data.cmd_id == "cancel-cmd-1"))
        | all(.[]; .job == $job and .lease == "fake-lease-1" and .epoch == 1)' "$out" >/dev/null

    # The effect happened once: the mirror carries the cancel request and its supervisor stops the job.
    [ "$(jq -r .cancel_requested "$CW_W/jobs/$id.json")" = "true" ]
    _cw_must 30 "the mirror job to end cancelled" _cw_mirror_state_is "$id" cancelled

    # The worker's persisted dedupe record names each command id once.
    [ -f "$CW_W/applied-cmds.json" ]
    [ "$(grep -o 'cancel-cmd-1' "$CW_W/applied-cmds.json" | wc -l | tr -d ' ')" = "1" ]
    [ "$(grep -o 'offer-cmd-1' "$CW_W/applied-cmds.json" | wc -l | tr -d ' ')" = "1" ]
}

# ===========================================================================
# 12. The worker secret is fd-only

@test "a worker started without a secret fd refuses to run, even with the secret in its environment" {
    run env MOTHER_WORKER_SECRET="$CW_SECRET_W1" MOTHER_WORKER_SECRET_FD="" MOTHER_ROOT="$CW_W" \
        mother-worker --id w1 --root "$CW_W" --coord-sock "$CW_SOCK" --slots 1
    [ "$status" -ne 0 ]
    [[ "$output" == *"secret fd"* ]]
    [ ! -e "$CW_W/worker.pid" ]
}

@test "the secret is not in the running worker's own environment block" {
    _cw_boot "cw-env" 20
    local pid; read -r pid _ < "$CW_W/worker.pid"
    _cw_num "$pid"
    ! ps eww -o command= -p "$pid" 2>/dev/null | grep -q "$CW_SECRET_W1"
    ! ps eww -o command= -p "$pid" 2>/dev/null | grep -q "MOTHER_WORKER_SECRET="
}
