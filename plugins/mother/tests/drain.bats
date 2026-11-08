#!/usr/bin/env bats
# drain.bats — maintenance mode (`mother drain` / `undrain`) and the ordered `mother upgrade`.
#
# Contract: while $RUNNER_DIR/drain.json exists dispatch starts nothing (ready jobs wait, running jobs are
# never touched); only the owner at a terminal can change it; `drain --wait` waits for running jobs and never
# kills them; `mother upgrade` = drain, wait, pull, build, restart, verify, undrain, and leaves drain ON when
# anything fails. Drain older than an hour raises a `drain_stuck` attention item.
#
# Also under test (maintenance-mode hardening): `mother run --once` honours drain; `upgrade --resume` finishes
# an interrupted upgrade from the old sha recorded in the flag; one upgrade at a time ($RUNNER_DIR/upgrade.lockdir)
# with a trap that says where it stopped; the code root must be the checkout the runner runs from; only the
# spawn loop is gated (quota pauses and dispatch-last.json keep working); restart is verified by a surviving pid
# and a fresh "mother-runner started" log line; owner-only refusals name their reason; a corrupt flag is loud.

load 'test_helper'

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"; mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none MOTHER_POSTURE_ENABLED=0 MOTHER_CONCURRENCY=2
    export MOTHER_DRAIN_POLL_S=0.2 MOTHER_TEST_FORCE_TTY=1
    unset CLAUDECODE CLAUDE_CODE_ENTRYPOINT MOTHER_JOB_ID MOTHER_DRAIN_STUCK_S

    _FAKE_BIN="$MOTHER_ROOT/fake-bin"; mkdir -p "$_FAKE_BIN"
    cat > "$_FAKE_BIN/mother-run-job" <<EOF2
#!/usr/bin/env bash
echo "\$*" >> "$MOTHER_ROOT/run-job-calls"
exit 0
EOF2
    chmod +x "$_FAKE_BIN/mother-run-job"
    # A live supervisor stand-in whose command line really contains `mother-run-job` (drain only counts a
    # children/<pid>.json entry whose process is a mother-run-job, so a reused pid is not a running job).
    _SUP_DIR="$MOTHER_ROOT/sup"; mkdir -p "$_SUP_DIR"
    printf '#!/usr/bin/env bash\nwhile :; do sleep 0.2; done\n' > "$_SUP_DIR/mother-run-job"
    chmod +x "$_SUP_DIR/mother-run-job"
    # The owner-only guard walks the process ancestry looking for a mother-run-job; a suite run from inside
    # a Mother worker would always look like a worker. The ancestry walk (`ps -o ppid=,command= -p N`) gets a
    # clean answer (MOTHER_JOB_ID still works); every other ps call (`ps -o command= -p N`) is the real ps.
    REAL_PS=$(PATH=/bin:/usr/bin command -v ps)
    cat > "$_MOCK_BIN/ps" <<EOF2
#!/usr/bin/env bash
case "\$*" in
    *ppid*) echo "1 bash" ;;
    *) exec "$REAL_PS" "\$@" ;;
esac
EOF2
    chmod +x "$_MOCK_BIN/ps"
    REPO="$MOTHER_ROOT/some-repo"; mkdir -p "$REPO"
    SLEEPPIDS="$MOTHER_ROOT/sleeppids"; : > "$SLEEPPIDS"
}

teardown() {
    local p
    while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done < "$SLEEPPIDS"
    teardown_mother_env
}

# ---- helpers ----
_m() { MOTHER_BIN_DIR="$_BIN_DIR" mother "$@" < /dev/null; }
_state_of() { jq -r '.state' "$JOBS_DIR/$1.json"; }
_drain_on() { [ -f "$RUNNER_DIR/drain.json" ]; }
_tick() { MOTHER_BIN_DIR="$_FAKE_BIN" mother-runner --dispatch-tick >/dev/null 2>&1 || true; }
_ready_job() { make_job "$1" "ready" ".repo_path = \"$REPO\" | .created_at = \"2026-09-01T00:00:00Z\""; }

# Poll: _wait_until <timeout_s> <cmd...> — true as soon as the command succeeds.
_wait_until() {
    local t="$1" i=0; shift
    while ! "$@" >/dev/null 2>&1; do
        i=$((i + 1)); [ "$i" -lt $((t * 10)) ] || return 1
        sleep 0.1
    done
}

# Start a live supervisor stand-in (a process whose command line contains mother-run-job) and register it in
# runner/children. Sets SPID.
_fake_running() {
    local jid="$1"
    "$_SUP_DIR/mother-run-job" >/dev/null 2>&1 3>&- &
    SPID=$!
    echo "$SPID" >> "$SLEEPPIDS"
    # the fork must have exec'd the script before anything asks ps what this pid is
    _wait_until 5 _is_supervisor "$SPID"
    mkdir -p "$RUNNER_DIR/children"
    jq -nc --argjson p "$SPID" --arg j "$jid" '{pid:$p, job_id:$j, started_at:"2026-09-01T00:00:00Z"}' \
        > "$RUNNER_DIR/children/$SPID.json"
}
_is_supervisor() { [[ "$("$REAL_PS" -o command= -p "$1" 2>/dev/null)" == *mother-run-job* ]]; }

