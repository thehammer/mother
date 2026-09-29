#!/usr/bin/env bats
# autostash.bats — the operator's stashed working state must ALWAYS come back.
#
# A main-dir job auto-stashes the operator's uncommitted/untracked work before
# it touches the shared checkout (marker at $RUNNER_DIR/<id>.stash: line 1 =
# stash message, line 2 = the branch the operator was on). Historically the
# restore only happened on the happy path at the end of a run; a job that
# failed early (branch_create_failed / checkout_failed) or whose supervisor
# was killed left the operator's work stranded in `git stash list` (incident:
# job 20260926T215255Z-d23375c8).
#
# Contract under test:
#   lib/autostash.sh   mother_autostash_restore <work_dir> <marker_file>
#                        -> prints ONE compact JSON object, returns 0:
#                           {outcome, stash_message, original_branch, stash_ref}
#                           outcome: restored | restore_failed | stash_not_found | none
#   bin/mother-run-job _restore_auto_stash, _exit_cleanup_workspace (pre-guard,
#                        reachable via SOURCE_ONLY=1)
#   bin/mother-runner  _recover_orphans restores the stash of a reaped main-dir job
#
# Everything here is expected to FAIL until the feature exists.

load 'test_helper'

MOTHER_RUN_JOB="$_BIN_DIR/mother-run-job"

setup() {
    setup_mother_env
    export MOTHER_POSTURE_ENABLED=0
    # Never inherit a kill switch from the developer's shell.
    unset MOTHER_TEARDOWN_ENABLED
}

teardown() {
    [ -n "${_STANDIN_PID:-}" ] && kill "$_STANDIN_PID" 2>/dev/null || true
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# A repo on `main` with one committed file. Usage: _as_mk_repo <dir> [bare_origin_dir]
_as_mk_repo() {
    local dir="$1" bare="${2:-}"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    echo "base" > "$dir/tracked.txt"
    git -C "$dir" add tracked.txt
    git -C "$dir" commit -q -m init
    git -C "$dir" branch -M main
    if [ -n "$bare" ]; then
        git init -q --bare "$bare"
        git -C "$dir" remote add origin "$bare"
        git -C "$dir" push -q origin main
    fi
}

# Dirty the operator's checkout the way the incident did (tracked edit + an
# untracked directory), without stashing. Usage: _as_make_dirty <repo>
_as_make_dirty() {
    echo "edited-by-operator" > "$1/tracked.txt"
    mkdir -p "$1/wip"
    echo "operator notes" > "$1/wip/notes.md"
}

# Stash the dirty state under the job-keyed message and write the marker,
# exactly as mother-run-job does. Usage: _as_stash_operator_work <repo> <id>
_as_stash_operator_work() {
    local repo="$1" id="$2" msg="mother:auto-stash:$2"
    _as_make_dirty "$repo"
    git -C "$repo" stash push -q --include-untracked -m "$msg"
    printf '%s\n%s\n' "$msg" "main" > "$RUNNER_DIR/$id.stash"
}

_as_assert_operator_work_back() {
    local repo="$1"
    [ "$(cat "$repo/tracked.txt")" = "edited-by-operator" ]
    [ -f "$repo/wip/notes.md" ]
    [ "$(cat "$repo/wip/notes.md")" = "operator notes" ]
}

_as_assert_no_job_stash_left() {
    local repo="$1" list
    list=$(git -C "$repo" stash list)
    case "$list" in *"mother:auto-stash:"*) echo "stash still present: $list" >&2; return 1 ;; esac
    return 0
}

# Run mother_autostash_restore in a strict (set -u) subshell, stdout only.
_as_restore() {
    bash -uc 'source "$1" && mother_autostash_restore "$2" "$3"' _ \
        "$_LIB_DIR/autostash.sh" "$1" "$2" 2>/dev/null
}

_as_lock_file() {
    bash -c 'source "$1"; lock_get_file "$2"' _ "$_LIB_DIR/locks.sh" "$1"
}

# Load mother-run-job's pre-guard functions plus the libs a real run sources
# after the guard, and give iso_now something to call.
_as_load_run_job() {
    SOURCE_ONLY=1 source "$MOTHER_RUN_JOB" 2>/dev/null || true
    type _iso_now >/dev/null 2>&1 || _iso_now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
    source "$_LIB_DIR/locks.sh"
    source "$_LIB_DIR/autostash.sh"
}

