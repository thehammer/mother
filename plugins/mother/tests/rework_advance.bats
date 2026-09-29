#!/usr/bin/env bats
# rework_advance.bats — a run that STARTS with a shipped artifact (an open PR,
# or its branch already on origin) must actually MOVE it, or it is not a
# success.
#
# Incident (job 20260926T220129Z-0d46eb6d): an adherence-rework run edited
# files in the worktree, never committed or pushed, and was reported
# `succeeded` — because _verify_artifact_or_fail returned 0 the moment ANY
# pr_url was set (the one the FIRST run opened). The rework's changes were
# stranded in a worktree and the PR was unchanged.
#
# Contract (bin/mother-run-job, pre-SOURCE_ONLY-guard so bats can drive it):
#   _capture_run_baseline          snapshots, before the worker spawns:
#       run_pr_url_at_start, run_head_sha_at_start, run_remote_ref,
#       run_remote_sha_at_start, run_remote_check_at_start (ok|indeterminate),
#       run_had_artifact_at_start (true|false)
#   _verify_run_advanced_or_fail   first thing _verify_artifact_or_fail does
#       (after the no_pr branch). No-op unless the run had a pre-existing
#       artifact. Advanced = a new PR url, or origin's ref moved. Otherwise
#       `failed` with reason rework_no_new_commit (fail closed when origin
#       cannot be queried). Never clears .pr_url.
#
# Tests drive the real functions via SOURCE_ONLY=1 against a real local bare
# `origin`; `gh` is mocked (tests/gh_mock.bash).

load 'test_helper'
load 'gh_mock'

MOTHER_RUN_JOB="$_BIN_DIR/mother-run-job"
RA_PR_URL="https://github.com/thehammer/mother/pull/600"

