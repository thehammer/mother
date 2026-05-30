#!/usr/bin/env bats
# pipeline_driver.bats — tests for W4: _run_pipeline_job, the per-tick
# pipeline orchestrator wired into mother-runner.
#
# Tests drive the driver by calling `mother-runner --driver-tick`, which
# runs one tick of _run_pipeline_job and exits without starting the daemon
# loop.  All assertions inspect the job JSON and events/<id>.jsonl files
# written to the isolated MOTHER_ROOT tree set up by setup_mother_env.

load 'test_helper'

# ---------------------------------------------------------------------------
# Setup / teardown

setup() {
    setup_mother_env
    mkdir -p "$RUNNER_DIR/children"

    # Real git repo — phase_render_input (called by review-phase) needs one.
    export TEST_REPO_DIR="$MOTHER_ROOT/testrepo"
    git init -q "$TEST_REPO_DIR"
    git -C "$TEST_REPO_DIR" config user.email "test@test.com"
    git -C "$TEST_REPO_DIR" config user.name "Test"
    touch "$TEST_REPO_DIR/README.md"
    git -C "$TEST_REPO_DIR" add -A
    git -C "$TEST_REPO_DIR" commit -q -m "init"

    # Mock gh so advisory PR comments don't fail.
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"

    # Mock bishop (posture bias must not affect pipeline driver).
    cat > "$_MOCK_BIN/bishop" <<'BISHOP'
#!/usr/bin/env bash
if [ "${1:-}" = "get" ] && [ "${2:-}" = "posture" ]; then
    echo "${MOCK_BISHOP_POSTURE:-normal}"
fi
exit 0
BISHOP
    chmod +x "$_MOCK_BIN/bishop"

    export MOCK_CLAUDE_ARGS_FILE="$MOTHER_ROOT/mock-claude-args"
    export MOCK_CLAUDE_EXIT=0

    # Disable posture bias to keep tier fields clean.
    export MOTHER_POSTURE_ENABLED=0

    # Always enable the pipeline driver unless a test overrides it.
    export MOTHER_PIPELINE_ENABLED=1
    export MOTHER_PIPELINE_CYCLE_CAP=3
}

teardown() {
    teardown_mother_env
    rm -rf "${TEST_REPO_DIR:-}"
}

# ---------------------------------------------------------------------------
# Helpers

# Run one pipeline driver tick.
_driver_tick() {
    run mother-runner --driver-tick
}

# Build a pipeline job with phase=review, state=succeeded, one reviewer (perri),
# and the given extra jq filter applied on top.
_make_review_job() {
    local id="$1" extra="${2:-.}"
    make_pipeline_job "$id" "marty" \
        '.repo_path = "'"$TEST_REPO_DIR"'"
        | .pipeline.reviewers = ["perri"]
        | .pipeline.review_cycle = 0
        | .pipeline.cycle_cap = 3
        | .pipeline.phase = "review"
        | .state = "succeeded"' \
        | jq "$extra" > "$JOBS_DIR/$id.json"
    # make_pipeline_job already wrote to JOBS_DIR; overwrite with the filter.
    # Simpler: call make_pipeline_job then patch.
    make_pipeline_job "$id" "marty" \
        '.repo_path = "'"$TEST_REPO_DIR"'"
        | .pipeline.reviewers = ["perri"]
        | .pipeline.review_cycle = 0
        | .pipeline.cycle_cap = 3'
    local merged
    merged=$(jq \
        '.pipeline.phase = "review" | .state = "succeeded"' \
        "$JOBS_DIR/$id.json")
    merged=$(printf '%s' "$merged" | jq "$extra")
    printf '%s' "$merged" > "$JOBS_DIR/$id.json"
}

