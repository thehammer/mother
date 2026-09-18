#!/usr/bin/env bats
# pr_url_capture.bats — tests for PR URL capture helpers in mother-run-job.
#
# These helpers do not exist yet; all tests in this file are expected to FAIL
# (red) until Cody implements the fix.  Once the fix ships, this file should
# be updated to source the real helpers from mother-run-job (or from whichever
# lib/ file they are promoted to).
#
# The helpers under test:
#   _job_owner_repo_from_url <remote_url>   → "owner/repo" or ""
#   _scrape_pr_url_filtered <log_file> <owner_repo>  → URL or ""
#   _derive_pr_url_from_branch <owner_repo> <branch>  → URL or ""
#
# Strategy: source mother-run-job with SOURCE_ONLY=1 (a convention Cody will
# add alongside the helpers) so we can call the functions without running the
# job.  Until that support exists the source line fails, making every test red
# for exactly the right reason: the functions don't exist yet.

load 'test_helper'

# Path to the worker script under test.
MOTHER_RUN_JOB="$_BIN_DIR/mother-run-job"

setup() {
    setup_mother_env

    # Attempt to source only the helper functions from mother-run-job.
    # The fix must add SOURCE_ONLY=1 guard support to the script so this works.
    # Until then, the source will exit/error and the test will be red.
    SOURCE_ONLY=1 source "$MOTHER_RUN_JOB" 2>/dev/null || true

    # If the helpers weren't exported by the source (pre-fix), commands like
    # _job_owner_repo_from_url will be "not found" and tests will fail correctly.
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# _job_owner_repo_from_url — SSH remote parsing
# ---------------------------------------------------------------------------

@test "_job_owner_repo_from_url parses SSH remote with .git suffix" {
    result=$(_job_owner_repo_from_url "git@github.com:owner/repo.git")
    [ "$result" = "owner/repo" ]
}

@test "_job_owner_repo_from_url parses SSH remote without .git suffix" {
    result=$(_job_owner_repo_from_url "git@github.com:owner/repo")
    [ "$result" = "owner/repo" ]
}

# ---------------------------------------------------------------------------
# _job_owner_repo_from_url — HTTPS remote parsing
# ---------------------------------------------------------------------------

@test "_job_owner_repo_from_url parses HTTPS remote with .git suffix" {
    result=$(_job_owner_repo_from_url "https://github.com/owner/repo.git")
    [ "$result" = "owner/repo" ]
}

@test "_job_owner_repo_from_url parses HTTPS remote without .git suffix" {
    result=$(_job_owner_repo_from_url "https://github.com/owner/repo")
    [ "$result" = "owner/repo" ]
}

# ---------------------------------------------------------------------------
# _job_owner_repo_from_url — non-github remote → empty
# ---------------------------------------------------------------------------

@test "_job_owner_repo_from_url returns empty for non-github remote" {
    result=$(_job_owner_repo_from_url "https://gitlab.com/owner/repo")
    [ "$result" = "" ]
}

# ---------------------------------------------------------------------------
# _scrape_pr_url_filtered — repo-filtered log scraping
# ---------------------------------------------------------------------------

@test "_scrape_pr_url_filtered returns empty when log contains only foreign-repo URL" {
    local log_file="$MOTHER_ROOT/foreign-only.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
Creating a PR at https://github.com/acme/api/pull/7 for the API changes.
EOF
    result=$(_scrape_pr_url_filtered "$log_file" "thehammer/mother")
    [ "$result" = "" ]
}

@test "_scrape_pr_url_filtered picks correct URL when log has foreign URL then own-repo URL" {
    local log_file="$MOTHER_ROOT/mixed.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
I noticed https://github.com/acme/api/pull/7 was merged already.
Created PR at https://github.com/thehammer/mother/pull/37
EOF
    result=$(_scrape_pr_url_filtered "$log_file" "thehammer/mother")
    [ "$result" = "https://github.com/thehammer/mother/pull/37" ]
}

@test "_scrape_pr_url_filtered captures URL when log contains only same-repo URL" {
    local log_file="$MOTHER_ROOT/own-only.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
PR opened: https://github.com/thehammer/mother/pull/37
EOF
    result=$(_scrape_pr_url_filtered "$log_file" "thehammer/mother")
    [ "$result" = "https://github.com/thehammer/mother/pull/37" ]
}

# ---------------------------------------------------------------------------
# _derive_pr_url_from_branch — preferred over log scrape
# ---------------------------------------------------------------------------

@test "_derive_pr_url_from_branch returns gh-derived URL even when log has foreign URL" {
    # Stub gh to return the authoritative URL for our branch.
    cat > "$MOTHER_ROOT/mock-bin/gh" <<'GHSTUB'
#!/bin/bash
if echo "$*" | grep -q "pr list" && echo "$*" | grep -q "feature/foo" \
    && echo "$*" | grep -q "thehammer/mother"; then
    printf '{"url":"https://github.com/thehammer/mother/pull/42"}\n'
    exit 0
fi
exit 0
GHSTUB
    chmod +x "$MOTHER_ROOT/mock-bin/gh"

    result=$(_derive_pr_url_from_branch "thehammer/mother" "feature/foo")
    [ "$result" = "https://github.com/thehammer/mother/pull/42" ]
}

@test "_derive_pr_url_from_branch returns empty when gh pr list finds no open PR" {
    # Stub gh pr list to return empty output (no open PRs).
    cat > "$MOTHER_ROOT/mock-bin/gh" <<'GHSTUB'
#!/bin/bash
if echo "$*" | grep -q "pr list"; then
    exit 0
fi
exit 0
GHSTUB
    chmod +x "$MOTHER_ROOT/mock-bin/gh"

    result=$(_derive_pr_url_from_branch "thehammer/mother" "feature/foo")
    [ "$result" = "" ]
}

@test "filtered scrape is used as fallback when _derive_pr_url_from_branch returns empty" {
    # Stub gh pr list to return nothing.
    cat > "$MOTHER_ROOT/mock-bin/gh" <<'GHSTUB'
#!/bin/bash
if echo "$*" | grep -q "pr list"; then
    exit 0
fi
exit 0
GHSTUB
    chmod +x "$MOTHER_ROOT/mock-bin/gh"

    local log_file="$MOTHER_ROOT/real-pr.log"
    cat > "$log_file" <<'EOF'
PR created: https://github.com/thehammer/mother/pull/37
EOF

    derived=$(_derive_pr_url_from_branch "thehammer/mother" "feature/foo")
    [ "$derived" = "" ]

    scraped=$(_scrape_pr_url_filtered "$log_file" "thehammer/mother")
    [ "$scraped" = "https://github.com/thehammer/mother/pull/37" ]
}

# ---------------------------------------------------------------------------
# Validation: unresolvable URL → must be cleared
#
# The fix changes the semantics: gh pr view failure means "clear", not "keep".
# We test the correct post-fix behavior using a job file so we can assert the
# mutation via jq.  Until the validation block is fixed, it will keep the URL
# and the assertion will fail.
# ---------------------------------------------------------------------------

@test "validation clears pr_url when gh pr view fails (nonexistent PR)" {
    cat > "$MOTHER_ROOT/mock-bin/gh" <<'GHSTUB'
#!/bin/bash
if echo "$*" | grep -q "pr view"; then
    echo "GraphQL: Could not resolve to a PullRequest" >&2
    exit 1
fi
exit 0
GHSTUB
    chmod +x "$MOTHER_ROOT/mock-bin/gh"

    # Build a minimal job file with a pre-seeded pr_url.
    local job_file="$JOBS_DIR/val-fail-test.json"
    local branch="feature/foo"
    local pr_url="https://github.com/thehammer/mother/pull/99"
    jq -n \
        --arg pr_url "$pr_url" \
        --arg branch "$branch" \
        '{id: "val-fail-test", branch: $branch, pr_url: $pr_url, state: "running"}' \
        > "$job_file"

    # Run the validation helper (added by the fix) against the job file.
    # Pre-fix: no such function exists → fails with "not found".
    # Post-fix: function exists and clears pr_url in the job file.
    _validate_and_clear_pr_url "val-fail-test" "$branch"

    actual=$(jq -r '.pr_url // empty' "$job_file")
    [ "$actual" = "" ]
}

@test "validation clears pr_url when gh pr view returns a different branch name" {
    cat > "$MOTHER_ROOT/mock-bin/gh" <<'GHSTUB'
#!/bin/bash
if echo "$*" | grep -q "pr view"; then
    echo "feature/other-branch"
    exit 0
fi
exit 0
GHSTUB
    chmod +x "$MOTHER_ROOT/mock-bin/gh"

    local job_file="$JOBS_DIR/val-mismatch-test.json"
    local branch="feature/foo"
    local pr_url="https://github.com/thehammer/mother/pull/99"
    jq -n \
        --arg pr_url "$pr_url" \
        --arg branch "$branch" \
        '{id: "val-mismatch-test", branch: $branch, pr_url: $pr_url, state: "running"}' \
        > "$job_file"

    _validate_and_clear_pr_url "val-mismatch-test" "$branch"

    actual=$(jq -r '.pr_url // empty' "$job_file")
    [ "$actual" = "" ]
}

@test "validation keeps pr_url when gh pr view confirms the correct branch" {
    cat > "$MOTHER_ROOT/mock-bin/gh" <<'GHSTUB'
#!/bin/bash
if echo "$*" | grep -q "pr view"; then
    echo "feature/foo"
    exit 0
fi
exit 0
GHSTUB
    chmod +x "$MOTHER_ROOT/mock-bin/gh"

    local job_file="$JOBS_DIR/val-match-test.json"
    local branch="feature/foo"
    local pr_url="https://github.com/thehammer/mother/pull/42"
    jq -n \
        --arg pr_url "$pr_url" \
        --arg branch "$branch" \
        '{id: "val-match-test", branch: $branch, pr_url: $pr_url, state: "running"}' \
        > "$job_file"

    _validate_and_clear_pr_url "val-match-test" "$branch"

    actual=$(jq -r '.pr_url // empty' "$job_file")
    [ "$actual" = "$pr_url" ]
}

# ---------------------------------------------------------------------------
# _verify_artifact_or_fail — the "pushed under some other branch name" escape
# hatch (prd_sha_on_origin).
#
# JUDGMENT CALL (flagged for Cody): _verify_artifact_or_fail is defined in
# mother-run-job AFTER the `[ "${SOURCE_ONLY:-}" = "1" ] && return 0` guard
# (currently ~line 1107, guard is ~line 125), so today SOURCE_ONLY=1 sourcing
# does NOT define it — these tests are red with "command not found", which is
# the correct failure today. The fix as scoped explicitly touches
# _verify_artifact_or_fail's body (to add the prd_sha_on_origin escape hatch),
# and the established convention in this file is that anything meant to be
# unit-tested this way lives before the guard (see the file-level comment
# above _job_owner_repo_from_url: "defined early so SOURCE_ONLY=1 sourcing
# works"). I'm assuming Cody moves the guard (or _verify_artifact_or_fail
# itself) so it becomes reachable the same way. To make that move
# self-contained, this setup also defines its own copies of the small
# `_transition`/`_append_event`/`_job_update`/`iso_now` wrappers that
# _verify_artifact_or_fail depends on (copied verbatim from mother-run-job
# lines ~151-199) — if Cody's real script also defines them once sourcing
# reaches that far, the redefinition is identical and harmless.
# ---------------------------------------------------------------------------

# Real repo + bare "origin" remote + real worktree, wired the way
# mother-run-job expects: work_dir is a worktree of repo_path, checked out to
# `branch`, based on `base_ref` (a local branch standing in for origin/main).
# Usage: _va_make_repo_and_worktree <repo_dir> <bare_dir> <wt_dir> <branch> <base_branch>
_va_make_repo_and_worktree() {
    local repo_dir="$1" bare_dir="$2" wt_dir="$3" branch="$4" base_branch="$5"
    git init -q --bare "$bare_dir"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" remote add origin "$bare_dir"
    git -C "$repo_dir" commit -q --allow-empty -m init
    git -C "$repo_dir" branch -M "$base_branch"
    git -C "$repo_dir" push -q origin "$base_branch"
    git -C "$repo_dir" worktree add -q -b "$branch" "$wt_dir" "$base_branch"
}

# Set up the outer variables and local wrapper functions _verify_artifact_or_fail
# depends on, bound to the given job. Usage: _va_bind_context <id> <branch> <base_ref> <isolation> <work_dir>
_va_bind_context() {
    id="$1"; branch="$2"; base_ref="$3"; isolation="$4"; work_dir="$5"
    job_file="$JOBS_DIR/$id.json"
    iso_now() { _iso_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S.000Z; }
    _atomic_write() {
        local _target="$1" content="$2" tmp="${1}.tmp.$$"
        printf '%s' "$content" > "$tmp" && mv "$tmp" "$_target"
    }
    _with_lock() {
        local target="$1"; shift
        local lockdir="${target}.lockdir"
        local tries=0
        while ! mkdir "$lockdir" 2>/dev/null; do
            sleep 0.05
            tries=$((tries + 1))
            [ "$tries" -gt 200 ] && return 1
        done
        "$@"
        local rc=$?
        rmdir "$lockdir" 2>/dev/null || true
        return $rc
    }
    _append_line() { printf '%s\n' "$2" >> "$1"; }
    _append_event() {
        local kind="$1" detail="${2:-}"
        [ -z "$detail" ] && detail='{}'
        local ev _eventpath
        ev=$(jq -nc --arg ts "$(iso_now)" --arg kind "$kind" --argjson detail "$detail" \
            '{ts: $ts, kind: $kind, detail: $detail}')
        _eventpath="$EVENTS_DIR/$id.jsonl"
        _with_lock "$_eventpath" _append_line "$_eventpath" "$ev"
    }
    _job_update() {
        local filter="$1"
        local merged; merged=$(jq "$filter" "$job_file") || return 1
        _atomic_write "$job_file" "$merged"
    }
    _transition() {
        local new="$1" detail="${2:-}"
        [ -z "$detail" ] && detail='{}'
        _job_update ".state = \"$new\""
        case "$new" in
            running)    _job_update ".started_at = \"$(iso_now)\"" ;;
            succeeded|failed|cancelled)
                        _job_update ".finished_at = \"$(iso_now)\""
                        _job_update ".force_start = null" ;;
        esac
        _append_event "$new" "$detail"
    }
}