_as_event_count() {
    local id="$1" kind="$2"
    local n
    n=$(grep -c "\"kind\":\"$kind\"" "$EVENTS_DIR/$id.jsonl" 2>/dev/null || true)
    echo "${n:-0}"
}

# A main-dir job shaped like 20260926T215255Z-d23375c8: base_ref that doesn't
# exist on origin, and a branch that doesn't exist yet.
# Usage: _as_make_main_dir_job <id> <repo_dir> <repo_name> <branch> <base_ref>
_as_make_main_dir_job() {
    local id="$1" repo_dir="$2" repo_name="$3" branch="$4" base_ref="$5"
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo = "'"$repo_name"'"
         | .repo_path = "'"$repo_dir"'"
         | .base_ref = "'"$base_ref"'"
         | .branch = "'"$branch"'"
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
}

# ===========================================================================
# mother_autostash_restore — the four outcomes
# ===========================================================================

@test "mother_autostash_restore: outcome=restored puts the operator's work back on their original branch and clears the marker" {
    local repo="$MOTHER_ROOT/as-lib-restored" id="as-lib-1"
    _as_mk_repo "$repo"
    _as_stash_operator_work "$repo" "$id"
    # The worker left the checkout on the job's branch.
    git -C "$repo" checkout -q -b "feature/$id"

    run _as_restore "$repo" "$RUNNER_DIR/$id.stash"
    [ "$status" -eq 0 ]

    # One compact JSON object on one line.
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
    printf '%s' "$output" | jq -e 'type == "object"' >/dev/null
    [ "$(printf '%s' "$output" | jq -r '.outcome')" = "restored" ]
    [ "$(printf '%s' "$output" | jq -r '.stash_message')" = "mother:auto-stash:$id" ]
    [ "$(printf '%s' "$output" | jq -r '.original_branch')" = "main" ]

    _as_assert_operator_work_back "$repo"
    [ "$(git -C "$repo" rev-parse --abbrev-ref HEAD)" = "main" ]
    _as_assert_no_job_stash_left "$repo"
    [ ! -f "$RUNNER_DIR/$id.stash" ]
}

@test "mother_autostash_restore: outcome=restore_failed leaves the stash in place (never discards work) but still removes the marker" {
    local repo="$MOTHER_ROOT/as-lib-failed" id="as-lib-2"
    _as_mk_repo "$repo"
    _as_stash_operator_work "$repo" "$id"
    # A conflicting uncommitted edit to the same tracked file blocks the pop.
    echo "conflicting-edit" > "$repo/tracked.txt"

    run _as_restore "$repo" "$RUNNER_DIR/$id.stash"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.outcome')" = "restore_failed" ]
    [ "$(printf '%s' "$output" | jq -r '.stash_message')" = "mother:auto-stash:$id" ]
    [ -n "$(printf '%s' "$output" | jq -r '.stash_ref // empty')" ]

    # The operator's work is still recoverable from the stash.
    run git -C "$repo" stash list
    [[ "$output" == *"mother:auto-stash:$id"* ]]
    # The unrelated conflicting edit was not clobbered.
    [ "$(cat "$repo/tracked.txt")" = "conflicting-edit" ]
    [ ! -f "$RUNNER_DIR/$id.stash" ]
}

@test "mother_autostash_restore: outcome=stash_not_found when the marker names a stash that no longer exists" {
    local repo="$MOTHER_ROOT/as-lib-notfound" id="as-lib-3"
    _as_mk_repo "$repo"
    printf '%s\n%s\n' "mother:auto-stash:$id" "main" > "$RUNNER_DIR/$id.stash"

    run _as_restore "$repo" "$RUNNER_DIR/$id.stash"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.outcome')" = "stash_not_found" ]
    [ "$(printf '%s' "$output" | jq -r '.stash_message')" = "mother:auto-stash:$id" ]
    [ ! -f "$RUNNER_DIR/$id.stash" ]
}

