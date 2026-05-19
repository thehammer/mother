#!/usr/bin/env bats
# dependencies.bats — tests for the `waiting` state and dependency gating.

load 'test_helper'

setup() {
    setup_mother_env
    export FAKE_REPO="$MOTHER_ROOT/testrepo"
    mkdir -p "$FAKE_REPO/.git"

    # Disable posture and quota so they don't interfere.
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_ESCALATION_ENABLED=0
    export MOTHER_ADHERENCE_ENABLED=0
    export MOTHER_CONTINUATIONS_ENABLED=0

    # Shim bin for gh overrides — installed per-test.
    export SHIM_BIN="$MOTHER_ROOT/shim-bin"
    mkdir -p "$SHIM_BIN"
    # Ensure shim-bin is first on PATH (after the already-prepended mock-bin).
    export PATH="$SHIM_BIN:$PATH"
}

teardown() {
    teardown_mother_env
}

# --------------------------------------------------------------------------
# Helper: install a gh shim that returns a given PR state JSON.

install_gh_shim() {
    local state="$1"   # e.g. MERGED or OPEN
    # The shim must echo just the state value (not JSON) because _pr_is_merged
    # calls `gh pr view --json state -q .state` and expects the raw value.
    cat > "$SHIM_BIN/gh" <<SHIM
#!/usr/bin/env bash
echo "${state}"
SHIM
    chmod +x "$SHIM_BIN/gh"
}

# --------------------------------------------------------------------------
# mother add with a dep that is NOT yet satisfied → child enters waiting

@test "mother add --depends-on queued dep → child state is waiting" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    # Create a parent job in queued state.
    local parent_id="parent-$(date +%s)"
    make_job "$parent_id" "queued"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/child \
        --depends-on "$parent_id"

    [ "$status" -eq 0 ]
    local child_id="$output"
    [ -n "$child_id" ]

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "waiting" ]

    run jq -c '.depends_on' "$JOBS_DIR/$child_id.json"
    [ "$output" = "[\"$parent_id\"]" ]
}

# --------------------------------------------------------------------------
# mother add with a no-PR dep that has succeeded → child enters queued directly

@test "mother add --depends-on no-pr succeeded dep → child state is queued" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    # Parent: succeeded + no_pr = true (no gh call needed).
    local parent_id="parent-$(date +%s)"
    make_job "$parent_id" "succeeded" '.no_pr = true'

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/child \
        --depends-on "$parent_id"

    [ "$status" -eq 0 ]
    local child_id="$output"

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "queued" ]
}

# --------------------------------------------------------------------------
# v1 single-dep enforcement: comma list with 2 ids is rejected

@test "mother add --depends-on a,b exits non-zero and mentions single" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/child \
        --depends-on "id-one,id-two"

    [ "$status" -ne 0 ]
    [[ "$output" =~ single ]] || [[ "$stderr" =~ single ]]
}

# --------------------------------------------------------------------------
# _promote_ready: no-PR parent succeeds → waiting child promoted to queued

@test "_promote_ready promotes waiting child to queued when no-PR parent succeeds" {
    # Source state.sh directly so we can call _promote_ready.
    source "$MOTHER_LIB_DIR/state.sh"

    local parent_id="parent-noPR"
    local child_id="child-of-parent"

    make_job "$parent_id" "succeeded" '.no_pr = true'
    make_job "$child_id" "waiting"
    jq --arg dep "$parent_id" '.depends_on = [$dep]' \
        "$JOBS_DIR/$child_id.json" > "$JOBS_DIR/$child_id.json.tmp" \
        && mv "$JOBS_DIR/$child_id.json.tmp" "$JOBS_DIR/$child_id.json"

    _promote_ready

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "queued" ]
}

# --------------------------------------------------------------------------
# _promote_ready cascade: cancelled parent → waiting child cancelled

@test "_promote_ready cancels waiting child when parent is cancelled" {
    source "$MOTHER_LIB_DIR/state.sh"

    local parent_id="parent-cancelled"
    local child_id="child-of-cancelled"

    make_job "$parent_id" "cancelled"
    make_job "$child_id" "waiting"
    jq --arg dep "$parent_id" '.depends_on = [$dep]' \
        "$JOBS_DIR/$child_id.json" > "$JOBS_DIR/$child_id.json.tmp" \
        && mv "$JOBS_DIR/$child_id.json.tmp" "$JOBS_DIR/$child_id.json"

    _promote_ready

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "cancelled" ]

    # Verify cancellation detail carries reason and parent_id.
    run grep '"reason":"parent_cancelled"' "$EVENTS_DIR/$child_id.jsonl"
    [ "$status" -eq 0 ]
    run grep "\"parent_id\":\"$parent_id\"" "$EVENTS_DIR/$child_id.jsonl"
    [ "$status" -eq 0 ]
}

