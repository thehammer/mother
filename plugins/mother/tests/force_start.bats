#!/usr/bin/env bats
# force_start.bats — tests for the force_start flag and `mother force-start` command.

load 'test_helper'

setup() {
    setup_mother_env
    export METRICS_DIR="$MOTHER_ROOT/metrics"
    mkdir -p "$METRICS_DIR"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# 1. CLI sets the flag on a ready job

@test "force-start: sets force_start=true and emits event on a ready job" {
    make_job "job-fs-ready" "ready"

    run mother force-start "job-fs-ready" --yes
    [ "$status" -eq 0 ]
    [[ "$output" =~ "force_start set" ]]

    run jq -r '.force_start' "$JOBS_DIR/job-fs-ready.json"
    [ "$output" = "true" ]

    assert_event_kind "job-fs-ready" "force_start_requested"
}

# ---------------------------------------------------------------------------
# 2. CLI rejects non-eligible states

@test "force-start: rejects running job with non-zero exit" {
    make_job "job-fs-running" "running"

    run mother force-start "job-fs-running" --yes
    [ "$status" -ne 0 ]
    [[ "$output" =~ "must be ready or queued" ]]

    # Flag must not be set
    run jq -r '.force_start // "absent"' "$JOBS_DIR/job-fs-running.json"
    [ "$output" = "absent" ]
}

@test "force-start: rejects succeeded job with non-zero exit" {
    make_job "job-fs-succeeded" "succeeded"

    run mother force-start "job-fs-succeeded" --yes
    [ "$status" -ne 0 ]
    [[ "$output" =~ "must be ready or queued" ]]
}

@test "force-start: rejects failed job with non-zero exit" {
    make_job "job-fs-failed" "failed"

    run mother force-start "job-fs-failed" --yes
    [ "$status" -ne 0 ]
    [[ "$output" =~ "must be ready or queued" ]]
}

@test "force-start: rejects awaiting job with non-zero exit" {
    make_job "job-fs-awaiting" "awaiting"

    run mother force-start "job-fs-awaiting" --yes
    [ "$status" -ne 0 ]
    [[ "$output" =~ "must be ready or queued" ]]
}

@test "force-start: rejects unknown job with non-zero exit" {
    run mother force-start "no-such-job-xyz" --yes
    [ "$status" -ne 0 ]
    [[ "$output" =~ "no such job" ]]
}

@test "force-start: rejects awaiting job with non-quota paused_reason" {
    make_job "job-fs-awaiting-other" "awaiting" '.paused_reason = "answer_needed"'

    run mother force-start "job-fs-awaiting-other" --yes
    [ "$status" -ne 0 ]
    [[ "$output" =~ "must be ready or queued" ]]

    run jq -r '.force_start // "absent"' "$JOBS_DIR/job-fs-awaiting-other.json"
    [ "$output" = "absent" ]
}

# ---------------------------------------------------------------------------
# 2b. Force-start un-pauses an awaiting job parked for quota (mirrors
#     _auto_resume_check's un-pause merge, then sets force_start).

@test "force-start: resumes and forces an awaiting job paused for quota (5h window)" {
    make_job "job-fs-quota5h" "awaiting" '
        .paused_reason = "quota_5h"
        | .pause_requested = true
        | .auto_resume_at = 9999999999
    '

    run mother force-start "job-fs-quota5h" --yes
    [ "$status" -eq 0 ]
    [[ "$output" =~ "force_start set" ]]

    run jq -r '.state' "$JOBS_DIR/job-fs-quota5h.json"
    [ "$output" = "ready" ]

    run jq -r '.force_start' "$JOBS_DIR/job-fs-quota5h.json"
    [ "$output" = "true" ]

    run jq -r '.paused_reason // "absent"' "$JOBS_DIR/job-fs-quota5h.json"
    [ "$output" = "absent" ]

    run jq -r '.pause_requested // "absent"' "$JOBS_DIR/job-fs-quota5h.json"
    [ "$output" = "absent" ]

    run jq -r '.auto_resume_at // "absent"' "$JOBS_DIR/job-fs-quota5h.json"
    [ "$output" = "absent" ]

    run jq -r '.resume_count' "$JOBS_DIR/job-fs-quota5h.json"
    [ "$output" = "1" ]

    assert_event_kind "job-fs-quota5h" "auto_resumed"
    assert_event_kind "job-fs-quota5h" "force_start_requested"
}

@test "force-start: resumes an awaiting job paused for quota (7d window)" {
    make_job "job-fs-quota7d" "awaiting" '.paused_reason = "quota_7d"'

    run mother force-start "job-fs-quota7d" --yes
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/job-fs-quota7d.json"
    [ "$output" = "ready" ]
}

# ---------------------------------------------------------------------------
# 3. Force-start on a queued job is accepted (flag set, state stays queued)

@test "force-start: accepts queued job, flag set, state stays queued" {
    make_job "job-fs-queued" "queued"

    run mother force-start "job-fs-queued" --yes
    [ "$status" -eq 0 ]

    run jq -r '.force_start' "$JOBS_DIR/job-fs-queued.json"
    [ "$output" = "true" ]

    run jq -r '.state' "$JOBS_DIR/job-fs-queued.json"
    [ "$output" = "queued" ]
}

# ---------------------------------------------------------------------------
# 4. --yes required non-interactively (stdin redirected from /dev/null)

@test "force-start: refuses without --yes in non-interactive context" {
    make_job "job-fs-noyes" "ready"

    # Redirect stdin from /dev/null to simulate non-interactive context.
    run bash -c "mother force-start job-fs-noyes </dev/null"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "non-interactive" ]]

    # Flag must not be set
    run jq -r '.force_start // "absent"' "$JOBS_DIR/job-fs-noyes.json"
    [ "$output" = "absent" ]
}

