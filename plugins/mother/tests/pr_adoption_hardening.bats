#!/usr/bin/env bats
# pr_adoption_hardening.bats — a PR is adopted for a job only on evidence that
# the job (this run) produced it, and a PR-bearing job is never `succeeded`
# while its final commit exists only in the worktree.
#
# Behaviors:
#   1. expect_branch_mismatch does not blanket-adopt a PR created BEFORE this
#      run started (current_run.spawned_at); gh failure = not adopted.
#   2. A mismatched PR created AFTER spawn is adopted (actual_branch recorded).
#   3. _verify_artifact_or_fail with a PR but a final commit absent from the
#      remote head: one push attempt; success passes, failure ends `failed`
#      reason unpushed_commit + needs_attention, never `succeeded`.
#   4. unpushed_commit is routed as a hold.
#   5. First adherence fail moves the job to ready/cody_rework itself.

load 'test_helper'
load 'gh_mock'

MOTHER_RUN_JOB="$_BIN_DIR/mother-run-job"
SPAWN_AT="2026-11-08T12:00:00Z"
BEFORE_AT="2026-11-08T11:00:00Z"
AFTER_AT="2026-11-08T12:30:00Z"
OTHER_PR="https://github.com/thehammer/mother/pull/5083"

setup() {
    setup_mother_env
    export MOTHER_POSTURE_ENABLED=0
    gh_mock_install
    SOURCE_ONLY=1 source "$MOTHER_RUN_JOB" 2>/dev/null || true
    type _iso_now >/dev/null 2>&1 || _iso_now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
}

teardown() {
    teardown_mother_env
}

# --- fixtures --------------------------------------------------------------

# Local repo (origin = github URL so scraping filters on thehammer/mother),
# job branch with one commit ahead of main. With "nocommits" no commit ahead.
_ph_make_repo() {
    local dir="$1" branch="$2" mode="${3:-commits}"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m init
    git -C "$dir" branch -M main
    git -C "$dir" checkout -q -b "$branch"
    [ "$mode" = "nocommits" ] || git -C "$dir" commit -q --allow-empty -m work
    git -C "$dir" remote add origin "https://github.com/thehammer/mother.git"
}

# Bind a running job with expect_branch_mismatch and a spawn timestamp.
_ph_bind() {
    local jid="$1" repo="$2" br="$3"
    make_job "$jid" "running" \
        ".branch = \"$br\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$repo\" | .expect_branch_mismatch = true | .current_run = {spawned_at: \"$SPAWN_AT\", log_offset: 0}"
    id="$jid"; branch="$br"; base_ref="main"; isolation="worktree"; work_dir="$repo"
    job_file="$JOBS_DIR/$jid.json"
    pr_url=""; _pr_rejected_urls=""; _pr_transient_failures=""
    log_path="$MOTHER_ROOT/$jid.log"; : > "$log_path"
    log_offset_at_spawn=0
    jq -nc --arg c "$OTHER_PR" \
        '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:$c}]}}' >> "$log_path"
}

_ph_events() { grep -c "\"kind\":\"$2\"" "$EVENTS_DIR/$1.jsonl" 2>/dev/null || true; }

_ph_assert_not_adopted() {
    [ "$(jq -r '.pr_url // "null"' "$job_file")" = "null" ]
    [ -z "${pr_url:-}" ]
    [ "$(_ph_events "$1" pr_opened)" = "0" ]
}

# ===========================================================================
# 1-3. expect_branch_mismatch needs evidence the PR is from this run
# ===========================================================================

@test "finalize: a PR from another branch created before the run started is not adopted despite expect_branch_mismatch" {
    local repo="$MOTHER_ROOT/ph-repo-1"
    _ph_make_repo "$repo" "feature/ph-1"
    _ph_bind "ph-job-1" "$repo" "feature/ph-1"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _finalize_pr_url || true

    _ph_assert_not_adopted ph-job-1
}

@test "live capture: a PR from another branch created before the run started is not adopted despite expect_branch_mismatch" {
    local repo="$MOTHER_ROOT/ph-repo-2"
    _ph_make_repo "$repo" "feature/ph-2"
    _ph_bind "ph-job-2" "$repo" "feature/ph-2"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _live_capture_pr_url

    _ph_assert_not_adopted ph-job-2
}