@test "mother_autostash_restore: outcome=none when there is no marker, and nothing is touched" {
    local repo="$MOTHER_ROOT/as-lib-none" id="as-lib-4"
    _as_mk_repo "$repo"
    _as_make_dirty "$repo"
    local before; before=$(git -C "$repo" status --porcelain)

    run _as_restore "$repo" "$RUNNER_DIR/$id.stash"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.outcome')" = "none" ]
    [ "$(git -C "$repo" status --porcelain)" = "$before" ]
}

@test "mother_autostash_restore: safe to call twice — the second call is a 'none' no-op" {
    local repo="$MOTHER_ROOT/as-lib-twice" id="as-lib-5"
    _as_mk_repo "$repo"
    _as_stash_operator_work "$repo" "$id"

    run _as_restore "$repo" "$RUNNER_DIR/$id.stash"
    [ "$(printf '%s' "$output" | jq -r '.outcome')" = "restored" ]

    run _as_restore "$repo" "$RUNNER_DIR/$id.stash"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.outcome')" = "none" ]
    _as_assert_operator_work_back "$repo"
}

# ===========================================================================
# F regression — a main-dir job that fails during workspace setup must hand
# the operator's work back (shape of job 20260926T215255Z-d23375c8)
# ===========================================================================

@test "F regression: branch_create_failed restores the operator's stashed work, clears the marker, and releases the workspace lock" {
    local id="as-f-1" repo="$MOTHER_ROOT/as-f-repo1" bare="$MOTHER_ROOT/as-f-origin1.git"
    _as_mk_repo "$repo" "$bare"
    _as_make_dirty "$repo"
    _as_make_main_dir_job "$id" "$repo" "autostash-fx1" "feature/as-$id" "origin/does-not-exist"

    run mother-run-job "$id"

    assert_job_field "$id" '.state' "failed"
    assert_job_field "$id" '.failure_reason' "branch_create_failed"

    # The stash was taken and then handed back, in that order.
    assert_event_kind "$id" "auto_stashed"
    assert_event_kind "$id" "auto_stash_restored"
    local events="$EVENTS_DIR/$id.jsonl" stashed_line restored_line
    stashed_line=$(grep -n '"kind":"auto_stashed"' "$events" | head -1 | cut -d: -f1)
    restored_line=$(grep -n '"kind":"auto_stash_restored"' "$events" | head -1 | cut -d: -f1)
    [ "$stashed_line" -lt "$restored_line" ]

    _as_assert_operator_work_back "$repo"
    _as_assert_no_job_stash_left "$repo"
    [ ! -f "$RUNNER_DIR/$id.stash" ]
    [ ! -e "$(_as_lock_file "autostash-fx1:workspace")" ]
}

@test "F regression: checkout_failed (branch busy in another worktree) also restores the operator's stashed work and releases the lock" {
    local id="as-f-2" repo="$MOTHER_ROOT/as-f-repo2" bare="$MOTHER_ROOT/as-f-origin2.git"
    _as_mk_repo "$repo" "$bare"
    # The target branch exists but is checked out elsewhere, so `git checkout`
    # of it in the main dir must fail.
    git -C "$repo" branch "feature/as-$id" main
    git -C "$repo" worktree add -q "$MOTHER_ROOT/as-f-otherwt2" "feature/as-$id"
    _as_make_dirty "$repo"
    _as_make_main_dir_job "$id" "$repo" "autostash-fx2" "feature/as-$id" "main"

    run mother-run-job "$id"

    assert_job_field "$id" '.state' "failed"
    assert_job_field "$id" '.failure_reason' "checkout_failed"
    assert_event_kind "$id" "auto_stashed"
    assert_event_kind "$id" "auto_stash_restored"

    _as_assert_operator_work_back "$repo"
    _as_assert_no_job_stash_left "$repo"
    [ ! -f "$RUNNER_DIR/$id.stash" ]
    [ ! -e "$(_as_lock_file "autostash-fx2:workspace")" ]
}

