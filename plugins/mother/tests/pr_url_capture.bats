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