# A children/<pid>.json whose pid is alive but is NOT a mother-run-job (a reused pid). Sets RPID.
_reused_pid_child() {
    sleep 300 >/dev/null 2>&1 3>&- &
    RPID=$!
    echo "$RPID" >> "$SLEEPPIDS"
    mkdir -p "$RUNNER_DIR/children"
    jq -nc --argjson p "$RPID" --arg j "$1" '{pid:$p, job_id:$j, started_at:"2026-09-01T00:00:00Z"}' \
        > "$RUNNER_DIR/children/$RPID.json"
}

_write_drain() { # <since> [reason]
    jq -nc --arg s "$1" --arg r "${2:-test}" '{since:$s, by:"t@h", reason:$r}' > "$RUNNER_DIR/drain.json"
}
_old_iso() { date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ; }
_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
_attn_count() { _m status --format json | jq '[.needs_attention[] | select(.kind == "drain_stuck")] | length'; }

# ===========================================================================
# Dispatch gate
# ===========================================================================

@test "no drain flag: a ready job is started as before" {
    _ready_job d-normal
    _tick
    local i=0; while [ ! -s "$MOTHER_ROOT/run-job-calls" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    [ -s "$MOTHER_ROOT/run-job-calls" ]
}

@test "draining: a ready job is not started and stays ready, even across repeated ticks" {
    _ready_job d-hold
    _m drain
    _tick; _tick
    sleep 0.5
    [ "$(_state_of d-hold)" = "ready" ]
    [ ! -e "$MOTHER_ROOT/run-job-calls" ]
}

@test "draining: a running job is untouched" {
    _fake_running d-run
    make_job d-run running ".repo_path = \"$REPO\""
    _m drain
    _tick
    kill -0 "$SPID"
    [ -f "$RUNNER_DIR/children/$SPID.json" ]
    [ "$(_state_of d-run)" = "running" ]
}

@test "draining: force-start is refused and says draining" {
    _ready_job d-force
    _m drain
    run _m force-start d-force --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"draining"* ]]
    [ "$(_state_of d-force)" = "ready" ]
}

@test "undrain: dispatch resumes and the next tick starts the job" {
    _ready_job d-resume
    _m drain
    _tick
    [ ! -e "$MOTHER_ROOT/run-job-calls" ]
    run _m undrain
    [ "$status" -eq 0 ]
    ! _drain_on
    _tick
    local i=0; while [ ! -s "$MOTHER_ROOT/run-job-calls" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    [ -s "$MOTHER_ROOT/run-job-calls" ]
}

@test "drain flag is mode 0600 and records since, by and reason" {
    _m drain --reason "disk swap"
    local f="$RUNNER_DIR/drain.json"
    [ -f "$f" ]
    [ "$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")" = "600" ]
    [ -n "$(jq -r '.since // empty' "$f")" ]
    [ -n "$(jq -r '.by // empty' "$f")" ]
    [ "$(jq -r '.reason' "$f")" = "disk swap" ]
}

@test "mother run --once while draining: refuses, says draining, never runs the job, job stays ready" {
    _ready_job d-once-held
    _m drain
    run env MOTHER_BIN_DIR="$_FAKE_BIN" mother run --once < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"draining"* ]]
    [ ! -e "$MOTHER_ROOT/run-job-calls" ]
    [ "$(_state_of d-once-held)" = "ready" ]
}

@test "mother run --once when not draining still starts the oldest ready job" {
    _ready_job d-once-free
    run env MOTHER_BIN_DIR="$_FAKE_BIN" mother run --once < /dev/null
    [ "$status" -eq 0 ]
    grep -q 'd-once-free' "$MOTHER_ROOT/run-job-calls"
}

# Only the spawn loop is gated: everything else the dispatch pass does keeps working while drained.
_over_cap() { # the 7-day window is at 100% (cap 90) and resets tomorrow
    jq -nc --argjson r5 "$(( $(date +%s) + 3600 ))" --argjson r7 "$(( $(date +%s) + 86400 ))" \
        '{posture:"Cruise", stale_input:false,
          five_hour:{used_pct:10, resets_at:$r5}, seven_day:{used_pct:100, resets_at:$r7}}' > "$MOTHER_BISHOP_POSTURE_FILE"
}

@test "quota pause control: over the cap and not draining, the dispatch pass pauses a running job" {
    _over_cap
    _fake_running d-qc
    make_job d-qc running ".repo_path = \"$REPO\""
    _tick
    [ "$(jq -r '.pause_requested // false' "$JOBS_DIR/d-qc.json")" = "true" ]
    [ "$(jq -r '.paused_reason' "$JOBS_DIR/d-qc.json")" = "quota_7d" ]
}

