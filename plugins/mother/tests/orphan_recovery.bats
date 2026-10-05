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

@test "orphan recovery: stops the RWX sandbox of a reaped worktree job (reason: orphan)" {
    local wd="$BATS_TEST_TMPDIR/wt"
    mkdir -p "$wd/.rwx"
    printf 'base: ubuntu\n' > "$wd/.rwx/sandbox.yml"
    cat > "$_MOCK_BIN/rwx" <<'RWX'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd -P)" "$*" >> "$MOTHER_ROOT/rwx-calls.log"
RWX
    chmod +x "$_MOCK_BIN/rwx"
    make_job "job-rwx-orphan" "running" \
        ".worker_pid = null | .tmux_window = null | .started_at = \"2000-01-01T00:00:00Z\" | .work_dir = \"$wd\""

    run mother-runner --recover-orphans-tick 60
    [ "$status" -eq 0 ]
    grep -q "|sandbox stop" "$MOTHER_ROOT/rwx-calls.log"
    run jq -s -r '[.[] | select(.kind == "rwx_sandbox_stop")] | .[0].detail.reason' \
        "$EVENTS_DIR/job-rwx-orphan.jsonl"
    [ "$output" = "orphan" ]
}

# ---------------------------------------------------------------------------
# Preview stacks: a SIGKILLed supervisor never ran _preview_post_exit, so the
# runner's orphan sweep stops the stack (reason: orphan) — for EVERY isolation,
# because `down` is keyed by stack id and never needs the worktree.

_install_fake_preview_stack() {
    cat > "$_MOCK_BIN/fake-preview-stack" <<'FAKEPS'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd -P)" "$*" >> "$MOTHER_ROOT/preview-cli.log"
exit 0
FAKEPS
    chmod +x "$_MOCK_BIN/fake-preview-stack"
    export MOTHER_PREVIEW_STACK_BIN="$_MOCK_BIN/fake-preview-stack"
}

# jq assignment for a live (non-stopped) preview record on stack job-<id>.
_orphan_preview_rec() {
    local id="$1" status="${2:-ready}"
    printf '%s' '.preview = {
        stack_id: "job-'"$id"'", backend: "cli", combo: "ap", components: ["ap"],
        refs: {ap: {ref: "feature/x", sha: "1111111111111111111111111111111111111111"}},
        urls: {stack: "https://stk-job-'"$id"'-ap.example.invalid"},
        run_id: "run-test-1", run_url: "https://cloud.example.invalid/runs/run-test-1",
        launched_at: "2026-10-04T17:25:28Z", status: "'"$status"'", expected_sha: {},
        launches: 1, stopped_at: null }'
}

_orphan_base_filter() {
    printf '%s' '.worker_pid = null | .tmux_window = null | .started_at = "2000-01-01T00:00:00Z"'
}

@test "orphan recovery: stops the preview stack of a reaped worktree job (reason: orphan)" {
    _install_fake_preview_stack
    local id="pvorphanwt"
    # The worktree is already gone: stopping a stack must not need it.
    make_job "$id" "running" \
        "$(_orphan_base_filter) | .isolation = \"worktree\" | .work_dir = \"$BATS_TEST_TMPDIR/gone-worktree\" | $(_orphan_preview_rec "$id")"
    printf '{"seed":"x","tokens":{"ADMIN_API_TOKEN":"planted"}}' > "$RUNNER_DIR/$id.preview-secrets.json"

    run mother-runner --recover-orphans-tick 60
    [ "$status" -eq 0 ]

    assert_job_field "$id" '.state' "failed"
    [ "$(grep -cF "|down job-$id" "$MOTHER_ROOT/preview-cli.log")" = "1" ]
    run jq -s -r '[.[] | select(.kind == "preview_stop")] | .[0].detail | "\(.reason) \(.outcome) \(.backend)"' \
        "$EVENTS_DIR/$id.jsonl"
    [ "$output" = "orphan ok cli" ]
    assert_job_field "$id" '.preview.status' "stopped"
    [ ! -e "$RUNNER_DIR/$id.preview-secrets.json" ]
}

@test "orphan recovery: stops the preview stack of a reaped main-dir job (reason: orphan)" {
    _install_fake_preview_stack
    local id="pvorphanmd"
    local wd="$BATS_TEST_TMPDIR/maindir"
    mkdir -p "$wd"
    make_job "$id" "running" \
        "$(_orphan_base_filter) | .isolation = \"main-dir\" | .work_dir = \"$wd\" | .repo_path = \"$wd\" | $(_orphan_preview_rec "$id")"
    printf '{"seed":"x","tokens":{"ADMIN_API_TOKEN":"planted"}}' > "$RUNNER_DIR/$id.preview-secrets.json"

    run mother-runner --recover-orphans-tick 60
    [ "$status" -eq 0 ]

    assert_job_field "$id" '.state' "failed"
    [ "$(grep -cF "|down job-$id" "$MOTHER_ROOT/preview-cli.log")" = "1" ]
    run jq -s -r '[.[] | select(.kind == "preview_stop")] | .[0].detail.reason' "$EVENTS_DIR/$id.jsonl"
    [ "$output" = "orphan" ]
    assert_job_field "$id" '.preview.status' "stopped"
    [ ! -e "$RUNNER_DIR/$id.preview-secrets.json" ]
}

@test "orphan recovery: a reaped job that never launched a preview gets no stop call and no preview_stop event" {
    _install_fake_preview_stack
    local id="pvorphannone"
    make_job "$id" "running" "$(_orphan_base_filter) | .isolation = \"worktree\""

    run mother-runner --recover-orphans-tick 60
    [ "$status" -eq 0 ]

    assert_job_field "$id" '.state' "failed"
    [ ! -s "$MOTHER_ROOT/preview-cli.log" ]
    run jq -s '[.[] | select(.kind == "preview_stop")] | length' "$EVENTS_DIR/$id.jsonl"
    [ "$output" = "0" ]
}

@test "orphan recovery: an already-stopped preview record is not stopped again" {
    _install_fake_preview_stack
    local id="pvorphandone"
    make_job "$id" "running" \
        "$(_orphan_base_filter) | .isolation = \"worktree\" | $(_orphan_preview_rec "$id" stopped)"

    run mother-runner --recover-orphans-tick 60
    [ "$status" -eq 0 ]

    assert_job_field "$id" '.state' "failed"
    [ ! -s "$MOTHER_ROOT/preview-cli.log" ]
}
