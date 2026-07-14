#!/usr/bin/env bats
# orphan_recovery.bats — tests for `_recover_orphans`'s handling of `running`
# jobs whose job JSON has no `worker_pid` yet.
#
# Regression coverage for: a job whose supervisor (mother-run-job) is
# legitimately still alive and mid-setup (e.g. slow worktree creation under
# load) was being misdiagnosed as `failed: runner_died` purely because
# MOTHER_ORPHAN_GRACE (60s) had elapsed since `started_at`, with no check on
# whether the supervisor process itself was actually dead. That false
# failure then auto-escalated and re-spawned a second supervisor into the
# *same* worktree while the original was still working — a live duplicate.
#
# The fix mirrors the existing `worker_pid`-present branch: before reaping,
# confirm via `_supervisor_alive_for_job` (which checks the CHILDREN_DIR
# entry the daemon writes at spawn time — the mother-run-job pid, not the
# job's own `worker_pid` field) that the supervision tree is actually gone.

load 'test_helper'

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
    # Clean up any stray background sleep pids we used as supervisor stand-ins.
    [ -n "${_STANDIN_PID:-}" ] && kill "$_STANDIN_PID" 2>/dev/null || true
}

# Record a CHILDREN_DIR entry the way `_track_child` (mother-runner) does,
# without needing to source the whole script. mother-runner itself defines
# CHILDREN_DIR="$RUNNER_DIR/children" and creates it at load time, but that
# only happens once the binary runs — so callers that need the file to
# exist *before* invoking `mother-runner --recover-orphans-tick` (like this
# helper) must compute the same path and create it themselves.
# Usage: track_child <pid> <job_id>
track_child() {
    local pid="$1" job_id="$2"
    local children_dir="$RUNNER_DIR/children"
    mkdir -p "$children_dir"
    jq -nc --argjson pid "$pid" --arg job_id "$job_id" --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{pid: $pid, job_id: $job_id, started_at: $started}' \
        > "$children_dir/$pid.json"
}

@test "orphan recovery: does not reap a running job past grace when its supervisor is still alive" {
    make_job "job-slow-spawn" "running" \
        '.worker_pid = null | .tmux_window = null | .started_at = "2000-01-01T00:00:00Z"'

    # Stand in for a live mother-run-job supervisor that just hasn't
    # persisted worker_pid yet (e.g. still creating the worktree).
    sleep 100 &
    _STANDIN_PID=$!
    track_child "$_STANDIN_PID" "job-slow-spawn"

    # Grace is trivially satisfied (started_at is year 2000), so the only
    # thing that should prevent reaping is the supervisor liveness check.
    run mother-runner --recover-orphans-tick 60
    [ "$status" -eq 0 ]

    assert_job_field "job-slow-spawn" '.state' "running"

    kill "$_STANDIN_PID" 2>/dev/null || true
}

@test "orphan recovery: reaps a running job past grace once its supervisor is truly gone" {
    make_job "job-dead-spawn" "running" \
        '.worker_pid = null | .tmux_window = null | .started_at = "2000-01-01T00:00:00Z"'

    # No CHILDREN_DIR entry at all — supervisor never registered or already
    # reaped by _reap_children. This is the genuine "spawn failed" case.
    run mother-runner --recover-orphans-tick 60
    [ "$status" -eq 0 ]

    assert_job_field "job-dead-spawn" '.state' "failed"
    assert_event_kind "job-dead-spawn" "failed"
}

@test "orphan recovery: does not reap before grace elapses, regardless of supervisor liveness" {
    make_job "job-fresh-spawn" "running" \
        '.worker_pid = null | .tmux_window = null'
    # started_at defaults to null in make_job's base template unless
    # overridden; set it to "now" so grace clearly hasn't elapsed.
    merged=$(jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.started_at = $now' "$JOBS_DIR/job-fresh-spawn.json")
    printf '%s' "$merged" > "$JOBS_DIR/job-fresh-spawn.json"

    # No CHILDREN_DIR entry (supervisor truly dead) — but grace (60s) hasn't
    # elapsed since started_at, so this must not be reaped yet either way.
    run mother-runner --recover-orphans-tick 60
    [ "$status" -eq 0 ]

    assert_job_field "job-fresh-spawn" '.state' "running"
}
