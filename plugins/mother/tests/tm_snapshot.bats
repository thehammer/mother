#!/usr/bin/env bats
# tm_snapshot.bats — Time Machine hygiene around Mother's disk use.
#
# Contract under test:
#   A) Thin (mother-runner, via `--dispatch-tick`): with a ready job and free space
#      below MOTHER_SNAPSHOT_THIN_BELOW_GB (default 40), the daemon runs
#      `tmutil thinlocalsnapshots / 999999999999 4` in the BACKGROUND at most once per
#      MOTHER_SNAPSHOT_THIN_INTERVAL (default 1800), bounded by
#      MOTHER_SNAPSHOT_THIN_TIMEOUT. BELOW_GB=0 disables. It never deletes snapshots,
#      never blocks or stops dispatch, records $RUNNER_DIR/snapshot-thin.json and
#      `mother status` shows "Last snapshot thin:".
#   B) Exclusion (mother-run-job): a freshly created job worktree (never the main
#      checkout) is excluded with `tmutil addexclusion <worktree>`;
#      MOTHER_TM_EXCLUDE_WORKTREES=0 disables; a failing tmutil changes nothing.
#
# tmutil is always a stub on $_MOCK_BIN; the real one is never reached.

bats_require_minimum_version 1.5.0
load 'test_helper'

GB_KB=1048576

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_POSTURE_ENABLED=0
    unset MOTHER_LOWDISK_GC_INTERVAL MOTHER_GC_ENABLED \
          MOTHER_SNAPSHOT_THIN_BELOW_GB MOTHER_SNAPSHOT_THIN_INTERVAL \
          MOTHER_SNAPSHOT_THIN_TIMEOUT MOTHER_TM_EXCLUDE_WORKTREES
    export MOTHER_CONCURRENCY=10
    export MOTHER_SNAPSHOT_THIN_TIMEOUT=20
    # Keep the low-disk pause out of the way so dispatch is observable at 30 GB.
    export MOTHER_MIN_FREE_GB=5

    _FAKE_BIN="$MOTHER_ROOT/fake-bin"
    mkdir -p "$_FAKE_BIN"
    export MOTHER_BIN_DIR="$_FAKE_BIN"
    cat > "$_FAKE_BIN/mother-run-job" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$MOTHER_ROOT/run-job-calls"
exit 0
EOF
    cat > "$_FAKE_BIN/mother" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$MOTHER_ROOT/mother-calls"
exit 0
EOF
    chmod +x "$_FAKE_BIN/mother-run-job" "$_FAKE_BIN/mother"

    cat > "$_MOCK_BIN/df" <<'EOF'
#!/usr/bin/env bash
kb=$(cat "${MOTHER_ROOT}/df-avail-kb" 2>/dev/null || echo 999999999999)
echo "Filesystem   1024-blocks      Used Available Capacity  Mounted on"
echo "/dev/disk3s1  976490576 900000000 $kb      95%    /"
EOF
    chmod +x "$_MOCK_BIN/df"

    TM_LOG="$MOTHER_ROOT/tmutil-calls"
    _tmutil_stub
    REPO="$MOTHER_ROOT/some-repo"
    mkdir -p "$REPO"
}

teardown() { teardown_mother_env; }

# tmutil stub: logs args; mode file = ok (default) | fail | hang (thin only).
# `exec sleep` keeps the stub's pid == the sleeping process so a kill by pid works.
_tmutil_stub() {
    cat > "$_MOCK_BIN/tmutil" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TM_LOG"
mode=\$(cat "$MOTHER_ROOT/tm-mode" 2>/dev/null || echo ok)
case "\$1" in
    thinlocalsnapshots|addexclusion)
        case "\$mode" in
            fail) echo "tmutil: boom" >&2; exit 1 ;;
            hang) [ "\$1" = thinlocalsnapshots ] && exec sleep 60 ;;
        esac ;;
esac
exit 0
EOF
    chmod +x "$_MOCK_BIN/tmutil"
}

_tm_mode() { echo "$1" > "$MOTHER_ROOT/tm-mode"; }
_df_free_gb() { echo $(( $1 * GB_KB )) > "$MOTHER_ROOT/df-avail-kb"; }
_ready_job() {
    make_job "$1" "ready" ".repo_path = \"$REPO\" | .created_at = \"2026-09-01T00:00:00Z\""
}
# 3>&- : the implementation's background watchdog sleeps would otherwise hold bats' fd 3 open.
_dispatch_tick() { mother-runner --dispatch-tick >/dev/null 2>&1 3>&- || true; }
_state_of() { jq -r '.state' "$JOBS_DIR/$1.json"; }

