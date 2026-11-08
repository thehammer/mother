#!/usr/bin/env bats
# drain.bats — maintenance mode (`mother drain` / `undrain`) and the ordered `mother upgrade`.
#
# Contract: while $RUNNER_DIR/drain.json exists dispatch starts nothing (ready jobs wait, running jobs are
# never touched); only the owner at a terminal can change it; `drain --wait` waits for running jobs and never
# kills them; `mother upgrade` = drain, wait, pull, build, restart, verify, undrain, and leaves drain ON when
# anything fails. Drain older than an hour raises a `drain_stuck` attention item.

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
    # The owner-only guard walks the process ancestry looking for a mother-run-job; a suite run from inside
    # a Mother worker would always look like a worker. Report a clean ancestry (MOTHER_JOB_ID still works).
    printf '#!/usr/bin/env bash\necho "1 bash"\n' > "$_MOCK_BIN/ps"; chmod +x "$_MOCK_BIN/ps"
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

# Start a sleep, register it as a live supervisor in runner/children. Sets SPID.
_fake_running() {
    local jid="$1"
    sleep 300 >/dev/null 2>&1 &
    SPID=$!
    echo "$SPID" >> "$SLEEPPIDS"
    mkdir -p "$RUNNER_DIR/children"
    jq -nc --argjson p "$SPID" --arg j "$jid" '{pid:$p, job_id:$j, started_at:"2026-09-01T00:00:00Z"}' \
        > "$RUNNER_DIR/children/$SPID.json"
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

# ===========================================================================
# Owner-only
# ===========================================================================

@test "drain and upgrade are refused for an agent session, a worker and a non-TTY stdin; flag unchanged" {
    local how cmd
    for how in agent worker notty; do
        for cmd in drain upgrade; do
            ( case "$how" in
                agent)  export CLAUDECODE=1 ;;
                worker) export MOTHER_JOB_ID=j1 ;;
                notty)  unset MOTHER_TEST_FORCE_TTY ;;
              esac
              MOTHER_BIN_DIR="$_BIN_DIR" mother "$cmd" < /dev/null >/dev/null 2>&1 ) && { echo "$cmd allowed for $how"; return 1; }
            ! _drain_on
        done
    done
}

@test "undrain is refused for an agent session, a worker and a non-TTY stdin; flag stays" {
    _write_drain "$(_now_iso)" keep
    local how
    for how in agent worker notty; do
        ( case "$how" in
            agent)  export CLAUDECODE=1 ;;
            worker) export MOTHER_JOB_ID=j1 ;;
            notty)  unset MOTHER_TEST_FORCE_TTY ;;
          esac
          MOTHER_BIN_DIR="$_BIN_DIR" mother undrain < /dev/null >/dev/null 2>&1 ) && { echo "undrain allowed for $how"; return 1; }
        _drain_on
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

# ===========================================================================
# mother upgrade
# ===========================================================================

_upgrade_setup() {
    export MOTHER_CODE_ROOT="$MOTHER_ROOT/code"
    ORIGIN="$MOTHER_ROOT/origin.git"
    WORK="$MOTHER_CODE_ROOT/mother"
    PUSHER="$MOTHER_ROOT/pusher"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
    REAL_GIT=$(command -v git)
    "$REAL_GIT" init -q --bare -b main "$ORIGIN"
    "$REAL_GIT" init -q -b main "$PUSHER"
    mkdir -p "$PUSHER/plugins/mother/scripts"
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

    # CLI stub: logs each call with the drain state; `daemon start` publishes a new live runner pid.
    sleep 300 >/dev/null 2>&1 & echo $! >> "$SLEEPPIDS"; echo $! > "$RUNNER_DIR/runner.pid"
    cat > "$MOTHER_ROOT/cli-stub" <<EOF2
#!/usr/bin/env bash
echo "\$* drain=\$([ -f "$RUNNER_DIR/drain.json" ] && echo 1 || echo 0)" >> "$MOTHER_ROOT/steps.log"
if [ "\$1 \$2" = "daemon start" ]; then
    sleep 300 >/dev/null 2>&1 &
    echo \$! >> "$SLEEPPIDS"; echo \$! > "$RUNNER_DIR/runner.pid"
fi
exit 0
EOF2
    chmod +x "$MOTHER_ROOT/cli-stub"
    export MOTHER_UPGRADE_CLI="$MOTHER_ROOT/cli-stub"

    # git wrapper logging pull (and optionally failing it)
    mkdir -p "$MOTHER_ROOT/gitwrap"
    cat > "$MOTHER_ROOT/gitwrap/git" <<EOF2
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = pull ]; then
    echo "pull drain=\$([ -f "$RUNNER_DIR/drain.json" ] && echo 1 || echo 0)" >> "$MOTHER_ROOT/steps.log"
    [ -f "$MOTHER_ROOT/fail-pull" ] && exit 1
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