# Canonical stdout for a review session with a single cody-targeting finding.
_cody_finding_stdout() {
    cat <<'EOF'
I reviewed the code.

```findings
[
  {
    "id": "f1",
    "target": "cody",
    "severity": "blocking",
    "summary": "Missing null check in processJob",
    "detail": "processJob() does not handle nil input.",
    "location": "job.go:42"
  }
]
```
EOF
}

# Stdout for a review with a human-blocking finding.
_human_blocking_stdout() {
    cat <<'EOF'
Critical issue found.

```findings
[
  {
    "id": "f1",
    "target": "human",
    "severity": "blocking",
    "summary": "Security vulnerability in auth flow",
    "detail": "Auth tokens are logged in plaintext.",
    "location": "auth.go:100"
  }
]
```
EOF
}

# Stdout for a review with a human-advisory finding only.
_human_advisory_stdout() {
    cat <<'EOF'
Minor suggestion noted.

```findings
[
  {
    "id": "f1",
    "target": "human",
    "severity": "advisory",
    "summary": "Consider adding README section",
    "detail": "A README section on configuration would be helpful.",
    "location": "README.md"
  }
]
```
EOF
}

# Stdout for a review with both redd and marty findings (skip cody).
_redd_marty_findings_stdout() {
    cat <<'EOF'
Multiple issues found.

```findings
[
  {
    "id": "f1",
    "target": "redd",
    "severity": "blocking",
    "summary": "Missing test for edge case",
    "detail": "No test for empty input.",
    "location": "job_test.go:10"
  },
  {
    "id": "f2",
    "target": "marty",
    "severity": "advisory",
    "summary": "Duplicate code",
    "detail": "Lines 40-55 are duplicated.",
    "location": "job.go:40"
  }
]
```
EOF
}

# Stdout for a review with both a human-blocking finding AND a cody finding.
# Used to test that human-blocking short-circuits the B4 decision.
_mixed_human_cody_stdout() {
    printf '%s\n' 'Review findings.' ''
    printf '```findings\n'
    printf '%s\n' '[' \
        '  {"id":"f1","target":"human","severity":"blocking","summary":"Security issue"},' \
        '  {"id":"f2","target":"cody","severity":"blocking","summary":"Missing error handling"}' \
        ']'
    printf '```\n'
}

# Stdout for a review with no findings block (treated as empty by review-phase).
_no_block_stdout() {
    echo "Looks good to me."
}

# ===========================================================================
# Kill switch
# ===========================================================================

@test "kill switch: MOTHER_PIPELINE_ENABLED=0 leaves pipeline job untouched" {
    make_pipeline_job "ks-1" "redd" '.state = "succeeded"'

    MOTHER_PIPELINE_ENABLED=0 run mother-runner --driver-tick
    [ "$status" -eq 0 ]

    # State and phase must be unchanged.
    run jq -r '.state' "$JOBS_DIR/ks-1.json"
    [ "$output" = "succeeded" ]
    run jq -r '.pipeline.phase' "$JOBS_DIR/ks-1.json"
    [ "$output" = "redd" ]

    # No pipeline events emitted.
    run grep -l 'pipeline_phase_advance\|pipeline_shipped\|pipeline_blocked' \
        "$EVENTS_DIR/ks-1.jsonl" 2>/dev/null
    [ "$status" -ne 0 ]
}

# ===========================================================================
# Non-pipeline jobs ignored
# ===========================================================================

@test "non-pipeline job in succeeded state is ignored by the driver" {
    make_job "np-1" "succeeded" \
        '.suggested_config = {
           "cody":  {"model":"sonnet","effort":"medium","rationale":"t"},
           "redd":  {"model":"sonnet","effort":"medium","rationale":"t"},
           "marty": {"model":"sonnet","effort":"medium","rationale":"t"},
           "perri": {"model":"sonnet","effort":"medium","rationale":"t"}
         }'

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/np-1.json"
    [ "$output" = "succeeded" ]
}

# ===========================================================================
# Build-phase advancement (succeeded → next phase or → review)
# ===========================================================================