@test "F regression ordering: the stash is restored BEFORE the workspace lock is released (another job must not be able to grab a dirty checkout)" {
    local id="as-f-3" repo="$MOTHER_ROOT/as-f-repo3" bare="$MOTHER_ROOT/as-f-origin3.git"
    _as_mk_repo "$repo" "$bare"
    _as_make_dirty "$repo"
    _as_make_main_dir_job "$id" "$repo" "autostash-fx3" "feature/as-$id" "origin/does-not-exist"

    # Test-local lib shadow: lock_release records whether the stash marker
    # still exists at the moment the lock is released, then delegates.
    local shadow="$MOTHER_ROOT/shadow-lib"
    cp -R "$_LIB_DIR" "$shadow"
    sed -e 's/^lock_release() {/_real_lock_release() {/' \
        -e '/^export -f lock_release$/d' "$_LIB_DIR/locks.sh" > "$shadow/locks.sh"
    cat >> "$shadow/locks.sh" <<'SHADOW'
lock_release() {
    if [ -f "${MOTHER_TEST_STASH_MARKER:-/nonexistent}" ]; then
        echo "marker-present" >> "${MOTHER_ROOT}/lock-release-order.log"
    else
        echo "marker-absent" >> "${MOTHER_ROOT}/lock-release-order.log"
    fi
    _real_lock_release "$@"
}
SHADOW
    export MOTHER_LIB_DIR="$shadow"
    export MOTHER_TEST_STASH_MARKER="$RUNNER_DIR/$id.stash"

    run mother-run-job "$id"

    assert_job_field "$id" '.state' "failed"
    assert_event_kind "$id" "auto_stash_restored"
    [ -s "$MOTHER_ROOT/lock-release-order.log" ]
    run grep -c "marker-present" "$MOTHER_ROOT/lock-release-order.log"
    [ "$output" = "0" ]
}

# ===========================================================================
# _restore_auto_stash (mother-run-job) — outcome -> event mapping
# ===========================================================================

@test "_restore_auto_stash: does nothing unless the job is main-dir with a stash marker configured" {
    _as_load_run_job
    id="as-rs-1"; job_file="$JOBS_DIR/$id.json"; make_job "$id" "running"
    local repo_dir="$MOTHER_ROOT/as-rs-repo1"
    _as_mk_repo "$repo_dir"
    _as_stash_operator_work "$repo_dir" "$id"
    work_dir="$repo_dir"; repo="rs1"

    # worktree isolation: hands off.
    isolation="worktree"; stash_marker="$RUNNER_DIR/$id.stash"
    _restore_auto_stash
    [ -f "$RUNNER_DIR/$id.stash" ]
    run git -C "$repo_dir" stash list
    [[ "$output" == *"mother:auto-stash:$id"* ]]

    # main-dir but no marker path configured: hands off.
    isolation="main-dir"; stash_marker=""
    _restore_auto_stash
    [ -f "$RUNNER_DIR/$id.stash" ]
    run git -C "$repo_dir" stash list
    [[ "$output" == *"mother:auto-stash:$id"* ]]

    [ "$(_as_event_count "$id" auto_stash_restored)" = "0" ]
}

@test "_restore_auto_stash: a restored stash emits auto_stash_restored {stash_message, original_branch}" {
    _as_load_run_job
    id="as-rs-2"; job_file="$JOBS_DIR/$id.json"; make_job "$id" "running"
    local repo_dir="$MOTHER_ROOT/as-rs-repo2"
    _as_mk_repo "$repo_dir"
    _as_stash_operator_work "$repo_dir" "$id"
    isolation="main-dir"; work_dir="$repo_dir"; repo="rs2"; stash_marker="$RUNNER_DIR/$id.stash"

    _restore_auto_stash

    _as_assert_operator_work_back "$repo_dir"
    [ "$(jq -r 'select(.kind=="auto_stash_restored") | .detail.stash_message' "$EVENTS_DIR/$id.jsonl")" = "mother:auto-stash:$id" ]
    [ "$(jq -r 'select(.kind=="auto_stash_restored") | .detail.original_branch' "$EVENTS_DIR/$id.jsonl")" = "main" ]
}

@test "_restore_auto_stash: a failed pop emits auto_stash_restore_failed and keeps the stash" {
    _as_load_run_job
    id="as-rs-3"; job_file="$JOBS_DIR/$id.json"; make_job "$id" "running"
    local repo_dir="$MOTHER_ROOT/as-rs-repo3"
    _as_mk_repo "$repo_dir"
    _as_stash_operator_work "$repo_dir" "$id"
    echo "conflicting-edit" > "$repo_dir/tracked.txt"
    isolation="main-dir"; work_dir="$repo_dir"; repo="rs3"; stash_marker="$RUNNER_DIR/$id.stash"

    _restore_auto_stash

    assert_event_kind "$id" "auto_stash_restore_failed"
    [ "$(jq -r 'select(.kind=="auto_stash_restore_failed") | .detail.stash_message' "$EVENTS_DIR/$id.jsonl")" = "mother:auto-stash:$id" ]
    run git -C "$repo_dir" stash list
    [[ "$output" == *"mother:auto-stash:$id"* ]]
}