@test "_verify_artifact_or_fail: HEAD pushed under a different branch name is accepted via prd_sha_on_origin, not failed" {
    local repo_dir="$MOTHER_ROOT/va-repo1"
    local bare_dir="$MOTHER_ROOT/va-bare1.git"
    local wt_dir="$MOTHER_ROOT/va-wt1"
    _va_make_repo_and_worktree "$repo_dir" "$bare_dir" "$wt_dir" "feature/assigned" "main"

    # The worker made a commit but pushed it to a DIFFERENT branch name than
    # the one it was assigned (e.g. it renamed the branch, or pushed to an
    # existing PR's branch by hand) — HEAD is reachable on origin, just not
    # under "feature/assigned".
    git -C "$wt_dir" commit -q --allow-empty -m "work"
    git -C "$wt_dir" push -q origin HEAD:refs/heads/some-other-branch-name

    make_job "va-job1" "running" \
        ".branch = \"feature/assigned\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$wt_dir\""

    _va_bind_context "va-job1" "feature/assigned" "main" "worktree" "$wt_dir"
    pr_url=""

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    # Must NOT have transitioned to failed.
    run jq -r '.state' "$job_file"
    [ "$output" != "failed" ]

    # Must NOT record the no_pr_no_push failure reason anywhere.
    run bash -c "grep -F '\"reason\":\"no_pr_no_push\"' '$EVENTS_DIR/va-job1.jsonl' 2>/dev/null; true"
    [ -z "$output" ]

    assert_event_kind "va-job1" "pushed_to_other_branch"
    run grep '"pushed_to_other_branch"' "$EVENTS_DIR/va-job1.jsonl"
    [[ "$output" =~ '"job_branch":"feature/assigned"' ]]
}