@test "build phase: succeeded+redd advances phase to cody and resets to ready" {
    make_pipeline_job "bp-1" "redd" '.state = "succeeded"'

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.pipeline.phase' "$JOBS_DIR/bp-1.json"
    [ "$output" = "cody" ]
    run jq -r '.state' "$JOBS_DIR/bp-1.json"
    [ "$output" = "ready" ]
    run jq -r '.activity' "$JOBS_DIR/bp-1.json"
    [ "$output" = "pipeline_phase" ]

    # Worker fields cleared.
    run jq -r '.worker_pid // "null"' "$JOBS_DIR/bp-1.json"
    [ "$output" = "null" ]
    run jq -r '.finished_at // "null"' "$JOBS_DIR/bp-1.json"
    [ "$output" = "null" ]

    # Phase-advance event emitted.
    assert_event_kind "bp-1" "pipeline_phase_advance"
}

@test "build phase: succeeded+cody advances phase to marty and resets to ready" {
    make_pipeline_job "bp-2" "cody" '.state = "succeeded"'

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.pipeline.phase' "$JOBS_DIR/bp-2.json"
    [ "$output" = "marty" ]
    run jq -r '.state' "$JOBS_DIR/bp-2.json"
    [ "$output" = "ready" ]
}

@test "build phase: succeeded+marty advances phase to review (state stays succeeded)" {
    make_pipeline_job "bp-3" "marty" '.state = "succeeded"'

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.pipeline.phase' "$JOBS_DIR/bp-3.json"
    [ "$output" = "review" ]
    # State stays succeeded — normal dispatch must not try to spawn review.
    run jq -r '.state' "$JOBS_DIR/bp-3.json"
    [ "$output" = "succeeded" ]

    assert_event_kind "bp-3" "pipeline_phase_advance"
}

@test "build phase: done/blocked phases are skipped by the driver" {
    make_pipeline_job "bp-skip-done" "marty" \
        '.state = "succeeded" | .pipeline.phase = "done"'
    make_pipeline_job "bp-skip-blocked" "marty" \
        '.state = "awaiting" | .pipeline.phase = "blocked"'

    _driver_tick
    [ "$status" -eq 0 ]

    # Neither job should have changed.
    run jq -r '.pipeline.phase' "$JOBS_DIR/bp-skip-done.json"
    [ "$output" = "done" ]
    run jq -r '.pipeline.phase' "$JOBS_DIR/bp-skip-blocked.json"
    [ "$output" = "blocked" ]
}

# ===========================================================================
# B6: review re-runs do NOT escalate the tier
# ===========================================================================

@test "B6: tier and escalation_count are unchanged after a build-phase advance" {
    make_pipeline_job "b6-1" "redd" \
        '.state = "succeeded" | .current_tier = "tier_0" | .escalation_count = 0'

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.current_tier' "$JOBS_DIR/b6-1.json"
    [ "$output" = "tier_0" ]
    run jq -r '.escalation_count' "$JOBS_DIR/b6-1.json"
    [ "$output" = "0" ]
}

# ===========================================================================
# B4 ship
# ===========================================================================

@test "B4 ship: empty findings → state=succeeded, phase=done, pipeline_reviewed=true" {
    _make_review_job "ship-1"
    export MOCK_CLAUDE_STDOUT="$(_no_block_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/ship-1.json"
    [ "$output" = "succeeded" ]
    run jq -r '.pipeline.phase' "$JOBS_DIR/ship-1.json"
    [ "$output" = "done" ]
    run jq -r '.pipeline_reviewed' "$JOBS_DIR/ship-1.json"
    [ "$output" = "true" ]
    run jq -r '.activity // "null"' "$JOBS_DIR/ship-1.json"
    [ "$output" = "null" ]

    assert_event_kind "ship-1" "pipeline_shipped"
}