@test "_restore_auto_stash: a marker whose stash is gone emits auto_stash_not_found {stash_message}" {
    _as_load_run_job
    id="as-rs-4"; job_file="$JOBS_DIR/$id.json"; make_job "$id" "running"
    local repo_dir="$MOTHER_ROOT/as-rs-repo4"
    _as_mk_repo "$repo_dir"
    printf '%s\n%s\n' "mother:auto-stash:$id" "main" > "$RUNNER_DIR/$id.stash"
    isolation="main-dir"; work_dir="$repo_dir"; repo="rs4"; stash_marker="$RUNNER_DIR/$id.stash"

    _restore_auto_stash

    assert_event_kind "$id" "auto_stash_not_found"
    [ "$(jq -r 'select(.kind=="auto_stash_not_found") | .detail.stash_message' "$EVENTS_DIR/$id.jsonl")" = "mother:auto-stash:$id" ]
}

@test "_restore_auto_stash: no marker file on disk emits no auto_stash* events at all" {
    _as_load_run_job
    id="as-rs-5"; job_file="$JOBS_DIR/$id.json"; make_job "$id" "running"
    local repo_dir="$MOTHER_ROOT/as-rs-repo5"
    _as_mk_repo "$repo_dir"
    isolation="main-dir"; work_dir="$repo_dir"; repo="rs5"; stash_marker="$RUNNER_DIR/$id.stash"

    _restore_auto_stash

    run bash -c "grep -c 'auto_stash' '$EVENTS_DIR/$id.jsonl' 2>/dev/null; true"
    [ "$output" = "0" ] || [ -z "$output" ]
}

# ===========================================================================
# _exit_cleanup_workspace — the single exit-path cleanup
# ===========================================================================

@test "_exit_cleanup_workspace: restores the stash and releases a held workspace lock; a second call is a no-op" {
    _as_load_run_job
    id="as-ec-1"; job_file="$JOBS_DIR/$id.json"; make_job "$id" "running"
    local repo_dir="$MOTHER_ROOT/as-ec-repo1"
    _as_mk_repo "$repo_dir"
    _as_stash_operator_work "$repo_dir" "$id"
    lock_acquire "ec1:workspace" 0 >/dev/null
    [ -e "$(lock_get_file "ec1:workspace")" ]
    isolation="main-dir"; work_dir="$repo_dir"; repo="ec1"
    stash_marker="$RUNNER_DIR/$id.stash"; _workspace_lock_held=1

    _exit_cleanup_workspace

    _as_assert_operator_work_back "$repo_dir"
    [ ! -f "$RUNNER_DIR/$id.stash" ]
    [ ! -e "$(lock_get_file "ec1:workspace")" ]
    [ "$(_as_event_count "$id" auto_stash_restored)" = "1" ]

    # Second call (e.g. explicit cleanup + EXIT trap): must not restore again
    # and must NOT release a lock that some other job has since taken.
    lock_acquire "ec1:workspace" 0 >/dev/null
    _exit_cleanup_workspace
    [ -e "$(lock_get_file "ec1:workspace")" ]
    [ "$(_as_event_count "$id" auto_stash_restored)" = "1" ]
}

@test "_exit_cleanup_workspace: never releases a workspace lock this run does not hold" {
    _as_load_run_job
    id="as-ec-2"; job_file="$JOBS_DIR/$id.json"; make_job "$id" "running"
    local repo_dir="$MOTHER_ROOT/as-ec-repo2"
    _as_mk_repo "$repo_dir"
    # Somebody else's lock (we failed lock_busy, so we never held it).
    lock_acquire "ec2:workspace" 0 >/dev/null
    isolation="main-dir"; work_dir="$repo_dir"; repo="ec2"
    stash_marker="$RUNNER_DIR/$id.stash"; _workspace_lock_held=0

    _exit_cleanup_workspace

    [ -e "$(lock_get_file "ec2:workspace")" ]
}

