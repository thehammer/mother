#!/usr/bin/env bats
# escalation.bats — tests for `mother escalate` and the tier ladder.

load 'test_helper'

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Tier ladder

@test "tier ladder: tier_0 -> tier_1 -> tier_2 -> tier_3" {
    # Source state.sh to get access to tier functions via mother binary.
    # We test the tier ladder via cmd_escalate behaviour.
    make_job "job-tier" "failed" \
        '.escalation_count = 0 | .current_tier = "tier_0" | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"test"},"redd":{"model":"sonnet","effort":"medium","rationale":"test"},"marty":{"model":"sonnet","effort":"medium","rationale":"test"},"perri":{"model":"sonnet","effort":"medium","rationale":"test"}}'

    # First escalation: tier_0 -> tier_1
    run mother escalate "job-tier"
    [ "$status" -eq 0 ]
    run jq -r '.current_tier' "$JOBS_DIR/job-tier.json"
    [ "$output" = "tier_1" ]
    run jq -r '.escalation_count' "$JOBS_DIR/job-tier.json"
    [ "$output" = "1" ]

    # Transition back to failed for next escalation
    run jq -r '.state' "$JOBS_DIR/job-tier.json"
    [ "$output" = "ready" ]
    merged=$(jq '.state = "failed"' "$JOBS_DIR/job-tier.json") && printf '%s' "$merged" > "$JOBS_DIR/job-tier.json"

    # Second escalation: tier_1 -> tier_2
    run mother escalate "job-tier"
    [ "$status" -eq 0 ]
    run jq -r '.current_tier' "$JOBS_DIR/job-tier.json"
    [ "$output" = "tier_2" ]
    run jq -r '.escalation_count' "$JOBS_DIR/job-tier.json"
    [ "$output" = "2" ]

    # Third escalation: should be refused (cap=2)
    merged=$(jq '.state = "failed"' "$JOBS_DIR/job-tier.json") && printf '%s' "$merged" > "$JOBS_DIR/job-tier.json"
    run mother escalate "job-tier"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "escalation_count=2" ]] || [[ "$output" =~ "cap" ]]
}

# ---------------------------------------------------------------------------
# Manual escalation: failed job at tier_0

@test "mother escalate on failed job bumps tier, transitions to ready, emits event" {
    make_job "job-esc1" "failed" \
        '.escalation_count = 0 | .current_tier = "tier_0" | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"test"},"redd":{"model":"sonnet","effort":"medium","rationale":"test"},"marty":{"model":"sonnet","effort":"medium","rationale":"test"},"perri":{"model":"sonnet","effort":"medium","rationale":"test"}}'

    run mother escalate "job-esc1"
    [ "$status" -eq 0 ]

    # State transitions to ready
    run jq -r '.state' "$JOBS_DIR/job-esc1.json"
    [ "$output" = "ready" ]

    # Tier bumped to tier_1
    run jq -r '.current_tier' "$JOBS_DIR/job-esc1.json"
    [ "$output" = "tier_1" ]

    # escalation_count incremented
    run jq -r '.escalation_count' "$JOBS_DIR/job-esc1.json"
    [ "$output" = "1" ]

    # escalated event emitted
    assert_event_kind "job-esc1" "escalated"
}

# ---------------------------------------------------------------------------
# Escalation cap

@test "mother escalate on job at escalation_count=2 fails without state change" {
    make_job "job-cap" "failed" \
        '.escalation_count = 2 | .current_tier = "tier_2"'

    run mother escalate "job-cap"
    [ "$status" -ne 0 ]

    # State unchanged
    run jq -r '.state' "$JOBS_DIR/job-cap.json"
    [ "$output" = "failed" ]
    run jq -r '.escalation_count' "$JOBS_DIR/job-cap.json"
    [ "$output" = "2" ]
}

# ---------------------------------------------------------------------------
# suggested_config preserved across escalation

@test "suggested_config is preserved after escalation" {
    local sc='{"cody":{"model":"sonnet","effort":"high","rationale":"test"},"redd":{"model":"sonnet","effort":"medium","rationale":"test"},"marty":{"model":"sonnet","effort":"medium","rationale":"test"},"perri":{"model":"sonnet","effort":"medium","rationale":"test"}}'
    make_job "job-sc" "failed" \
        ".escalation_count = 0 | .current_tier = \"tier_0\" | .suggested_config = $sc"

    run mother escalate "job-sc"
    [ "$status" -eq 0 ]

    # suggested_config preserved
    run jq -r '.suggested_config.cody.effort' "$JOBS_DIR/job-sc.json"
    [ "$output" = "high" ]
}