@test "B4 ship: human-advisory findings do not hold loop open; land in pipeline.advisories" {
    _make_review_job "ship-2"
    export MOCK_CLAUDE_STDOUT="$(_human_advisory_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    # Still ships — advisory findings must NOT block.
    run jq -r '.state' "$JOBS_DIR/ship-2.json"
    [ "$output" = "succeeded" ]
    run jq -r '.pipeline.phase' "$JOBS_DIR/ship-2.json"
    [ "$output" = "done" ]

    # Advisories appear in pipeline.advisories.
    run jq -r '.pipeline.advisories | length' "$JOBS_DIR/ship-2.json"
    [ "$output" = "1" ]
    run jq -r '.pipeline.advisories[0].target' "$JOBS_DIR/ship-2.json"
    [ "$output" = "human" ]

    assert_event_kind "ship-2" "pipeline_shipped"
}

# ===========================================================================
# B4 block — human-blocking finding
# ===========================================================================

@test "B4 block: human-blocking finding → state=awaiting, activity=pipeline_blocked" {
    _make_review_job "blk-1"
    export MOCK_CLAUDE_STDOUT="$(_human_blocking_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/blk-1.json"
    [ "$output" = "awaiting" ]
    run jq -r '.activity' "$JOBS_DIR/blk-1.json"
    [ "$output" = "pipeline_blocked" ]
    run jq -r '.pipeline.phase' "$JOBS_DIR/blk-1.json"
    [ "$output" = "blocked" ]

    assert_event_kind "blk-1" "pipeline_blocked"
}

@test "B4 block: human-blocking short-circuits even when agent findings also present" {
    # Build a findings block that has BOTH a human-blocking and a cody finding.
    _make_review_job "blk-2"
    export MOCK_CLAUDE_STDOUT="$(_mixed_human_cody_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    # Must block (not continue) because human-blocking short-circuits.
    run jq -r '.state' "$JOBS_DIR/blk-2.json"
    [ "$output" = "awaiting" ]
    run jq -r '.pipeline.phase' "$JOBS_DIR/blk-2.json"
    [ "$output" = "blocked" ]
    assert_event_kind "blk-2" "pipeline_blocked"
}

# ===========================================================================
# B4 continue + B5 skip
# ===========================================================================

@test "B4 continue: cody finding → review_cycle incremented, pending_agents=[cody], phase=cody" {
    _make_review_job "cont-1"
    export MOCK_CLAUDE_STDOUT="$(_cody_finding_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/cont-1.json"
    [ "$output" = "ready" ]
    run jq -r '.pipeline.phase' "$JOBS_DIR/cont-1.json"
    [ "$output" = "cody" ]
    run jq -r '.pipeline.review_cycle' "$JOBS_DIR/cont-1.json"
    [ "$output" = "1" ]
    run jq -r '.pipeline.pending_agents | sort | join(",")' "$JOBS_DIR/cont-1.json"
    [ "$output" = "cody" ]
    run jq -r '.activity' "$JOBS_DIR/cont-1.json"
    [ "$output" = "pipeline_phase" ]

    assert_event_kind "cont-1" "pipeline_cycle_continued"
}

@test "B5 skip: redd+marty findings → pending_agents=[marty,redd], phase starts at redd (forward order)" {
    _make_review_job "b5-1"
    export MOCK_CLAUDE_STDOUT="$(_redd_marty_findings_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    # First pending agent in forward order is redd.
    run jq -r '.pipeline.phase' "$JOBS_DIR/b5-1.json"
    [ "$output" = "redd" ]

    # pending_agents contains both redd and marty but NOT cody.
    run jq -r '.pipeline.pending_agents | contains(["cody"])' "$JOBS_DIR/b5-1.json"
    [ "$output" = "false" ]
    run jq -r '.pipeline.pending_agents | contains(["redd"])' "$JOBS_DIR/b5-1.json"
    [ "$output" = "true" ]
    run jq -r '.pipeline.pending_agents | contains(["marty"])' "$JOBS_DIR/b5-1.json"
    [ "$output" = "true" ]
}