@test "draining: the dispatch pass still pauses a running job that is over the quota cap" {
    _over_cap
    _fake_running d-qd
    make_job d-qd running ".repo_path = \"$REPO\""
    _m drain
    _tick
    [ "$(jq -r '.pause_requested // false' "$JOBS_DIR/d-qd.json")" = "true" ]
    [ "$(jq -r '.paused_reason' "$JOBS_DIR/d-qd.json")" = "quota_7d" ]
    kill -0 "$SPID"
}

@test "draining: the dispatch pass refreshes dispatch-last.json with drained true and nothing spawned" {
    echo '{"ts":1,"spawned":["stale-entry"]}' > "$RUNNER_DIR/dispatch-last.json"
    _ready_job d-dl
    _m drain
    local before; before=$(date +%s)
    _tick
    jq -e --argjson b "$before" '.ts >= $b and .drained == true and .spawned == []' "$RUNNER_DIR/dispatch-last.json"
    [ "$(_state_of d-dl)" = "ready" ]
    [ ! -e "$MOTHER_ROOT/run-job-calls" ]
}

@test "not draining: dispatch-last.json does not claim drained" {
    _tick
    jq -e '.drained != true' "$RUNNER_DIR/dispatch-last.json"
}

@test "drain survives a runner restart: daemon start notes it and dispatch still holds" {
    _ready_job d-restart
    _m drain
    sleep 300 >/dev/null 2>&1 & echo $! >> "$SLEEPPIDS"; echo $! > "$RUNNER_DIR/runner.pid"
    run _m daemon start
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRAINING"* ]]
    _drain_on
    _tick
    [ "$(_state_of d-restart)" = "ready" ]
}

# ===========================================================================
# drain --wait
# ===========================================================================

@test "drain --wait returns 0 once the last running job ends" {
    _fake_running d-wait
    ( sleep 1; kill "$SPID" 2>/dev/null ) &
    run _m drain --wait --timeout 10
    [ "$status" -eq 0 ]
    _drain_on
}

@test "drain --wait --timeout exits 3, keeps drain on, and never kills the job" {
    _fake_running d-timeout
    run _m drain --wait --timeout 1
    [ "$status" -eq 3 ]
    _drain_on
    kill -0 "$SPID"
}

@test "drain --wait is not idle while the adherence-review or pipeline-driver lock is held: exits 3 naming it, idle once released" {
    local pair lock word
    for pair in adherence-review:adherence pipeline-driver:pipeline; do
        lock="$RUNNER_DIR/${pair%%:*}.lockdir"; word="${pair##*:}"
        mkdir "$lock"
        run _m drain --wait --timeout 1
        [ "$status" -eq 3 ]
        [[ "$output" == *"$word"* ]]
        ( sleep 1; rmdir "$lock" ) 3>&- &
        run _m drain --wait --timeout 10
        [ "$status" -eq 0 ]
        [[ "$output" == *"idle"* ]]
    done
}

@test "drain --wait does not count a children entry whose live pid is not a mother-run-job (reused pid)" {
    _reused_pid_child d-reused
    run _m drain --wait --timeout 3
    [ "$status" -eq 0 ]
    [[ "$output" == *"idle"* ]]
    kill -0 "$RPID"
}

@test "status does not count a reused pid as a running job, but does count a real supervisor" {
    _write_drain "$(_now_iso)" maint
    _reused_pid_child d-reused2
    run _m status
    [[ "$output" =~ dispatch:\ DRAINING.*,\ 0\ running ]]
    _fake_running d-real
    run _m status
    [[ "$output" =~ dispatch:\ DRAINING.*,\ 1\ running ]]
}

# ===========================================================================
# Owner-only
# ===========================================================================

# _as <agent|worker|notty> <mother args...> — run mother as that kind of non-owner caller (sets status/output).
# MOTHER_BIN_DIR is $_AS_BIN (upgrade tests point it inside the checkout under upgrade).
_as() {
    local how="$1"; shift
    case "$how" in
        agent)  run env CLAUDECODE=1 MOTHER_BIN_DIR="${_AS_BIN:-$_BIN_DIR}" mother "$@" < /dev/null ;;
        worker) run env MOTHER_JOB_ID=j1 MOTHER_BIN_DIR="${_AS_BIN:-$_BIN_DIR}" mother "$@" < /dev/null ;;
        notty)  run env -u MOTHER_TEST_FORCE_TTY MOTHER_BIN_DIR="${_AS_BIN:-$_BIN_DIR}" mother "$@" < /dev/null ;;
    esac
}
_refusal_reason() {
    case "$1" in
        agent) echo "agent session" ;;
        worker) echo "inside a Mother job" ;;
        notty) echo "stdin is not a terminal" ;;
    esac
}