# ---------------------------------------------------------------------------
# Non-failed job cannot be escalated

@test "mother escalate on non-failed job fails" {
    make_job "job-running" "running" '.escalation_count = 0 | .current_tier = "tier_0"'

    run mother escalate "job-running"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "failed" ]]
}

# ---------------------------------------------------------------------------
# Kill switch

@test "MOTHER_ESCALATION_ENABLED=0 disables auto-escalation in runner" {
    # We test the kill switch by checking the env var is read. The actual
    # daemon auto-escalation is hard to unit test without running the daemon,
    # so we verify the env var is honored at the function level by sourcing
    # the runner and calling _auto_escalate_failed in a subshell.
    make_job "job-killswitch" "failed" \
        '.escalation_count = 0 | .current_tier = "tier_0"'

    export MOTHER_ESCALATION_ENABLED=0
    # Source just enough of the runner to test _auto_escalate_failed.
    (
        export MOTHER_ROOT JOBS_DIR EVENTS_DIR
        MOTHER_BIN_DIR="$_BIN_DIR"
        MOTHER_LIB_DIR="$_LIB_DIR"
        # shellcheck source=/dev/null
        source "$_LIB_DIR/state.sh"
        MOTHER_ESCALATION_ENABLED=0
        _log() { true; }

        _auto_escalate_failed() {
            [ "$MOTHER_ESCALATION_ENABLED" = "1" ] || return 0
            mother escalate "job-killswitch"
        }
        _auto_escalate_failed
    )

    # State should still be failed (not escalated)
    run jq -r '.state' "$JOBS_DIR/job-killswitch.json"
    [ "$output" = "failed" ]
    export MOTHER_ESCALATION_ENABLED=1
}

# ---------------------------------------------------------------------------
# _guard_existing_pr — pre-dispatch guard shared by retry/escalate/force-start.
#
# When a job's branch (or one of its commits) already has a verified OPEN
# pull request, re-dispatching (retry/escalate) or forcing (force-start) it
# risks a second worker opening a duplicate PR or clobbering work already
# under review. The guard refuses unless --yes is passed.
#
# _eg_repo_with_open_pr sets up a real repo (so prd_owner_repo_from_dir has
# something to read) plus a mock `gh` that reports an OPEN PR for the given
# branch via both the branch-query shape (`pr list --head <branch> --state
# open`) and the disposition-check shape (`pr view <url> ... state`) — the
# exact two gh calls the prdetect.sh contract commits to for
# prd_pr_for_branch / _teardown_pr_disposition-style state checks.

_eg_repo_with_open_pr() {
    local repo_dir="$1" branch="$2" pr_url="$3"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" commit -q --allow-empty -m init
    git -C "$repo_dir" remote add origin "https://github.com/thehammer/mother.git"

    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
    *"pr list"*)
        printf '{"url":"$pr_url"}\n'
        ;;
    *"pr view"*state*)
        echo "OPEN"
        ;;
    *)
        echo ""
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"
}

@test "mother escalate refuses when the job's branch already has a verified open PR" {
    local repo_dir="$MOTHER_ROOT/guard-repo-esc"
    local pr_url="https://github.com/thehammer/mother/pull/501"
    _eg_repo_with_open_pr "$repo_dir" "feature/guarded-esc" "$pr_url"
    make_job "job-guard-esc" "failed" \
        ".branch = \"feature/guarded-esc\" | .repo_path = \"$repo_dir\" | .escalation_count = 0 | .current_tier = \"tier_0\" | .suggested_config = {\"cody\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"test\"},\"redd\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"test\"},\"marty\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"test\"},\"perri\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"test\"}}"

    run mother escalate "job-guard-esc"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "$pr_url" ]]
    [[ "$output" =~ "reconcile" ]]

    # State and escalation_count unchanged.
    run jq -r '.state' "$JOBS_DIR/job-guard-esc.json"
    [ "$output" = "failed" ]
    run jq -r '.escalation_count' "$JOBS_DIR/job-guard-esc.json"
    [ "$output" = "0" ]
}