@test "_verify_artifact_or_fail: still fails no_pr_no_push when the branch was never pushed anywhere" {
    local repo_dir="$MOTHER_ROOT/va-repo2"
    local bare_dir="$MOTHER_ROOT/va-bare2.git"
    local wt_dir="$MOTHER_ROOT/va-wt2"
    _va_make_repo_and_worktree "$repo_dir" "$bare_dir" "$wt_dir" "feature/assigned2" "main"

    # Local commit exists, but nothing was ever pushed to origin.
    git -C "$wt_dir" commit -q --allow-empty -m "local only work"

    make_job "va-job2" "running" \
        ".branch = \"feature/assigned2\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$wt_dir\""

    _va_bind_context "va-job2" "feature/assigned2" "main" "worktree" "$wt_dir"
    pr_url=""

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    run jq -r '.state' "$job_file"
    [ "$output" = "failed" ]

    assert_event_kind "va-job2" "failed"
    run grep '"failed"' "$EVENTS_DIR/va-job2.jsonl"
    [[ "$output" =~ '"reason":"no_pr_no_push"' ]]
}

@test "_verify_artifact_or_fail: a no-op HEAD (zero commits ahead of base) is NOT accepted as shipped work via prd_sha_on_origin" {
    local repo_dir="$MOTHER_ROOT/va-repo3"
    local bare_dir="$MOTHER_ROOT/va-bare3.git"
    local wt_dir="$MOTHER_ROOT/va-wt3"
    _va_make_repo_and_worktree "$repo_dir" "$bare_dir" "$wt_dir" "feature/assigned3" "main"

    # No commits at all in the worktree — HEAD is identical to "main", which
    # _va_make_repo_and_worktree already pushed to origin. This is the exact
    # shape of the live incident: a worker that "ships" nothing still has a
    # HEAD that is trivially reachable from origin. An uncommitted edit is
    # left in place to mirror the real incident (real edits that were never
    # committed) — it must not change the outcome.
    echo "uncommitted edit" > "$wt_dir/scratch.txt"

    make_job "va-job3" "running" \
        ".branch = \"feature/assigned3\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$wt_dir\""

    _va_bind_context "va-job3" "feature/assigned3" "main" "worktree" "$wt_dir"
    pr_url=""

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    run jq -r '.state' "$job_file"
    [ "$output" = "failed" ]

    assert_event_kind "va-job3" "failed"
    run grep '"failed"' "$EVENTS_DIR/va-job3.jsonl"
    [[ "$output" =~ '"reason":"no_pr_no_push"' ]]

    # The escape hatch must NOT fire for a no-op HEAD — it must never be
    # accepted as "pushed under some other branch name".
    run bash -c "grep -F 'pushed_to_other_branch' '$EVENTS_DIR/va-job3.jsonl' 2>/dev/null; true"
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _verify_artifact_or_fail: no_pr:true commit verification.
#
# The `no_pr:true` opt-out drops the push/PR requirement, but the success
# condition it claims in the surrounding comment — "worker exited cleanly
# with commits on the branch" — must actually be checked. These tests pin
# down the real contract: count commits between base_ref and a tip ref that
# depends on isolation (HEAD for worktree jobs; refs/heads/$branch for
# main-dir jobs, since main-dir jobs restore the operator's original branch
# to HEAD after the worker exits). Zero commits or an unresolvable ref must
# fail closed; a non-empty pr_url still short-circuits everything.
# ---------------------------------------------------------------------------

# Plain (non-worktree) repo for main-dir no_pr fixtures: a real repo with an
# initial commit on `main`, no worktree involved. Usage: _va_maindir_repo <dir>
_va_maindir_repo() {
    local dir="$1"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m init
    git -C "$dir" branch -M "main"
}

@test "_verify_artifact_or_fail: no_pr job with zero commits on a worktree branch fails with no_commits_on_branch" {
    local repo_dir="$MOTHER_ROOT/va-repo-np1"
    local bare_dir="$MOTHER_ROOT/va-bare-np1.git"
    local wt_dir="$MOTHER_ROOT/va-wt-np1"
    _va_make_repo_and_worktree "$repo_dir" "$bare_dir" "$wt_dir" "feature/np1" "main"
    # No commits made in the worktree beyond the fixture's own base commit.

    make_job "np-job1" "running" \
        ".no_pr = true | .branch = \"feature/np1\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$wt_dir\""

    _va_bind_context "np-job1" "feature/np1" "main" "worktree" "$wt_dir"
    pr_url=""

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    run jq -r '.state' "$job_file"
    [ "$output" = "failed" ]

    assert_event_kind "np-job1" "failed"
    run grep '"failed"' "$EVENTS_DIR/np-job1.jsonl"
    [[ "$output" =~ '"reason":"no_commits_on_branch"' ]]
}

@test "_verify_artifact_or_fail: no_pr job with a worktree commit succeeds without ever pushing" {
    local repo_dir="$MOTHER_ROOT/va-repo-np2"
    local bare_dir="$MOTHER_ROOT/va-bare-np2.git"
    local wt_dir="$MOTHER_ROOT/va-wt-np2"
    _va_make_repo_and_worktree "$repo_dir" "$bare_dir" "$wt_dir" "feature/np2" "main"
    git -C "$wt_dir" commit -q --allow-empty -m "did work"
    # Deliberately never pushed to origin.

    make_job "np-job2" "running" \
        ".no_pr = true | .branch = \"feature/np2\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$wt_dir\""

    _va_bind_context "np-job2" "feature/np2" "main" "worktree" "$wt_dir"
    pr_url=""

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    run jq -r '.state' "$job_file"
    [ "$output" != "failed" ]

    assert_event_kind "np-job2" "no_pr_commits_verified"
}

@test "_verify_artifact_or_fail: no_pr main-dir job succeeds off the branch ref even when HEAD was restored elsewhere" {
    local repo_dir="$MOTHER_ROOT/va-maindir-np3"
    _va_maindir_repo "$repo_dir"
    # Commit lands on feature/x, then HEAD is restored to main — exactly what
    # mother-run-job's main-dir stash-restore does once the worker exits.
    git -C "$repo_dir" checkout -q -b "feature/x" main
    git -C "$repo_dir" commit -q --allow-empty -m "did work"
    git -C "$repo_dir" checkout -q main

    make_job "np-job3" "running" \
        ".no_pr = true | .branch = \"feature/x\" | .base_ref = \"main\" | .isolation = \"main-dir\" | .work_dir = \"$repo_dir\""

    _va_bind_context "np-job3" "feature/x" "main" "main-dir" "$repo_dir"
    pr_url=""

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    run jq -r '.state' "$job_file"
    [ "$output" != "failed" ]

    assert_event_kind "np-job3" "no_pr_commits_verified"
}

@test "_verify_artifact_or_fail: no_pr main-dir job with zero commits on the branch ref fails with no_commits_on_branch" {
    local repo_dir="$MOTHER_ROOT/va-maindir-np4"
    _va_maindir_repo "$repo_dir"
    # feature/y is created directly off main with no extra commits.
    git -C "$repo_dir" checkout -q -b "feature/y" main
    git -C "$repo_dir" checkout -q main

    make_job "np-job4" "running" \
        ".no_pr = true | .branch = \"feature/y\" | .base_ref = \"main\" | .isolation = \"main-dir\" | .work_dir = \"$repo_dir\""

    _va_bind_context "np-job4" "feature/y" "main" "main-dir" "$repo_dir"
    pr_url=""

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    run jq -r '.state' "$job_file"
    [ "$output" = "failed" ]

    assert_event_kind "np-job4" "failed"
    run grep '"failed"' "$EVENTS_DIR/np-job4.jsonl"
    [[ "$output" =~ '"reason":"no_commits_on_branch"' ]]
}

@test "_verify_artifact_or_fail: no_pr job with an unresolvable base_ref fails closed as commit_check_indeterminate" {
    local repo_dir="$MOTHER_ROOT/va-repo-np5"
    local bare_dir="$MOTHER_ROOT/va-bare-np5.git"
    local wt_dir="$MOTHER_ROOT/va-wt-np5"
    _va_make_repo_and_worktree "$repo_dir" "$bare_dir" "$wt_dir" "feature/np5" "main"
    git -C "$wt_dir" commit -q --allow-empty -m "did work"

    make_job "np-job5" "running" \
        ".no_pr = true | .branch = \"feature/np5\" | .base_ref = \"nonexistent-base-ref\" | .isolation = \"worktree\" | .work_dir = \"$wt_dir\""

    # base_ref bound here deliberately doesn't exist in the repo.
    _va_bind_context "np-job5" "feature/np5" "nonexistent-base-ref" "worktree" "$wt_dir"
    pr_url=""

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    run jq -r '.state' "$job_file"
    [ "$output" = "failed" ]
    [ "$output" != "succeeded" ]

    assert_event_kind "np-job5" "failed"
    run grep '"failed"' "$EVENTS_DIR/np-job5.jsonl"
    [[ "$output" =~ '"reason":"commit_check_indeterminate"' ]]
    [[ "$output" != *'"reason":"no_commits_on_branch"'* ]]
}

@test "_verify_artifact_or_fail: no_pr job with an existing pr_url short-circuits the commit check entirely" {
    local repo_dir="$MOTHER_ROOT/va-repo-np6"
    local bare_dir="$MOTHER_ROOT/va-bare-np6.git"
    local wt_dir="$MOTHER_ROOT/va-wt-np6"
    _va_make_repo_and_worktree "$repo_dir" "$bare_dir" "$wt_dir" "feature/np6" "main"
    # Zero commits ahead of base — would fail the commit check on its own.

    make_job "np-job6" "running" \
        ".no_pr = true | .branch = \"feature/np6\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$wt_dir\""

    _va_bind_context "np-job6" "feature/np6" "main" "worktree" "$wt_dir"
    pr_url="https://github.com/x/y/pull/1"

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    run jq -r '.state' "$job_file"
    [ "$output" != "failed" ]

    # An existing pr_url means the artifact is real regardless of commit
    # count — no failed event should be recorded for this job at all.
    run bash -c "[ -f '$EVENTS_DIR/np-job6.jsonl' ] && grep -c '\"failed\"' '$EVENTS_DIR/np-job6.jsonl' || echo 0"
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# _finalize_pr_url — authoritative post-run PR URL capture, stale-URL
# re-derivation, and branch-mismatch validation. This is the biggest single
# change in the PR-detection rework and previously had zero coverage in this
# file (only _job_owner_repo_from_url / _scrape_pr_url_filtered /
# _derive_pr_url_from_branch / _verify_artifact_or_fail were exercised).
#
# Reuses _va_bind_context (above) for the outer globals/helper functions
# _finalize_pr_url depends on (job_file, _append_event, _job_update, etc.) —
# same rationale: it only touches globals/helpers resolved at call time.
# Additionally sets log_path/log_offset_at_spawn (unused by these scenarios,
# but referenced under `set -u`) and clears the global `pr_url` before each
# call so a prior test's value can't leak in.
# ---------------------------------------------------------------------------

# A plain (non-worktree) repo is enough for _finalize_pr_url's git calls
# (rev-parse, rev-list) — no real push to origin is needed since every gh
# call is mocked. Usage: _fin_make_repo <dir> <branch> <base_branch>
_fin_make_repo() {
    local dir="$1" branch="$2" base_branch="${3:-main}"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m init
    git -C "$dir" branch -M "$base_branch"
    git -C "$dir" checkout -q -b "$branch"
    git -C "$dir" commit -q --allow-empty -m "work"
    git -C "$dir" remote add origin "https://github.com/thehammer/mother.git"
}

@test "_finalize_pr_url captures a PR via prd_detect_pr's commit-match fallback when no pr_url is stored and the branch query finds nothing" {
    local repo="$MOTHER_ROOT/fin-repo-1"
    _fin_make_repo "$repo" "feature/fin-1" "main"
    local head_sha; head_sha=$(git -C "$repo" rev-parse HEAD)
    local pr="https://github.com/thehammer/mother/pull/701"

    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
    *"pr list"*)
        exit 0
        ;;
    *"commits/$head_sha/pulls"*)
        printf '[{"state":"open","updated_at":"2026-01-01T00:00:00Z","html_url":"$pr"}]\n'
        ;;
    *"pr view $pr --json headRefName"*)
        echo "feature/fin-1"
        ;;
    *)
        exit 0
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"

    make_job "fin-job-1" "running" \
        ".branch = \"feature/fin-1\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$repo\""
    _va_bind_context "fin-job-1" "feature/fin-1" "main" "worktree" "$repo"
    pr_url=""; log_path=""; log_offset_at_spawn=0

    _finalize_pr_url

    [ "$pr_url" = "$pr" ]
    run jq -r '.pr_url' "$job_file"
    [ "$output" = "$pr" ]
    assert_event_kind "fin-job-1" "pr_opened"
}

