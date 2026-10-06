#!/usr/bin/env bats
# low_disk_guard.bats — the daemon stops starting NEW work when the disk is nearly full.
#
# Incident shape: worktrees, target/ dirs and docker volumes filled the disk;
# new jobs kept dispatching into a full volume and failed in confusing ways
# (git/npm/cargo "No space left on device"), and nothing told the operator.
#
# Contract under test (bin/mother-runner, via the `--dispatch-tick` seam):
#   * For as long as running children < MOTHER_CONCURRENCY, the next `ready`
#     job is spawned via $MOTHER_BIN_DIR/mother-run-job — UNLESS free space on
#     the volume holding that job's repo_path (`df -kP`, nearest existing parent
#     if the path is gone, then $MOTHER_ROOT) is below MOTHER_MIN_FREE_GB
#     (default 20; env var, or config.env; 0 disables). Exactly the threshold is
#     not low.
#   * Low: the job stays `ready`; $RUNNER_DIR/low-disk.json is written; a
#     `low_disk` needs-attention item "Low disk: <N> GB free, dispatch paused"
#     appears; a `mother gc` hygiene sweep is triggered, rate limited by
#     $RUNNER_DIR/last-lowdisk-gc.ts and MOTHER_LOWDISK_GC_INTERVAL (default 600).
#   * Space recovers: the next tick dispatches, low-disk.json is removed, the
#     item is gone.
#   * Jobs that are already running are never touched.
#   * `--publish-config-tick` reports min_free_gb and its source.

load 'test_helper'

GB_KB=1048576

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_POSTURE_ENABLED=0
    unset MOTHER_MIN_FREE_GB MOTHER_LOWDISK_GC_INTERVAL MOTHER_GC_ENABLED
    export MOTHER_CONCURRENCY=2

    # Fake daemon collaborators, in a dir MOTHER_BIN_DIR points at (as in
    # archive_watchdog.bats). mother-run-job is what `_spawn_job` execs; the
    # fake `mother` receives the hygiene sweep (`mother gc`).
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

    # df shim: header + one data line, free space read from a file so a test
    # can change it between ticks. Arguments are logged.
    cat > "$_MOCK_BIN/df" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${MOTHER_ROOT:?}/df-calls"
kb=$(cat "${MOTHER_ROOT}/df-avail-kb" 2>/dev/null || echo 999999999999)
echo "Filesystem   1024-blocks      Used Available Capacity  Mounted on"
echo "/dev/disk3s1  976490576 900000000 $kb      95%    /"
EOF
    chmod +x "$_MOCK_BIN/df"

    REPO="$MOTHER_ROOT/some-repo"
    mkdir -p "$REPO"
    SLEEP_PID=""
}