@test "upgrade refuses a dirty tree and leaves drain off" {
    _upgrade_setup; _push_upstream x.txt
    echo dirt >> "$WORK/README"
    local before; before=$(_head)
    run _m upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"uncommitted"* ]]
    ! _drain_on
    [ "$(_head)" = "$before" ]
}

@test "upgrade refuses a branch other than main and leaves drain off" {
    _upgrade_setup; _push_upstream x.txt
    "$REAL_GIT" -C "$WORK" checkout -q -b feature
    local before; before=$(_head)
    run _m upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"main"* ]]
    ! _drain_on
    [ "$(_head)" = "$before" ]
}

@test "upgrade with nothing new exits 0, says so, and never drains" {
    _upgrade_setup
    run _m upgrade
    [ "$status" -eq 0 ]
    [[ "$output" == *"nothing"* ]]
    ! _drain_on
    ! grep -q 'daemon' "$MOTHER_ROOT/steps.log"
}

@test "upgrade happy path: drain, wait for the job, pull, build, stop, start, status, undrain" {
    _upgrade_setup; _push_upstream plugins/mother/broker/main.go
    _fake_running d-up
    ( sleep 1; kill "$SPID" 2>/dev/null; echo "job-ended" >> "$MOTHER_ROOT/steps.log" ) &
    run _m upgrade --timeout 20
    [ "$status" -eq 0 ]
    local new; new=$("$REAL_GIT" -C "$WORK" rev-parse --short HEAD)
    [ "$new" != "$OLD_SHA" ]
    [[ "$output" == *"$OLD_SHA"* && "$output" == *"$new"* ]]
    ! _drain_on
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

@test "upgrade does not rebuild the broker when only non-Go files changed" {
    _upgrade_setup; _push_upstream docs/notes.md
    run _m upgrade
    [ "$status" -eq 0 ]
    ! grep -q '^build' "$MOTHER_ROOT/steps.log"
    grep -q '^daemon start' "$MOTHER_ROOT/steps.log"
    ! _drain_on
}

@test "upgrade with a failed pull exits non-zero, names the pull step, and leaves drain on" {
    _upgrade_setup; _push_upstream x.txt
    touch "$MOTHER_ROOT/fail-pull"
    run _m upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *"pull"* ]]
    _drain_on
    ! grep -q 'daemon' "$MOTHER_ROOT/steps.log"
}

@test "upgrade --dry-run changes nothing" {
    _upgrade_setup; _push_upstream x.txt
    local before; before=$(_head)
    run _m upgrade --dry-run
    [ "$status" -eq 0 ]
    ! _drain_on
    [ "$(_head)" = "$before" ]
    [ ! -s "$MOTHER_ROOT/steps.log" ]
}

@test "upgrade times out with a job running: exit 3, drain on, nothing pulled, job alive" {
    _upgrade_setup; _push_upstream x.txt
    _fake_running d-busy
    local before; before=$(_head)
    run _m upgrade --timeout 1
    [ "$status" -eq 3 ]
    _drain_on
    [ "$(_head)" = "$before" ]
    ! grep -q '^pull' "$MOTHER_ROOT/steps.log"
    kill -0 "$SPID"
}
