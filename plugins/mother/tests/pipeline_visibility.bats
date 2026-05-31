#!/usr/bin/env bats
# pipeline_visibility.bats — W5: pipeline progress in list/status/JSON/broker.
#
# Tests cover:
#   - _pipeline_cycles_json: FR2 schema derivation, timestamps from events,
#     skipped phases, multi-cycle jobs, missing-event tolerance.
#   - _pipeline_list_label: compact string for each pipeline phase.
#   - cmd_list text: pipeline-aware state column.
#   - cmd_list --format json: cycles attached to pipeline jobs, standard jobs
#     byte-identical (back-compat).
#   - cmd_status text: pipeline section, PIPELINE-BLOCKED banner, advisory listing.
#   - cmd_status --format json: cycles attached; standard jobs unchanged.

load 'test_helper'

# ---------------------------------------------------------------------------
# Setup / teardown

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers

# Source state.sh into the test's shell so we can call helpers directly.
_source_state() {
    # shellcheck disable=SC1090
    source "$_LIB_DIR/state.sh"
}

# Build a pipeline job with a full pipeline object.
# Usage: _make_pipeline_job <id> <phase> <state> [extra-jq-filter]
_make_pipeline_job() {
    local id="$1" phase="$2" jstate="$3" extra="${4:-.}"
    make_pipeline_job "$id" "$phase" \
        --arg jstate "$jstate" '
        .state = $jstate
        | .pipeline += {
            review_cycle: 0,
            cycle_cap: 3,
            reviewers: ["perri"],
            pending_agents: [],
            findings: [],
            findings_history: [],
            reviewer_findings: {}
          }' 2>/dev/null || true
    # make_pipeline_job doesn't accept --arg; patch via jq directly.
    local merged
    merged=$(jq \
        --arg jstate "$jstate" \
        --arg phase "$phase" \
        '. + {state: $jstate} | .pipeline.phase = $phase' \
        "$JOBS_DIR/$id.json")
    merged=$(printf '%s' "$merged" | jq "$extra")
    printf '%s' "$merged" > "$JOBS_DIR/$id.json"
}

# Write a phase_started or phase_completed event for a job.
_write_phase_event() {
    local id="$1" kind="$2" cycle="$3" agent="$4" rt="$5"
    local evfile="$EVENTS_DIR/$id.jsonl"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    printf '{"ts":"%s","kind":"%s","detail":{"cycle":%s,"agent":"%s","request_type":"%s"}}\n' \
        "$ts" "$kind" "$cycle" "$agent" "$rt" >> "$evfile"
}

# Write a review_cycle_started or review_cycle_completed event.
_write_review_event() {
    local id="$1" kind="$2" cycle="$3" decision="${4:-ship}" fc="${5:-0}"
    local evfile="$EVENTS_DIR/$id.jsonl"
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
    if [ "$kind" = "review_cycle_started" ]; then
        printf '{"ts":"%s","kind":"%s","detail":{"cycle":%s,"reviewers":["perri"]}}\n' \
            "$ts" "$kind" "$cycle" >> "$evfile"
    else
        printf '{"ts":"%s","kind":"%s","detail":{"cycle":%s,"decision":"%s","findings_count":%s}}\n' \
            "$ts" "$kind" "$cycle" "$decision" "$fc" >> "$evfile"
    fi
}

# ---------------------------------------------------------------------------
# _pipeline_list_label

@test "_pipeline_list_label: build phase shows cycle and title-cased agent" {
    _source_state
    make_pipeline_job "j1" "redd" \
        '.state = "running" | .pipeline.phase = "redd" | .pipeline.review_cycle = 0'
    result=$(_pipeline_list_label "$JOBS_DIR/j1.json")
    [ "$result" = "cycle 0 · Redd" ]
}

@test "_pipeline_list_label: cody on cycle 1" {
    _source_state
    make_pipeline_job "j1" "cody" \
        '.state = "running" | .pipeline.phase = "cody" | .pipeline.review_cycle = 1'
    result=$(_pipeline_list_label "$JOBS_DIR/j1.json")
    [ "$result" = "cycle 1 · Cody" ]
}

@test "_pipeline_list_label: review phase shows findings count" {
    _source_state
    make_pipeline_job "j1" "review" \
        '.state = "succeeded"
        | .pipeline.phase = "review"
        | .pipeline.findings = [{"id":"f1","summary":"x","target":"cody","severity":"blocking"},
                                 {"id":"f2","summary":"y","target":"cody","severity":"blocking"}]'
    result=$(_pipeline_list_label "$JOBS_DIR/j1.json")
    [ "$result" = "review · 2 finding(s)" ]
}