@test "B5 skip: on re-run, succeeded+redd skips cody when pending_agents=[marty]" {
    # Simulate a continue cycle that set pending_agents to [marty] only.
    make_pipeline_job "b5-skip" "redd" \
        '.state = "succeeded"
        | .pipeline.review_cycle = 1
        | .pipeline.pending_agents = ["marty"]'

    _driver_tick
    [ "$status" -eq 0 ]

    # Driver should skip cody and jump straight to marty.
    run jq -r '.pipeline.phase' "$JOBS_DIR/b5-skip.json"
    [ "$output" = "marty" ]
    run jq -r '.state' "$JOBS_DIR/b5-skip.json"
    [ "$output" = "ready" ]
}

@test "B5 skip: on re-run, succeeded+cody with pending_agents=[cody] → advances to review (no more pending agents)" {
    # cody is the last pending agent; after it succeeds, move to review.
    make_pipeline_job "b5-last" "cody" \
        '.state = "succeeded"
        | .pipeline.review_cycle = 1
        | .pipeline.pending_agents = ["cody"]'

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.pipeline.phase' "$JOBS_DIR/b5-last.json"
    [ "$output" = "review" ]
    run jq -r '.state' "$JOBS_DIR/b5-last.json"
    [ "$output" = "succeeded" ]
}

# ===========================================================================
# B4 cap hit
# ===========================================================================

@test "B4 cap hit: review_cycle at cap → blocked, pipeline_cap_hit event emitted" {
    # cycle_cap=3, review_cycle=3 → next would be 4 > 3 → cap hit.
    _make_review_job "cap-1" '.pipeline.review_cycle = 3 | .pipeline.cycle_cap = 3'
    export MOCK_CLAUDE_STDOUT="$(_cody_finding_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/cap-1.json"
    [ "$output" = "awaiting" ]
    run jq -r '.activity' "$JOBS_DIR/cap-1.json"
    [ "$output" = "pipeline_blocked" ]
    run jq -r '.pipeline.phase' "$JOBS_DIR/cap-1.json"
    [ "$output" = "blocked" ]

    assert_event_kind "cap-1" "pipeline_cap_hit"

    # Event must carry review_cycle, cap, and outstanding findings.
    local events_file="$EVENTS_DIR/cap-1.jsonl"
    run grep '"pipeline_cap_hit"' "$events_file"
    [[ "$output" =~ '"review_cycle":3' ]]
    [[ "$output" =~ '"cap":3' ]]
    [[ "$output" =~ '"outstanding"' ]]
}

@test "B4 cap hit: MOTHER_PIPELINE_CYCLE_CAP env overrides default cap" {
    # cap env = 1, review_cycle = 1 → next = 2 > 1 → cap hit.
    _make_review_job "cap-env" '.pipeline.review_cycle = 1 | .pipeline.cycle_cap = null'
    export MOCK_CLAUDE_STDOUT="$(_cody_finding_stdout)"

    MOTHER_PIPELINE_CYCLE_CAP=1 run mother-runner --driver-tick

    run jq -r '.state' "$JOBS_DIR/cap-env.json"
    [ "$output" = "awaiting" ]
    assert_event_kind "cap-env" "pipeline_cap_hit"
}

@test "B4 cap hit: per-job cycle_cap overrides env cap" {
    # per-job cap=2, env cap=5; review_cycle=2 → next=3 > 2 → cap hit.
    _make_review_job "cap-job" '.pipeline.review_cycle = 2 | .pipeline.cycle_cap = 2'
    export MOCK_CLAUDE_STDOUT="$(_cody_finding_stdout)"

    MOTHER_PIPELINE_CYCLE_CAP=5 run mother-runner --driver-tick

    run jq -r '.state' "$JOBS_DIR/cap-job.json"
    [ "$output" = "awaiting" ]
    assert_event_kind "cap-job" "pipeline_cap_hit"
}