setup() {
    setup_mother_env
    export MOTHER_POSTURE_ENABLED=0
    unset MOTHER_REWORK_ADVANCE_CHECK_ENABLED
    gh_mock_install
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

_ra_load() {
    SOURCE_ONLY=1 source "$MOTHER_RUN_JOB" 2>/dev/null || true
    type _iso_now >/dev/null 2>&1 || _iso_now() { date -u +%Y-%m-%dT%H:%M:%S.000Z; }
}

# Bare origin + repo (main pushed) and a worktree for the job branch.
# Usage: _ra_make_env <tag> <branch> [remote_ref]
#   Default: the job's own branch was pushed once by the first run (commit S
#   on origin/<branch>).
#   With remote_ref: the PR lives on a DIFFERENT branch (<remote_ref>, on
#   origin at S) and the job branch is stacked on it locally.
# Sets RA_REPO RA_BARE RA_WT RA_BRANCH RA_REF RA_S.
_ra_make_env() {
    local tag="$1" branch="$2" remote_ref="${3:-$2}"
    RA_BARE="$MOTHER_ROOT/ra-$tag-origin.git"
    RA_REPO="$MOTHER_ROOT/ra-$tag-repo"
    RA_WT="$MOTHER_ROOT/ra-$tag-wt"
    RA_BRANCH="$branch"; RA_REF="$remote_ref"

    git init -q --bare "$RA_BARE"
    git init -q "$RA_REPO"
    git -C "$RA_REPO" config user.email "test@test.com"
    git -C "$RA_REPO" config user.name "Test"
    git -C "$RA_REPO" commit -q --allow-empty -m init
    git -C "$RA_REPO" branch -M main
    git -C "$RA_REPO" remote add origin "$RA_BARE"
    git -C "$RA_REPO" push -q origin main

    if [ "$remote_ref" = "$branch" ]; then
        git -C "$RA_REPO" worktree add -q -b "$branch" "$RA_WT" main
        git -C "$RA_WT" commit -q --allow-empty -m "first run work"
        git -C "$RA_WT" push -q origin "$branch"
    else
        git -C "$RA_REPO" checkout -q -b "$remote_ref" main
        git -C "$RA_REPO" commit -q --allow-empty -m "someone else's PR work"
        git -C "$RA_REPO" push -q origin "$remote_ref"
        git -C "$RA_REPO" checkout -q main
        git -C "$RA_REPO" worktree add -q -b "$branch" "$RA_WT" "$remote_ref"
    fi
    RA_S=$(git -C "$RA_BARE" rev-parse "refs/heads/$remote_ref")
}

# A worktree job that has never shipped anything (no PR, branch not on origin).
_ra_make_unshipped_env() {
    local tag="$1" branch="$2"
    RA_BARE="$MOTHER_ROOT/ra-$tag-origin.git"
    RA_REPO="$MOTHER_ROOT/ra-$tag-repo"
    RA_WT="$MOTHER_ROOT/ra-$tag-wt"
    RA_BRANCH="$branch"; RA_REF="$branch"
    git init -q --bare "$RA_BARE"
    git init -q "$RA_REPO"
    git -C "$RA_REPO" config user.email "test@test.com"
    git -C "$RA_REPO" config user.name "Test"
    git -C "$RA_REPO" commit -q --allow-empty -m init
    git -C "$RA_REPO" branch -M main
    git -C "$RA_REPO" remote add origin "$RA_BARE"
    git -C "$RA_REPO" push -q origin main
    git -C "$RA_REPO" worktree add -q -b "$branch" "$RA_WT" main
}

# Job JSON for the current RA_* env. Usage: _ra_make_job <id> [extra-jq]
_ra_make_job() {
    local id="$1" extra="${2:-.}"
    make_job "$id" "running" \
        '.branch = "'"$RA_BRANCH"'"
         | .base_ref = "main"
         | .isolation = "worktree"
         | .work_dir = "'"$RA_WT"'"
         | .repo_path = "'"$RA_REPO"'"
         | ('"$extra"')'
}

# Bind the globals the verify functions read (as the real script has them).
_ra_bind() {
    id="$1"
    branch="$RA_BRANCH"; base_ref="main"; isolation="worktree"
    work_dir="$RA_WT"; repo_path="$RA_REPO"
    job_file="$JOBS_DIR/$id.json"
    pr_url=""
}

_ra_failed_detail() {
    jq -c 'select(.kind=="failed") | .detail' "$EVENTS_DIR/$1.jsonl" | head -1
}

# The standard "PR already open on the job's own branch" scenario.
# Usage: _ra_open_pr_scenario <id> [extra-jq]   (runs baseline; pr_url = stored PR)
_ra_open_pr_scenario() {
    # NB: no `local id` here — _ra_bind sets the global `id` the real script
    # functions read, and a local of the same name would shadow it.
    local sid="$1" extra="${2:-.}"
    _ra_load
    _ra_make_env "$sid" "feature/$sid"
    _ra_make_job "$sid" '.pr_url = "'"$RA_PR_URL"'" | ('"$extra"')'
    gh_mock_set_pr "$RA_PR_URL" OPEN "$RA_BRANCH"
    _ra_bind "$sid"
    _capture_run_baseline
    pr_url="$RA_PR_URL"     # what _finalize_pr_url leaves for a still-OPEN stored PR
}

# ===========================================================================
# _capture_run_baseline
# ===========================================================================

@test "_capture_run_baseline: an OPEN stored PR is the artifact; its head branch and origin sha are recorded" {
    _ra_open_pr_scenario "ra-base-1"

    [ "$run_pr_url_at_start" = "$RA_PR_URL" ]
    [ "$run_head_sha_at_start" = "$(git -C "$RA_WT" rev-parse HEAD)" ]
    [ "$run_remote_ref" = "$RA_BRANCH" ]
    [ "$run_remote_sha_at_start" = "$RA_S" ]
    [ "$run_remote_check_at_start" = "ok" ]
    [ "$run_had_artifact_at_start" = "true" ]
}

@test "_capture_run_baseline: the PR's head branch (not the job branch) is the ref to watch when they differ" {
    _ra_load
    _ra_make_env "ra-base-2" "feature/ra-base-2" "someone/elses-pr-branch"
    _ra_make_job "ra-base-2" '.pr_url = "'"$RA_PR_URL"'"'
    gh_mock_set_pr "$RA_PR_URL" OPEN "someone/elses-pr-branch"
    _ra_bind "ra-base-2"

    _capture_run_baseline

    [ "$run_remote_ref" = "someone/elses-pr-branch" ]
    [ "$run_remote_sha_at_start" = "$RA_S" ]
    [ "$run_had_artifact_at_start" = "true" ]
}

@test "_capture_run_baseline: a MERGED stored PR is not an OPEN artifact — falls back to .actual_branch, then .branch" {
    _ra_load
    _ra_make_env "ra-base-3" "feature/ra-base-3"
    _ra_make_job "ra-base-3" '.pr_url = "'"$RA_PR_URL"'" | .actual_branch = "actual/never-pushed"'
    gh_mock_set_pr "$RA_PR_URL" MERGED "some/merged-branch"
    _ra_bind "ra-base-3"

    _capture_run_baseline

    # .actual_branch wins over .branch, and nothing is on origin under it.
    [ "$run_remote_ref" = "actual/never-pushed" ]
    [ -z "$run_remote_sha_at_start" ]
    [ "$run_had_artifact_at_start" != "true" ]

    # Without .actual_branch the job's own (pushed) branch is the ref.
    _ra_make_job "ra-base-3" '.pr_url = "'"$RA_PR_URL"'"'
    _capture_run_baseline
    [ "$run_remote_ref" = "$RA_BRANCH" ]
    [ "$run_remote_sha_at_start" = "$RA_S" ]
    [ "$run_had_artifact_at_start" = "true" ]
}

@test "_capture_run_baseline: a first run (no PR, branch not on origin) has no artifact" {
    _ra_load
    _ra_make_unshipped_env "ra-base-4" "feature/ra-base-4"
    _ra_make_job "ra-base-4"
    _ra_bind "ra-base-4"

    _capture_run_baseline

    [ -z "$run_pr_url_at_start" ]
    [ -z "$run_remote_sha_at_start" ]
    [ "$run_remote_check_at_start" = "ok" ]
    [ "$run_had_artifact_at_start" != "true" ]
}

@test "_capture_run_baseline: an unreachable origin is recorded as indeterminate, not as 'nothing there'" {
    _ra_load
    _ra_make_env "ra-base-5" "feature/ra-base-5"
    _ra_make_job "ra-base-5" '.pr_url = "'"$RA_PR_URL"'"'
    gh_mock_set_pr "$RA_PR_URL" OPEN "$RA_BRANCH"
    git -C "$RA_WT" remote set-url origin "$MOTHER_ROOT/does-not-exist.git"
    _ra_bind "ra-base-5"

    _capture_run_baseline

    [ "$run_remote_check_at_start" = "indeterminate" ]
}

# ===========================================================================
# _verify_artifact_or_fail — rework must advance the artifact
# ===========================================================================

@test "G regression: rework leaves only uncommitted edits (never pushes) with an OPEN PR -> failed rework_no_new_commit, PR pointer kept" {
    # Shape of job 20260926T220129Z-0d46eb6d.
    _ra_open_pr_scenario "ra-g-1"
    echo "edit made by the rework run" > "$RA_WT/stranded.txt"

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    assert_job_field "ra-g-1" '.state' "failed"
    local d; d=$(_ra_failed_detail "ra-g-1")
    [ "$(printf '%s' "$d" | jq -r '.reason')" = "rework_no_new_commit" ]
    [ "$(printf '%s' "$d" | jq -r '.local_advanced')" = "false" ]
    printf '%s' "$d" | jq -e '.uncommitted_files >= 1' >/dev/null
    [ "$(printf '%s' "$d" | jq -r '.origin_check')" = "ok" ]
    [ "$(printf '%s' "$d" | jq -r '.remote_ref')" = "$RA_BRANCH" ]
    [ "$(printf '%s' "$d" | jq -r '.remote_sha_at_start')" = "$RA_S" ]
    [ "$(printf '%s' "$d" | jq -r '.remote_sha_at_end')" = "$RA_S" ]
    [ "$(printf '%s' "$d" | jq -r '.pr_url')" = "$RA_PR_URL" ]
    [ -n "$(printf '%s' "$d" | jq -r '.head_sha_at_start // empty')" ]

    # The PR pointer must survive: the PR is real, the run just didn't move it.
    assert_job_field "ra-g-1" '.pr_url' "$RA_PR_URL"
}

@test "rework commits locally but never pushes -> failed rework_no_new_commit with local_advanced=true" {
    _ra_open_pr_scenario "ra-g-2"
    git -C "$RA_WT" commit -q --allow-empty -m "rework commit that never left the worktree"

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    local d; d=$(_ra_failed_detail "ra-g-2")
    [ "$(printf '%s' "$d" | jq -r '.reason')" = "rework_no_new_commit" ]
    [ "$(printf '%s' "$d" | jq -r '.local_advanced')" = "true" ]
    [ "$(printf '%s' "$d" | jq -r '.head_sha_at_end')" != "$(printf '%s' "$d" | jq -r '.head_sha_at_start')" ]
    [ "$(printf '%s' "$d" | jq -r '.remote_sha_at_end')" = "$RA_S" ]
    assert_job_field "ra-g-2" '.pr_url' "$RA_PR_URL"
}

@test "rework commits AND pushes to the PR branch -> succeeds and records rework_advance_verified" {
    _ra_open_pr_scenario "ra-g-3"
    git -C "$RA_WT" commit -q --allow-empty -m "rework commit"
    git -C "$RA_WT" push -q origin "$RA_BRANCH"
    local new_sha; new_sha=$(git -C "$RA_WT" rev-parse HEAD)

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    local state; state=$(jq -r '.state' "$job_file")
    [ "$state" != "failed" ]
    assert_event_kind "ra-g-3" "rework_advance_verified"
    local d; d=$(jq -c 'select(.kind=="rework_advance_verified") | .detail' "$EVENTS_DIR/ra-g-3.jsonl" | head -1)
    [ "$(printf '%s' "$d" | jq -r '.remote_ref')" = "$RA_BRANCH" ]
    [ "$(printf '%s' "$d" | jq -r '.remote_sha_at_start')" = "$RA_S" ]
    [ "$(printf '%s' "$d" | jq -r '.remote_sha_at_end')" = "$new_sha" ]
}

@test "worker landed on ANOTHER PR's branch (PR head != job branch) and pushed there -> succeeds" {
    # Shape of job 20260910T130607Z-773bf2c4.
    _ra_load
    _ra_make_env "ra-g-4" "feature/ra-g-4" "someone/elses-pr-branch"
    _ra_make_job "ra-g-4" '.pr_url = "'"$RA_PR_URL"'"'
    gh_mock_set_pr "$RA_PR_URL" OPEN "someone/elses-pr-branch"
    _ra_bind "ra-g-4"
    _capture_run_baseline
    pr_url="$RA_PR_URL"

    git -C "$RA_WT" commit -q --allow-empty -m "rework on the other PR"
    git -C "$RA_WT" push -q origin "HEAD:refs/heads/someone/elses-pr-branch"

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    local d; d=$(jq -c 'select(.kind=="rework_advance_verified") | .detail' "$EVENTS_DIR/ra-g-4.jsonl" | head -1)
    [ "$(printf '%s' "$d" | jq -r '.remote_ref')" = "someone/elses-pr-branch" ]
}

@test "worker replaced the PR with a new one (final pr_url differs from the one at start) -> counts as advanced" {
    _ra_open_pr_scenario "ra-g-5"
    pr_url="https://github.com/thehammer/mother/pull/601"   # what _finalize_pr_url derived after the run

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    assert_event_kind "ra-g-5" "rework_advance_verified"
}

@test "end-of-run origin check fails (origin unreachable) -> fails closed as rework_no_new_commit with origin_check=indeterminate" {
    _ra_open_pr_scenario "ra-g-6"
    git -C "$RA_WT" commit -q --allow-empty -m "rework commit (push would have failed)"
    git -C "$RA_WT" remote set-url origin "$MOTHER_ROOT/does-not-exist.git"

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    assert_job_field "ra-g-6" '.state' "failed"
    local d; d=$(_ra_failed_detail "ra-g-6")
    [ "$(printf '%s' "$d" | jq -r '.reason')" = "rework_no_new_commit" ]
    [ "$(printf '%s' "$d" | jq -r '.origin_check')" = "indeterminate" ]
    assert_job_field "ra-g-6" '.pr_url' "$RA_PR_URL"
}

# ===========================================================================
# Where the check must NOT apply
# ===========================================================================

@test "no-op: a FIRST run with nothing shipped still fails the ordinary no_pr_no_push check, not rework_no_new_commit" {
    _ra_load
    _ra_make_unshipped_env "ra-noop-1" "feature/ra-noop-1"
    _ra_make_job "ra-noop-1"
    _ra_bind "ra-noop-1"
    _capture_run_baseline

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    local d; d=$(_ra_failed_detail "ra-noop-1")
    [ "$(printf '%s' "$d" | jq -r '.reason')" = "no_pr_no_push" ]
    run bash -c "grep -c 'rework_' '$EVENTS_DIR/ra-noop-1.jsonl'; true"
    [ "$output" = "0" ]
}

@test "no-op: a FIRST run that pushed its branch passes the ordinary check with no rework events" {
    _ra_load
    _ra_make_unshipped_env "ra-noop-2" "feature/ra-noop-2"
    _ra_make_job "ra-noop-2"
    _ra_bind "ra-noop-2"
    _capture_run_baseline
    git -C "$RA_WT" commit -q --allow-empty -m "first run work"
    git -C "$RA_WT" push -q origin "$RA_BRANCH"

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    assert_event_kind "ra-noop-2" "no_pr_url_but_branch_pushed"
    run bash -c "grep -c 'rework_' '$EVENTS_DIR/ra-noop-2.jsonl'; true"
    [ "$output" = "0" ]
}

@test "no-op: pipeline jobs are exempt (a phase may legitimately make no commits)" {
    _ra_open_pr_scenario "ra-noop-3" '.kind = "pipeline"'

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    run bash -c "grep -c 'rework_' '$EVENTS_DIR/ra-noop-3.jsonl' 2>/dev/null; true"
    [ "$output" = "0" ] || [ -z "$output" ]
}

@test "no-op: no_pr jobs keep their own commits-on-branch verification and are not subject to the push check" {
    _ra_open_pr_scenario "ra-noop-4" '.no_pr = true'

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    run bash -c "grep -c 'rework_' '$EVENTS_DIR/ra-noop-4.jsonl' 2>/dev/null; true"
    [ "$output" = "0" ] || [ -z "$output" ]
}

@test "no-op: MOTHER_REWORK_ADVANCE_CHECK_ENABLED=0 restores the old behavior (any pr_url passes)" {
    _ra_open_pr_scenario "ra-noop-5"
    echo "stranded" > "$RA_WT/stranded.txt"
    export MOTHER_REWORK_ADVANCE_CHECK_ENABLED=0

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    run bash -c "grep -c 'rework_' '$EVENTS_DIR/ra-noop-5.jsonl' 2>/dev/null; true"
    [ "$output" = "0" ] || [ -z "$output" ]
}