@test "drain is refused (saying refused and why) for an agent session, a worker and a non-TTY stdin; no flag is written" {
    local how
    for how in agent worker notty; do
        _as "$how" drain
        [ "$status" -ne 0 ] || { echo "drain allowed for $how"; return 1; }
        [[ "$output" == *"refused"* ]] || { echo "no 'refused' for $how: $output"; return 1; }
        [[ "$output" == *"$(_refusal_reason "$how")"* ]] || { echo "wrong reason for $how: $output"; return 1; }
        ! _drain_on
    done
}

@test "undrain is refused (saying refused and why) for an agent session, a worker and a non-TTY stdin; the flag is untouched" {
    _write_drain "$(_now_iso)" keep
    local before how; before=$(cat "$RUNNER_DIR/drain.json")
    for how in agent worker notty; do
        _as "$how" undrain
        [ "$status" -ne 0 ] || { echo "undrain allowed for $how"; return 1; }
        [[ "$output" == *"refused"* ]] || { echo "no 'refused' for $how: $output"; return 1; }
        [[ "$output" == *"$(_refusal_reason "$how")"* ]] || { echo "wrong reason for $how: $output"; return 1; }
        [ "$(cat "$RUNNER_DIR/drain.json")" = "$before" ]
    done
}

@test "upgrade (a fully valid setup) is refused for an agent session, a worker and a non-TTY stdin, and changes nothing" {
    _upgrade_setup; _push_upstream x.txt
    _AS_BIN="$WORK/plugins/mother/bin"
    local before how; before=$(_head)
    for how in agent worker notty; do
        _as "$how" upgrade
        [ "$status" -ne 0 ] || { echo "upgrade allowed for $how"; return 1; }
        [[ "$output" == *"refused"* ]] || { echo "no 'refused' for $how: $output"; return 1; }
        [[ "$output" == *"$(_refusal_reason "$how")"* ]] || { echo "wrong reason for $how: $output"; return 1; }
        ! _drain_on
        [ "$(_head)" = "$before" ]
        [ ! -s "$MOTHER_ROOT/steps.log" ]
        [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
    done
}

@test "drain --status works for an agent session, a worker and a non-TTY stdin" {
    local how
    for how in agent worker notty; do
        ( case "$how" in
            agent)  export CLAUDECODE=1 ;;
            worker) export MOTHER_JOB_ID=j1 ;;
            notty)  unset MOTHER_TEST_FORCE_TTY ;;
          esac
          MOTHER_BIN_DIR="$_BIN_DIR" mother drain --status < /dev/null >/dev/null 2>&1 ) || { echo "status failed for $how"; return 1; }
    done
    _write_drain "$(_now_iso)" maint
    run env CLAUDECODE=1 MOTHER_BIN_DIR="$_BIN_DIR" mother drain --status < /dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRAINING"* ]]
}

# ===========================================================================
# Surfaces
# ===========================================================================

@test "status shows a dispatch: DRAINING line with reason, running and waiting counts; none otherwise" {
    run _m status
    [[ "$output" != *"dispatch:"* ]]
    _ready_job d-s1
    _fake_running d-s2
    _m drain --reason "disk swap"
    run _m status
    [ "$status" -eq 0 ]
    [[ "$output" =~ dispatch:\ DRAINING\ since\ .*\(disk\ swap\),\ 1\ running,\ 1\ waiting ]]
}

@test "drain_stuck attention: raised after an hour, absent when recent, gone after undrain" {
    _write_drain "$(_now_iso)"
    [ "$(_attn_count)" = "0" ]
    _write_drain "$(_old_iso)"
    [ "$(_attn_count)" = "1" ]
    _m undrain >/dev/null
    [ "$(_attn_count)" = "0" ]
}

@test "corrupt drain flag: status --format json raises a drain_stuck item saying unreadable" {
    echo 'not json' > "$RUNNER_DIR/drain.json"
    local out; out=$(_m status --format json 2>/dev/null)
    echo "$out" | jq -e '[.needs_attention[] | select(.kind == "drain_stuck" and (.reason | test("unreadable")))] | length == 1'
}

@test "corrupt drain flag: text status prints 'drain flag unreadable' and drain --status says unreadable" {
    echo 'not json' > "$RUNNER_DIR/drain.json"
    run _m status
    [[ "$output" == *"drain flag unreadable"* ]]
    run _m drain --status
    [[ "$output" == *"unreadable"* ]]
}

@test "corrupt drain flag: undrain still removes it" {
    echo 'not json' > "$RUNNER_DIR/drain.json"
    run _m undrain
    [ "$status" -eq 0 ]
    ! _drain_on
}

# ===========================================================================
# mother upgrade
# ===========================================================================