@test "_finalize_pr_url replaces a stale non-OPEN pr_url with the live open PR on the branch (pr_url_updated)" {
    local repo="$MOTHER_ROOT/fin-repo-2"
    _fin_make_repo "$repo" "feature/fin-2" "main"
    local old_pr="https://github.com/thehammer/mother/pull/59"
    local new_pr="https://github.com/thehammer/mother/pull/60"

    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
    *"pr view $old_pr --json state,headRefName"*)
        printf 'MERGED\tfeature/fin-2-old\n'
        ;;
    *"pr list"*"feature/fin-2"*)
        printf '{"url":"$new_pr"}\n'
        ;;
    *)
        exit 0
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"

    make_job "fin-job-2" "running" \
        ".branch = \"feature/fin-2\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$repo\" | .pr_url = \"$old_pr\""
    _va_bind_context "fin-job-2" "feature/fin-2" "main" "worktree" "$repo"
    pr_url=""; log_path=""; log_offset_at_spawn=0

    _finalize_pr_url

    [ "$pr_url" = "$new_pr" ]
    run jq -r '.pr_url' "$job_file"
    [ "$output" = "$new_pr" ]
    assert_event_kind "fin-job-2" "pr_url_updated"
    run grep '"pr_url_updated"' "$EVENTS_DIR/fin-job-2.jsonl"
    [[ "$output" =~ "\"previous_url\":\"$old_pr\"" ]]
    [[ "$output" =~ "\"url\":\"$new_pr\"" ]]
}

