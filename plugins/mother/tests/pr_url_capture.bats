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