# The code root is $MOTHER_CODE_ROOT/mother ($WORK). `mother upgrade` must run from the plugin bin dir of that
# same checkout (MOTHER_BIN_DIR), so every upgrade test points MOTHER_BIN_DIR inside $WORK.
_mu() { MOTHER_BIN_DIR="$WORK/plugins/mother/bin" mother "$@" < /dev/null; }

_upgrade_setup() {
    export MOTHER_CODE_ROOT="$MOTHER_ROOT/code"
    ORIGIN="$MOTHER_ROOT/origin.git"
    WORK="$MOTHER_CODE_ROOT/mother"
    PUSHER="$MOTHER_ROOT/pusher"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    export MOTHER_UPGRADE_SETTLE_S=0.3
    REAL_GIT=$(command -v git)
    "$REAL_GIT" init -q --bare -b main "$ORIGIN"
    "$REAL_GIT" init -q -b main "$PUSHER"
    mkdir -p "$PUSHER/plugins/mother/scripts" "$PUSHER/plugins/mother/bin"
    echo placeholder > "$PUSHER/plugins/mother/bin/.keep"
    cat > "$PUSHER/plugins/mother/scripts/build-broker.sh" <<EOF2
#!/usr/bin/env bash
echo "build drain=\$([ -f "$RUNNER_DIR/drain.json" ] && echo 1 || echo 0)" >> "$MOTHER_ROOT/steps.log"
EOF2
    chmod +x "$PUSHER/plugins/mother/scripts/build-broker.sh"
    echo base > "$PUSHER/README"
    "$REAL_GIT" -C "$PUSHER" add -A; "$REAL_GIT" -C "$PUSHER" commit -qm base
    "$REAL_GIT" -C "$PUSHER" remote add origin "$ORIGIN"; "$REAL_GIT" -C "$PUSHER" push -q origin main
    mkdir -p "$MOTHER_CODE_ROOT"
    "$REAL_GIT" clone -q "$ORIGIN" "$WORK"
    OLD_SHA=$("$REAL_GIT" -C "$WORK" rev-parse --short HEAD)

    # CLI stub: logs each call with the drain state. `daemon start` behaves per $MOTHER_ROOT/start-mode:
    #   ok (default)  publishes a new live runner pid and logs "mother-runner started (pid N ...)" like the real one
    #   die           publishes a pid that exits almost at once (the log line is written)
    #   nolog         publishes a live pid but never writes the log line
    #   slow          signals it is running (in-start), lingers 1.5s, then fails
    # and fails outright while $MOTHER_ROOT/fail-start exists.
    sleep 300 >/dev/null 2>&1 3>&- & echo $! >> "$SLEEPPIDS"; echo $! > "$RUNNER_DIR/runner.pid"
    cat > "$MOTHER_ROOT/cli-stub" <<EOF2
#!/usr/bin/env bash
echo "\$* drain=\$([ -f "$RUNNER_DIR/drain.json" ] && echo 1 || echo 0)" >> "$MOTHER_ROOT/steps.log"
if [ "\$1 \$2" = "daemon start" ]; then
    [ -f "$MOTHER_ROOT/fail-start" ] && exit 1
    mode=\$(cat "$MOTHER_ROOT/start-mode" 2>/dev/null || echo ok)
    case "\$mode" in
        slow) touch "$MOTHER_ROOT/in-start"; sleep 1.5; exit 1 ;;
        die)  sleep 0.1 >/dev/null 2>&1 3>&- & ;;
        *)    sleep 300 >/dev/null 2>&1 3>&- & echo \$! >> "$SLEEPPIDS" ;;
    esac
    echo \$! > "$RUNNER_DIR/runner.pid"
    [ "\$mode" = nolog ] || echo "[\$(date -u +%Y-%m-%dT%H:%M:%SZ)] mother-runner started (pid \$!, concurrency=2 [default], poll=5s)" >> "$RUNNER_DIR/runner.log"
fi
exit 0
EOF2
    chmod +x "$MOTHER_ROOT/cli-stub"
    export MOTHER_UPGRADE_CLI="$MOTHER_ROOT/cli-stub"

    # git wrapper: `merge` is the step that lands the new commits (upgrade fetches, then fast-forward merges);
    # it is logged as "pull" in steps.log, and fails with a recognisable git error while fail-pull exists.
    mkdir -p "$MOTHER_ROOT/gitwrap"
    cat > "$MOTHER_ROOT/gitwrap/git" <<EOF2
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = merge ]; then
    echo "pull drain=\$([ -f "$RUNNER_DIR/drain.json" ] && echo 1 || echo 0)" >> "$MOTHER_ROOT/steps.log"
    if [ -f "$MOTHER_ROOT/fail-pull" ]; then echo "fatal: test pull failure" >&2; exit 1; fi
  fi
done
exec "$REAL_GIT" "\$@"
EOF2
    chmod +x "$MOTHER_ROOT/gitwrap/git"
    export PATH="$MOTHER_ROOT/gitwrap:$PATH"
    : > "$MOTHER_ROOT/steps.log"
}

