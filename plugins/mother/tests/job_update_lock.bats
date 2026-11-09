#!/usr/bin/env bats
# job_update_lock.bats — a job-document read-modify-write must be atomic against a concurrent writer.
#
# The supervisor's poll loop writes live_cost_usd / final_result_at while the worker runs `mother await`.
# With an unlocked read-modify-write (jq read, then write the whole document back) the supervisor can read
# the document, `mother await` can write state=awaiting, and the supervisor's write then puts state=running
# back: the await is lost and the job is finalised `succeeded`. MOTHER_TEST_JOB_UPDATE_DELAY_S (honoured only
# under MOTHER_TEST_ROOT=1) sleeps between the read and the write so the bad interleaving is forced.

load 'test_helper'

MOTHER_RUN_JOB="$_BIN_DIR/mother-run-job"

setup() { setup_mother_env; }
teardown() { teardown_mother_env; }

# _await_during_update <helper-script> — run a delayed update in the background, `mother await` while it is
# between its read and its write, then wait for both.
_await_during_update() {
    local id="$1" updater="$2" t0 t1
    t0=$(date +%s)
    ( MOTHER_TEST_JOB_UPDATE_DELAY_S=3 bash -c "$updater" _ "$id" ) & local bg=$!
    sleep 1
    MOTHER_JOB_ID="$id" mother await --question "need clarification" >/dev/null 2>&1 || true
    wait "$bg"
    t1=$(date +%s)
    # Not vacuous: the updater must really have slept in the read-to-write window (the seam exists), or the
    # bad interleaving was never forced and a pass proves nothing (on main, without the seam, it "passes").
    [ $(( t1 - t0 )) -ge 3 ] || { echo "the test seam MOTHER_TEST_JOB_UPDATE_DELAY_S did not delay the update" >&2; return 1; }
}

@test "supervisor _job_update racing an in-agent mother await: the await is not lost" {
    local id="ju-sup"
    make_job "$id" running
    _await_during_update "$id" '
        export SOURCE_ONLY=1
        source "'"$MOTHER_RUN_JOB"'" 2>/dev/null || true
        id="$1"; job_file="$JOBS_DIR/$id.json"
        _job_update ".live_cost_usd = 1.5 | .live_tokens = 7"'
    [ "$(jq -r .state "$JOBS_DIR/$id.json")" = "awaiting" ]
    [ "$(jq -r .live_cost_usd "$JOBS_DIR/$id.json")" = "1.5" ]
}

@test "mother_job_update racing an in-agent mother await (legacy path): the await is not lost" {
    local id="ju-lib"
    make_job "$id" running
    _await_during_update "$id" '
        source "'"$_LIB_DIR"'/state.sh"
        mother_job_update "$1" ".live_cost_usd = 2.5"'
    [ "$(jq -r .state "$JOBS_DIR/$id.json")" = "awaiting" ]
    [ "$(jq -r .live_cost_usd "$JOBS_DIR/$id.json")" = "2.5" ]
}

@test "supervisor _job_update that cannot get the lock: dropped loudly (stderr and a job_update_lock_failed event), within its try bound" {
    local id="ju-wedge"
    make_job "$id" running
    mkdir "$JOBS_DIR/$id.json.lockdir"
    echo "$$" > "$JOBS_DIR/$id.json.lockdir/owner"   # a live holder (this shell) that never lets go
    run bash -c '
        export SOURCE_ONLY=1
        source "'"$MOTHER_RUN_JOB"'" 2>/dev/null || true
        id="'"$id"'"; job_file="$JOBS_DIR/$id.json"
        _job_update_n 3 ".live_cost_usd = 9"'
    [ "$status" -ne 0 ]
    [[ "$output" == *"lock not acquired after 3 tries"* ]]
    grep -q '"kind":"job_update_lock_failed"' "$EVENTS_DIR/$id.jsonl"
    [ "$(jq -r '.live_cost_usd // "unset"' "$JOBS_DIR/$id.json")" != "9" ]
    rmdir "$JOBS_DIR/$id.json.lockdir" 2>/dev/null || { rm -f "$JOBS_DIR/$id.json.lockdir/owner"; rmdir "$JOBS_DIR/$id.json.lockdir"; }
}
