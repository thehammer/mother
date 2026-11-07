#!/usr/bin/env bats
# lock_takeover_serialized.bats — _switch_with_lock serializes stale-lock takeovers behind a
# short-lived <lockdir>.takeover mutex: concurrent takers of a dead owner's lock never end up holding
# the lock together, and a live owner that acquired the path in the middle of a takeover is left alone.

load 'test_helper'

setup() { setup_mother_env; export MOTHER_NOTIFY_TRANSPORT=none; }
teardown() { teardown_mother_env; }

_dead_pid() { sleep 0 & local p=$!; wait "$p"; echo "$p"; }

# Each taker enters the critical section, flags "inside", holds it, and records a violation if
# another holder was already inside.
_taker() {   # <name> <lockdir> <dir>
    cat > "$3/taker.sh" <<'SH'
. "$MOTHER_LIB_DIR/state.sh"
_crit() {
    if [ -e "$D/inside" ]; then echo "$NAME" >> "$D/violations"; fi
    touch "$D/inside"; echo "$NAME" >> "$D/entered"; sleep 1; rm -f "$D/inside"
}
_switch_with_lock "$LOCKDIR" test 400 _crit
SH
}

@test "three takers racing for a dead owner's lock, with a slowed takeover, never hold it together" {
    local d="$BATS_TEST_TMPDIR/tk"; mkdir -p "$d"
    local lockdir="$d/x.lockdir"
    mkdir "$lockdir"; _dead_pid > "$lockdir/owner"
    _taker x "$lockdir" "$d"
    local pids=() n
    for n in a b c; do
        D="$d" NAME="$n" LOCKDIR="$lockdir" MOTHER_TEST_TAKEOVER_DELAY_S=0.5 \
            bash "$d/taker.sh" 2>/dev/null &
        pids+=($!)
    done
    for n in "${pids[@]}"; do wait "$n"; done
    [ ! -s "$d/violations" ]
    [ "$(wc -l < "$d/entered" | tr -d ' ')" = "3" ]
    [ ! -e "$lockdir" ]
    [ ! -e "$lockdir.takeover" ]
}

@test "a live owner that acquires the path mid-takeover is not displaced by a waiting taker" {
    local d="$BATS_TEST_TMPDIR/tk2"; mkdir -p "$d"
    local lockdir="$d/y.lockdir"
    mkdir "$lockdir"; _dead_pid > "$lockdir/owner"
    _taker y "$lockdir" "$d"
    # First taker holds the takeover mutex for a while (slowed judgement); the second queues behind it.
    for n in first second; do
        D="$d" NAME="$n" LOCKDIR="$lockdir" MOTHER_TEST_TAKEOVER_DELAY_S=1 bash "$d/taker.sh" 2>/dev/null &
        pids+=($!)
        sleep 0.2
    done
    for p in "${pids[@]}"; do wait "$p"; done
    [ ! -s "$d/violations" ]
    [ "$(wc -l < "$d/entered" | tr -d ' ')" = "2" ]
}

@test "a takeover mutex left by a dead owner does not block takeovers" {
    local d="$BATS_TEST_TMPDIR/tk3"; mkdir -p "$d"
    local lockdir="$d/z.lockdir"
    mkdir "$lockdir"; _dead_pid > "$lockdir/owner"
    mkdir "$lockdir.takeover"; _dead_pid > "$lockdir.takeover/owner"
    _taker z "$lockdir" "$d"
    D="$d" NAME=only LOCKDIR="$lockdir" run bash "$d/taker.sh"
    [ "$status" -eq 0 ]
    [ "$(cat "$d/entered")" = "only" ]
}