_push_upstream() { # <file> — commit a new file upstream
    mkdir -p "$(dirname "$PUSHER/$1")"
    echo "$RANDOM" > "$PUSHER/$1"
    "$REAL_GIT" -C "$PUSHER" add -A; "$REAL_GIT" -C "$PUSHER" commit -qm "change $1"
    "$REAL_GIT" -C "$PUSHER" push -q origin main
}
_head() { "$REAL_GIT" -C "$WORK" rev-parse HEAD; }
_origin_head() { "$REAL_GIT" -C "$ORIGIN" rev-parse main; }

# _upgrade_bg <outfile> <args...> — run `mother upgrade` in the background, output to <outfile>. Sets UPID.
_upgrade_bg() {
    local out="$1"; shift
    MOTHER_BIN_DIR="$WORK/plugins/mother/bin" mother upgrade "$@" < /dev/null > "$out" 2>&1 3>&- &
    UPID=$!
}
# _upgrade_reap — wait (bounded) for UPID to exit; sets URC to its exit status. Never leaves it running.
_upgrade_reap() {
    local i=0
    while kill -0 "$UPID" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
    if kill -0 "$UPID" 2>/dev/null; then kill -KILL "$UPID" 2>/dev/null; URC=137; return 1; fi
    URC=0; wait "$UPID" 2>/dev/null || URC=$?
}

@test "upgrade refuses a dirty tree and leaves drain off" {
    _upgrade_setup; _push_upstream x.txt
    echo dirt >> "$WORK/README"
    local before; before=$(_head)
    run _mu upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted"* ]]
    ! _drain_on
    [ "$(_head)" = "$before" ]
}

@test "upgrade is not blocked by an untracked file in the checkout" {
    _upgrade_setup; _push_upstream x.txt
    echo scratch > "$WORK/scratch.txt"
    run _mu upgrade
    [ "$status" -eq 0 ]
    [ "$(_head)" = "$(_origin_head)" ]
    ! _drain_on
}

@test "upgrade refuses a branch other than main and leaves drain off" {
    _upgrade_setup; _push_upstream x.txt
    "$REAL_GIT" -C "$WORK" checkout -q -b feature
    local before; before=$(_head)
    run _mu upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"main"* ]]
    ! _drain_on
    [ "$(_head)" = "$before" ]
}

@test "upgrade with nothing new exits 0, says so, and never drains" {
    _upgrade_setup
    run _mu upgrade
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing"* ]]
    ! _drain_on
    ! grep -q 'daemon' "$MOTHER_ROOT/steps.log"
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
}

@test "upgrade with nothing new leaves a manual drain in place (it is not an unfinished upgrade)" {
    _upgrade_setup
    _m drain --reason "manual hold" >/dev/null
    run _mu upgrade
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing"* ]]
    _drain_on
    [ "$(jq -r '.reason' "$RUNNER_DIR/drain.json")" = "manual hold" ]
    [ "$(jq -r '.upgrade // "none"' "$RUNNER_DIR/drain.json")" = "none" ]
    ! grep -q 'daemon' "$MOTHER_ROOT/steps.log"
}

@test "upgrade happy path: drain, wait for the job, pull, build, stop, start, status, undrain" {
    _upgrade_setup; _push_upstream plugins/mother/broker/main.go
    _fake_running d-up
    ( sleep 1; kill "$SPID" 2>/dev/null; echo "job-ended" >> "$MOTHER_ROOT/steps.log" ) 3>&- &
    run _mu upgrade --timeout 20
    [ "$status" -eq 0 ]
    local new; new=$("$REAL_GIT" -C "$WORK" rev-parse --short HEAD)
    [ "$new" != "$OLD_SHA" ]
    [[ "$output" == *"$OLD_SHA"* && "$output" == *"$new"* ]]
    ! _drain_on
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
    local seq; seq=$(sed 's/ *drain=.*//' "$MOTHER_ROOT/steps.log" | tr '\n' ',')
    [ "$seq" = "job-ended,pull,build,daemon stop,daemon start,status,limiter status," ]
    # every step from the pull to the status check ran with drain ON
    local line
    while read -r line; do
        case "$line" in pull*|build*|"daemon stop"*|"daemon start"*|status*) [[ "$line" == *"drain=1" ]] || { echo "not drained: $line"; return 1; } ;; esac
    done < "$MOTHER_ROOT/steps.log"
    # the pull happened after the job ended
    [ "$(grep -n '^job-ended' "$MOTHER_ROOT/steps.log" | cut -d: -f1)" -lt "$(grep -n '^pull' "$MOTHER_ROOT/steps.log" | cut -d: -f1)" ]
}