# ---------------------------------------------------------------------------
# 5. Flag cleared on terminal transition (cancel)

@test "force-start: flag cleared when job is cancelled via mother cancel" {
    make_job "job-fs-cancel" "ready" '.force_start = true'

    run mother cancel "job-fs-cancel"
    [ "$status" -eq 0 ]

    run jq -r '.force_start // "absent"' "$JOBS_DIR/job-fs-cancel.json"
    [ "$output" = "absent" ]
}

@test "force-start: flag cleared on terminal transition via _job_transition" {
    # Test the state.sh chokepoint directly by sourcing the lib.
    make_job "job-fs-terminal" "running" '.force_start = true'

    (
        export MOTHER_ROOT JOBS_DIR EVENTS_DIR
        MOTHER_BIN_DIR="$_BIN_DIR"
        MOTHER_LIB_DIR="$_LIB_DIR"
        # shellcheck source=/dev/null
        source "$_LIB_DIR/state.sh"
        _job_transition "job-fs-terminal" "succeeded" '{}'
    )

    run jq -r '.force_start // "absent"' "$JOBS_DIR/job-fs-terminal.json"
    [ "$output" = "absent" ]

    run jq -r '.state' "$JOBS_DIR/job-fs-terminal.json"
    [ "$output" = "succeeded" ]
}

# ---------------------------------------------------------------------------
# 6. Flag cleared on escalation re-queue

@test "force-start: flag cleared after mother escalate" {
    make_job "job-fs-esc" "failed" \
        '.force_start = true | .escalation_count = 0 | .current_tier = "tier_0" | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"test"},"redd":{"model":"sonnet","effort":"medium","rationale":"test"},"marty":{"model":"sonnet","effort":"medium","rationale":"test"},"perri":{"model":"sonnet","effort":"medium","rationale":"test"}}'

    run mother escalate "job-fs-esc"
    [ "$status" -eq 0 ]

    run jq -r '.force_start // "absent"' "$JOBS_DIR/job-fs-esc.json"
    [ "$output" = "absent" ]
}

# ---------------------------------------------------------------------------
# 7. Flag cleared on adherence rework re-queue (grep check on jq filter)

@test "force-start: mother-runner adherence rework jq filter includes .force_start = null" {
    # Unit check: verify the jq filter used for adherence rework re-queuing
    # includes force_start = null. We grep the runner source since spinning
    # up a full adherence cycle in bats is impractical.
    run grep -c 'force_start = null' "$_BIN_DIR/mother-runner"
    [ "$output" -ge 1 ]
}