# --------------------------------------------------------------------------
# _promote_ready: --keep-on-parent-cancel keeps child in waiting

@test "_promote_ready leaves child in waiting when keep_on_parent_cancel is true" {
    source "$MOTHER_LIB_DIR/state.sh"

    local parent_id="parent-cancelled2"
    local child_id="child-keep"

    make_job "$parent_id" "cancelled"
    make_job "$child_id" "waiting"
    jq --arg dep "$parent_id" '.depends_on = [$dep] | .keep_on_parent_cancel = true' \
        "$JOBS_DIR/$child_id.json" > "$JOBS_DIR/$child_id.json.tmp" \
        && mv "$JOBS_DIR/$child_id.json.tmp" "$JOBS_DIR/$child_id.json"

    _promote_ready

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "waiting" ]
}

# --------------------------------------------------------------------------
# mother cancel works on a waiting job

@test "mother cancel on a waiting job transitions directly to cancelled" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    local parent_id="parent-running"
    make_job "$parent_id" "running"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/child \
        --depends-on "$parent_id"

    [ "$status" -eq 0 ]
    local child_id="$output"

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "waiting" ]

    run mother cancel "$child_id"
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "cancelled" ]
}

# --------------------------------------------------------------------------
# mother list: WAIT-ON column appears when waiting rows present

@test "mother list shows WAIT-ON column when a waiting job exists" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    local parent_id="parent-for-list"
    make_job "$parent_id" "queued"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/child \
        --depends-on "$parent_id"

    [ "$status" -eq 0 ]

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "WAIT-ON" ]]
}

@test "mother list shows dep_id:pending in WAIT-ON column for waiting job" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    local parent_id="parent-for-list2"
    make_job "$parent_id" "queued"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/child \
        --depends-on "$parent_id"

    [ "$status" -eq 0 ]

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" =~ "${parent_id}:pending" ]]
}

@test "mother list has no WAIT-ON column when no waiting jobs exist" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/no-dep

    [ "$status" -eq 0 ]

    run mother list
    [ "$status" -eq 0 ]
    # WAIT-ON column should NOT be present.
    [[ ! "$output" =~ "WAIT-ON" ]]
}

# --------------------------------------------------------------------------
# mother list --format json: shape is unchanged

@test "mother list --format json does not add WAIT-ON to output" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    local parent_id="parent-json"
    make_job "$parent_id" "queued"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/child \
        --depends-on "$parent_id"

    [ "$status" -eq 0 ]
    local child_id="$output"

    run mother list --format json
    [ "$status" -eq 0 ]
    # Save JSON before $output is overwritten by subsequent run commands.
    local json_output="$output"
    # Output is valid JSON array with at least one element.
    run jq 'length' <<< "$json_output"
    [ "$status" -eq 0 ]
    [ "$output" -ge 1 ]
    # No wait_on key in the JSON items (WAIT-ON is a display-only column).
    result=$(jq -e 'all(has("wait_on") | not)' <<< "$json_output")
    [ "$result" = "true" ]
}

# --------------------------------------------------------------------------
# PR-merge gating: gh shim returns MERGED → promotion happens

@test "_promote_ready promotes waiting child when gh returns MERGED" {
    source "$MOTHER_LIB_DIR/state.sh"
    install_gh_shim "MERGED"

    local parent_id="parent-merged"
    local child_id="child-of-merged"

    # Parent: succeeded with a pr_url, no_pr=false.
    make_job "$parent_id" "succeeded"
    jq '.pr_url = "https://github.com/test/repo/pull/42" | .no_pr = false' \
        "$JOBS_DIR/$parent_id.json" > "$JOBS_DIR/$parent_id.json.tmp" \
        && mv "$JOBS_DIR/$parent_id.json.tmp" "$JOBS_DIR/$parent_id.json"

    make_job "$child_id" "waiting"
    jq --arg dep "$parent_id" '.depends_on = [$dep]' \
        "$JOBS_DIR/$child_id.json" > "$JOBS_DIR/$child_id.json.tmp" \
        && mv "$JOBS_DIR/$child_id.json.tmp" "$JOBS_DIR/$child_id.json"

    _promote_ready

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "queued" ]
}