@test "_pipeline_list_label: blocked phase shows findings count" {
    _source_state
    make_pipeline_job "j1" "blocked" \
        '.state = "awaiting"
        | .activity = "pipeline_blocked"
        | .pipeline.phase = "blocked"
        | .pipeline.findings = [{"id":"f1","summary":"x","target":"human","severity":"blocking"}]'
    result=$(_pipeline_list_label "$JOBS_DIR/j1.json")
    [ "$result" = "blocked · 1 finding(s)" ]
}

@test "_pipeline_list_label: done with no advisories shows shipped" {
    _source_state
    make_pipeline_job "j1" "done" \
        '.state = "succeeded"
        | .pipeline.phase = "done"
        | .pipeline.advisories = []'
    result=$(_pipeline_list_label "$JOBS_DIR/j1.json")
    [ "$result" = "shipped" ]
}

@test "_pipeline_list_label: done with 1 advisory shows singular" {
    _source_state
    make_pipeline_job "j1" "done" \
        '.state = "succeeded"
        | .pipeline.phase = "done"
        | .pipeline.advisories = [{"id":"a1","summary":"watch this","target":"human","severity":"advisory"}]'
    result=$(_pipeline_list_label "$JOBS_DIR/j1.json")
    [ "$result" = "shipped · 1 advisory" ]
}

@test "_pipeline_list_label: done with 2 advisories shows plural" {
    _source_state
    make_pipeline_job "j1" "done" \
        '.state = "succeeded"
        | .pipeline.phase = "done"
        | .pipeline.advisories = [{"id":"a1","summary":"x","target":"human","severity":"advisory"},
                                   {"id":"a2","summary":"y","target":"human","severity":"advisory"}]'
    result=$(_pipeline_list_label "$JOBS_DIR/j1.json")
    [ "$result" = "shipped · 2 advisories" ]
}

# ---------------------------------------------------------------------------
# _pipeline_cycles_json — schema and state derivation

@test "_pipeline_cycles_json: returns nothing for standard job" {
    _source_state
    make_job "std1" "running"
    result=$(_pipeline_cycles_json "$JOBS_DIR/std1.json")
    [ -z "$result" ]
}

@test "_pipeline_cycles_json: single cycle, phase=redd running, correct states" {
    _source_state
    make_pipeline_job "j1" "redd" \
        '.state = "running"
        | .activity = "pipeline_phase"
        | .pipeline.phase = "redd"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]
        | .pipeline.pending_agents = []'
    result=$(_pipeline_cycles_json "$JOBS_DIR/j1.json")
    # One cycle
    count=$(printf '%s' "$result" | jq 'length')
    [ "$count" = "1" ]
    # Cycle number is 1-indexed
    cycle_num=$(printf '%s' "$result" | jq '.[0].cycle')
    [ "$cycle_num" = "1" ]
    # redd=running, cody=pending, marty=pending
    redd_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="redd") | .state')
    [ "$redd_state" = "running" ]
    cody_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="cody") | .state')
    [ "$cody_state" = "pending" ]
    marty_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="marty") | .state')
    [ "$marty_state" = "pending" ]
    # perri (reviewer) = pending
    perri_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="perri") | .state')
    [ "$perri_state" = "pending" ]
    # perri request_type = review
    perri_rt=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="perri") | .request_type')
    [ "$perri_rt" = "review" ]
}

@test "_pipeline_cycles_json: phase=cody, redd is completed" {
    _source_state
    make_pipeline_job "j1" "cody" \
        '.state = "running"
        | .activity = "pipeline_phase"
        | .pipeline.phase = "cody"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]
        | .pipeline.pending_agents = []'
    result=$(_pipeline_cycles_json "$JOBS_DIR/j1.json")
    redd_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="redd") | .state')
    [ "$redd_state" = "completed" ]
    cody_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="cody") | .state')
    [ "$cody_state" = "running" ]
    marty_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="marty") | .state')
    [ "$marty_state" = "pending" ]
}