@test "upgrade lands exactly the commits it listed: a commit pushed while it waits is not pulled in" {
    _upgrade_setup; _push_upstream a.txt
    local sha_a; sha_a=$(_origin_head)
    _fake_running d-land
    local out="$MOTHER_ROOT/upgrade.out"
    _upgrade_bg "$out" --timeout 60
    _wait_until 15 grep -q 'drain ON' "$out"
    grep -q 'change a.txt' "$out"
    _push_upstream b.txt
    kill "$SPID"
    _upgrade_reap
    [ "$URC" -eq 0 ]
    [ "$(_head)" = "$sha_a" ]
    ! grep -q 'change b.txt' "$out"
    ! _drain_on
}

@test "upgrade does not rebuild the broker when only non-Go files changed" {
    _upgrade_setup; _push_upstream docs/notes.md
    run _mu upgrade
    [ "$status" -eq 0 ]
    ! grep -q '^build' "$MOTHER_ROOT/steps.log"
    grep -q '^daemon start' "$MOTHER_ROOT/steps.log"
    ! _drain_on
}

@test "upgrade with a failed pull exits non-zero, names the pull step and the git error, and leaves drain on" {
    _upgrade_setup; _push_upstream x.txt
    touch "$MOTHER_ROOT/fail-pull"
    run _mu upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"pull"* ]]
    [[ "$output" == *"fatal: test pull failure"* ]]
    _drain_on
    ! grep -q 'daemon' "$MOTHER_ROOT/steps.log"
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
}

@test "upgrade --dry-run changes nothing" {
    _upgrade_setup; _push_upstream x.txt
    local before; before=$(_head)
    run _mu upgrade --dry-run
    [ "$status" -eq 0 ]
    ! _drain_on
    [ "$(_head)" = "$before" ]
    [ ! -s "$MOTHER_ROOT/steps.log" ]
}

@test "upgrade times out with a job running: exit 3, drain on, nothing pulled, job alive, lock released" {
    _upgrade_setup; _push_upstream x.txt
    _fake_running d-busy
    local before; before=$(_head)
    run _mu upgrade --timeout 1
    [ "$status" -eq 3 ]
    _drain_on
    [ "$(_head)" = "$before" ]
    ! grep -q '^pull' "$MOTHER_ROOT/steps.log"
    kill -0 "$SPID"
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
}

# ---- resume ----

# A new Go file upstream, the pull succeeds, then `daemon start` fails: the first upgrade stops at 'restart'.
_failed_restart_upgrade() {
    _upgrade_setup; _push_upstream plugins/mother/broker/main.go
    OLD_FULL=$(_head)
    touch "$MOTHER_ROOT/fail-start"
    run _mu upgrade
}

@test "upgrade that fails at restart leaves drain on with the pre-pull sha and the failing step recorded" {
    _failed_restart_upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"step 'restart'"* ]]
    _drain_on
    [ "$(jq -r '.upgrade.old_sha' "$RUNNER_DIR/drain.json")" = "$OLD_FULL" ]
    [ "$(jq -r '.upgrade.step' "$RUNNER_DIR/drain.json")" = "restart" ]
    [ "$(_head)" != "$OLD_FULL" ]
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
}

@test "upgrade --resume after a failed restart rebuilds the broker for the commits already pulled, restarts, and undrains" {
    _failed_restart_upgrade
    [ "$status" -ne 0 ]
    : > "$MOTHER_ROOT/steps.log"
    rm -f "$MOTHER_ROOT/fail-start"
    run _mu upgrade --resume
    [ "$status" -eq 0 ]
    [[ "$output" != *"nothing to do"* ]]
    [[ "$output" == *"$OLD_SHA"* ]]
    grep -q '^build' "$MOTHER_ROOT/steps.log"
    grep -q '^daemon stop' "$MOTHER_ROOT/steps.log"
    grep -q '^daemon start' "$MOTHER_ROOT/steps.log"
    ! _drain_on
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
}

@test "a plain upgrade (no --resume) with the flag left by a failed upgrade resumes it too" {
    _failed_restart_upgrade
    [ "$status" -ne 0 ]
    : > "$MOTHER_ROOT/steps.log"
    rm -f "$MOTHER_ROOT/fail-start"
    run _mu upgrade
    [ "$status" -eq 0 ]
    [[ "$output" != *"nothing to do"* ]]
    grep -q '^build' "$MOTHER_ROOT/steps.log"
    grep -q '^daemon start' "$MOTHER_ROOT/steps.log"
    ! _drain_on
}

# ---- one upgrade at a time, and interruption ----