@test "finalize: a pre-existing mismatched PR is not adopted when the run pushed no commits" {
    local repo="$MOTHER_ROOT/ph-repo-3"
    _ph_make_repo "$repo" "feature/ph-3" nocommits
    _ph_bind "ph-job-3" "$repo" "feature/ph-3"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _finalize_pr_url || true

    _ph_assert_not_adopted ph-job-3
}

@test "live capture: a pre-existing mismatched PR is not adopted when the run has no commits" {
    local repo="$MOTHER_ROOT/ph-repo-3b"
    _ph_make_repo "$repo" "feature/ph-3b" nocommits
    _ph_bind "ph-job-3b" "$repo" "feature/ph-3b"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _live_capture_pr_url

    _ph_assert_not_adopted ph-job-3b
}

@test "finalize: a mismatched PR created after the run started is adopted (pr_opened, actual_branch recorded)" {
    local repo="$MOTHER_ROOT/ph-repo-4"
    _ph_make_repo "$repo" "feature/ph-4"
    _ph_bind "ph-job-4" "$repo" "feature/ph-4"
    gh_mock_set_pr "$OTHER_PR" OPEN "landed/here"
    gh_mock_set_pr_created "$OTHER_PR" "$AFTER_AT"

    _finalize_pr_url

    [ "$pr_url" = "$OTHER_PR" ]
    [ "$(jq -r '.pr_url' "$job_file")" = "$OTHER_PR" ]
    [ "$(jq -r '.actual_branch' "$job_file")" = "landed/here" ]
    [ "$(_ph_events ph-job-4 pr_opened)" = "1" ]
}

@test "live capture: a mismatched PR created after the run started is adopted" {
    local repo="$MOTHER_ROOT/ph-repo-5"
    _ph_make_repo "$repo" "feature/ph-5"
    _ph_bind "ph-job-5" "$repo" "feature/ph-5"
    gh_mock_set_pr "$OTHER_PR" OPEN "landed/here"
    gh_mock_set_pr_created "$OTHER_PR" "$AFTER_AT"

    _live_capture_pr_url

    [ "$(jq -r '.pr_url' "$job_file")" = "$OTHER_PR" ]
    [ "$(_ph_events ph-job-5 pr_opened)" = "1" ]
}

@test "finalize: when gh cannot say when a mismatched PR was created it is not adopted" {
    local repo="$MOTHER_ROOT/ph-repo-6"
    _ph_make_repo "$repo" "feature/ph-6"
    _ph_bind "ph-job-6" "$repo" "feature/ph-6"
    # No fixture registered: every `gh pr view` exits 1.

    _finalize_pr_url || true

    _ph_assert_not_adopted ph-job-6
}

@test "live capture: when gh cannot say when a mismatched PR was created it is not adopted" {
    local repo="$MOTHER_ROOT/ph-repo-7"
    _ph_make_repo "$repo" "feature/ph-7"
    _ph_bind "ph-job-7" "$repo" "feature/ph-7"

    _live_capture_pr_url

    _ph_assert_not_adopted ph-job-7
}

@test "finalize: a mismatched PR whose createdAt is unavailable (state/head resolve, no createdAt) is not adopted" {
    local repo="$MOTHER_ROOT/ph-repo-8"
    _ph_make_repo "$repo" "feature/ph-8"
    _ph_bind "ph-job-8" "$repo" "feature/ph-8"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch"   # no createdAt field

    _finalize_pr_url || true

    _ph_assert_not_adopted ph-job-8
}

# ===========================================================================
# 4. _verify_artifact_or_fail: a PR does not vouch for unpushed work
# ===========================================================================

PH_PR="https://github.com/thehammer/mother/pull/700"