@test "_finalize_pr_url accepts a branch-mismatched PR that contains the job's HEAD commit (pr_branch_mismatch_accepted, actual_branch recorded)" {
    local repo="$MOTHER_ROOT/fin-repo-3"
    _fin_make_repo "$repo" "feature/fin-3" "main"
    local head_sha; head_sha=$(git -C "$repo" rev-parse HEAD)
    local pr="https://github.com/thehammer/mother/pull/703"

    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
    *"pr list"*)
        exit 0
        ;;
    *"commits/$head_sha/pulls"*)
        printf '[{"state":"open","updated_at":"2026-01-01T00:00:00Z","html_url":"$pr"}]\n'
        ;;
    *"pr view $pr --json headRefName"*)
        echo "some-other-branch"
        ;;
    *"pr view $pr --json commits"*)
        echo "$head_sha"
        ;;
    *)
        exit 0
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"

    make_job "fin-job-3" "running" \
        ".branch = \"feature/fin-3\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$repo\""
    _va_bind_context "fin-job-3" "feature/fin-3" "main" "worktree" "$repo"
    pr_url=""; log_path=""; log_offset_at_spawn=0

    _finalize_pr_url

    [ "$pr_url" = "$pr" ]
    run jq -r '.actual_branch' "$job_file"
    [ "$output" = "some-other-branch" ]
    assert_event_kind "fin-job-3" "pr_branch_mismatch_accepted"
    run grep '"pr_branch_mismatch_accepted"' "$EVENTS_DIR/fin-job-3.jsonl"
    [[ "$output" =~ "\"matched_sha\":\"$head_sha\"" ]]
    assert_event_kind "fin-job-3" "pr_opened"
}