@test "_pipeline_cycles_json: phase=review, all build phases completed, reviewers running" {
    _source_state
    make_pipeline_job "j1" "review" \
        '.state = "succeeded"
        | .activity = "pipeline_review"
        | .pipeline.phase = "review"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]
        | .pipeline.pending_agents = []
        | .pipeline.reviewer_findings = {}'
    result=$(_pipeline_cycles_json "$JOBS_DIR/j1.json")
    redd_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="redd") | .state')
    [ "$redd_state" = "completed" ]
    cody_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="cody") | .state')
    [ "$cody_state" = "completed" ]
    marty_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="marty") | .state')
    [ "$marty_state" = "completed" ]
    perri_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="perri") | .state')
    [ "$perri_state" = "running" ]
}

@test "_pipeline_cycles_json: phase=done, all phases completed" {
    _source_state
    make_pipeline_job "j1" "done" \
        '.state = "succeeded"
        | .activity = null
        | .pipeline.phase = "done"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]
        | .pipeline.pending_agents = []
        | .pipeline.reviewer_findings = {"perri": [{"id":"f1","summary":"x"}]}'
    result=$(_pipeline_cycles_json "$JOBS_DIR/j1.json")
    redd_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="redd") | .state')
    [ "$redd_state" = "completed" ]
    perri_state=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="perri") | .state')
    [ "$perri_state" = "completed" ]
    # perri findings count from reviewer_findings
    perri_fc=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="perri") | .findings')
    [ "$perri_fc" = "1" ]
}

@test "_pipeline_cycles_json: re-run cycle, non-pending agents are skipped" {
    _source_state
    make_pipeline_job "j1" "cody" \
        '.state = "running"
        | .activity = "pipeline_phase"
        | .pipeline.phase = "cody"
        | .pipeline.review_cycle = 1
        | .pipeline.reviewers = ["perri"]
        | .pipeline.pending_agents = ["cody"]
        | .pipeline.findings_history = [{"cycle": 0, "findings": []}]'
    result=$(_pipeline_cycles_json "$JOBS_DIR/j1.json")
    # Two cycles in output
    count=$(printf '%s' "$result" | jq 'length')
    [ "$count" = "2" ]
    # Cycle 1 (index 0): all completed
    redd_c0=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="redd") | .state')
    [ "$redd_c0" = "completed" ]
    # Cycle 2 (index 1, re-run): redd=skipped, cody=running, marty=skipped
    redd_c1=$(printf '%s' "$result" | jq -r '.[1].phases[] | select(.agent=="redd") | .state')
    [ "$redd_c1" = "skipped" ]
    cody_c1=$(printf '%s' "$result" | jq -r '.[1].phases[] | select(.agent=="cody") | .state')
    [ "$cody_c1" = "running" ]
    marty_c1=$(printf '%s' "$result" | jq -r '.[1].phases[] | select(.agent=="marty") | .state')
    [ "$marty_c1" = "skipped" ]
    # Cycle numbers are 1-indexed
    [ "$(printf '%s' "$result" | jq '.[0].cycle')" = "1" ]
    [ "$(printf '%s' "$result" | jq '.[1].cycle')" = "2" ]
}

@test "_pipeline_cycles_json: timestamps from events when present" {
    _source_state
    make_pipeline_job "j1" "cody" \
        '.state = "running"
        | .pipeline.phase = "cody"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]
        | .pipeline.pending_agents = []'
    # Write phase_completed for redd and phase_started for cody
    _write_phase_event "j1" "phase_completed" 0 "redd" "test"
    _write_phase_event "j1" "phase_started"   0 "cody" "build"
    result=$(_pipeline_cycles_json "$JOBS_DIR/j1.json")
    redd_finished=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="redd") | .finished_at // ""')
    [ -n "$redd_finished" ]
    cody_started=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="cody") | .started_at // ""')
    [ -n "$cody_started" ]
    # marty has no events — timestamps absent
    marty_started=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="marty") | .started_at // ""')
    [ -z "$marty_started" ]
}

@test "_pipeline_cycles_json: review timestamps from review_cycle events" {
    _source_state
    make_pipeline_job "j1" "review" \
        '.state = "succeeded"
        | .activity = "pipeline_review"
        | .pipeline.phase = "review"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]
        | .pipeline.pending_agents = []'
    _write_review_event "j1" "review_cycle_started" 0
    result=$(_pipeline_cycles_json "$JOBS_DIR/j1.json")
    perri_started=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="perri") | .started_at // ""')
    [ -n "$perri_started" ]
}