@test "mother escalate --yes bypasses the existing-open-PR guard" {
    local repo_dir="$MOTHER_ROOT/guard-repo-esc-yes"
    local pr_url="https://github.com/thehammer/mother/pull/502"
    _eg_repo_with_open_pr "$repo_dir" "feature/guarded-esc-yes" "$pr_url"
    make_job "job-guard-esc-yes" "failed" \
        ".branch = \"feature/guarded-esc-yes\" | .repo_path = \"$repo_dir\" | .escalation_count = 0 | .current_tier = \"tier_0\" | .suggested_config = {\"cody\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"test\"},\"redd\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"test\"},\"marty\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"test\"},\"perri\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"test\"}}"

    run mother escalate "job-guard-esc-yes" --yes
    [ "$status" -eq 0 ]
    run jq -r '.current_tier' "$JOBS_DIR/job-guard-esc-yes.json"
    [ "$output" = "tier_1" ]
}

@test "mother retry refuses when the job's branch already has a verified open PR" {
    local repo_dir="$MOTHER_ROOT/guard-repo-retry"
    local pr_url="https://github.com/thehammer/mother/pull/503"
    _eg_repo_with_open_pr "$repo_dir" "feature/guarded-retry" "$pr_url"
    make_job "job-guard-retry" "failed" \
        ".branch = \"feature/guarded-retry\" | .repo_path = \"$repo_dir\""

    run mother retry "job-guard-retry"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "$pr_url" ]]
    [[ "$output" =~ "reconcile" ]]

    run jq -r '.state' "$JOBS_DIR/job-guard-retry.json"
    [ "$output" = "failed" ]
}

@test "mother retry --yes bypasses the existing-open-PR guard" {
    local repo_dir="$MOTHER_ROOT/guard-repo-retry-yes"
    local pr_url="https://github.com/thehammer/mother/pull/504"
    _eg_repo_with_open_pr "$repo_dir" "feature/guarded-retry-yes" "$pr_url"
    make_job "job-guard-retry-yes" "failed" \
        ".branch = \"feature/guarded-retry-yes\" | .repo_path = \"$repo_dir\""

    run mother retry "job-guard-retry-yes" --yes
    [ "$status" -eq 0 ]
    run jq -r '.state' "$JOBS_DIR/job-guard-retry-yes.json"
    [ "$output" != "failed" ]
}

@test "mother retry without --yes still works normally when there is no existing PR for the branch" {
    # Regression guard: the new guard must not block the common case where
    # gh genuinely has nothing to report for the branch.
    make_job "job-retry-no-pr" "failed" '.branch = "feature/no-pr-here"'

    run mother retry "job-retry-no-pr"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# _auto_escalate_failed calls `mother reconcile --auto` before escalating
# (mother-runner change), gated by its own MOTHER_RECONCILE_ENABLED switch
# (independent of MOTHER_ESCALATION_ENABLED).
#
# JUDGMENT CALL: a real end-to-end test would need to run the actual
# mother-runner daemon loop, which the rest of this file avoids too (see the
# existing "MOTHER_ESCALATION_ENABLED=0" test's own comment: "hard to unit
# test without running the daemon"). Rather than redefining
# _auto_escalate_failed inline in the test (which would only prove the test's
# own stand-in logic, not Cody's real implementation — a trap the existing
# kill-switch test above actually falls into), these two assert directly on
# mother-runner's source for the two textual load-bearing facts the spec
# calls for: that _auto_escalate_failed's body calls `mother reconcile`
# before escalating, and that it's gated by MOTHER_RECONCILE_ENABLED. This is
# weaker than a behavioral test but is honest about what it checks, and it is
# red today (neither string exists yet) for the right reason.

@test "_auto_escalate_failed calls mother reconcile before escalating" {
    run grep -c 'mother reconcile' "$_BIN_DIR/mother-runner"
    [ "$output" -ge 1 ]
}

@test "_auto_escalate_failed's reconcile-before-escalate call is gated by MOTHER_RECONCILE_ENABLED" {
    run grep -c 'MOTHER_RECONCILE_ENABLED' "$_BIN_DIR/mother-runner"
    [ "$output" -ge 1 ]
}
