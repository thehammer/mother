#!/usr/bin/env bats
# failover_resume.bats — a job's work survives its worker (cluster Phase 1, slice P1-6: checkpoints, failover, resume).
#
# Black-box contract. Everything is observed through files, events, the origin repository and CLI output.
#
# THE FEATURE. In worker mode (MOTHER_DISPATCH_MODE=worker) a worker never loses a job's work when it stops:
#
#   cadence     the worker daemon runs `mother checkpoint take <id> --out <worker-root>/checkpoints/<id>/<n>` for every
#               active lease each checkpoint interval (`mother checkpoint interval` prints it; the test-only knob
#               MOTHER_TEST_CHECKPOINT_INTERVAL_S may go below the production floor of 30 s and is honoured only under
#               MOTHER_TEST_ROOT=1), ships transcript.delta + manifest.json as artifact.put and a checkpoint.taken op.
#               The coordinator (lib/coord_apply.sh) writes <canonical>/checkpoints/<job>/latest.json (only for a manifest
#               with pushed:true), appends every manifest to checkpoints/<job>/index.jsonl, and reassembles the
#               transcript at checkpoints/<job>/transcript/<session>.jsonl.
#   final       mother-run-job takes a final checkpoint (before the state change is visible) on every exit path: succeeded,
#               failed, cancelled, awaiting (mother await, cost-cap pause), limiter park, quota pause, and on SIGTERM
#               (then exits leaving the job `running`).
#   recovery    when a lease is lost (worker killed -9, TTL expired) or released while the mirror still says `running`
#               (SIGTERM), the runner appends the event worker_lost {worker, lease_epoch, last_heartbeat_at,
#               reason: lost|released_running}. If checkpoints/<job>/latest.json exists and its wip_ref is on origin, the job
#               goes back to `ready` (an event whose detail.reason is worker_lost_resume) with a dispatch request carrying
#               resume_from; the next lease has epoch+1; when it is active the event resumed_from_checkpoint
#               {from_worker, to_worker, checkpoint_at, checkpoint_n, lost_work_s, wip_sha} is appended; the new
#               supervisor restores the worktree at <normal worktree path>-e<epoch> and re-enters the same Claude
#               session with `--resume <session_id>`. job.worker_resume_count counts resumes.
#               No restorable checkpoint: the job fails `failed` / failure_reason no_checkpoint_restorable with a `why` in
#               the failed event's detail; it is never re-run from scratch. After MOTHER_WORKER_RESUME_MAX (default 3)
#               resumes: failed / worker_resume_exhausted.
#   fencing     a worker that lost its lease while alive (SIGSTOP/SIGCONT) stops its supervisor, pushes a salvage ref
#               refs/mother/wip-salvage/<job>/lease-<old epoch> (never refs/mother/wip/<job>) and sends a control frame
#               salvage{job, epoch, ref, wip_sha}; the coordinator records it in runner/leases/audit.jsonl and as the job
#               event worker_salvaged {epoch, ref, wip_sha}.
#   status      `mother status <id>` renders "worker local lost at 2:14 pm CT; resumed on local from the checkpoint at
#               2:11 pm CT; about 3 minutes of work re-done".
#   legacy      MOTHER_DISPATCH_MODE unset: no checkpoint is taken and no refs/mother/* ref is pushed.
#
# THE WORLD. One test = one temp tree (setup_mother_env). The canonical root is $MOTHER_ROOT itself; the local worker's root is
# $MOTHER_WORKER_ROOT/local (what the runner starts). Each job has a repo + bare origin of its own under the canonical root
# (worktree isolation, a real PR flow through the shared gh stand-in). `claude` is tests/mock_claude in scripted mode (see its
# header): a script of edit / commit / push / pr / sleep / wait-file / await ... steps whose completion is observable as marker
# files, so no test guesses with a fixed sleep. Transcripts are fake files under a temp MOTHER_CLAUDE_PROJECTS_DIR; the mock
# FAILS LOUDLY (exit 97) when asked to --resume a session whose transcript is not at the new path.
#
# SAFETY. Every daemon is stopped in teardown by EXACT pid / recorded process group (the worker daemon's <root>/worker.pid holds
# "<pid> <pgid>"); nothing is ever killed by pattern. The real ~/.mother and ~/.mother-worker are never touched (hermetic HOME).
#
# What this file asks of the implementation that is NOT spelled out in the contract (flagged to the maintainers, see the report):
#   - The first cadence checkpoint is taken one interval after the lease starts, not at lease start (test 2 needs a window with
#     no checkpoint at all).
#   - A restore at <path>-e<epoch> succeeds while the old worktree still holds the job branch (same machine, test 6).
#   - latest.json is the newest PUSHED manifest; a quiet worktree produces no new manifest ("unchanged" is skipped), so the
#     cadence bounds below are asserted on a worktree that keeps changing.

bats_require_minimum_version 1.5.0
load 'test_helper'
load 'gh_mock'

FR_USAGE_FIXTURES="$BATS_TEST_DIRNAME/fixtures/usage"
# Production watchdog for one checkpoint (docs/worker-protocol.md section 9): the loss bound is interval + this.
FR_WATCHDOG_S=60

setup() {
    setup_mother_env
    unset MOTHER_GATES_ENABLED MOTHER_PHI_REPOS MOTHER_JOB_ID MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR \
          MOTHER_LIVE_ROOT MOTHER_DISPATCH_MODE GH_MOCK_FAIL_DRAFT MOTHER_WORKER_RESUME_MAX \
          MOTHER_CHECKPOINT_INTERVAL_S MOTHER_TEST_CHECKPOINT_INTERVAL_S MOCK_CLAUDE_STDOUT MOCK_CLAUDE_STDOUT_FILE \
          MOCK_CLAUDE_SLEEP MOCK_CLAUDE_STDIN_FILE
    export MOTHER_POSTURE_ENABLED=0 MOTHER_POLL_INTERVAL=1 MOTHER_CONCURRENCY=1 MOTHER_MIN_FREE_GB=0
    export MOTHER_NOTIFY_ENABLED=0 MOTHER_BACKUP_ENABLED=0 MOTHER_BROKER_ENABLED=0 MOTHER_LIMITER_MODE=off
    export MOTHER_ADHERENCE_ENABLED=0 MOTHER_PROGRESS_ENABLED=0 MOTHER_GC_ENABLED=0 MOTHER_TEARDOWN_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120 MOTHER_RESULT_GRACE_SECONDS=120
    # Freeze outcomes at `failed`: a failed job must stay failed (no escalation, reconcile or routing re-run), so a
    # missing feature shows up as a failed assertion and never as a fresh from-scratch run of the mock.
    export MOTHER_ESCALATION_ENABLED=0 MOTHER_RECONCILE_ENABLED=0 MOTHER_FAILURE_ROUTING_ENABLED=0
    export MOTHER_LEASE_TTL_S=6 MOTHER_WORKER_BACKOFF_MAX_S=2
    export MOTHER_TEST_CHECKPOINT_INTERVAL_S=3
    export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com" \
           GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"
    export _MOTHER_TEST_REAL_HOME="${_MOTHER_TEST_REAL_HOME:-$HOME}"
    mkdir -p "$MOTHER_ROOT/fake-home"
    export HOME="$MOTHER_ROOT/fake-home"

    # Physical paths everywhere: real claude encodes its physical cwd, and so does the mock.
    FR_C="$(cd "$MOTHER_ROOT" && pwd -P)"
    FR_W="$MOTHER_WORKER_ROOT/local"
    FR_W2="$MOTHER_WORKER_ROOT/w2"
    FR_PIDS="$MOTHER_ROOT/fr-pids"
    : > "$FR_PIDS"
    FR_STEPS="$FR_C/steps"
    FR_GATES="$FR_C/gates"
    FR_PROJECTS="$FR_C/claude-projects"
    FR_ID=""; FR_REPO=""; FR_ORIGIN=""; FR_BRANCH=""; FR_PR_GLOB=""
    mkdir -p "$FR_STEPS" "$FR_GATES" "$FR_PROJECTS" "$FR_C/scripts"

    # The scripted mock and its fake transcripts (opt-in, see tests/mock_claude).
    export MOCK_CLAUDE_TRANSCRIPTS=1 MOTHER_CLAUDE_PROJECTS_DIR="$FR_PROJECTS" MOCK_CLAUDE_STEP_LOG="$FR_STEPS" \
           MOCK_CLAUDE_GH_DIRS="$MOTHER_ROOT/gh"
    unset MOCK_CLAUDE_SCRIPT MOCK_CLAUDE_RESUME_SCRIPT MOCK_CLAUDE_SCRIPT_1 MOCK_CLAUDE_SCRIPT_2 MOCK_CLAUDE_SCRIPT_3
}