_wait_for() { # <file> — wait for a non-empty file
    local i=0
    while [ ! -s "$1" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    [ -s "$1" ]
}
_thin_calls() { { grep -c '^thinlocalsnapshots' "$TM_LOG" 2>/dev/null || true; } | grep . || echo 0; }
_age_marker() { echo 1 > "$RUNNER_DIR/last-snapshot-thin.ts"; }

# ===========================================================================
# A) Thin
# ===========================================================================

@test "thin: below the 40 GB default, tmutil thinlocalsnapshots / 999999999999 4 runs" {
    _df_free_gb 30
    _ready_job "th-low"

    _dispatch_tick

    _wait_for "$TM_LOG"
    grep -qxF 'thinlocalsnapshots / 999999999999 4' "$TM_LOG"
}

@test "thin: at exactly the threshold or above, tmutil is not called" {
    _ready_job "th-ok"
    _df_free_gb 40
    _dispatch_tick
    _df_free_gb 300
    _dispatch_tick
    sleep 1
    [ "$(_thin_calls)" = "0" ]
    [ ! -e "$RUNNER_DIR/snapshot-thin.json" ]
}

@test "thin: MOTHER_SNAPSHOT_THIN_BELOW_GB overrides the threshold" {
    _df_free_gb 60
    _ready_job "th-env"
    MOTHER_SNAPSHOT_THIN_BELOW_GB=80 _dispatch_tick
    _wait_for "$TM_LOG"
    [ "$(_thin_calls)" = "1" ]
}

@test "thin: MOTHER_SNAPSHOT_THIN_BELOW_GB=0 disables it" {
    _df_free_gb 1
    _ready_job "th-off"
    MOTHER_SNAPSHOT_THIN_BELOW_GB=0 _dispatch_tick
    sleep 1
    [ "$(_thin_calls)" = "0" ]
}

@test "thin: is rate limited by the interval across ticks and runs again once the marker is old" {
    _df_free_gb 30
    _ready_job "th-rate"

    _dispatch_tick
    _wait_for "$RUNNER_DIR/snapshot-thin.json"
    # Each later tick needs a ready job (the disk check only runs for one).
    _ready_job "th-rate-2"
    _dispatch_tick
    _ready_job "th-rate-3"
    _dispatch_tick
    sleep 1
    [ "$(_thin_calls)" = "1" ]
    [ -f "$RUNNER_DIR/last-snapshot-thin.ts" ]

    _age_marker
    rm -f "$RUNNER_DIR/snapshot-thin.json"
    _ready_job "th-rate-4"
    _dispatch_tick
    _wait_for "$RUNNER_DIR/snapshot-thin.json"
    [ "$(_thin_calls)" = "2" ]
}

@test "thin: never deletes local snapshots" {
    _df_free_gb 30
    _ready_job "th-nodel"
    _dispatch_tick
    _wait_for "$RUNNER_DIR/snapshot-thin.json"
    ! grep -qi 'delete' "$TM_LOG"
}

@test "thin: success writes snapshot-thin.json with exit 0 and mother status prints 'Last snapshot thin:'" {
    _df_free_gb 30
    _ready_job "th-ok-json"
    _dispatch_tick
    _wait_for "$RUNNER_DIR/snapshot-thin.json"

    [ "$(jq -r '.exit' "$RUNNER_DIR/snapshot-thin.json")" = "0" ]
    [ -n "$(jq -r '.at // empty' "$RUNNER_DIR/snapshot-thin.json")" ]

    run env MOTHER_BIN_DIR="$_BIN_DIR" mother status
    [ "$status" -eq 0 ]
    [[ "$output" == *"Last snapshot thin:"* ]]
}

@test "thin: a failing tmutil is recorded with its exit code and does not stop dispatch" {
    _df_free_gb 30
    _tm_mode fail
    _ready_job "th-fail"

    _dispatch_tick

    _wait_for "$RUNNER_DIR/snapshot-thin.json"
    [ "$(jq -r '.exit' "$RUNNER_DIR/snapshot-thin.json")" = "1" ]
    [ "$(_state_of th-fail)" = "running" ]
    _wait_for "$MOTHER_ROOT/run-job-calls"
}

@test "thin: a hanging tmutil does not block the tick and is killed after MOTHER_SNAPSHOT_THIN_TIMEOUT" {
    _df_free_gb 30
    _tm_mode hang
    _ready_job "th-hang"

    local t0 t1
    t0=$(date +%s)
    MOTHER_SNAPSHOT_THIN_TIMEOUT=1 _dispatch_tick
    t1=$(date +%s)

    [ $((t1 - t0)) -lt 15 ]
    [ "$(_state_of th-hang)" = "running" ]

    _wait_for "$RUNNER_DIR/snapshot-thin.json"
    [ "$(jq -r '.exit' "$RUNNER_DIR/snapshot-thin.json")" -ne 0 ]
}

# ===========================================================================
# B) Exclusion in mother-run-job
# ===========================================================================

_xr_setup_repo() {
    ORIGIN="$MOTHER_ROOT/origin.git"
    XREPO="$MOTHER_ROOT/work/xrepo"
    mkdir -p "$XREPO"
    git init -q --bare "$ORIGIN"
    (
        cd "$XREPO"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        git add . && git commit -q -m init
        git remote add origin "$ORIGIN"
        git push -q -u origin main
    ) >/dev/null 2>&1
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo hi > worker.txt
git add worker.txt
git commit -q -m "worker change"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}'
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/gh" "$_MOCK_BIN/claude"
}

