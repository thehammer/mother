#!/usr/bin/env bats
# job_lock_stale.bats — cancel/retry/resume/priority take <job>.json.lockdir. A lockdir whose recorded
# owner (<lockdir>/owner) is a dead pid must be taken over, so a command killed inside its lock window
# cannot wedge later operator commands. A lockdir held by a live owner must never be stolen.

load 'test_helper'

setup() {
    setup_mother_env
    export MOTHER_NOTIFY_TRANSPORT=none
    LIVE_PID=""
}

teardown() {
    [ -z "$LIVE_PID" ] || kill "$LIVE_PID" 2>/dev/null || true
    teardown_mother_env
}

_dead_pid() { sleep 0 & local p=$!; wait "$p"; echo "$p"; }
_lockdir() { echo "$JOBS_DIR/$1.json.lockdir"; }
_plant_lock() {   # <id> <owner-pid>
    mkdir -p "$(_lockdir "$1")"
    printf '%s\n' "$2" > "$(_lockdir "$1")/owner"
}

@test "cancel takes over a job lock whose owner is dead, succeeds quickly and leaves no lockdir" {
    make_job lk-1 queued
    _plant_lock lk-1 "$(_dead_pid)"
    local t0=$SECONDS
    run mother cancel lk-1
    [ "$status" -eq 0 ]
    [ $((SECONDS - t0)) -le 5 ]
    [ "$(jq -r .state "$JOBS_DIR/lk-1.json")" = "cancelled" ]
    [ ! -e "$(_lockdir lk-1)" ]
}

@test "priority lower takes over a job lock whose owner is dead and leaves no lockdir" {
    make_job lk-2 ready
    _plant_lock lk-2 "$(_dead_pid)"
    local t0=$SECONDS
    run mother priority lk-2 lower
    [ "$status" -eq 0 ]
    [ $((SECONDS - t0)) -le 5 ]
    [ "$(jq -r '.priority_adjust' "$JOBS_DIR/lk-2.json")" = "-1" ]
    [ ! -e "$(_lockdir lk-2)" ]
}

@test "a job lock held by a live owner is not stolen: cancel fails and the lockdir remains" {
    make_job lk-3 queued
    sleep 120 & LIVE_PID=$!
    _plant_lock lk-3 "$LIVE_PID"
    run mother cancel lk-3
    [ "$status" -ne 0 ]
    [ -d "$(_lockdir lk-3)" ]
    [ "$(cat "$(_lockdir lk-3)/owner")" = "$LIVE_PID" ]
    [ "$(jq -r .state "$JOBS_DIR/lk-3.json")" = "queued" ]
}

@test "a live owner holding past MOTHER_QUOTA_LOCK_STALE_S keeps its lock (age never overrides a live owner)" {
    make_job lk-4 queued
    sleep 120 & LIVE_PID=$!
    _plant_lock lk-4 "$LIVE_PID"
    touch -t 200001010000 "$(_lockdir lk-4)"
    export MOTHER_QUOTA_LOCK_STALE_S=1
    run mother cancel lk-4
    [ "$status" -ne 0 ]
    [[ "$output" != *"took over"* ]]
    [ -d "$(_lockdir lk-4)" ]
    [ "$(cat "$(_lockdir lk-4)/owner")" = "$LIVE_PID" ]
    [ "$(jq -r .state "$JOBS_DIR/lk-4.json")" = "queued" ]
}

@test "an owner-less lock older than the stale age is taken over" {
    make_job lk-5 queued
    mkdir -p "$(_lockdir lk-5)"
    touch -t 200001010000 "$(_lockdir lk-5)"
    export MOTHER_QUOTA_LOCK_STALE_S=1
    run mother cancel lk-5
    [ "$status" -eq 0 ]
    [ ! -e "$(_lockdir lk-5)" ]
}

@test "an old owner-less lock replaced mid-takeover by a newer owner-less lock is put back, not discarded" {
    mkdir -p "$MOTHER_ROOT/lk6"
    local ld="$MOTHER_ROOT/lk6/x.lockdir"
    mkdir -p "$ld"
    touch -t 200001010000 "$ld"
    run bash -c '
        source "$1/lib/state.sh"
        ld="$2"
        _file_mtime() {   # the judged mtime is read first; swap the lock right after it
            local m; m=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1")
            if [ "$1" = "$ld" ] && [ ! -e "$ld.swapped" ]; then
                : > "$ld.swapped"; rmdir "$ld"; mkdir "$ld"; : > "$ld/newer-holder"
            fi
            echo "$m"
        }
        MOTHER_QUOTA_LOCK_STALE_S=1
        _switch_with_lock "$ld" test 2 true
        echo "rc=$?"
    ' _ "$MOTHER_PLUGIN_DIR" "$ld"
    [[ "$output" == *"rc=1"* ]]
    [ -f "$ld/newer-holder" ]
}