# ===========================================================================
# Concurrent review mechanics
# ===========================================================================

@test "concurrent review: multiple reviewers each write to their own slot" {
    make_pipeline_job "conc-1" "marty" \
        '.repo_path = "'"$TEST_REPO_DIR"'"
        | .pipeline.reviewers = ["perri","archie"]
        | .pipeline.review_cycle = 0
        | .pipeline.cycle_cap = 3'
    local merged
    merged=$(jq '.pipeline.phase = "review" | .state = "succeeded"' \
        "$JOBS_DIR/conc-1.json")
    printf '%s' "$merged" > "$JOBS_DIR/conc-1.json"

    export MOCK_CLAUDE_STDOUT="$(_no_block_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    # Both reviewer slots should exist (even though findings are empty).
    run jq -r '.pipeline.reviewer_findings | keys | sort | join(",")' \
        "$JOBS_DIR/conc-1.json"
    [ "$output" = "archie,perri" ]
}

@test "concurrent review: reviewer returning exit 2 (parse error) is tolerated" {
    _make_review_job "conc-parse-err"
    # An invalid target causes review-phase to return exit 2 (W3 contract).
    export MOCK_CLAUDE_STDOUT="$(cat <<'EOF'
Review.

\`\`\`findings
[{"id":"f1","target":"INVALID","severity":"blocking","summary":"bad"}]
\`\`\`
EOF
)"

    # Even with a parse error, the driver must not fail.
    _driver_tick
    [ "$status" -eq 0 ]

    # parse-error reviewer writes no slot → merge-findings returns [] → ship.
    run jq -r '.pipeline.phase' "$JOBS_DIR/conc-parse-err.json"
    [ "$output" = "done" ]
    run jq -r '.state' "$JOBS_DIR/conc-parse-err.json"
    [ "$output" = "succeeded" ]
}

@test "concurrent review: findings_history is appended each cycle" {
    _make_review_job "hist-1"
    export MOCK_CLAUDE_STDOUT="$(_cody_finding_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    # After first cycle that continues, findings_history should have one entry.
    run jq -r '.pipeline.findings_history | length' "$JOBS_DIR/hist-1.json"
    [ "$output" = "1" ]
    run jq -r '.pipeline.findings_history[0].cycle' "$JOBS_DIR/hist-1.json"
    [ "$output" = "0" ]
}

# ===========================================================================
# Empty reviewer list (misconfiguration)
# ===========================================================================

@test "empty reviewers: pipeline_error event emitted, job blocked for human" {
    make_pipeline_job "emp-rev" "marty" \
        '.state = "succeeded"
        | .pipeline.phase = "review"
        | .pipeline.reviewers = []'

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/emp-rev.json"
    [ "$output" = "awaiting" ]
    run jq -r '.activity' "$JOBS_DIR/emp-rev.json"
    [ "$output" = "pipeline_blocked" ]
    run jq -r '.pipeline.phase' "$JOBS_DIR/emp-rev.json"
    [ "$output" = "blocked" ]

    assert_event_kind "emp-rev" "pipeline_error"
}

# ===========================================================================
# review_cycle_count (field: pipeline.review_cycle)
# ===========================================================================

@test "review_cycle: incremented exactly once per continue-cycle" {
    _make_review_job "rc-1" '.pipeline.review_cycle = 0'
    export MOCK_CLAUDE_STDOUT="$(_cody_finding_stdout)"

    _driver_tick
    [ "$status" -eq 0 ]

    run jq -r '.pipeline.review_cycle' "$JOBS_DIR/rc-1.json"
    [ "$output" = "1" ]

    # Run another tick — job is now ready (not succeeded), so driver skips it.
    _driver_tick
    run jq -r '.pipeline.review_cycle' "$JOBS_DIR/rc-1.json"
    [ "$output" = "1" ]  # Not incremented again
}