@test "upgrade refuses to start while another upgrade holds the lock: names the owner pid, drains and pulls nothing" {
    _upgrade_setup; _push_upstream x.txt
    sleep 300 >/dev/null 2>&1 3>&- &
    local holder=$!; echo "$holder" >> "$SLEEPPIDS"
    mkdir -p "$RUNNER_DIR/upgrade.lockdir"; echo "$holder" > "$RUNNER_DIR/upgrade.lockdir/owner"
    local before; before=$(_head)
    run _mu upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"already running"* ]]
    [[ "$output" == *"$holder"* ]]
    ! _drain_on
    [ "$(_head)" = "$before" ]
    [ ! -s "$MOTHER_ROOT/steps.log" ]
    # the refused caller must not release someone else's lock
    [ "$(cat "$RUNNER_DIR/upgrade.lockdir/owner")" = "$holder" ]
}

@test "upgrade takes over a lock whose owner pid is dead, and releases it when done" {
    _upgrade_setup; _push_upstream x.txt
    sleep 0.1 >/dev/null 2>&1 3>&- &
    local dead=$!; wait "$dead" 2>/dev/null || true
    mkdir -p "$RUNNER_DIR/upgrade.lockdir"; echo "$dead" > "$RUNNER_DIR/upgrade.lockdir/owner"
    run _mu upgrade
    [ "$status" -eq 0 ]
    [ "$(_head)" = "$(_origin_head)" ]
    ! _drain_on
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
}

@test "SIGTERM during the wait step: says it was interrupted at 'wait', leaves drain on, releases the lock, kills no job" {
    _upgrade_setup; _push_upstream x.txt
    _fake_running d-sig
    local out="$MOTHER_ROOT/upgrade.out" before; before=$(_head)
    _upgrade_bg "$out" --timeout 60
    _wait_until 15 grep -q 'drain ON' "$out"
    sleep 0.6
    kill -TERM "$UPID"
    _upgrade_reap
    [ "$URC" -ne 0 ]
    grep -i 'interrupted' "$out" | grep -q 'wait'
    _drain_on
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
    [ "$(_head)" = "$before" ]
    kill -0 "$SPID"
}

@test "SIGTERM after the daemon was stopped: says the daemon is STOPPED and how to start it, leaves drain on, releases the lock" {
    _upgrade_setup; _push_upstream x.txt
    echo slow > "$MOTHER_ROOT/start-mode"
    local out="$MOTHER_ROOT/upgrade.out"
    _upgrade_bg "$out"
    _wait_until 20 test -f "$MOTHER_ROOT/in-start"
    kill -TERM "$UPID"
    _upgrade_reap
    [ "$URC" -ne 0 ]
    grep -qi 'interrupted' "$out"
    grep -q 'daemon is STOPPED' "$out"
    grep -q 'mother daemon start' "$out"
    _drain_on
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
}

# ---- the checkout upgrade updates must be the one the runner runs from ----

@test "upgrade refuses when MOTHER_BIN_DIR belongs to a different checkout than the code root: names both, drains and pulls nothing" {
    _upgrade_setup; _push_upstream x.txt
    local other="$MOTHER_ROOT/other-clone"
    "$REAL_GIT" clone -q "$ORIGIN" "$other"
    local before top_a top_b; before=$(_head)
    top_a=$("$REAL_GIT" -C "$WORK" rev-parse --show-toplevel)
    top_b=$("$REAL_GIT" -C "$other" rev-parse --show-toplevel)
    run env MOTHER_BIN_DIR="$other/plugins/mother/bin" mother upgrade < /dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"checkout"* ]]
    [[ "$output" == *"$top_a"* ]]
    [[ "$output" == *"$top_b"* ]]
    ! _drain_on
    [ "$(_head)" = "$before" ]
    [ ! -s "$MOTHER_ROOT/steps.log" ]
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
}

# ---- restart is verified, not assumed ----

@test "upgrade fails at 'restart' when the new runner dies right after starting, and leaves drain on" {
    _upgrade_setup; _push_upstream x.txt
    echo die > "$MOTHER_ROOT/start-mode"
    run _mu upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"step 'restart'"* ]]
    _drain_on
    [ ! -e "$RUNNER_DIR/upgrade.lockdir" ]
}

@test "upgrade fails at 'restart' when the runner pid is alive but it never logged 'mother-runner started' (an old log line does not count)" {
    _upgrade_setup; _push_upstream x.txt
    echo nolog > "$MOTHER_ROOT/start-mode"
    echo "[2026-09-01T00:00:00Z] mother-runner started (pid 1, concurrency=2 [default], poll=5s)" > "$RUNNER_DIR/runner.log"
    run _mu upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"step 'restart'"* ]]
    _drain_on
}

@test "upgrade succeeds at restart when the new runner stays alive and logs 'mother-runner started'" {
    _upgrade_setup; _push_upstream x.txt
    echo "[2026-09-01T00:00:00Z] mother-runner started (pid 1, concurrency=2 [default], poll=5s)" > "$RUNNER_DIR/runner.log"
    run _mu upgrade
    [ "$status" -eq 0 ]
    ! _drain_on
    [ "$(grep -c 'mother-runner started' "$RUNNER_DIR/runner.log")" -eq 2 ]
}