teardown() {
    local f n kind
    # Open every gate so nothing waits on a file that no longer matters, then stop by exact pid only: runner first (so
    # nothing is restarted), then the coordinator, the worker daemons and their supervisors' trees.
    if [ -d "${FR_GATES:-/nonexistent}" ]; then
        for f in resume finish edit park; do : > "$FR_GATES/$f-gate"; done
    fi
    _fr_kill_pid "$(_fr_pidfile_val "${FR_C:-/nonexistent}/runner/runner.pid")"
    if [ -f "${FR_PIDS:-/nonexistent}" ]; then
        while read -r kind n; do
            case "$kind" in P) _fr_kill_pid "$n" ;; esac
        done < "$FR_PIDS"
    fi
    _fr_kill_pid "$(_fr_pidfile_val "${FR_C:-/nonexistent}/runner/coord.pid")"
    _fr_kill_pid "$(_fr_pidfile_val "${FR_C:-/nonexistent}/runner/coord/coord.pid")"
    _fr_kill_pid "$(_fr_pidfile_val "${FR_C:-/nonexistent}/runner/worker-local.pid")"
    for n in "${FR_W:-/nonexistent}" "${FR_W2:-/nonexistent}" "${MOTHER_WORKER_ROOT:-/nonexistent}/m1"; do
        for f in "$n"/children/*.json; do
            [ -f "$f" ] && _fr_kill_tree "$(jq -r '.pid // empty' "$f" 2>/dev/null)"
        done
        if [ -f "$n/worker.pid" ]; then
            read -r f kind < "$n/worker.pid" || true
            _fr_kill_pid "$f"
            _fr_kill_group "$kind"
        fi
    done
    # The worker roots carry the .mother-worker-live marker safe_rm_tree refuses; they live inside this test's own temp
    # tree, so (only) the markers are removed before the tree is.
    rm -f "${FR_W:-/nonexistent}/.mother-worker-live" "${FR_W2:-/nonexistent}/.mother-worker-live" \
          "${MOTHER_WORKER_ROOT:-/nonexistent}/m1/.mother-worker-live" "${MOTHER_WORKER_ROOT:-/nonexistent}/.mother-worker-live"
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Process utilities (exact pids and groups only)

_fr_num() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 1 ]; }
_fr_alive() { local s; s=$(ps -o stat= -p "$1" 2>/dev/null) || return 1; [ -n "$s" ] && [[ "$s" != Z* ]]; }
_fr_dead() { ! _fr_alive "$1"; }
_fr_note() { printf '%s %s\n' "$1" "$2" >> "$FR_PIDS"; }
_fr_pidfile_val() { { cat "$1" 2>/dev/null || true; } | awk '{print $1}' | tr -dc '0-9'; }
_fr_mypgid() { ps -o pgid= -p $$ 2>/dev/null | tr -d ' '; }

_fr_kill_pid() {
    _fr_num "${1:-}" || return 0
    kill -9 "$1" 2>/dev/null || true
    _fr_wait_for 5 _fr_dead "$1" || true
}

# Exact process group only, never our own.
_fr_kill_group() {
    _fr_num "${1:-}" || return 0
    [ "$1" != "$(_fr_mypgid)" ] || return 0
    kill -9 -- "-$1" 2>/dev/null || true
}

# Every descendant of <pid> (not <pid> itself), one per line.
_fr_descendants() {
    ps -A -o pid=,ppid= | awk -v root="$1" '
        { ppid[$1] = $2; n[++c] = $1 }
        END { ch[root] = 1; changed = 1
              while (changed) { changed = 0
                  for (i = 1; i <= c; i++) { p = n[i]; if (!(p in ch) && (ppid[p] in ch)) { ch[p] = 1; changed = 1; print p } } } }'
}

# <pid> and everything below it, killed by the exact pids found now.
_fr_kill_tree() {
    local pids
    _fr_num "${1:-}" || return 0
    pids="$1 $(_fr_descendants "$1" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
}

# _fr_supervisor_pids <worker root> — the pids of every supervisor the worker tracks, and everything below them.
_fr_tree_pids() {
    local wroot="$1" f sp
    for f in "$wroot"/children/*.json; do
        [ -f "$f" ] || continue
        sp=$(jq -r '.pid // empty' "$f" 2>/dev/null)
        _fr_num "$sp" || continue
        printf '%s\n' "$sp"
        _fr_descendants "$sp"
    done
}

# _fr_kill9_worker <worker root> — a machine dying: the daemon's whole process group AND every supervisor's tree, in one kill
# call (a supervisor that survived would be re-adopted by the restarted worker: the designed non-loss path, not this test).
_fr_kill9_worker() {
    local wroot="$1" wpid wpgid pids
    read -r wpid wpgid < "$wroot/worker.pid" || return 1
    _fr_num "$wpgid" && [ "$wpgid" != "$(_fr_mypgid)" ] || return 1
    pids=$(_fr_tree_pids "$wroot" | tr '\n' ' ')
    # shellcheck disable=SC2086
    kill -9 -- "-$wpgid" $pids 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Waiting

_fr_wait_for() {
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

# A subshell: `set +e` here must never leak into the caller (it once silently disabled errexit for the rest of the test).
_fr_dump() (
    local f
    set +e   # a diagnostic dump must never stop at the first missing file (bats runs with -e)
    {
        echo "--- runner.out";    tail -n 25 "$FR_C/runner.out" 2>/dev/null
        echo "--- runner.log";    tail -n 25 "$FR_C/logs/runner.log" 2>/dev/null
        echo "--- coord.log";     tail -n 25 "$FR_C/logs/coord.log" "$FR_C/coord.out" 2>/dev/null
        echo "--- worker-local.log"; tail -n 25 "$FR_C/logs/worker-local.log" 2>/dev/null
        echo "--- leases";        cat "$FR_C"/runner/leases/*.json 2>/dev/null
        echo "--- audit";         tail -n 20 "$FR_C/runner/leases/audit.jsonl" 2>/dev/null
        echo "--- jobs";          for f in "$FR_C"/jobs/*.json; do [ -f "$f" ] && jq -c '{id,state,activity,paused_reason,failure_reason,worker_resume_count,work_dir}' "$f"; done
        for f in "$FR_C"/events/*.jsonl; do [ -f "$f" ] && { echo "--- $f"; jq -c '[.ts,.kind,.detail.reason,.detail.why]' "$f" 2>/dev/null | tail -n 30; }; done
        echo "--- mock steps";    ls "$FR_STEPS" 2>/dev/null | tr '\n' ' '; echo
        echo "--- mock args";     cat "$MOCK_CLAUDE_ARGS_FILE" 2>/dev/null | tr '\n' ' '; echo
        echo "--- checkpoints";   find "$FR_C/checkpoints" -maxdepth 3 2>/dev/null | head -n 30
        [ -f "$FR_C/checkpoints/$FR_ID/index.jsonl" ] && jq -c '{n,epoch,at,pushed,wip_sha}' "$FR_C/checkpoints/$FR_ID/index.jsonl" | tail -n 8
        echo "--- worker-side checkpoints"; ls "$FR_W/checkpoints/$FR_ID" 2>/dev/null | tr '\n' ' '; echo
        echo "--- origin refs";   [ -n "$FR_ORIGIN" ] && git --git-dir="$FR_ORIGIN" for-each-ref 2>/dev/null
    } >&2
    true
)

# Every wait is scaled (default x2): a loaded CI or laptop runs a bare supervisor start in tens of seconds.
_fr_must() {
    local t="$1" what="$2"
    shift 2
    t=$(( t * ${FR_TIMEOUT_SCALE:-2} ))
    if ! _fr_wait_for "$t" "$@"; then
        echo "timed out after ${t}s waiting for: $what" >&2
        _fr_dump
        return 1
    fi
}

# _fr_fail <message> — dump and fail (for assertions that are not a wait).
_fr_fail() { echo "FAIL: $*" >&2; _fr_dump; return 1; }

# _fr_not <cmd...> — succeeds when <cmd> fails. (A bare `! cmd` never trips bats' errexit, so it asserts nothing.)
_fr_not() { if "$@" >/dev/null 2>&1; then return 1; fi; return 0; }

# _fr_between <value> <lo> <hi> — a number (integer or not) within [lo, hi].
_fr_between() { awk -v v="$1" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v ~ /^[0-9]+([.][0-9]+)?$/ && v + 0 >= lo && v + 0 <= hi) }'; }

_fr_now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000'; }
_fr_iso_ms() { perl -MTime::Local=timegm -e '$ARGV[0]=~/^(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)(?:\.(\d+))?/ or exit 1; printf "%d", timegm($6,$5,$4,$3,$2-1,$1)*1000 + substr(($7//"0")."00",0,3)' "$1"; }

# ---------------------------------------------------------------------------
# The world: a repo + bare origin + job, the gh stand-in, scripts

_fr_export_root() {
    local r="$1"
    export MOTHER_ROOT="$r"
    export JOBS_DIR="$r/jobs" EVENTS_DIR="$r/events" LOGS_DIR="$r/logs" DRAFTS_DIR="$r/drafts" \
           CURSORS_DIR="$r/cursors" RUNNER_DIR="$r/runner" ARCHIVE_DIR="$r/archive" \
           TEARDOWN_DIR="$r/teardown-pending"
    mkdir -p "$JOBS_DIR" "$EVENTS_DIR" "$LOGS_DIR" "$DRAFTS_DIR" "$CURSORS_DIR" "$RUNNER_DIR" \
             "$ARCHIVE_DIR" "$TEARDOWN_DIR"
}

_fr_mother() { ( _fr_export_root "$FR_C"; mother "$@" ); }

# _fr_world <id> [extra-jq] — repo with seed files, bare origin, plan, log, gh stand-in, and a ready worktree job
# on branch feature/fr-<id> (a normal PR job, not no_pr). Sets FR_ID / FR_REPO / FR_ORIGIN / FR_BRANCH.
_fr_world() {
    local id="$1" extra="${2:-.}"
    FR_ID="$id"
    FR_REPO="$FR_C/work/repo-$id"
    # Mother only asks gh about a remote whose URL contains github.com/<owner>/<name> (lib/prdetect.sh), and the coordinator accepts a
    # pr_url only inside the origin's repo: a bare repo in a directory called github.com is both a local origin and a "GitHub" one.
    FR_ORIGIN="$FR_C/github.com/test/failover-$id.git"
    FR_PR_GLOB="https://github.com/test/failover-$id/pull/*"
    FR_BRANCH="feature/fr-$id"
    mkdir -p "$FR_REPO" "$(dirname "$FR_ORIGIN")"
    git init -q --bare -b main "$FR_ORIGIN"
    (
        cd "$FR_REPO" || exit 1
        git init -q -b main
        echo "# repo" > README.md
        echo "a0" > file-a.txt
        echo "b0" > file-b.txt
        echo "c0" > file-c.txt
        git add .
        git commit -q -m "init"
        git remote add origin "$FR_ORIGIN"
        git push -q -u origin main
    ) >/dev/null 2>&1
    gh_mock_install
    # Every gh call, in any root (the coordinator's, a worker's), reads the one fixture dir: the test's.
    mv "$_MOCK_BIN/gh" "$_MOCK_BIN/gh.real"
    printf '#!/usr/bin/env bash\nexport MOTHER_ROOT=%q\nexec %q "$@"\n' "$MOTHER_ROOT" "$_MOCK_BIN/gh.real" > "$_MOCK_BIN/gh"
    chmod +x "$_MOCK_BIN/gh"
    make_plan "$EVENTS_DIR/$id-plan.md"
    touch "$LOGS_DIR/$id.log"
    make_job "$id" "ready" \
        '.isolation = "worktree"
         | .repo = "repo-'"$id"'"
         | .repo_path = "'"$FR_REPO"'"
         | .base_ref = "origin/main"
         | .branch = "'"$FR_BRANCH"'"
         | .plan_path = "'"$EVENTS_DIR/$id-plan.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .no_pr = false
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }
         | '"$extra"
}

# _fr_script <name> <text> — writes a mock script file, prints its path.
_fr_script() {
    printf '%s\n' "$2" > "$FR_C/scripts/$1"
    printf '%s' "$FR_C/scripts/$1"
}

# The first run of every kill scenario: a commit, a tracked uncommitted edit, an untracked file, then the job "thinks".
_fr_first_run_script() {
    _fr_script first "edit file-a.txt committed-by-the-first-run
commit first run: file-a
edit file-b.txt uncommitted-edit-from-the-first-run
untracked scratch/untracked.txt
sleep 600"
}

# The resumed run: wait at a gate (so a test can inspect the restored worktree), then finish the job.
_fr_resume_script() {
    _fr_script resume "wait-file $FR_GATES/resume-gate
edit file-c.txt written-after-the-resume
commit second run: finish
push
pr"
}

# _fr_runner <worker|unset> [VAR=value...] — start mother-runner in the background (its exact pid is noted for teardown).
_fr_runner() {
    local mode="$1"
    shift
    (
        _fr_export_root "$FR_C"
        unset MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR MOTHER_DISPATCH_MODE
        [ "$mode" = "unset" ] || export MOTHER_DISPATCH_MODE="$mode"
        cd / || exit 1
        exec env "$@" mother-runner
    ) >> "$FR_C/runner.out" 2>&1 3>&- &
    _fr_note P "$!"
    disown "$!" 2>/dev/null || true
    _fr_must 20 "runner pid file" test -s "$FR_C/runner/runner.pid"
}

_fr_runner_stop() {
    local p; p=$(_fr_pidfile_val "$FR_C/runner/runner.pid")
    _fr_num "$p" || return 1
    kill -TERM "$p"
    _fr_must 60 "the runner to drain and exit" _fr_dead "$p"
}

# ---------------------------------------------------------------------------
# Observations

_fr_state() { jq -r '.state // empty' "$FR_C/jobs/$FR_ID.json" 2>/dev/null; }
_fr_state_is() { [ "$(_fr_state)" = "$1" ]; }
_fr_field() { jq -r ".$1 // empty" "$FR_C/jobs/$FR_ID.json" 2>/dev/null; }
_fr_lease() { jq -r ".$1 // empty" "$FR_C/runner/leases/$FR_ID.json" 2>/dev/null; }
_fr_lease_active_epoch() { [ "$(_fr_lease state)" = "active" ] && [ "$(_fr_lease epoch)" = "$1" ]; }
_fr_events() { printf '%s/events/%s.jsonl' "$FR_C" "$FR_ID"; }
_fr_ev_count() { jq -s --arg k "$1" 'map(select(.kind == $k)) | length' "$(_fr_events)" 2>/dev/null || echo 0; }
_fr_ev_has() { [ "$(_fr_ev_count "$1")" -ge 1 ]; }
# _fr_ev_where <jq-select-body> — some event matches.
_fr_ev_where() { jq -e -s "map(select($1)) | length > 0" "$(_fr_events)" >/dev/null 2>&1; }
_fr_ev_reason_has() { _fr_ev_where "(.detail.reason // \"\") == \"$1\""; }
# _fr_ev_detail <kind> <jq-expr> — the expression over the LAST event of that kind's detail.
_fr_ev_detail() { jq -r -s --arg k "$1" "map(select(.kind == \$k)) | last | .detail | $2" "$(_fr_events)" 2>/dev/null; }
_fr_ev_ts() { jq -r -s --arg k "$1" 'map(select(.kind == $k)) | first | .ts' "$(_fr_events)" 2>/dev/null; }
_fr_no_dup_events() { [ -z "$(sort "$(_fr_events)" | uniq -d)" ]; }

_fr_step_done() { [ -e "$FR_STEPS/inv$1.step$2" ]; }
_fr_inv_started() { [ -e "$FR_STEPS/inv$1.started" ]; }
# _fr_inv_field <inv> <mode|sid|cwd>
_fr_inv_field() {
    case "$2" in
        mode) awk '{print $1}' "$FR_STEPS/inv$1.started" ;;
        sid)  awk '{print $2}' "$FR_STEPS/inv$1.started" ;;
        cwd)  awk '{print $3}' "$FR_STEPS/inv$1.started" ;;
    esac
}
_fr_mock_runs() { grep -c '^---$' "$MOCK_CLAUDE_ARGS_FILE" 2>/dev/null || true; }
# _fr_args_block <n> — the argv of the n-th mock invocation, one arg per line.
_fr_args_block() { awk -v n="$1" 'BEGIN { b = 1 } $0 == "---" { b++; next } b == n' "$MOCK_CLAUDE_ARGS_FILE"; }
_fr_args_value() { _fr_args_block "$1" | awk -v f="$2" '$0 == f { getline; print; exit }'; }
_fr_enc() { local p="$1"; p="${p//\//-}"; printf '%s' "${p//./-}"; }
_fr_transcript_of() { printf '%s/%s/%s.jsonl' "$FR_PROJECTS" "$(_fr_enc "$1")" "$2"; }

_fr_ckpt_dir() { printf '%s/checkpoints/%s' "$FR_C" "$FR_ID"; }
_fr_latest() { jq -r "$1" "$(_fr_ckpt_dir)/latest.json" 2>/dev/null; }
_fr_latest_pushed() { [ -f "$(_fr_ckpt_dir)/latest.json" ] && [ "$(_fr_latest .pushed)" = "true" ]; }
_fr_index_count() { wc -l < "$(_fr_ckpt_dir)/index.jsonl" 2>/dev/null | tr -d ' ' || echo 0; }
_fr_origin_ref() { git --git-dir="$FR_ORIGIN" rev-parse --verify -q "$1" 2>/dev/null; }
_fr_ref_tree() { git --git-dir="$FR_ORIGIN" rev-parse --verify -q "$1^{tree}" 2>/dev/null; }
_fr_origin_has_file() { git --git-dir="$FR_ORIGIN" cat-file -e "$1:$2" 2>/dev/null; }
# The newest pushed checkpoint's wip commit holds <file>.
_fr_ckpt_has_file() { _fr_latest_pushed && _fr_origin_has_file "$(_fr_latest .wip_sha)" "$1"; }
# The reassembled transcript on the canonical side (everything up to latest.json) contains <fixed string>.
_fr_canonical_transcript_has() { grep -qF -- "$1" "$FR_C/$(_fr_latest .transcript_file)" 2>/dev/null; }
_fr_wip_ref() { printf 'refs/mother/wip/%s' "$FR_ID"; }

# _fr_tree_of <worktree> — the tree of the working directory as the checkpoint sees it (tracked edits, untracked files that are
# not ignored), computed in a throw-away index so the worktree's own index is never touched.
_fr_tree_of() {
    local wt="$1" idx="$BATS_TEST_TMPDIR/idx.$RANDOM$RANDOM"
    (
        export GIT_INDEX_FILE="$idx" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        git -C "$wt" read-tree HEAD >/dev/null && git -C "$wt" add -A >/dev/null && git -C "$wt" write-tree
    )
    rm -f "$idx"
}

# The wip ref on origin matches the worktree at exit, and canonical latest.json catches up with it. A checkpoint taken
# after the state change (the supervisor's boundary take once the session has exited) may still be in flight when the state
# is first seen, so the canonical side is polled rather than compared at one instant.
_fr_latest_is_origin_wip() { [ "$(_fr_latest .wip_sha)" = "$(_fr_origin_ref "$(_fr_wip_ref)")" ]; }
_fr_assert_wip_matches() {
    local wt="$1" want got
    [ -d "$wt" ] || { _fr_fail "worktree $wt is gone"; return 1; }
    want=$(_fr_tree_of "$wt")
    got=$(_fr_ref_tree "$(_fr_wip_ref)")
    [ -n "$got" ] || { _fr_fail "no $(_fr_wip_ref) on origin"; return 1; }
    [ "$got" = "$want" ] || { _fr_fail "wip tree $got != worktree tree $want at exit"; return 1; }
    _fr_must 30 "canonical latest.json to catch up with the origin wip ref" _fr_latest_is_origin_wip
}

# <kind>: waits for the first event of that kind (the state-change event: it is the LAST write of a transition, so the state
# can be visible before it), then requires a pushed checkpoint in index.jsonl taken at or before it whose wip tree is the
# worktree's tree at exit (the worktree is static once the run is over). That is "pushed before the state change".
_fr_assert_ckpt_before_event() {
    local kind="$1" ts want sha wt
    _fr_must 60 "the $kind event" _fr_ev_has "$kind"
    ts=$(_fr_ev_ts "$kind")
    [ -n "$ts" ] && [ "$ts" != null ] || { _fr_fail "no $kind event"; return 1; }
    ts=$(_fr_iso_ms "$ts")
    wt=$(_fr_inv_field 1 cwd)
    want=$(_fr_tree_of "$wt")
    sha=$(jq -r 'select(.pushed == true) | [.at, .wip_sha] | @tsv' "$(_fr_ckpt_dir)/index.jsonl" \
        | while IFS=$'\t' read -r a w; do echo "$(_fr_iso_ms "$a") $w"; done | sort -n | awk -v t="$ts" '$1 <= t {w = $2} END {print w}')
    [ -n "$sha" ] || { _fr_fail "no pushed checkpoint at or before the $kind event: the state change preceded the final checkpoint"; return 1; }
    [ "$(git --git-dir="$FR_ORIGIN" rev-parse --verify -q "$sha^{tree}")" = "$want" ] \
        || { _fr_fail "the newest checkpoint before the $kind event ($sha) does not hold the worktree as it was at exit"; return 1; }
    _fr_latest_pushed || { _fr_fail "latest.json is not pushed:true"; return 1; }
}

# The age (s) of the newest pushed manifest taken at or before <kill_ms>, from index.jsonl.
_fr_ckpt_age_at() {
    local kill_ms="$1" newest
    newest=$(jq -r 'select(.pushed == true) | .at' "$(_fr_ckpt_dir)/index.jsonl" | while read -r a; do _fr_iso_ms "$a"; echo; done | sort -n | awk -v k="$kill_ms" '$1 <= k {m = $1} END {print m}')
    [ -n "$newest" ] || return 1
    echo $(( (kill_ms - newest) / 1000 ))
}

_fr_interval() { echo "${MOTHER_TEST_CHECKPOINT_INTERVAL_S:-120}"; }

# ===========================================================================
# 0. The harness itself (passes today: it guards the scripted mock and the world the tests below stand on)

@test "meta: a failing assertion after a helper that dumps diagnostics still FAILS the test (_fr_dump must not disable errexit)" {
    # The bug this guards: _fr_dump ran `set +e` in the caller's shell, so after any failed _fr_must/_fr_fail the rest of the
    # test ran without errexit and a false assertion passed.
    run bash -c "set -e; FR_C=/nonexistent-fr FR_STEPS=/nonexistent FR_W=/nonexistent FR_ID=x FR_ORIGIN=
        $(declare -f _fr_dump _fr_fail _fr_must _fr_wait_for)
        _fr_fail boom || true
        _fr_must 0 'never true' false || true
        [ 1 = 2 ]
        echo SURVIVED"
    [ "$status" -ne 0 ]
    [[ "$output" != *SURVIVED* ]]
}

@test "harness: a scripted worktree job runs through the worker, commits, pushes and opens its PR (no failure injected)" {
    local id="fr-sanity"
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script sanity "edit file-a.txt hello
commit sanity commit
push
pr")
    _fr_runner worker
    _fr_must 90 "the job to succeed" _fr_state_is succeeded
    [ "$(_fr_mock_runs)" = "1" ]
    [[ "$(_fr_field pr_url)" == $FR_PR_GLOB ]]
    [ "$(_fr_origin_ref "refs/heads/$FR_BRANCH")" = "$(git -C "$(_fr_inv_field 1 cwd)" rev-parse HEAD)" ]
    [ -s "$(_fr_transcript_of "$(_fr_inv_field 1 cwd)" "$(_fr_inv_field 1 sid)")" ]
}

# ===========================================================================
# 1. kill -9 mid-job, resume elsewhere (MC-12, MC-13, MC-14), and
# 10. the status timeline

@test "kill -9 mid-job: the job resumes from its checkpoint on a new lease at a different worktree path with all its work, and finishes" {
    local id="fr-kill" t="$BATS_TEST_TMPDIR" old_epoch old_wd sid new_wd lw interval kill_ms age
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_first_run_script) MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_resume_script)
    interval=$(_fr_interval)
    _fr_runner worker

    _fr_must 60 "the first run's four work steps" _fr_step_done 1 4
    _fr_must 40 "a pushed checkpoint holding the untracked file on the canonical side" _fr_ckpt_has_file scratch/untracked.txt
    # The file exists a moment before the mock appends its step-4 line to the transcript: a checkpoint can land in between, and the
    # transcript the resumed session continues would then lack that line. Kill only once the canonical transcript has it.
    _fr_must 40 "the canonical reassembled transcript to hold the first run's step 4" _fr_canonical_transcript_has '"n":4,'
    _fr_must 10 "the lease to be active" bash -c '[ "$(jq -r .state "$1/runner/leases/$2.json")" = active ]' _ "$FR_C" "$id"
    old_epoch=$(_fr_lease epoch)
    old_wd=$(_fr_inv_field 1 cwd)
    sid=$(_fr_inv_field 1 sid)
    [ -n "$sid" ] && [ -n "$old_epoch" ]

    kill_ms=$(_fr_now_ms)
    _fr_kill9_worker "$FR_W"

    # --- the cadence bound (MC-14): the newest pushed checkpoint at kill time is at most interval + watchdog old
    age=$(_fr_ckpt_age_at "$kill_ms")
    [ "$age" -le $(( interval + FR_WATCHDOG_S )) ] || _fr_fail "newest checkpoint was ${age}s old at kill time (bound $((interval + FR_WATCHDOG_S)))"

    # --- recovery: worker_lost, back to ready, a new lease, resumed_from_checkpoint
    _fr_must 60 "a worker_lost event" _fr_ev_has worker_lost
    [ "$(_fr_ev_detail worker_lost .reason)" = "lost" ]
    [ "$(_fr_ev_detail worker_lost .worker)" = "local" ]
    [ "$(_fr_ev_detail worker_lost .lease_epoch)" = "$old_epoch" ]
    [ -n "$(_fr_ev_detail worker_lost .last_heartbeat_at)" ]
    _fr_must 30 "the job to be put back to ready for a resume (worker_lost_resume)" _fr_ev_reason_has worker_lost_resume
    _fr_must 60 "the second lease (epoch $((old_epoch + 1))) to be active" _fr_lease_active_epoch $((old_epoch + 1))
    _fr_must 60 "the second mock run to start" _fr_inv_started 2
    _fr_must 10 "the resumed_from_checkpoint event" _fr_ev_has resumed_from_checkpoint
    [ "$(_fr_state)" = "running" ]
    [ "$(_fr_field worker_resume_count)" = "1" ]
    [ "$(_fr_ev_detail resumed_from_checkpoint .from_worker)" = "local" ]
    [ "$(_fr_ev_detail resumed_from_checkpoint .to_worker)" = "local" ]
    [ "$(_fr_ev_detail resumed_from_checkpoint .checkpoint_at)" = "$(_fr_latest .at)" ]
    [ "$(_fr_ev_detail resumed_from_checkpoint .checkpoint_n)" = "$(_fr_latest .n)" ]
    [ "$(_fr_ev_detail resumed_from_checkpoint .wip_sha)" = "$(_fr_latest .wip_sha)" ]
    lw=$(_fr_ev_detail resumed_from_checkpoint .lost_work_s)
    _fr_between "$lw" 0 $(( interval + FR_WATCHDOG_S )) || _fr_fail "lost_work_s=$lw outside 0..$((interval + FR_WATCHDOG_S))"

    # --- the second run is the SAME Claude session, in a different worktree that holds everything
    new_wd=$(_fr_inv_field 2 cwd)
    [ "$(_fr_inv_field 2 mode)" = "resume" ]
    [ "$new_wd" != "$old_wd" ]
    [ "$new_wd" = "${old_wd}-e$((old_epoch + 1))" ] || _fr_fail "new worktree $new_wd is not ${old_wd}-e$((old_epoch + 1))"
    [ "$(_fr_mock_runs)" = "2" ]
    [ "$(_fr_args_value 1 --session-id)" = "$sid" ]
    [ "$(_fr_args_value 2 --resume)" = "$sid" ]
    [ "$(_fr_inv_field 2 sid)" = "$sid" ]
    # committed work: the commit is in the new worktree's history
    git -C "$new_wd" log --format=%s > "$t/log-subjects"   # not `| grep -q`: an early-exiting grep can SIGPIPE git under pipefail
    grep -qx 'first run: file-a' "$t/log-subjects"
    grep -qx 'committed-by-the-first-run' "$new_wd/file-a.txt"
    # the tracked uncommitted edit is still an uncommitted edit; the untracked file is back, untracked
    grep -qx 'uncommitted-edit-from-the-first-run' "$new_wd/file-b.txt"
    git -C "$new_wd" status --porcelain > "$t/status"
    grep -q '^ M file-b.txt$' "$t/status"
    grep -q '^?? scratch/$' "$t/status"
    grep -qx 'untracked scratch/untracked.txt' "$new_wd/scratch/untracked.txt"
    # the transcript is under the NEW path's encoded dir, holding the first run's lines (the mock would have exited 97 otherwise)
    [ -f "$(_fr_transcript_of "$new_wd" "$sid")" ]
    grep -q '"n":4,' "$(_fr_transcript_of "$new_wd" "$sid")"
    grep -q '"mode":"resume"' "$(_fr_transcript_of "$new_wd" "$sid")"

    # --- let the resumed run finish the job
    : > "$FR_GATES/resume-gate"
    _fr_must 90 "the job to succeed" _fr_state_is succeeded
    [ "$(_fr_mock_runs)" = "2" ]
    [[ "$(_fr_field pr_url)" == $FR_PR_GLOB ]]
    [ "$(_fr_origin_ref "refs/heads/$FR_BRANCH")" = "$(git -C "$new_wd" rev-parse HEAD)" ]
    _fr_origin_has_file "refs/heads/$FR_BRANCH" scratch/untracked.txt
    _fr_origin_has_file "refs/heads/$FR_BRANCH" file-c.txt

    # --- the canonical event stream: nothing lost, nothing twice, nothing from the dead epoch
    _fr_no_dup_events
    [ "$(_fr_ev_count failed)" = "0" ]
    [ "$(_fr_ev_count worker_spawned)" = "2" ]
    [ "$(_fr_ev_count worker_lost)" = "1" ]
    [ "$(_fr_ev_count resumed_from_checkpoint)" = "1" ]
    [ "$(jq -r -s 'map(select(.kind == "worker_spawned")) | .[1].detail.session_id' "$(_fr_events)")" = "$sid" ]

    # --- 10. the status timeline names the loss and the resume
    run _fr_mother status "$id"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -E 'worker .* lost at .*resumed on .* from the checkpoint at .*work re-done' >&2 \
        || _fr_fail "mother status has no worker-lost timeline line:
$output"
}

@test "status timeline: the worker_lost and resumed_from_checkpoint events render as one line naming both times and the re-done work" {
    local id="fr-status" out
    make_job "$id" running '.repo = "testrepo"'
    FR_ID="$id"
    cat > "$EVENTS_DIR/$id.jsonl" <<'EV'
{"ts":"2026-11-09T20:14:00.000Z","kind":"worker_lost","detail":{"worker":"local","lease_epoch":1,"last_heartbeat_at":"2026-11-09T20:13:50.000Z","reason":"lost"}}
{"ts":"2026-11-09T20:14:07.000Z","kind":"resumed_from_checkpoint","detail":{"from_worker":"local","to_worker":"local","checkpoint_at":"2026-11-09T20:11:00.000Z","checkpoint_n":4,"lost_work_s":180,"wip_sha":"cccccccccccccccccccccccccccccccccccccccc"}}
EV
    out=$( export TZ=UTC; _fr_mother status "$id" )
    printf '%s\n' "$out" | grep -E 'worker .* lost at .*resumed on .* from the checkpoint at .*work re-done' > "$BATS_TEST_TMPDIR/line" \
        || { echo "no timeline line in:" >&2; printf '%s\n' "$out" >&2; return 1; }
    # the two clock times (minutes survive any time zone) and the amount of work re-done
    grep -q ':14' "$BATS_TEST_TMPDIR/line"
    grep -q ':11' "$BATS_TEST_TMPDIR/line"
    grep -qE 'about 3 minutes' "$BATS_TEST_TMPDIR/line"
    grep -q 'local' "$BATS_TEST_TMPDIR/line"
}

# ===========================================================================
# 2. no checkpoint: never re-run from scratch

@test "kill -9 before the first checkpoint: the job fails no_checkpoint_restorable with a stated why, and the mock is never re-run from scratch" {
    local id="fr-nockpt"
    # Default interval (120 s): the first cadence checkpoint is far away, so the kill lands before any checkpoint exists.
    unset MOTHER_TEST_CHECKPOINT_INTERVAL_S
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script nockpt "edit file-a.txt work-nobody-checkpointed
sleep 600")
    _fr_runner worker

    _fr_must 60 "the first run's edit" _fr_step_done 1 1
    [ ! -e "$(_fr_ckpt_dir)/latest.json" ] || _fr_fail "a checkpoint already exists: this scenario needs a kill before the first one"
    _fr_kill9_worker "$FR_W"

    _fr_must 90 "the job to fail" _fr_state_is failed
    _fr_must 60 "the failed event (the last write of the transition)" _fr_ev_has failed
    [ "$(_fr_field failure_reason)" = "no_checkpoint_restorable" ]
    _fr_ev_where '.kind == "failed" and .detail.reason == "no_checkpoint_restorable"'
    [ -n "$(_fr_ev_detail failed .why)" ] && [ "$(_fr_ev_detail failed .why)" != null ]
    _fr_ev_has worker_lost
    # Nothing re-runs the work: no resume, no second mock run, and it stays failed.
    sleep 8
    [ "$(_fr_state)" = "failed" ]
    [ "$(_fr_mock_runs)" = "1" ]
    [ "$(_fr_field worker_resume_count)" != "1" ]
    _fr_not _fr_ev_reason_has worker_lost_resume
    [ "$(_fr_ev_count resumed_from_checkpoint)" = "0" ]
}

@test "kill -9 with a checkpoint whose wip ref is gone from origin: the job fails no_checkpoint_restorable (a checkpoint nobody can fetch is not one)" {
    local id="fr-wipgone"
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_first_run_script) MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_resume_script)
    _fr_runner worker
    _fr_must 60 "the first run's work steps" _fr_step_done 1 4
    _fr_must 40 "a pushed checkpoint" _fr_ckpt_has_file scratch/untracked.txt
    _fr_kill9_worker "$FR_W"
    # With the daemon dead nothing can push the ref back before the runner looks.
    git --git-dir="$FR_ORIGIN" update-ref -d "$(_fr_wip_ref)"
    git --git-dir="$FR_ORIGIN" for-each-ref --format='%(refname)' "refs/mother/wip-ckpt/$id" | while read -r r; do git --git-dir="$FR_ORIGIN" update-ref -d "$r"; done
    [ -z "$(_fr_origin_ref "$(_fr_wip_ref)")" ]
    [ -z "$(git --git-dir="$FR_ORIGIN" for-each-ref "refs/mother/wip-ckpt/$id")" ]

    _fr_must 90 "the job to fail" _fr_state_is failed
    _fr_must 60 "the failed event (the last write of the transition)" _fr_ev_has failed
    [ "$(_fr_field failure_reason)" = "no_checkpoint_restorable" ]
    [ -n "$(_fr_ev_detail failed .why)" ] && [ "$(_fr_ev_detail failed .why)" != null ]
    sleep 5
    [ "$(_fr_mock_runs)" = "1" ]
    [ "$(_fr_ev_count resumed_from_checkpoint)" = "0" ]
}

# The checkpoint on the coordinator is the worker's word. Each case below kills the worker (so nothing can
# rewrite the checkpoint), tampers one thing a hostile or buggy worker could have caused, and expects the job to
# fail no_checkpoint_restorable with a why naming the disagreement, never a resume and never a fresh run.

_fr_tamper_failure() { # <jq-edit-of-latest.json | ""> <origin-edit-cmd...> — kill, tamper, expect the hold
    local id="$1" edit="$2" want="$3"
    shift 3
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_first_run_script) MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_resume_script)
    _fr_runner worker
    _fr_must 60 "the first run's work steps" _fr_step_done 1 4
    _fr_must 40 "a pushed checkpoint" _fr_ckpt_has_file scratch/untracked.txt
    _fr_kill9_worker "$FR_W"
    if [ -n "$edit" ]; then
        jq -c "$edit" "$(_fr_ckpt_dir)/latest.json" > "$(_fr_ckpt_dir)/latest.json.tamper" \
            && mv "$(_fr_ckpt_dir)/latest.json.tamper" "$(_fr_ckpt_dir)/latest.json"
    fi
    if [ $# -gt 0 ]; then "$@"; fi
    _fr_must 90 "the job to fail" _fr_state_is failed
    _fr_must 60 "the failed event (the last write of the transition)" _fr_ev_has failed
    [ "$(_fr_field failure_reason)" = "no_checkpoint_restorable" ]
    _fr_ev_detail failed .why | grep -qF -- "$want" || _fr_fail "why does not say '$want': $(_fr_ev_detail failed .why)"
    sleep 5
    [ "$(_fr_mock_runs)" = "1" ]
    [ "$(_fr_ev_count resumed_from_checkpoint)" = "0" ]
}

_fr_other_sha() { git --git-dir="$FR_ORIGIN" rev-parse "$(git --git-dir="$FR_ORIGIN" for-each-ref --format='%(refname)' refs/heads | head -1)"; }
_fr_ckpt_ref() { printf 'refs/mother/wip-ckpt/%s/%s-%s' "$FR_ID" "$(_fr_latest .epoch)" "$(_fr_latest .n)"; }

_fr_origin_wip_refs_to_other_sha() { # BOTH the rolling ref and the latest checkpoint's own ref point at an unrelated commit
    git --git-dir="$FR_ORIGIN" update-ref "$(_fr_wip_ref)" "$(_fr_other_sha)"
    git --git-dir="$FR_ORIGIN" update-ref "$(_fr_ckpt_ref)" "$(_fr_other_sha)"
}

@test "kill -9, then every ref on origin that could hold the checkpoint points at an unrelated sha: the job fails no_checkpoint_restorable (an unrelated sha is never trusted)" {
    _fr_tamper_failure fr-wrongsha "" "not the checkpoint's wip_sha" _fr_origin_wip_refs_to_other_sha
}

# The worker pushes the wip ref first and the manifest travels the async outbox afterwards, so a worker that dies in between
# leaves the rolling ref AHEAD of the newest manifest the coordinator holds. That is routine, not tampering: the coordinator
# restores from the point whose manifest it holds (its own immutable ref), losing nothing it had a record of.
@test "kill -9 after a push whose manifest never landed (the rolling ref is ahead of latest.json): the job resumes from the newest checkpoint the coordinator knows" {
    local id="fr-ahead" ahead tree head n epoch new_wd
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_first_run_script) MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_resume_script)
    _fr_runner worker
    _fr_must 60 "the first run's work steps" _fr_step_done 1 4
    _fr_must 40 "a pushed checkpoint" _fr_ckpt_has_file scratch/untracked.txt
    _fr_kill9_worker "$FR_W"
    sleep 1
    n=$(_fr_latest .n); epoch=$(_fr_latest .epoch); head=$(_fr_latest .head_sha)
    # What a take that got as far as the push and no further leaves: a newer wip commit under the rolling ref and under the
    # checkpoint's own immutable ref, and no manifest for it at the coordinator.
    tree=$(_fr_ref_tree "$(_fr_latest .wip_sha)")
    ahead=$(git --git-dir="$FR_ORIGIN" commit-tree "$tree" -p "$head" -m "ahead of the manifest")
    git --git-dir="$FR_ORIGIN" update-ref "$(_fr_wip_ref)" "$ahead"
    git --git-dir="$FR_ORIGIN" update-ref "refs/mother/wip-ckpt/$id/$epoch-$((n + 1))" "$ahead"
    [ "$(_fr_origin_ref "$(_fr_wip_ref)")" != "$(_fr_latest .wip_sha)" ]

    _fr_must 90 "the resumed_from_checkpoint event" _fr_ev_has resumed_from_checkpoint
    [ "$(_fr_ev_count failed)" = "0" ]
    [ "$(_fr_ev_detail resumed_from_checkpoint .wip_sha)" = "$(_fr_latest .wip_sha)" ]
    _fr_must 60 "the second mock run to start" _fr_inv_started 2
    new_wd=$(_fr_inv_field 2 cwd)
    grep -qx 'untracked scratch/untracked.txt' "$new_wd/scratch/untracked.txt"
    : > "$FR_GATES/resume-gate"
    _fr_must 90 "the job to succeed" _fr_state_is succeeded
}

@test "kill -9, then the canonical checkpoint says pushed:false (an unpushed wip ref): the job fails no_checkpoint_restorable" {
    _fr_tamper_failure fr-unpushed '.pushed = false' "no pushed checkpoint"
}

@test "kill -9, then the canonical manifest names another job's wip_ref: the job fails no_checkpoint_restorable, the ref is rebuilt from the job id and never read from the manifest" {
    _fr_tamper_failure fr-otherref '.wip_ref = "refs/mother/wip/some-other-job"' "not refs/mother/wip/fr-otherref"
}

@test "kill -9, then the canonical manifest names another branch than the job's: the job fails no_checkpoint_restorable" {
    _fr_tamper_failure fr-otherbranch '.branch = "feature/someone-elses"' "not the job's branch"
}

# ===========================================================================
# 3. SIGTERM: the final checkpoint carries everything up to the termination

@test "SIGTERM of the worker daemon mid-job: the origin wip ref equals the worktree at termination within 30 s, and the job resumes with ~0 lost work" {
    local id="fr-term" t0 wpid wpgid expected old_wd sid lw n_before i
    # A long interval: the edit below falls well after the last cadence checkpoint, so only a FINAL checkpoint can hold it.
    export MOTHER_TEST_CHECKPOINT_INTERVAL_S=20
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script term "edit file-a.txt before-the-last-cadence-checkpoint
wait-file $FR_GATES/edit-gate
edit file-b.txt after-the-last-cadence-checkpoint
untracked scratch/after.txt
sleep 600")
    export MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_resume_script)
    _fr_runner worker

    _fr_must 60 "the first edit" _fr_step_done 1 1
    _fr_must 60 "the first cadence checkpoint to reach the canonical side" _fr_latest_pushed
    n_before=$(_fr_index_count)
    sleep 10
    : > "$FR_GATES/edit-gate"
    _fr_must 20 "the post-checkpoint edits" _fr_step_done 1 4
    old_wd=$(_fr_inv_field 1 cwd)
    sid=$(_fr_inv_field 1 sid)
    expected=$(_fr_tree_of "$old_wd")
    # The edits are not in the newest checkpoint yet.
    _fr_not _fr_ckpt_has_file scratch/after.txt || _fr_fail "a cadence checkpoint already holds the post-checkpoint edit: the final one proves nothing"

    read -r wpid wpgid < "$FR_W/worker.pid"
    _fr_num "$wpid"
    t0=$(date +%s)
    kill -TERM "$wpid"

    _fr_must 30 "the origin wip ref to equal the worktree as it was at termination" \
        bash -c '[ "$(git --git-dir="$1" rev-parse --verify -q "refs/mother/wip/$2^{tree}")" = "$3" ]' _ "$FR_ORIGIN" "$id" "$expected"
    [ $(( $(date +%s) - t0 )) -le 30 ]
    _fr_origin_has_file "$(_fr_wip_ref)" scratch/after.txt
    _fr_origin_has_file "$(_fr_wip_ref)" file-b.txt
    [ "$(git --git-dir="$FR_ORIGIN" show "$(_fr_wip_ref):file-b.txt" | tail -n 1)" = "after-the-last-cadence-checkpoint" ]
    # the canonical side learned about it, as a checkpoint taken after the earlier one
    _fr_must 30 "the canonical latest.json to point at the final checkpoint" \
        bash -c '[ "$(jq -r .wip_sha "$1")" = "$(git --git-dir="$2" rev-parse --verify -q "refs/mother/wip/$3")" ]' _ "$(_fr_ckpt_dir)/latest.json" "$FR_ORIGIN" "$id"
    [ "$(_fr_index_count)" -gt "$n_before" ]

    # The lease was released while the job was still running: worker_lost(released_running) and a resume.
    _fr_must 60 "a worker_lost event" _fr_ev_has worker_lost
    [ "$(_fr_ev_detail worker_lost .reason)" = "released_running" ]
    _fr_must 30 "the job to be put back to ready for a resume (worker_lost_resume)" _fr_ev_reason_has worker_lost_resume
    _fr_must 90 "the resumed run to start" _fr_inv_started 2
    _fr_must 10 "the resumed_from_checkpoint event" _fr_ev_has resumed_from_checkpoint
    lw=$(_fr_ev_detail resumed_from_checkpoint .lost_work_s)
    # The edits were made >= 10 s after the last cadence checkpoint; had they been lost, lost_work_s would show it.
    _fr_between "$lw" 0 8 || _fr_fail "lost_work_s=$lw: a final checkpoint on SIGTERM should leave about nothing to re-do"
    [ "$(_fr_args_value 2 --resume)" = "$sid" ]
    # all of it is back
    grep -qx 'after-the-last-cadence-checkpoint' "$(_fr_inv_field 2 cwd)/file-b.txt"
    [ -f "$(_fr_inv_field 2 cwd)/scratch/after.txt" ]
    : > "$FR_GATES/resume-gate"
    _fr_must 90 "the job to succeed" _fr_state_is succeeded
}

# ===========================================================================
# 4. pushed before every exit path

@test "exit path succeeded: the wip ref matches the worktree and the final checkpoint precedes the succeeded event" {
    local id="fr-x-ok"
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script xok "edit file-a.txt finished-work
commit the finished work
edit file-b.txt trailing-uncommitted-edit
untracked scratch/trailing.txt
push
pr")
    _fr_runner worker
    _fr_must 90 "the job to succeed" _fr_state_is succeeded
    _fr_assert_ckpt_before_event succeeded
    _fr_assert_wip_matches "$(_fr_inv_field 1 cwd)"
    _fr_origin_has_file "$(_fr_wip_ref)" scratch/trailing.txt
}

@test "exit path failed: the wip ref matches the worktree and the final checkpoint precedes the failed event" {
    local id="fr-x-fail"
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script xfail "edit file-a.txt work-before-the-crash
commit work before the crash
edit file-b.txt uncommitted-before-the-crash
untracked scratch/crash.txt
exit 3")
    _fr_runner worker
    _fr_must 90 "the job to fail" _fr_state_is failed
    _fr_assert_ckpt_before_event failed
    _fr_assert_wip_matches "$(_fr_inv_field 1 cwd)"
    _fr_origin_has_file "$(_fr_wip_ref)" scratch/crash.txt
}

@test "exit path cancelled: the wip ref matches the worktree and the final checkpoint precedes the cancelled event" {
    local id="fr-x-cancel"
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script xcancel "edit file-a.txt work-before-the-cancel
commit work before the cancel
edit file-b.txt uncommitted-before-the-cancel
untracked scratch/cancel.txt
sleep 600")
    _fr_runner worker
    _fr_must 60 "the work steps" _fr_step_done 1 4
    run _fr_mother cancel "$id"
    [ "$status" -eq 0 ]
    _fr_must 30 "the job to be cancelled" _fr_state_is cancelled
    _fr_assert_ckpt_before_event cancelled
    _fr_assert_wip_matches "$(_fr_inv_field 1 cwd)"
    _fr_origin_has_file "$(_fr_wip_ref)" scratch/cancel.txt
}

@test "exit path awaiting (mother await): the wip ref matches the worktree and the final checkpoint precedes the awaiting_input event" {
    local id="fr-x-await"
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script xawait "edit file-a.txt work-before-the-question
commit work before the question
edit file-b.txt uncommitted-before-the-question
untracked scratch/question.txt
await Which flavour do you want?
exit 0")
    _fr_runner worker
    _fr_must 90 "the job to be awaiting" _fr_state_is awaiting
    _fr_must 20 "the awaiting_input event" _fr_ev_has awaiting_input
    _fr_assert_ckpt_before_event awaiting_input
    _fr_assert_wip_matches "$(_fr_inv_field 1 cwd)"
    _fr_origin_has_file "$(_fr_wip_ref)" scratch/question.txt
}

@test "exit path cost-cap pause: the wip ref matches the worktree and the final checkpoint precedes the forced pause" {
    local id="fr-x-cost"
    _fr_world "$id" '.max_cost_usd = 0.001'
    export MOCK_CLAUDE_STDOUT_FILE="$FR_USAGE_FIXTURES/full_run.jsonl"
    export MOTHER_USAGE_CHECK_INTERVAL=0 MOTHER_COST_CAP_GRACE_SECONDS=2
    export MOCK_CLAUDE_SCRIPT=$(_fr_script xcost "edit file-a.txt work-before-the-cap
commit work before the cap
edit file-b.txt uncommitted-before-the-cap
untracked scratch/cap.txt
sleep 600")
    _fr_runner worker
    _fr_must 90 "the job to be paused by the cost cap" _fr_state_is awaiting
    [ "$(_fr_field paused_reason)" = "cost_cap" ]
    _fr_must 20 "the cost_cap_forced_pause event" _fr_ev_has cost_cap_forced_pause
    _fr_step_done 1 4
    _fr_assert_ckpt_before_event cost_cap_forced_pause
    _fr_assert_wip_matches "$(_fr_inv_field 1 cwd)"
    _fr_origin_has_file "$(_fr_wip_ref)" scratch/cap.txt
}

@test "exit path quota pause: the wip ref matches the worktree and the final checkpoint precedes the paused_for_quota event" {
    local id="fr-x-quota"
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script xquota "edit file-a.txt work-before-the-quota-pause
commit work before the quota pause
edit file-b.txt uncommitted-before-the-quota-pause
untracked scratch/quota.txt
sleep 600")
    _fr_runner worker
    _fr_must 60 "the work steps" _fr_step_done 1 4
    # Usage jumps over the cap (a fresh feed, both windows at 95%): the runner asks the running leased job to pause.
    jq -nc --argjson r "$(( $(date +%s) + 3600 ))" \
        '{posture: "Cruise", stale_input: false, five_hour: {used_pct: 95, resets_at: $r}, seven_day: {used_pct: 95, resets_at: $r}}' \
        > "$MOTHER_BISHOP_POSTURE_FILE"
    _fr_must 60 "the job to pause to awaiting" _fr_state_is awaiting
    case "$(_fr_field paused_reason)" in quota_*) ;; *) _fr_fail "paused_reason=$(_fr_field paused_reason)"; return 1 ;; esac
    _fr_must 20 "the paused_for_quota event" _fr_ev_has paused_for_quota
    _fr_assert_ckpt_before_event paused_for_quota
    _fr_assert_wip_matches "$(_fr_inv_field 1 cwd)"
    _fr_origin_has_file "$(_fr_wip_ref)" scratch/quota.txt
}

# --- limiter park: no runner here. The runner clears every .hold it did not write itself unless the limiter's own tick says it is
# enforcing, so this scenario starts the coordinator and one worker by hand (the way coord_worker.bats does) and plays the limiter.

_fr_m_coord_up() {
    local p; p=$(_fr_pidfile_val "$FR_C/runner/coord/coord.pid")
    [ -n "$p" ] && _fr_alive "$p" && [ -S "$FR_C/runner/coord/worker.sock" ]
}

_fr_m_start_coord() {
    FR_M_REG="$BATS_TEST_TMPDIR/fr-reg.fifo"
    mkfifo "$FR_M_REG"
    mkdir -p "$FR_C/runner"
    ( _fr_export_root "$FR_C"; cd / || exit 1; exec mother-coord --secrets-fd 4 ) 4<>"$FR_M_REG" >> "$FR_C/coord.out" 2>&1 3>&- &
    _fr_note P "$!"
    _fr_must 20 "the coordinator's pid and socket" _fr_m_coord_up
    _fr_note P "$(_fr_pidfile_val "$FR_C/runner/coord/coord.pid")"
}

_fr_m_start_worker() {
    local root="$MOTHER_WORKER_ROOT/m1" secret="fr-m1-$$-$RANDOM$RANDOM" launched
    mkdir -p "$root"
    (
        cd / || exit 1
        exec env -u JOBS_DIR -u EVENTS_DIR -u LOGS_DIR -u DRAFTS_DIR -u CURSORS_DIR -u RUNNER_DIR -u ARCHIVE_DIR -u TEARDOWN_DIR \
            MOTHER_ROOT="$root" mother-worker --id m1 --root "$root" --coord-sock "$FR_C/runner/coord/worker.sock" --slots 2 --secret-fd 4
    ) 4< <(printf '%s\n' "$secret") >> "$FR_C/worker-m1.out" 2>&1 3>&- &
    launched=$!
    _fr_note P "$launched"
    printf 'm1=%s=%s\n' "$launched" "$secret" > "$FR_M_REG"
    _fr_must 20 "the worker's pid file" test -s "$root/worker.pid"
}

_fr_m_connected() {
    ( _fr_export_root "$FR_C"; mother-coord --status-json 2>/dev/null ) \
        | jq -e '[.workers[]? | select(.id == "m1" and .connected == true)] | length == 1' >/dev/null
}

@test "exit path limiter park: the wip ref matches the worktree and the final checkpoint precedes the paused_for_limiter event" {
    local id="fr-x-limiter"
    unset MOTHER_LIMITER_MODE
    export MOTHER_LIMITER_HOLD_GRACE_S=2 MOTHER_LIMITER_QUIET_S=1 MOTHER_LIMITER_HOOK_POLL_S=0.2 MOTHER_USAGE_CHECK_INTERVAL=3600
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script xlimiter "edit file-a.txt work-before-the-park
commit work before the park
edit file-b.txt uncommitted-before-the-park
untracked scratch/park.txt
wait-file $FR_GATES/park-gate
hook
sleep 600")
    mkdir -p "$FR_C/limiter"
    jq -nc '{mode: "enforce", changed_at: "2026-11-09T12:00:00.000Z", changed_by: "cli"}' > "$FR_C/limiter/mode.json"
    _fr_m_start_coord
    _fr_m_start_worker
    _fr_must 20 "the worker to be connected" _fr_m_connected
    _fr_must 20 "the limiter mode to reach the worker" test -s "$MOTHER_WORKER_ROOT/m1/limiter/mode.json"
    mkdir -p "$FR_C/runner/dispatch"
    printf '{"job":"%s"}\n' "$id" > "$FR_C/runner/dispatch.tmp.$id"
    mv "$FR_C/runner/dispatch.tmp.$id" "$FR_C/runner/dispatch/$id.json"

    _fr_must 90 "the work steps" _fr_step_done 1 4
    # The limiter wants this job held: the flag reaches the worker through the downlink, then the job's next tool call blocks.
    jq -nc '{code: "backoff", reason: "provider rate limit", since: "2026-11-09T12:00:00Z"}' > "$FR_C/runner/$id.hold"
    _fr_must 20 "the hold to reach the worker" test -s "$MOTHER_WORKER_ROOT/m1/runner/$id.hold"
    : > "$FR_GATES/park-gate"
    _fr_must 60 "the job to be parked" _fr_state_is awaiting
    [ "$(_fr_field paused_reason)" = "limiter_hold" ]
    _fr_must 20 "the paused_for_limiter event" _fr_ev_has paused_for_limiter
    _fr_assert_ckpt_before_event paused_for_limiter
    _fr_assert_wip_matches "$(_fr_inv_field 1 cwd)"
    _fr_origin_has_file "$(_fr_wip_ref)" scratch/park.txt
}

# ===========================================================================
# 5. awaiting, then the answer: applied exactly once

@test "awaiting then answered: a new lease runs, the answer is applied exactly once (one resumed_from_input), and the pre-question work is kept" {
    local id="fr-answer" first_epoch
    _fr_world "$id"
    export MOCK_CLAUDE_STDIN_FILE="$FR_C/mock-stdin"
    export MOCK_CLAUDE_SCRIPT_1=$(_fr_script ans1 "edit file-a.txt work-before-the-question
commit work before the question
await Blue or green?
exit 0")
    export MOCK_CLAUDE_SCRIPT_2=$(_fr_script ans2 "edit file-c.txt written-after-the-answer
commit work after the answer
push
pr")
    _fr_runner worker
    _fr_must 90 "the job to be awaiting" _fr_state_is awaiting
    _fr_must 20 "the awaiting_input event" _fr_ev_has awaiting_input
    # The final checkpoint was taken before the question became visible.
    _fr_assert_ckpt_before_event awaiting_input
    first_epoch=$(_fr_lease epoch)

    run _fr_mother resume "$id" "green, please"
    [ "$status" -eq 0 ]
    _fr_must 90 "the job to succeed on a new lease" _fr_state_is succeeded
    [ "$(_fr_lease epoch)" -gt "$first_epoch" ]
    [ "$(_fr_ev_count resumed_from_input)" = "1" ]
    [ "$(_fr_mock_runs)" = "2" ]
    # exactly once in the prompt the second run received
    [ "$(grep -c 'green, please' "$FR_C/mock-stdin")" = "1" ]
    [ "$(_fr_ev_detail resumed_from_input .answer)" = "green, please" ]
    _fr_no_dup_events
    # The first run's commit is part of what the second run pushed.
    git --git-dir="$FR_ORIGIN" log --format=%s "refs/heads/$FR_BRANCH" | grep -qx 'work before the question'
    git --git-dir="$FR_ORIGIN" log --format=%s "refs/heads/$FR_BRANCH" | grep -qx 'work after the answer'
}

# ===========================================================================
# 6. fenced zombie (MC-15)

# A second worker daemon, registered with the runner's coordinator the way the runner registers its own (an id=pid=secret line
# on runner/coord-reg.fifo). It has far more slots than the local worker (MOTHER_CONCURRENCY=1 gives that one a single slot), and
# the coordinator offers a job to the connected worker with the most free slots, so the resumed lease lands here.
_fr_start_w2() {
    local secret="fr-w2-$$-$RANDOM$RANDOM" launched
    mkdir -p "$FR_W2"
    _fr_must 30 "the coordinator's socket and registration fifo" bash -c '[ -S "$1/runner/coord/worker.sock" ] && [ -p "$1/runner/coord-reg.fifo" ]' _ "$FR_C"
    (
        cd / || exit 1
        exec env -u JOBS_DIR -u EVENTS_DIR -u LOGS_DIR -u DRAFTS_DIR -u CURSORS_DIR -u RUNNER_DIR -u ARCHIVE_DIR -u TEARDOWN_DIR \
            -u MOTHER_LIVE_ROOT MOTHER_ROOT="$FR_W2" \
            mother-worker --id w2 --root "$FR_W2" --coord-sock "$FR_C/runner/coord/worker.sock" --slots 8 --secret-fd 4
    ) 4< <(printf '%s\n' "$secret") >> "$FR_C/worker-w2.out" 2>&1 3>&- &
    launched=$!
    _fr_note P "$launched"
    printf 'w2=%s=%s\n' "$launched" "$secret" 1<>"$FR_C/runner/coord-reg.fifo"
    _fr_must 20 "w2's pid file" test -s "$FR_W2/worker.pid"
}

_fr_w2_connected() {
    ( _fr_export_root "$FR_C"; mother workers --json 2>/dev/null ) \
        | jq -e '[.workers[]? | select(.id == "w2" and .connected == true)] | length == 1' >/dev/null
}

_fr_epoch2_wip() {   # the origin wip ref is the sha of some manifest of lease epoch $1
    local cur; cur=$(_fr_origin_ref "$(_fr_wip_ref)") || return 1
    jq -e -s --arg s "$cur" --argjson e "$1" 'map(select(.epoch == $e and .wip_sha == $s)) | length > 0' "$(_fr_ckpt_dir)/index.jsonl" >/dev/null
}

@test "fenced zombie: a frozen worker thawed after its job moved on is refused, stops its supervisor and salvages to wip-salvage, never to the wip ref" {
    local id="fr-zombie" old_epoch zwpid zwpgid zpids zombie_tree salvage_ref new_wd p
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_first_run_script)
    export MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_script zres "edit w2-only.txt written-by-the-resumed-run-on-the-second-worker
wait-file $FR_GATES/finish-gate
commit second run: finish
push
pr")
    _fr_runner worker
    _fr_must 60 "the first run's work steps" _fr_step_done 1 4
    _fr_must 40 "a pushed checkpoint holding the untracked file" _fr_ckpt_has_file scratch/untracked.txt
    _fr_start_w2
    _fr_must 20 "w2 to be connected" _fr_w2_connected
    old_epoch=$(_fr_lease epoch)
    zombie_tree=$(_fr_tree_of "$(_fr_inv_field 1 cwd)")
    zpids=$(_fr_tree_pids "$FR_W" | tr '\n' ' ')
    read -r zwpid zwpgid < "$FR_W/worker.pid"
    _fr_num "$zwpgid" && [ "$zwpgid" != "$(_fr_mypgid)" ]

    # The local worker freezes (heartbeats stop; its supervisor and mock keep running, as in a network partition).
    kill -STOP -- "-$zwpgid"
    _fr_must 60 "a worker_lost event" _fr_ev_has worker_lost
    _fr_must 60 "the second lease to be active" _fr_lease_active_epoch $((old_epoch + 1))
    [ "$(_fr_lease worker_id)" = "w2" ]
    _fr_must 60 "the resumed run to start" _fr_inv_started 2
    _fr_must 10 "the resumed_from_checkpoint event" _fr_ev_has resumed_from_checkpoint
    [ "$(_fr_ev_detail resumed_from_checkpoint .from_worker)" = "local" ]
    [ "$(_fr_ev_detail resumed_from_checkpoint .to_worker)" = "w2" ]
    new_wd=$(_fr_inv_field 2 cwd)
    [[ "$new_wd" == *-e$((old_epoch + 1)) ]]
    # The second worker moves the job on: its edit is in the wip ref, which the zombie cannot know.
    _fr_must 40 "w2 to checkpoint its own edit" _fr_ckpt_has_file w2-only.txt
    [ "$(_fr_latest .epoch)" = "$((old_epoch + 1))" ]
    _fr_must 20 "the origin wip ref to be one of the second lease's checkpoints" _fr_epoch2_wip $((old_epoch + 1))

    # The zombie thaws.
    kill -CONT -- "-$zwpgid"
    salvage_ref="refs/mother/wip-salvage/$id/lease-$old_epoch"
    _fr_must 90 "the salvage ref on origin" bash -c '[ -n "$(git --git-dir="$1" rev-parse --verify -q "$2")" ]' _ "$FR_ORIGIN" "$salvage_ref"
    # It holds the zombie's own worktree (not w2's work) ...
    [ "$(_fr_ref_tree "$salvage_ref")" = "$zombie_tree" ]
    _fr_not _fr_origin_has_file "$salvage_ref" w2-only.txt || _fr_fail "the salvage ref holds the second worker's file"
    _fr_origin_has_file "$salvage_ref" scratch/untracked.txt
    # ... and the wip ref is still the second worker's line: never overwritten by the zombie.
    _fr_origin_has_file "$(_fr_wip_ref)" w2-only.txt
    _fr_must 20 "the origin wip ref to still be one of the second lease's checkpoints" _fr_epoch2_wip $((old_epoch + 1))
    # The coordinator recorded the salvage, as an audit line and as a job event.
    _fr_must 60 "the worker_salvaged event" _fr_ev_has worker_salvaged
    [ "$(_fr_ev_detail worker_salvaged .epoch)" = "$old_epoch" ]
    [ "$(_fr_ev_detail worker_salvaged .ref)" = "$salvage_ref" ]
    [ "$(_fr_ev_detail worker_salvaged .wip_sha)" = "$(_fr_origin_ref "$salvage_ref")" ]
    jq -e -s --arg j "$id" 'map(select(.job == $j and (tostring | test("salvage")))) | length >= 1' "$FR_C/runner/leases/audit.jsonl" >/dev/null \
        || _fr_fail "no salvage line in runner/leases/audit.jsonl"
    # The zombie's supervisor tree is stopped.
    for p in $zpids; do _fr_must 30 "zombie process $p to be gone" _fr_dead "$p"; done
    # No stale write got into the canonical checkpoint index after the second worker took over.
    jq -e -s 'map(.epoch) | . == sort' "$(_fr_ckpt_dir)/index.jsonl" >/dev/null || _fr_fail "an old-epoch manifest was indexed after a newer one"

    # Canonical state is otherwise untouched: the second worker finishes the job.
    [ "$(_fr_state)" = "running" ]
    : > "$FR_GATES/finish-gate"
    _fr_must 90 "the job to succeed on w2" _fr_state_is succeeded
    [ "$(_fr_ev_count failed)" = "0" ]
    [ "$(_fr_ev_count worker_spawned)" = "2" ]
    [ "$(_fr_origin_ref "refs/heads/$FR_BRANCH")" = "$(git -C "$new_wd" rev-parse HEAD)" ]
    _fr_no_dup_events
}

@test "failover to another machine, then a second loss: latest.json advances to the second lease's checkpoints (ordered by epoch, numbering continues) and the third lease resumes from them" {
    local id="fr-twice" old_epoch zwpid zwpgid n1 n2 wd3
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_first_run_script)
    export MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_script twice "edit w2-only.txt written-on-the-second-machine
wait-file $FR_GATES/finish-gate
commit last run: finish
push
pr")
    _fr_runner worker
    _fr_must 60 "the first run's work steps" _fr_step_done 1 4
    _fr_must 40 "a pushed checkpoint holding the untracked file" _fr_ckpt_has_file scratch/untracked.txt
    _fr_start_w2
    _fr_must 20 "w2 to be connected" _fr_w2_connected
    old_epoch=$(_fr_lease epoch)
    read -r zwpid zwpgid < "$FR_W/worker.pid"
    _fr_num "$zwpgid" && [ "$zwpgid" != "$(_fr_mypgid)" ]
    n1=$(_fr_latest .n)
    [ "$(_fr_latest .epoch)" = "$old_epoch" ]

    # Machine 1 freezes; the job moves to w2 (an empty checkpoints directory of its own).
    kill -STOP -- "-$zwpgid"
    _fr_must 60 "the second lease to be active" _fr_lease_active_epoch $((old_epoch + 1))
    [ "$(_fr_lease worker_id)" = "w2" ]
    _fr_must 60 "w2's run to start" _fr_inv_started 2
    _fr_must 60 "w2's own checkpoint to become latest.json (epoch $((old_epoch + 1)))" bash -c '[ "$(jq -r .epoch "$1/latest.json")" = "$2" ]' _ "$(_fr_ckpt_dir)" $((old_epoch + 1))
    _fr_must 40 "a checkpoint of the second machine holding its own edit" _fr_ckpt_has_file w2-only.txt
    n2=$(_fr_latest .n)
    # Numbering continues from the offered manifest instead of restarting at 1 on the new machine.
    [ "$n2" -gt "$n1" ] || _fr_fail "the second lease numbered its checkpoint $n2, not past the first lease's $n1"

    # Machine 2 dies for good (and so does the frozen machine 1: nothing can interfere); the runner restarts the local worker.
    _fr_kill9_worker "$FR_W2"
    kill -9 -- "-$zwpgid" 2>/dev/null || true
    _fr_must 90 "the third lease to be active" _fr_lease_active_epoch $((old_epoch + 2))
    _fr_must 60 "the third run to start" _fr_inv_started 3
    [ "$(_fr_field worker_resume_count)" = "2" ]
    [ "$(_fr_ev_count failed)" = "0" ]
    # It resumed from the SECOND lease's checkpoint: that line's file is in its worktree.
    jq -e -s --arg s "$(_fr_ev_detail resumed_from_checkpoint .wip_sha)" --argjson e "$((old_epoch + 1))" \
        'map(select(.epoch == $e and .wip_sha == $s)) | length > 0' "$(_fr_ckpt_dir)/index.jsonl" >/dev/null \
        || _fr_fail "the third lease did not resume from a checkpoint of epoch $((old_epoch + 1))"
    wd3=$(_fr_inv_field 3 cwd)
    [ -f "$wd3/w2-only.txt" ]
    [ -f "$wd3/scratch/untracked.txt" ]
    : > "$FR_GATES/finish-gate"
    _fr_must 90 "the job to succeed" _fr_state_is succeeded
}

# latest.json is what a restore reads: it must be exactly Go's (validated) manifest plus the coordinator's own fields, never
# the worker's bytes (case-variant or duplicate keys parse differently in Go and jq).
@test "latest.json is the Go Manifest re-serialisation: the keys of the wire manifest in order, then the coordinator's received_at, transcript_file, transcript_ok" {
    local id="fr-wire"
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_first_run_script)
    _fr_runner worker
    _fr_must 60 "the first run's work steps" _fr_step_done 1 4
    _fr_must 40 "a pushed checkpoint" _fr_ckpt_has_file scratch/untracked.txt
    jq -e 'keys_unsorted[0:13] == ["v","job","lease","epoch","n","at","head_sha","branch","base_sha","wip_sha","wip_ref","pushed","session_id"]' \
        "$(_fr_ckpt_dir)/latest.json" >/dev/null || _fr_fail "latest.json key order: $(jq -c 'keys_unsorted' "$(_fr_ckpt_dir)/latest.json")"
    jq -e 'keys_unsorted[-3:] == ["received_at","transcript_file","transcript_ok"]' "$(_fr_ckpt_dir)/latest.json" >/dev/null \
        || _fr_fail "latest.json does not end with the coordinator's fields: $(jq -c 'keys_unsorted' "$(_fr_ckpt_dir)/latest.json")"
}

# The resume entry runs the same session with `_spawn_and_wait resume ... || true`: a session that cannot be re-entered (here the
# mock exits 97 as real `claude --resume` does for an unknown session) must end the job failed with a stated reason, never start a
# fresh run (the job would redo work already done) and never report success.
@test "a resume that cannot re-enter the session fails the job with a defined reason: no fresh run, never succeeded" {
    local id="fr-noreenter" why
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_first_run_script)
    export MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_script noreenter "exit 97")
    _fr_runner worker
    _fr_must 60 "the first run's work steps" _fr_step_done 1 4
    _fr_must 40 "a pushed checkpoint" _fr_ckpt_has_file scratch/untracked.txt
    _fr_kill9_worker "$FR_W"
    _fr_must 90 "the resumed run to start" _fr_inv_started 2
    _fr_must 90 "the job to fail" _fr_state_is failed
    _fr_must 60 "the failed event" _fr_ev_has failed
    sleep 5
    [ "$(_fr_state)" = "failed" ]
    [ "$(_fr_mock_runs)" = "2" ]
    [ "$(_fr_ev_count succeeded)" = "0" ]
    [ "$(_fr_ev_count worker_spawned)" -le 2 ]
    # The stated reason is on the failed event (a worker never writes failure_reason itself: the coordinator derives it).
    why="$(_fr_field failure_reason) $(_fr_ev_detail failed .reason)"
    [[ "$why" =~ [a-z_] ]] && [[ "$why" != *unspecified* ]] || _fr_fail "no defined failure reason: [$why] events: $(cat "$(_fr_events)" 2>&1 | head -c 1500)"
    [ "$(_fr_inv_field 2 mode)" = "resume" ]
}

# ===========================================================================
# 7. coordinator absent during checkpoints (MC-16)

_fr_coord_dead() {
    local p; p=$(_fr_pidfile_val "$FR_C/runner/coord/coord.pid")
    [ -n "$p" ] || p=$(_fr_pidfile_val "$FR_C/runner/coord.pid")
    [ -z "$p" ] || _fr_dead "$p"
}
_fr_worker_side_count() { ls "$FR_W/checkpoints/$FR_ID" 2>/dev/null | grep -c '^[0-9][0-9]*$' || true; }
_fr_worker_side_at_least() { [ "$(_fr_worker_side_count)" -ge "$1" ]; }

@test "coordinator down for two checkpoint intervals: every checkpoint arrives once it is back, and the canonical transcript equals the worker's byte for byte" {
    local id="fr-coord" i lines="" pre base cur sid wd
    _fr_world "$id"
    lines="edit file-a.txt start-of-the-job"
    for i in $(seq 1 30); do lines="$lines
edit tick.txt tick-$i
sleep 1"; done
    lines="$lines
commit the whole run
push
pr"
    export MOCK_CLAUDE_SCRIPT=$(_fr_script coord "$lines")
    _fr_runner worker

    _fr_must 60 "the job to be running its ticks" _fr_step_done 1 5
    _fr_must 40 "a first pushed checkpoint on the canonical side" _fr_latest_pushed
    # The runner drains, and the coordinator goes with it; the worker and the job keep running (MC-16).
    _fr_runner_stop
    _fr_must 20 "the coordinator to be gone" _fr_coord_dead
    pre=$(_fr_index_count)
    base=$(_fr_worker_side_count)
    [ "$base" -ge 1 ]
    _fr_must 60 "two more checkpoints on the worker side while the coordinator is away" _fr_worker_side_at_least $((base + 2))
    [ "$(_fr_index_count)" = "$pre" ] || _fr_fail "the canonical index moved while the coordinator was down"

    _fr_runner worker
    _fr_must 150 "the job to succeed" _fr_state_is succeeded
    sid=$(_fr_inv_field 1 sid)
    wd=$(_fr_inv_field 1 cwd)
    # Every checkpoint's delta arrived, in order, none twice: the index has n = 1..N with no gap.
    jq -e -s 'map(.n) as $n | ($n | length) >= 3 and $n == [range(1; ($n | length) + 1)]' "$(_fr_ckpt_dir)/index.jsonl" >/dev/null \
        || { _fr_fail "checkpoint numbers in index.jsonl are not 1..N: $(jq -c .n "$(_fr_ckpt_dir)/index.jsonl" | tr '\n' ' ')"; return 1; }
    [ "$(_fr_index_count)" -gt "$pre" ]
    # The reassembled transcript is the worker's transcript.
    [ -s "$(_fr_ckpt_dir)/transcript/$sid.jsonl" ]
    [ "$(shasum -a 256 < "$(_fr_ckpt_dir)/transcript/$sid.jsonl")" = "$(shasum -a 256 < "$(_fr_transcript_of "$wd" "$sid")")" ]
    [ "$(_fr_latest .transcript.sha256)" = "$(shasum -a 256 < "$(_fr_transcript_of "$wd" "$sid")" | awk '{print $1}')" ]
    _fr_no_dup_events
}

# ===========================================================================
# 8. cadence bound

@test "cadence: a changing worktree is checkpointed every interval, and the newest pushed checkpoint is never older than interval + watchdog at kill time" {
    local id="fr-cadence" lines="" i kill_ms age gap interval
    interval=$(_fr_interval)
    _fr_world "$id"
    lines="edit file-a.txt start"
    for i in $(seq 1 40); do lines="$lines
edit tick.txt tick-$i
sleep 1"; done
    export MOCK_CLAUDE_SCRIPT=$(_fr_script cadence "$lines")
    export MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_script cadence-res "sleep 600")
    _fr_runner worker
    _fr_must 60 "the job to be running" _fr_step_done 1 3
    _fr_must 60 "at least three pushed checkpoints on the canonical side" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -ge 3 ]' _ "$(_fr_ckpt_dir)/index.jsonl"
    sleep 1
    kill_ms=$(_fr_now_ms)
    _fr_kill9_worker "$FR_W"

    age=$(_fr_ckpt_age_at "$kill_ms")
    [ "$age" -le $(( interval + FR_WATCHDOG_S )) ] || _fr_fail "newest checkpoint ${age}s old at kill time (bound $((interval + FR_WATCHDOG_S)))"
    # While the worktree kept changing, consecutive checkpoints are never further apart than interval + watchdog.
    gap=$(jq -r '.at' "$(_fr_ckpt_dir)/index.jsonl" | while read -r a; do _fr_iso_ms "$a"; echo; done | sort -n \
        | awk 'prev != "" && $1 - prev > m {m = $1 - prev} {prev = $1} END {print int(m / 1000)}')
    [ "$gap" -le $(( interval + FR_WATCHDOG_S )) ] || _fr_fail "two checkpoints ${gap}s apart"
}

# ===========================================================================
# 9. legacy is untouched

@test "legacy mode: a job run takes no checkpoint and pushes no refs/mother/* ref" {
    local id="fr-legacy"
    _fr_world "$id"
    # The knob is set (3 s) on purpose: only worker mode may act on it.
    export MOCK_CLAUDE_SCRIPT=$(_fr_script legacy "edit file-a.txt legacy-work
commit legacy commit
untracked scratch/legacy.txt
sleep 9
push
pr")
    _fr_runner unset
    _fr_must 120 "the job to succeed" _fr_state_is succeeded
    [ ! -e "$FR_C/checkpoints" ] || _fr_fail "a checkpoints directory exists in legacy mode"
    [ ! -e "$MOTHER_WORKER_ROOT" ] || [ -z "$(find "$MOTHER_WORKER_ROOT" -name manifest.json 2>/dev/null)" ]
    [ -z "$(git --git-dir="$FR_ORIGIN" for-each-ref 'refs/mother')" ] || _fr_fail "refs/mother/* exists on origin in legacy mode"
    [ -z "$(_fr_origin_ref "$(_fr_wip_ref)")" ]
    [ "$(_fr_ev_count worker_lost)" = "0" ]
}

# ===========================================================================
# Beyond the numbered scenarios: risks the contract names

@test "worker_resume_exhausted: after MOTHER_WORKER_RESUME_MAX resumes the next loss fails the job instead of resuming again" {
    local id="fr-exhaust" old_epoch
    export MOTHER_WORKER_RESUME_MAX=1
    _fr_world "$id"
    export MOCK_CLAUDE_SCRIPT=$(_fr_first_run_script)
    export MOCK_CLAUDE_RESUME_SCRIPT=$(_fr_script exres "edit file-c.txt written-by-the-resumed-run
sleep 600")
    _fr_runner worker
    _fr_must 60 "the first run's work steps" _fr_step_done 1 4
    _fr_must 40 "a pushed checkpoint" _fr_ckpt_has_file scratch/untracked.txt
    old_epoch=$(_fr_lease epoch)
    _fr_kill9_worker "$FR_W"
    _fr_must 60 "the first resume" _fr_ev_has resumed_from_checkpoint
    _fr_must 60 "the second lease to be active" _fr_lease_active_epoch $((old_epoch + 1))
    _fr_must 30 "the resumed run's first step" _fr_step_done 2 1
    [ "$(_fr_field worker_resume_count)" = "1" ]

    # The (restarted) worker dies again.
    _fr_must 30 "the restarted worker's pid file" test -s "$FR_W/worker.pid"
    _fr_kill9_worker "$FR_W"
    _fr_must 90 "the job to fail" _fr_state_is failed
    _fr_must 60 "the failed event (the last write of the transition)" _fr_ev_has failed
    [ "$(_fr_field failure_reason)" = "worker_resume_exhausted" ]
    _fr_ev_where '.kind == "failed" and .detail.reason == "worker_resume_exhausted"'
    [ "$(_fr_ev_count worker_lost)" = "2" ]
    [ "$(_fr_ev_count resumed_from_checkpoint)" = "1" ]
    sleep 5
    [ "$(_fr_mock_runs)" = "2" ]
}

@test "checkpoint interval: the production floor holds (the test knob is ignored outside MOTHER_TEST_ROOT) and the knob works inside it" {
    run env -u MOTHER_TEST_ROOT -u MOTHER_CHECKPOINT_INTERVAL_S MOTHER_TEST_CHECKPOINT_INTERVAL_S=3 MOTHER_ROOT="$FR_C" mother checkpoint interval
    [ "$status" -eq 0 ]
    [ "$output" = "120" ]
    run env -u MOTHER_CHECKPOINT_INTERVAL_S MOTHER_TEST_ROOT=1 MOTHER_TEST_CHECKPOINT_INTERVAL_S=3 MOTHER_ROOT="$FR_C" mother checkpoint interval
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
    # The production setting is still bounded to 30..240.
    run --separate-stderr env -u MOTHER_TEST_ROOT -u MOTHER_TEST_CHECKPOINT_INTERVAL_S MOTHER_CHECKPOINT_INTERVAL_S=5 MOTHER_ROOT="$FR_C" mother checkpoint interval
    [ "$status" -eq 0 ]
    [ "$output" = "120" ]
}