@test "_pipeline_cycles_json: missing events produce no timestamps (no fabrication)" {
    _source_state
    make_pipeline_job "j1" "marty" \
        '.state = "running"
        | .pipeline.phase = "marty"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]
        | .pipeline.pending_agents = []'
    # No events file at all.
    result=$(_pipeline_cycles_json "$JOBS_DIR/j1.json")
    redd_started=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="redd") | .started_at // ""')
    [ -z "$redd_started" ]
    redd_finished=$(printf '%s' "$result" | jq -r '.[0].phases[] | select(.agent=="redd") | .finished_at // ""')
    [ -z "$redd_finished" ]
}

# ---------------------------------------------------------------------------
# cmd_list text — pipeline-aware state column

@test "cmd_list text: pipeline job shows pipeline label not raw activity" {
    make_pipeline_job "j1" "cody" \
        '.state = "running"
        | .activity = "pipeline_phase"
        | .pipeline.phase = "cody"
        | .pipeline.review_cycle = 0'
    run mother list
    [ "$status" -eq 0 ]
    # Should show "cycle 0 · Cody" in the state column, not raw "pipeline_phase"
    [[ "$output" == *"cycle 0 · Cody"* ]]
    [[ "$output" != *"[pipeline_phase]"* ]]
}

@test "cmd_list text: standard job state column unchanged" {
    make_job "std1" "running" '.activity = "cody_rework" | .current_tier = "tier_1"'
    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" == *"[cody_rework]"* ]]
    [[ "$output" == *"tier:1"* ]]
}

@test "cmd_list text: review phase shows findings count" {
    make_pipeline_job "j1" "review" \
        '.state = "succeeded"
        | .activity = "pipeline_review"
        | .pipeline.phase = "review"
        | .pipeline.review_cycle = 0
        | .pipeline.findings = [{"id":"f1","summary":"x","target":"cody","severity":"blocking"},
                                 {"id":"f2","summary":"y","target":"cody","severity":"blocking"}]'
    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" == *"review · 2 finding(s)"* ]]
}

@test "cmd_list text: blocked phase shows blocked label" {
    make_pipeline_job "j1" "blocked" \
        '.state = "awaiting"
        | .activity = "pipeline_blocked"
        | .pipeline.phase = "blocked"
        | .pipeline.findings = [{"id":"f1","summary":"x","target":"human","severity":"blocking"}]'
    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" == *"blocked · 1 finding(s)"* ]]
}

# ---------------------------------------------------------------------------
# cmd_list --format json — cycles attached to pipeline jobs

@test "cmd_list json: pipeline job has cycles key" {
    make_pipeline_job "j1" "redd" \
        '.state = "running"
        | .pipeline.phase = "redd"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]'
    run mother list --format json
    [ "$status" -eq 0 ]
    has_cycles=$(printf '%s' "$output" | jq '.[0] | has("cycles")')
    [ "$has_cycles" = "true" ]
}

@test "cmd_list json: standard job has no cycles key (back-compat)" {
    make_job "std1" "running"
    run mother list --format json
    [ "$status" -eq 0 ]
    has_cycles=$(printf '%s' "$output" | jq '.[0] | has("cycles")')
    [ "$has_cycles" = "false" ]
}

@test "cmd_list json: cycles array is non-empty for pipeline job" {
    make_pipeline_job "j1" "redd" \
        '.state = "running"
        | .pipeline.phase = "redd"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]'
    run mother list --format json
    [ "$status" -eq 0 ]
    cycles_len=$(printf '%s' "$output" | jq '.[0].cycles | length')
    [ "$cycles_len" -gt 0 ]
}

@test "cmd_list json: mixed standard and pipeline jobs — only pipeline gets cycles" {
    make_job "std1" "running"
    make_pipeline_job "p1" "cody" \
        '.state = "running"
        | .pipeline.phase = "cody"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]'
    run mother list --format json
    [ "$status" -eq 0 ]
    std_has_cycles=$(printf '%s' "$output" | jq '[.[] | select(.id=="std1") | has("cycles")] | .[0]')
    [ "$std_has_cycles" = "false" ]
    pl_has_cycles=$(printf '%s' "$output" | jq '[.[] | select(.id=="p1") | has("cycles")] | .[0]')
    [ "$pl_has_cycles" = "true" ]
}

# ---------------------------------------------------------------------------
# cmd_status text — pipeline section

@test "cmd_status text: pipeline section present for pipeline job" {
    make_pipeline_job "j1" "cody" \
        '.state = "running"
        | .pipeline.phase = "cody"
        | .pipeline.review_cycle = 0
        | .pipeline.cycle_cap = 3
        | .pipeline.reviewers = ["perri"]'
    run mother status j1
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== pipeline ==="* ]]
    [[ "$output" == *"Phase:"* ]]
    [[ "$output" == *"Reviewers:"* ]]
}