@test "_finalize_pr_url clears a stored pr_url when the mismatched PR shares no commits with the job (pr_url_branch_mismatch)" {
    local repo="$MOTHER_ROOT/fin-repo-4"
    _fin_make_repo "$repo" "feature/fin-4" "main"
    local pr="https://github.com/thehammer/mother/pull/704"

    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
    *"pr view $pr --json state,headRefName"*)
        printf 'OPEN\tsome-other-branch\n'
        ;;
    *"pr view $pr --json commits"*)
        echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
        ;;
    *"pr list"*)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"

    make_job "fin-job-4" "running" \
        ".branch = \"feature/fin-4\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$repo\" | .pr_url = \"$pr\""
    _va_bind_context "fin-job-4" "feature/fin-4" "main" "worktree" "$repo"
    pr_url=""; log_path=""; log_offset_at_spawn=0

    # run (not a bare call): the candidate-SHA loop inside _finalize_pr_url
    # invokes prd_pr_contains_sha directly (capturing $? on the next line),
    # which is exactly the shape bats' errexit-under-test treats as a fatal
    # nonzero command if called bare — `run` disables that for the duration.
    run _finalize_pr_url
    [ "$status" -eq 0 ]

    run jq -r '.pr_url // "null"' "$job_file"
    [ "$output" = "null" ]
    assert_event_kind "fin-job-4" "pr_url_branch_mismatch"

    # Regression guard: the jq filter for this event previously had a
    # backslash line-continuation INSIDE a single-quoted jq program, which
    # bash preserves literally there (it is not a shell line continuation
    # inside single quotes) — invalid jq syntax. jq errored and
    # _append_event recorded an empty `{}` detail, so the event kind landed
    # but every field silently vanished. Assert the actual fields.
    run grep '"pr_url_branch_mismatch"' "$EVENTS_DIR/fin-job-4.jsonl"
    [[ "$output" =~ "\"pr_url\":\"$pr\"" ]]
    [[ "$output" =~ "\"pr_branch\":\"some-other-branch\"" ]]
    [[ "$output" =~ "\"job_branch\":\"feature/fin-4\"" ]]
}