# _xr_run — add a no_pr worktree job and run it once; sets ID.
_xr_run() {
    export MOTHER_BIN_DIR="$_BIN_DIR"
    export MOTHER_IDLE_REAP_SECONDS=120 MOTHER_RESULT_GRACE_SECONDS=120
    cat > "$MOTHER_ROOT/plan.md" <<'PLAN'
# Plan

## Target
- **Repo:** xrepo

```yaml
suggested_config:
  cody: {model: sonnet, effort: medium, rationale: "x"}
  redd: {model: sonnet, effort: medium, rationale: "x"}
  marty: {model: sonnet, effort: medium, rationale: "x"}
  perri: {model: sonnet, effort: medium, rationale: "x"}
no_pr: true
```
PLAN
    run mother add --plan-file "$MOTHER_ROOT/plan.md" --repo xrepo \
        --repo-path "$XREPO" --branch feature/tm --base origin/main
    [ "$status" -eq 0 ]
    ID=$(printf '%s\n' "$output" | tail -1)
    jq '.state = "ready"' "$JOBS_DIR/$ID.json" > "$JOBS_DIR/$ID.tmp" && mv "$JOBS_DIR/$ID.tmp" "$JOBS_DIR/$ID.json"
    run mother-run-job "$ID" 3>&-
}

@test "exclusion: the new job worktree is excluded via tmutil addexclusion, the main checkout never" {
    _xr_setup_repo
    _xr_run

    local wt; wt=$(jq -r '.work_dir' "$JOBS_DIR/$ID.json")
    [ -n "$wt" ] && [ "$wt" != "null" ] && [ "$wt" != "$XREPO" ]
    grep -qxF "addexclusion $wt" "$TM_LOG"
    ! grep -qxF "addexclusion $XREPO" "$TM_LOG"
    ! grep -q "^addexclusion .*-p" "$TM_LOG"
}

@test "exclusion: MOTHER_TM_EXCLUDE_WORKTREES=0 never calls tmutil" {
    _xr_setup_repo
    export MOTHER_TM_EXCLUDE_WORKTREES=0
    _xr_run

    [ -n "$(jq -r '.work_dir // empty' "$JOBS_DIR/$ID.json")" ]
    [ ! -e "$TM_LOG" ] || ! grep -q '^addexclusion' "$TM_LOG"
}

@test "exclusion: a failing tmutil does not change the job's outcome" {
    _xr_setup_repo
    _xr_run
    local want_state want_reason
    want_state=$(jq -r '.state' "$JOBS_DIR/$ID.json")
    want_reason=$(jq -r '.failure_reason // ""' "$JOBS_DIR/$ID.json")
    git -C "$XREPO" worktree remove --force "$(jq -r '.work_dir' "$JOBS_DIR/$ID.json")"
    git -C "$XREPO" branch -q -D feature/tm
    : > "$TM_LOG"

    _tm_mode fail
    _xr_run

    grep -q '^addexclusion' "$TM_LOG"
    [ "$(jq -r '.failure_reason // ""' "$JOBS_DIR/$ID.json")" != "worktree_create_failed" ]
    [ "$(jq -r '.state' "$JOBS_DIR/$ID.json")" = "$want_state" ]
    [ "$(jq -r '.failure_reason // ""' "$JOBS_DIR/$ID.json")" = "$want_reason" ]
}