# Origin bare repo, worktree on <branch>, branch pushed once (S), then one
# further LOCAL commit that origin lacks. Job has pr_url set.
_ph_unpushed_env() {
    local tag="$1"
    RA_BARE="$MOTHER_ROOT/ph-$tag-origin.git"
    RA_REPO="$MOTHER_ROOT/ph-$tag-repo"
    RA_WT="$MOTHER_ROOT/ph-$tag-wt"
    RA_BRANCH="feature/ph-$tag"
    git init -q --bare "$RA_BARE"
    git init -q "$RA_REPO"
    git -C "$RA_REPO" config user.email "test@test.com"
    git -C "$RA_REPO" config user.name "Test"
    git -C "$RA_REPO" commit -q --allow-empty -m init
    git -C "$RA_REPO" branch -M main
    git -C "$RA_REPO" remote add origin "$RA_BARE"
    git -C "$RA_REPO" push -q origin main
    git -C "$RA_REPO" worktree add -q -b "$RA_BRANCH" "$RA_WT" main
    git -C "$RA_WT" commit -q --allow-empty -m "pushed work"
    git -C "$RA_WT" push -q origin "$RA_BRANCH"
    git -C "$RA_WT" commit -q --allow-empty -m "final commit, never pushed"

    make_job "ph-$tag" "running" \
        ".branch = \"$RA_BRANCH\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$RA_WT\" | .repo_path = \"$RA_REPO\" | .pr_url = \"$PH_PR\""
    gh_mock_set_pr "$PH_PR" OPEN "$RA_BRANCH"
    id="ph-$tag"; branch="$RA_BRANCH"; base_ref="main"; isolation="worktree"
    work_dir="$RA_WT"; repo_path="$RA_REPO"; job_file="$JOBS_DIR/$id.json"
    pr_url="$PH_PR"
    run_had_artifact_at_start=false
}

_ph_reject_pushes() {
    printf '#!/bin/sh\nexit 1\n' > "$RA_BARE/hooks/pre-receive"
    chmod +x "$RA_BARE/hooks/pre-receive"
}

@test "verify: a PR job whose final commit is not on the remote and cannot be pushed fails unpushed_commit with needs_attention" {
    _ph_unpushed_env "u1"
    _ph_reject_pushes

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    [ "$(jq -r '.state' "$job_file")" = "failed" ]
    [ "$(jq -r '.state' "$job_file")" != "succeeded" ]
    run jq -r 'select(.kind=="failed") | .detail.reason' "$EVENTS_DIR/ph-u1.jsonl"
    [ "$output" = "unpushed_commit" ]
    [ "$(jq -r '.needs_attention.reason' "$job_file")" = "unpushed_commit" ]
}

@test "verify: a PR job whose final commit is missing from the remote passes after a single successful push" {
    _ph_unpushed_env "u2"
    local head; head=$(git -C "$RA_WT" rev-parse HEAD)

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    # The commit really is on origin now.
    [ "$(git -C "$RA_BARE" rev-parse "refs/heads/$RA_BRANCH")" = "$head" ]
}

@test "verify: a PR job whose final commit is already on the remote passes untouched" {
    _ph_unpushed_env "u3"
    git -C "$RA_WT" push -q origin "$RA_BRANCH"
    # A rejecting hook proves no further push is needed.
    _ph_reject_pushes

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]
    [ "$(jq -r '.state' "$job_file")" != "failed" ]
}

# ===========================================================================
# 5. failure routing
# ===========================================================================

@test "mother_failure_class: unpushed_commit -> hold" {
    run bash -uc 'source "$1" && mother_failure_class unpushed_commit' _ "$_LIB_DIR/failure-route.sh"
    [ "$output" = "hold" ]
}

# ===========================================================================
# 6. adherence: first fail requeues the job itself
# ===========================================================================

@test "adherence-review: a first fail moves the job from succeeded to ready/cody_rework itself" {
    make_job "ph-adh" "succeeded" \
        '.pr_url = "https://github.com/Carefeed/test/pull/42" | .adherence_attempts = 0 | .adherence_status = null | .adherence_pending = null | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"t"},"redd":{"model":"sonnet","effort":"medium","rationale":"t"},"marty":{"model":"sonnet","effort":"medium","rationale":"t"},"perri":{"model":"sonnet","effort":"medium","rationale":"t"}}'
    local plan="$EVENTS_DIR/ph-adh-plan.md"
    printf '# Plan\n\n## Acceptance criteria\n- It works.\n' > "$plan"
    local m; m=$(jq --arg p "$plan" '.plan_path = $p' "$JOBS_DIR/ph-adh.json")
    printf '%s' "$m" > "$JOBS_DIR/ph-adh.json"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
Skipped the README criterion."

    run mother adherence-review "ph-adh"
    [ "$status" -eq 1 ]

    [ "$(jq -r '.adherence_status' "$JOBS_DIR/ph-adh.json")" = "failed_first" ]
    [ "$(jq -r '.state' "$JOBS_DIR/ph-adh.json")" = "ready" ]
    [ "$(jq -r '.activity' "$JOBS_DIR/ph-adh.json")" = "cody_rework" ]
    [ -n "$(jq -r '.pending_answer // ""' "$JOBS_DIR/ph-adh.json")" ]
}