@test "_finalize_pr_url clears a stored pr_url that never resolves at all (pr_url_unresolved), with detail fields intact" {
    local repo="$MOTHER_ROOT/fin-repo-7"
    _fin_make_repo "$repo" "feature/fin-7" "main"
    local pr="https://github.com/thehammer/mother/pull/707"

    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
    *"pr view $pr"*)
        echo "gh: could not resolve to a PullRequest" >&2
        exit 1
        ;;
    *"pr list"*)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"

    make_job "fin-job-7" "running" \
        ".branch = \"feature/fin-7\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$repo\" | .pr_url = \"$pr\""
    _va_bind_context "fin-job-7" "feature/fin-7" "main" "worktree" "$repo"
    pr_url=""; log_path=""; log_offset_at_spawn=0

    run _finalize_pr_url
    [ "$status" -eq 0 ]

    run jq -r '.pr_url // "null"' "$job_file"
    [ "$output" = "null" ]

    # Same jq-syntax regression as pr_url_branch_mismatch above, in the
    # sibling pr_url_unresolved event — assert fields, not just the kind.
    assert_event_kind "fin-job-7" "pr_url_unresolved"
    run grep '"pr_url_unresolved"' "$EVENTS_DIR/fin-job-7.jsonl"
    [[ "$output" =~ "\"pr_url\":\"$pr\"" ]]
    [[ "$output" =~ "\"job_branch\":\"feature/fin-7\"" ]]
}