teardown() {
    [ -n "${SLEEP_PID:-}" ] && kill "$SLEEP_PID" 2>/dev/null || true
    pkill -f "$_FAKE_BIN/mother" 2>/dev/null || true
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_df_free_gb() { echo $(( $1 * GB_KB )) > "$MOTHER_ROOT/df-avail-kb"; }
_df_free_kb() { echo "$1" > "$MOTHER_ROOT/df-avail-kb"; }

# A ready job whose repo lives at <repo_path> (default $REPO).
_ready_job() {
    local id="$1" repo_path="${2:-$REPO}"
    make_job "$id" "ready" ".repo_path = \"$repo_path\" | .created_at = \"2026-09-01T00:00:00Z\""
}

_dispatch_tick() { mother-runner --dispatch-tick >/dev/null 2>&1 || true; }

# mother-run-job is spawned in the background by the daemon; wait for its
# fake to log.
_wait_for_spawn() {
    local i=0
    while [ ! -s "$MOTHER_ROOT/run-job-calls" ] && [ "$i" -lt 100 ]; do
        sleep 0.1; i=$((i + 1))
    done
    [ -s "$MOTHER_ROOT/run-job-calls" ]
}

_state_of() { jq -r '.state' "$JOBS_DIR/$1.json"; }

_gc_call_count() {
    if [ -f "$MOTHER_ROOT/mother-calls" ]; then
        grep -c '^gc' "$MOTHER_ROOT/mother-calls" || true
    else
        echo 0
    fi
}

# needs_attention items of <kind> from the real CLI (not the fake one).
_attention_kind_count() {
    local out
    out=$(MOTHER_BIN_DIR="$_BIN_DIR" mother status --format json 2>/dev/null)
    printf '%s' "$out" | jq --arg k "$1" '[.needs_attention[] | select(.kind == $k)] | length'
}

_attention_item() {
    local out
    out=$(MOTHER_BIN_DIR="$_BIN_DIR" mother status --format json 2>/dev/null)
    printf '%s' "$out" | jq -c --arg k "$1" '[.needs_attention[] | select(.kind == $k)] | .[0] // empty'
}

# ===========================================================================
# Low disk pauses dispatch
# ===========================================================================

@test "low disk: the next ready job is not spawned and stays ready" {
    _df_free_gb 5
    _ready_job "ld-low"

    _dispatch_tick

    [ "$(_state_of ld-low)" = "ready" ]
    [ ! -e "$MOTHER_ROOT/run-job-calls" ]
}

@test "low disk: low-disk.json records free space, threshold, path and timestamps" {
    _df_free_gb 5
    _ready_job "ld-json"

    _dispatch_tick

    local f="$RUNNER_DIR/low-disk.json"
    [ -f "$f" ]
    [ "$(jq -r '.free_gb' "$f")" = "5" ]
    [ "$(jq -r '.threshold_gb' "$f")" = "20" ]
    [ "$(jq -r '.repo_path' "$f")" = "$REPO" ]
    [ "$(jq -r '.path' "$f")" = "$REPO" ]
    [ -n "$(jq -r '.since // empty' "$f")" ]
    [ -n "$(jq -r '.checked_at // empty' "$f")" ]
}

@test "low disk: free space is read with df -kP on the next ready job's repo_path" {
    _df_free_gb 5
    _ready_job "ld-dfargs"

    _dispatch_tick

    [ -f "$MOTHER_ROOT/df-calls" ]
    grep -Fq -- "-kP $REPO" "$MOTHER_ROOT/df-calls"
}

@test "low disk: mother status lists a low_disk item reading 'Low disk: N GB free, dispatch paused'" {
    _df_free_gb 5
    _ready_job "ld-attn"

    _dispatch_tick

    local item
    item=$(_attention_item low_disk)
    [ -n "$item" ]
    [[ "$(printf '%s' "$item" | jq -r '.reason')" == *"Low disk: 5 GB free, dispatch paused"* ]]
}

@test "low disk: the published attention.json carries the low_disk item too" {
    _df_free_gb 5
    _ready_job "ld-attn-json"
    _dispatch_tick

    MOTHER_ATTENTION_INTERVAL=0 mother-runner --attention-tick >/dev/null 2>&1 || true

    [ -f "$MOTHER_ROOT/attention.json" ]
    [ "$(jq '[.[] | select(.kind == "low_disk")] | length' "$MOTHER_ROOT/attention.json")" = "1" ]
}

@test "low disk: the pause is announced once, not duplicated by repeat ticks" {
    _df_free_gb 5
    _ready_job "ld-once"

    _dispatch_tick
    _dispatch_tick
    _dispatch_tick

    [ "$(_attention_kind_count low_disk)" = "1" ]
    [ "$(jq -r '.since' "$RUNNER_DIR/low-disk.json")" != "" ]
}

# ---------------------------------------------------------------------------
# Hygiene sweep trigger
# ---------------------------------------------------------------------------

@test "low disk: triggers one hygiene sweep (mother gc) and records the rate-limit marker" {
    _df_free_gb 5
    _ready_job "ld-gc"

    _dispatch_tick

    [ "$(_gc_call_count)" = "1" ]
    [ -f "$RUNNER_DIR/last-lowdisk-gc.ts" ]
}

@test "low disk: a second tick inside MOTHER_LOWDISK_GC_INTERVAL does not run gc again" {
    _df_free_gb 5
    _ready_job "ld-gc-rate"

    MOTHER_LOWDISK_GC_INTERVAL=600 _dispatch_tick
    MOTHER_LOWDISK_GC_INTERVAL=600 _dispatch_tick
    MOTHER_LOWDISK_GC_INTERVAL=600 _dispatch_tick

    [ "$(_gc_call_count)" = "1" ]
}

@test "low disk: with MOTHER_LOWDISK_GC_INTERVAL=0 every low tick runs gc" {
    _df_free_gb 5
    _ready_job "ld-gc-every"

    MOTHER_LOWDISK_GC_INTERVAL=0 _dispatch_tick
    MOTHER_LOWDISK_GC_INTERVAL=0 _dispatch_tick

    [ "$(_gc_call_count)" = "2" ]
}

@test "enough free disk: no hygiene sweep is triggered by dispatch" {
    _df_free_gb 500
    _ready_job "ld-nogc"

    _dispatch_tick
    _wait_for_spawn

    [ "$(_gc_call_count)" = "0" ]
}

# ===========================================================================
# Recovery
# ===========================================================================

@test "space recovers: the next tick dispatches the job, clears low-disk.json and the attention item" {
    _df_free_gb 5
    _ready_job "ld-recover"
    _dispatch_tick
    [ "$(_state_of ld-recover)" = "ready" ]
    [ -f "$RUNNER_DIR/low-disk.json" ]
    [ "$(_attention_kind_count low_disk)" = "1" ]

    _df_free_gb 200
    _dispatch_tick

    [ "$(_state_of ld-recover)" = "running" ]
    _wait_for_spawn
    grep -Fq "ld-recover" "$MOTHER_ROOT/run-job-calls"
    [ ! -e "$RUNNER_DIR/low-disk.json" ]
    [ "$(_attention_kind_count low_disk)" = "0" ]
}

@test "plenty of free disk: the job dispatches normally" {
    _df_free_gb 500
    _ready_job "ld-plenty"

    _dispatch_tick

    [ "$(_state_of ld-plenty)" = "running" ]
    _wait_for_spawn
    grep -Fq "ld-plenty" "$MOTHER_ROOT/run-job-calls"
    [ ! -e "$RUNNER_DIR/low-disk.json" ]
}

# ===========================================================================
# Running jobs are never touched
# ===========================================================================

@test "low disk never pauses, kills or transitions a job that is already running" {
    sleep 120 &
    SLEEP_PID=$!
    make_job "ld-running" "running" \
        ".repo_path = \"$REPO\" | .worker_pid = $SLEEP_PID | .started_at = \"2026-09-01T00:00:00Z\""
    _ready_job "ld-waiting"
    _df_free_gb 1
    local before; before=$(cksum < "$JOBS_DIR/ld-running.json")

    _dispatch_tick
    _dispatch_tick

    [ "$(_state_of ld-running)" = "running" ]
    [ "$(cksum < "$JOBS_DIR/ld-running.json")" = "$before" ]
    kill -0 "$SLEEP_PID"
    [ "$(_state_of ld-waiting)" = "ready" ]
}

# ===========================================================================
# Threshold configuration
# ===========================================================================

@test "MOTHER_MIN_FREE_GB=0 disables the guard even when df reports almost nothing free" {
    _df_free_kb 1024
    _ready_job "ld-off"

    MOTHER_MIN_FREE_GB=0 _dispatch_tick

    [ "$(_state_of ld-off)" = "running" ]
    [ ! -e "$RUNNER_DIR/low-disk.json" ]
    [ "$(_attention_kind_count low_disk)" = "0" ]
}

@test "MOTHER_MIN_FREE_GB from the environment raises the threshold" {
    _df_free_gb 30
    _ready_job "ld-env"

    MOTHER_MIN_FREE_GB=50 _dispatch_tick

    [ "$(_state_of ld-env)" = "ready" ]
    [ "$(jq -r '.threshold_gb' "$RUNNER_DIR/low-disk.json")" = "50" ]
}

@test "the default threshold is 20 GB: 30 GB free dispatches, 19 GB free does not" {
    _df_free_gb 30
    _ready_job "ld-default-ok"
    _dispatch_tick
    [ "$(_state_of ld-default-ok)" = "running" ]

    _df_free_gb 19
    _ready_job "ld-default-low"
    _dispatch_tick
    [ "$(_state_of ld-default-low)" = "ready" ]
}

@test "free space exactly at the threshold is not low" {
    _df_free_gb 20
    _ready_job "ld-boundary"

    _dispatch_tick

    [ "$(_state_of ld-boundary)" = "running" ]
    [ ! -e "$RUNNER_DIR/low-disk.json" ]
}

@test "MOTHER_MIN_FREE_GB is also read from config.env when the environment does not set it" {
    _df_free_gb 30
    _ready_job "ld-conf"
    echo "MOTHER_MIN_FREE_GB=50" > "$MOTHER_ROOT/config.env"

    _dispatch_tick

    [ "$(_state_of ld-conf)" = "ready" ]
    [ "$(jq -r '.threshold_gb' "$RUNNER_DIR/low-disk.json")" = "50" ]
}

@test "the environment wins over config.env for MOTHER_MIN_FREE_GB" {
    _df_free_kb 1024
    _ready_job "ld-envwins"
    echo "MOTHER_MIN_FREE_GB=50" > "$MOTHER_ROOT/config.env"

    MOTHER_MIN_FREE_GB=0 _dispatch_tick

    [ "$(_state_of ld-envwins)" = "running" ]
}

# ===========================================================================
# df path resolution
# ===========================================================================

@test "a repo_path that no longer exists is measured on its nearest existing parent" {
    _df_free_gb 500
    _ready_job "ld-gone" "$MOTHER_ROOT/missing/deeper/repo"

    _dispatch_tick

    [ "$(_state_of ld-gone)" = "running" ]
    local last_arg
    last_arg=$(tail -n1 "$MOTHER_ROOT/df-calls" | awk '{print $NF}')
    [ "$last_arg" = "$MOTHER_ROOT" ]
}

@test "a job with no usable repo_path is still measured (on MOTHER_ROOT) rather than crashing the tick" {
    _df_free_gb 5
    make_job "ld-norepo" "ready" '.repo_path = "" | .created_at = "2026-09-01T00:00:00Z"'

    _dispatch_tick

    [ "$(_state_of ld-norepo)" = "ready" ]
    [ -f "$MOTHER_ROOT/df-calls" ]
    [ -f "$RUNNER_DIR/low-disk.json" ]
}

# ===========================================================================
# Effective config
# ===========================================================================

_publish_min_free() {
    # What a freshly started runner resolves, as "<value>|<source>".
    mother-runner --publish-config-tick >/dev/null 2>&1
    jq -r '"\(.min_free_gb)|\(.min_free_gb_source)"' "$RUNNER_DIR/effective-config.json"
}

@test "effective-config.json reports min_free_gb as 20 from the default" {
    run _publish_min_free
    [ "$status" -eq 0 ]
    [ "$output" = "20|default" ]
}

@test "effective-config.json reports min_free_gb from the environment" {
    export MOTHER_MIN_FREE_GB=7
    run _publish_min_free
    [ "$status" -eq 0 ]
    [ "$output" = "7|env" ]
}

@test "effective-config.json reports min_free_gb from config.env" {
    echo "MOTHER_MIN_FREE_GB=35" > "$MOTHER_ROOT/config.env"
    run _publish_min_free
    [ "$status" -eq 0 ]
    [ "$output" = "35|config file" ]
}