# --------------------------------------------------------------------------
# PR-merge gating: gh shim returns OPEN → child stays waiting

@test "_promote_ready leaves waiting child when gh returns OPEN" {
    source "$MOTHER_LIB_DIR/state.sh"
    install_gh_shim "OPEN"
    # Zero out cache TTL so no stale cache interferes.
    export MOTHER_DEP_PR_POLL_INTERVAL=0

    local parent_id="parent-open"
    local child_id="child-of-open"

    make_job "$parent_id" "succeeded"
    jq '.pr_url = "https://github.com/test/repo/pull/99" | .no_pr = false' \
        "$JOBS_DIR/$parent_id.json" > "$JOBS_DIR/$parent_id.json.tmp" \
        && mv "$JOBS_DIR/$parent_id.json.tmp" "$JOBS_DIR/$parent_id.json"

    make_job "$child_id" "waiting"
    jq --arg dep "$parent_id" '.depends_on = [$dep]' \
        "$JOBS_DIR/$child_id.json" > "$JOBS_DIR/$child_id.json.tmp" \
        && mv "$JOBS_DIR/$child_id.json.tmp" "$JOBS_DIR/$child_id.json"

    _promote_ready

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "waiting" ]
}

# --------------------------------------------------------------------------
# keep_on_parent_cancel is persisted in job JSON

@test "mother add --keep-on-parent-cancel stores flag in job JSON" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    local parent_id="parent-kpc"
    make_job "$parent_id" "queued"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/keep \
        --depends-on "$parent_id" \
        --keep-on-parent-cancel

    [ "$status" -eq 0 ]
    local child_id="$output"

    run jq -r '.keep_on_parent_cancel' "$JOBS_DIR/$child_id.json"
    [ "$output" = "true" ]
}

# --------------------------------------------------------------------------
# mother retry re-evaluates dep and sets waiting when dep not satisfied

@test "mother retry sets state to waiting when dep is not satisfied" {
    source "$MOTHER_LIB_DIR/state.sh"

    local parent_id="parent-not-merged"
    local child_id="child-retry"

    make_job "$parent_id" "running"
    make_job "$child_id" "failed"
    jq --arg dep "$parent_id" '.depends_on = [$dep]' \
        "$JOBS_DIR/$child_id.json" > "$JOBS_DIR/$child_id.json.tmp" \
        && mv "$JOBS_DIR/$child_id.json.tmp" "$JOBS_DIR/$child_id.json"

    run mother retry "$child_id"
    [ "$status" -eq 0 ]

    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "waiting" ]
}

@test "mother retry --skip-dep-check bypasses dep re-evaluation" {
    source "$MOTHER_LIB_DIR/state.sh"

    local parent_id="parent-skip"
    local child_id="child-skip"

    # Parent still running — dep not satisfied.
    make_job "$parent_id" "running"
    make_job "$child_id" "failed"
    jq --arg dep "$parent_id" '.depends_on = [$dep]' \
        "$JOBS_DIR/$child_id.json" > "$JOBS_DIR/$child_id.json.tmp" \
        && mv "$JOBS_DIR/$child_id.json.tmp" "$JOBS_DIR/$child_id.json"

    run mother retry --skip-dep-check "$child_id"
    [ "$status" -eq 0 ]

    # With --skip-dep-check, old logic: parent not succeeded → queued.
    run jq -r '.state' "$JOBS_DIR/$child_id.json"
    [ "$output" = "queued" ]
}

# --------------------------------------------------------------------------
# Waiting event has dep_id in detail

@test "waiting event detail includes dep_id" {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"

    local parent_id="parent-event"
    make_job "$parent_id" "queued"

    run mother add \
        --plan-file "$plan" \
        --repo testrepo \
        --repo-path "$FAKE_REPO" \
        --branch feature/child \
        --depends-on "$parent_id"

    [ "$status" -eq 0 ]
    local child_id="$output"

    run grep '"kind":"waiting"' "$EVENTS_DIR/$child_id.jsonl"
    [ "$status" -eq 0 ]
    run grep "\"dep_id\":\"$parent_id\"" "$EVENTS_DIR/$child_id.jsonl"
    [ "$status" -eq 0 ]
}