@test "cmd_status text: pipeline section absent for standard job" {
    make_job "std1" "running"
    run mother status std1
    [ "$status" -eq 0 ]
    [[ "$output" != *"=== pipeline ==="* ]]
}

@test "cmd_status text: PIPELINE-BLOCKED banner when activity=pipeline_blocked" {
    make_pipeline_job "j1" "blocked" \
        '.state = "awaiting"
        | .activity = "pipeline_blocked"
        | .pipeline.phase = "blocked"
        | .pipeline.findings = [{"id":"f1","summary":"Bad thing","target":"human","severity":"blocking"}]'
    run mother status j1
    [ "$status" -eq 0 ]
    [[ "$output" == *"[PIPELINE-BLOCKED]"* ]]
    [[ "$output" == *"[blocking] Bad thing"* ]]
    [[ "$output" == *"mother resume j1"* ]]
}

@test "cmd_status text: no PIPELINE-BLOCKED banner for non-blocked pipeline job" {
    make_pipeline_job "j1" "cody" '.state = "running" | .pipeline.phase = "cody"'
    run mother status j1
    [ "$status" -eq 0 ]
    [[ "$output" != *"[PIPELINE-BLOCKED]"* ]]
}

@test "cmd_status text: advisory findings listed distinctly in pipeline section" {
    make_pipeline_job "j1" "done" \
        '.state = "succeeded"
        | .pipeline.phase = "done"
        | .pipeline.advisories = [
            {"id":"a1","summary":"Consider refactoring foo","target":"human","severity":"advisory","reviewer":"perri"}
          ]'
    run mother status j1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Advisory findings:"* ]]
    [[ "$output" == *"[advisory] Consider refactoring foo"* ]]
}

@test "cmd_status text: review cycle history shown" {
    make_pipeline_job "j1" "done" \
        '.state = "succeeded"
        | .pipeline.phase = "done"
        | .pipeline.review_cycle = 1
        | .pipeline.findings_history = [{"cycle": 0, "findings": [{"id":"f1","summary":"x","target":"cody","severity":"blocking"}]}]'
    run mother status j1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Review cycle history:"* ]]
    [[ "$output" == *"cycle 1: 1 finding(s)"* ]]
}

# ---------------------------------------------------------------------------
# cmd_status --format json — cycles attached

@test "cmd_status json: pipeline job has cycles in job object" {
    make_pipeline_job "j1" "cody" \
        '.state = "running"
        | .pipeline.phase = "cody"
        | .pipeline.review_cycle = 0
        | .pipeline.reviewers = ["perri"]'
    run mother status j1 --format json
    [ "$status" -eq 0 ]
    has_cycles=$(printf '%s' "$output" | jq '.job | has("cycles")')
    [ "$has_cycles" = "true" ]
}

@test "cmd_status json: standard job has no cycles key (back-compat)" {
    make_job "std1" "running"
    run mother status std1 --format json
    [ "$status" -eq 0 ]
    has_cycles=$(printf '%s' "$output" | jq '.job | has("cycles")')
    [ "$has_cycles" = "false" ]
}

@test "cmd_status json: standard job output is structurally identical to pre-W5" {
    make_job "std1" "running" '.current_tier = "tier_0" | .escalation_count = 0'
    run mother status std1 --format json
    [ "$status" -eq 0 ]
    # Must have job and events keys; must NOT have cycles at top level
    has_job=$(printf '%s' "$output" | jq 'has("job")')
    [ "$has_job" = "true" ]
    has_events=$(printf '%s' "$output" | jq 'has("events")')
    [ "$has_events" = "true" ]
    job_has_cycles=$(printf '%s' "$output" | jq '.job | has("cycles")')
    [ "$job_has_cycles" = "false" ]
}

@test "cmd_status json: pipeline.advisories survive in job object" {
    make_pipeline_job "j1" "done" \
        '.state = "succeeded"
        | .pipeline.phase = "done"
        | .pipeline.advisories = [{"id":"a1","summary":"Watch this","target":"human","severity":"advisory"}]'
    run mother status j1 --format json
    [ "$status" -eq 0 ]
    adv_len=$(printf '%s' "$output" | jq '.job.pipeline.advisories | length')
    [ "$adv_len" = "1" ]
    adv_summary=$(printf '%s' "$output" | jq -r '.job.pipeline.advisories[0].summary')
    [ "$adv_summary" = "Watch this" ]
}