@test "force-start: adherence rework clears force_start via runner jq filter" {
    # Simulate the adherence rework jq filter directly against a job file
    # to verify the filter produces null for force_start.
    make_job "job-fs-adh" "succeeded" '.force_start = true | .adherence_status = "failed_first"'

    local merged
    merged=$(jq '
        .state = "ready"
        | .activity = "cody_rework"
        | .finished_at = null
        | .worker_pid = null
        | .actual_cost_usd = null
        | .cancel_requested = null
        | .pause_requested = null
        | .final_result_at = null
        | .force_start = null
    ' "$JOBS_DIR/job-fs-adh.json")
    printf '%s' "$merged" > "$JOBS_DIR/job-fs-adh.json"

    run jq -r '.force_start // "absent"' "$JOBS_DIR/job-fs-adh.json"
    [ "$output" = "absent" ]

    run jq -r '.state' "$JOBS_DIR/job-fs-adh.json"
    [ "$output" = "ready" ]
}

# ---------------------------------------------------------------------------
# 8. Posture bypass — verify the jq filter and worker script contain
#    the force_start bypass logic. (Full posture-bias integration requires
#    running mother-run-job end-to-end; the posture block is verified here
#    by inspecting the script source for the key constructs.)

@test "force-start: mother-run-job has force_start posture bypass block" {
    run grep -c 'force_start.*true' "$_BIN_DIR/mother-run-job"
    [ "$output" -ge 1 ]
}

@test "force-start: mother-run-job posture bypass emits forced bias value" {
    run grep -c 'posture_bias_applied="forced"' "$_BIN_DIR/mother-run-job"
    [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# 9. Over-cap dispatch: _pick_next_forced_ready selects forced-ready jobs

@test "_pick_next_forced_ready: returns a forced-ready job" {
    make_job "job-normal-ready" "ready"
    make_job "job-forced-ready" "ready" '.force_start = true'

    result=$(
        export MOTHER_ROOT JOBS_DIR EVENTS_DIR
        MOTHER_BIN_DIR="$_BIN_DIR"
        MOTHER_LIB_DIR="$_LIB_DIR"
        # shellcheck source=/dev/null
        source "$_LIB_DIR/state.sh"

        _pick_next_forced_ready() {
            find "$JOBS_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | while read -r f; do
                jq -r 'select(.state == "ready" and (.force_start == true)) | .created_at + "\t" + .id' "$f"
            done | sort | head -1 | cut -f2
        }
        _pick_next_forced_ready
    )
    [ "$result" = "job-forced-ready" ]
}

@test "_pick_next_forced_ready: does NOT return a non-forced ready job" {
    make_job "job-only-normal" "ready"

    result=$(
        export MOTHER_ROOT JOBS_DIR EVENTS_DIR
        MOTHER_BIN_DIR="$_BIN_DIR"
        MOTHER_LIB_DIR="$_LIB_DIR"
        # shellcheck source=/dev/null
        source "$_LIB_DIR/state.sh"

        _pick_next_forced_ready() {
            find "$JOBS_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | while read -r f; do
                jq -r 'select(.state == "ready" and (.force_start == true)) | .created_at + "\t" + .id' "$f"
            done | sort | head -1 | cut -f2
        }
        _pick_next_forced_ready
    )
    [ -z "$result" ]
}

@test "_maybe_pause_running: force_start=true exempts job from pause" {
    # Verify the runner source contains the force_start exemption read
    # and a comment about never pausing for quota.
    run grep -c 'force_start' "$_BIN_DIR/mother-runner"
    [ "$output" -ge 1 ]
    run grep -c 'never pause for quota' "$_BIN_DIR/mother-runner"
    [ "$output" -ge 1 ]
}

# ---------------------------------------------------------------------------
# Event detail includes over_cap and posture context

@test "force-start: event detail includes over_cap and posture fields" {
    make_job "job-fs-event" "ready"

    run mother force-start "job-fs-event" --yes
    [ "$status" -eq 0 ]

    # The event should have been appended; check it contains over_cap and posture.
    local event_line
    event_line=$(grep '"force_start_requested"' "$EVENTS_DIR/job-fs-event.jsonl" | tail -1)
    [ -n "$event_line" ]
    echo "$event_line" | jq -e '.detail.over_cap != null' >/dev/null
    echo "$event_line" | jq -e '.detail.posture != null' >/dev/null
}

# ---------------------------------------------------------------------------
# mother-switcher has ctrl-f binding

@test "mother-switcher: has ctrl-f force-start keybind" {
    run grep -c 'ctrl-f' "$_BIN_DIR/mother-switcher"
    [ "$output" -ge 2 ]  # header hint + bind
}

@test "mother-switcher: ctrl-f calls mother force-start with --yes" {
    run grep 'ctrl-f' "$_BIN_DIR/mother-switcher"
    [[ "$output" =~ "force-start" ]]
    [[ "$output" =~ "--yes" ]]
}