@test "_finalize_pr_url leaves a stored pr_url intact when the commit-containment check is indeterminate (pr_branch_mismatch_unverified)" {
    local repo="$MOTHER_ROOT/fin-repo-5"
    _fin_make_repo "$repo" "feature/fin-5" "main"
    local pr="https://github.com/thehammer/mother/pull/705"

    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
    *"pr view $pr --json state,headRefName"*)
        printf 'OPEN\tsome-other-branch\n'
        ;;
    *"pr view $pr --json commits"*)
        echo "gh: network error" >&2
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"

    make_job "fin-job-5" "running" \
        ".branch = \"feature/fin-5\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$repo\" | .pr_url = \"$pr\""
    _va_bind_context "fin-job-5" "feature/fin-5" "main" "worktree" "$repo"
    pr_url=""; log_path=""; log_offset_at_spawn=0

    # run (not a bare call): see the comment on the pr_url_branch_mismatch
    # test above — prd_pr_contains_sha's indeterminate (rc=2) return from a
    # bare call inside the candidate loop trips bats' errexit-under-test.
    run _finalize_pr_url
    [ "$status" -eq 0 ]

    run jq -r '.pr_url' "$job_file"
    [ "$output" = "$pr" ]
    assert_event_kind "fin-job-5" "pr_branch_mismatch_unverified"
}

@test "_finalize_pr_url accepts a mismatched branch without the SHA check when expect_branch_mismatch is true" {
    local repo="$MOTHER_ROOT/fin-repo-6"
    _fin_make_repo "$repo" "feature/fin-6" "main"
    local pr="https://github.com/thehammer/mother/pull/706"
    local sha_check_marker="$MOTHER_ROOT/fin-6-sha-check-called"

    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
    *"pr view $pr --json state,headRefName"*)
        printf 'OPEN\tsome-other-branch\n'
        ;;
    *"pr view $pr --json commits"*)
        touch "$sha_check_marker"
        echo "deadbeef"
        ;;
    *)
        exit 0
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"

    make_job "fin-job-6" "running" \
        ".branch = \"feature/fin-6\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$repo\" | .pr_url = \"$pr\" | .expect_branch_mismatch = true"
    _va_bind_context "fin-job-6" "feature/fin-6" "main" "worktree" "$repo"
    pr_url=""; log_path=""; log_offset_at_spawn=0

    _finalize_pr_url

    [ "$pr_url" = "$pr" ]
    [ ! -f "$sha_check_marker" ]
    run jq -r '.actual_branch' "$job_file"
    [ "$output" = "some-other-branch" ]
    assert_event_kind "fin-job-6" "pr_branch_mismatch_accepted"
    run grep '"pr_branch_mismatch_accepted"' "$EVENTS_DIR/fin-job-6.jsonl"
    [[ "$output" =~ '"matched_sha":null' ]]
    [[ "$output" =~ '"expected":true' ]]
}