@test "_exit_cleanup_workspace: restores the stash before releasing the lock" {
    _as_load_run_job
    id="as-ec-3"; job_file="$JOBS_DIR/$id.json"; make_job "$id" "running"
    local repo_dir="$MOTHER_ROOT/as-ec-repo3"
    _as_mk_repo "$repo_dir"
    _as_stash_operator_work "$repo_dir" "$id"
    isolation="main-dir"; work_dir="$repo_dir"; repo="ec3"
    stash_marker="$RUNNER_DIR/$id.stash"; _workspace_lock_held=1

    lock_release() {
        if [ -f "$stash_marker" ]; then echo present; else echo absent; fi >> "$MOTHER_ROOT/ec3-order.log"
        return 0
    }

    _exit_cleanup_workspace

    [ -s "$MOTHER_ROOT/ec3-order.log" ]
    run grep -c present "$MOTHER_ROOT/ec3-order.log"
    [ "$output" = "0" ]
    _as_assert_operator_work_back "$repo_dir"
}

# ===========================================================================
# Orphan reaper — a dead supervisor's stash comes back too
# ===========================================================================

_as_make_orphan_main_dir_job() {
    local id="$1" repo_dir="$2" pid="$3"
    make_job "$id" "running" \
        '.isolation = "main-dir"
         | .repo_path = "'"$repo_dir"'"
         | .branch = "feature/'"$id"'"
         | .worker_pid = '"$pid"'
         | .tmux_window = null
         | .started_at = "2000-01-01T00:00:00Z"'
}

@test "orphan reaper: restores the auto-stash of a reaped main-dir job whose supervisor died" {
    local id="as-orph-1" repo="$MOTHER_ROOT/as-orph-repo1"
    _as_mk_repo "$repo"
    _as_stash_operator_work "$repo" "$id"
    git -C "$repo" checkout -q -b "feature/$id"    # where the dead worker left the checkout

    ( exit 0 ) &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null
    _as_make_orphan_main_dir_job "$id" "$repo" "$dead_pid"

    run mother-runner --recover-orphans-tick 0
    [ "$status" -eq 0 ]

    assert_job_field "$id" '.state' "failed"
    _as_assert_operator_work_back "$repo"
    _as_assert_no_job_stash_left "$repo"
    [ ! -f "$RUNNER_DIR/$id.stash" ]
    assert_event_kind "$id" "auto_stash_restored"
}

@test "orphan reaper: defers the restore while another main-dir job is running in the same repo, and keeps the marker" {
    local id="as-orph-2" other="as-orph-2-live" repo="$MOTHER_ROOT/as-orph-repo2"
    _as_mk_repo "$repo"
    _as_stash_operator_work "$repo" "$id"
    git -C "$repo" checkout -q -b "feature/$id"

    ( exit 0 ) &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null
    _as_make_orphan_main_dir_job "$id" "$repo" "$dead_pid"

    # A genuinely live job sharing the checkout: restoring now would dump the
    # operator's files into that job's working tree.
    sleep 100 &
    _STANDIN_PID=$!
    _as_make_orphan_main_dir_job "$other" "$repo" "$_STANDIN_PID"

    run mother-runner --recover-orphans-tick 0
    [ "$status" -eq 0 ]

    assert_job_field "$other" '.state' "running"
    assert_event_kind "$id" "auto_stash_restore_deferred"
    [ "$(jq -r 'select(.kind=="auto_stash_restore_deferred") | .detail.conflicting_job_id' "$EVENTS_DIR/$id.jsonl")" = "$other" ]
    [ "$(jq -r 'select(.kind=="auto_stash_restore_deferred") | .detail.stash_message' "$EVENTS_DIR/$id.jsonl")" = "mother:auto-stash:$id" ]

    # Nothing was restored or discarded.
    [ -f "$RUNNER_DIR/$id.stash" ]
    run git -C "$repo" stash list
    [[ "$output" == *"mother:auto-stash:$id"* ]]
    [ "$(cat "$repo/tracked.txt")" = "base" ]
    run bash -c "grep -c '\"kind\":\"auto_stash_restored\"' '$EVENTS_DIR/$id.jsonl'; true"
    [ "$output" = "0" ]
}
