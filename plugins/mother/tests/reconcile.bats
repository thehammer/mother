#!/usr/bin/env bats
# reconcile.bats — behavioral contract for `mother reconcile`.
#
# `mother reconcile` does NOT exist yet — every test in this file is expected
# to FAIL (red) until Cody implements it. This file is the acceptance bar.
#
# Usage under test: mother reconcile <id> [--pr-url URL] [--auto] [--yes] [--dry-run]
#
# Purpose: a job that failed (e.g. `_verify_artifact_or_fail` couldn't find a
# pr_url, or the worker crashed after actually opening/landing a PR) may in
# fact have shippable work sitting on GitHub already. `mother reconcile` lets
# an operator (or mother-runner's own pre-escalation check) adopt that PR
# instead of blindly re-running/escalating a job that already succeeded in
# spirit.

load 'test_helper'

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Fixtures & helpers
# ---------------------------------------------------------------------------

# A reconcile-eligible job: failed, with routing/adherence state populated so
# tests can assert exactly what reconcile does and does not touch.
# Usage: _rc_make_job <id> [extra-jq-filter]
_rc_make_job() {
    local id="$1" extra="${2:-.}"
    make_job "$id" "failed" "
        .branch = \"feature/${id}\"
        | .base_ref = \"main\"
        | .current_tier = \"tier_2\"
        | .escalation_count = 2
        | .adherence_attempts = 1
        | .adherence_pending = true
        | .adherence_status = \"failed_first\"
        | .adherence_notes = \"archie's old notes\"
        | .force_start = true
        | .finished_at = null
        | ($extra)
    "
}

# gh mock: `pr view <url> --json headRefName` -> $head_branch;
# `pr view <url> --json commits --jq ...` -> one oid per line from $shas (may
# be empty); `pr list --head <branch> --state open --json url` -> {"url":$auto_url}
# if $auto_url is non-empty, else nothing. Any unmatched call prints empty.
_rc_install_mock_gh() {
    local head_branch="$1" shas="$2" auto_url="${3:-}"
    local shas_file="$MOTHER_ROOT/rc-shas.txt"
    printf '%s\n' "$shas" > "$shas_file"
    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOTHER_ROOT:?}/mock-gh-calls"
case "\$*" in
    *"pr view"*headRefName*)
        echo "$head_branch"
        ;;
    *"pr view"*commits*)
        cat "$shas_file"
        ;;
    *"pr list"*)
        if [ -n "$auto_url" ]; then
            printf '{"url":"%s"}\n' "$auto_url"
        else
            echo ""
        fi
        ;;
    *)
        echo ""
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"
}

# ===========================================================================
# State gate
# ===========================================================================

@test "mother reconcile refuses on a running job, naming the state" {
    make_job "job-rc-running" "running"
    run mother reconcile "job-rc-running" --pr-url "https://github.com/x/y/pull/1"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "running" ]]
}

@test "mother reconcile refuses on a ready job, naming the state" {
    make_job "job-rc-ready" "ready"
    run mother reconcile "job-rc-ready" --pr-url "https://github.com/x/y/pull/1"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "ready" ]]
}

@test "mother reconcile refuses on a queued job, naming the state" {
    make_job "job-rc-queued" "queued"
    run mother reconcile "job-rc-queued" --pr-url "https://github.com/x/y/pull/1"
    [ "$status" -ne 0 ]
    [[ "$output" =~ "queued" ]]
}

# ===========================================================================
# --pr-url — explicit adoption, verified by headRefName match
# ===========================================================================

@test "--pr-url adopts an explicit PR verified by matching headRefName" {
    local branch="feature/job-rc-explicit"
    local pr_url="https://github.com/thehammer/mother/pull/70"
    _rc_install_mock_gh "$branch" ""
    _rc_make_job "job-rc-explicit" ".branch = \"$branch\" | .work_dir = \"/nonexistent/does-not-matter\""

    run mother reconcile "job-rc-explicit" --pr-url "$pr_url"
    [ "$status" -eq 0 ]

    assert_job_field "job-rc-explicit" '.state' "succeeded"
    assert_job_field "job-rc-explicit" '.pr_url' "$pr_url"
    assert_job_field "job-rc-explicit" '.force_start // "absent"' "absent"
    assert_job_field "job-rc-explicit" '.adherence_pending // "absent"' "absent"
    assert_job_field "job-rc-explicit" '.adherence_status // "absent"' "absent"
    assert_job_field "job-rc-explicit" '.adherence_notes // "absent"' "absent"
    assert_job_field "job-rc-explicit" '.adherence_attempts' "0"
    assert_job_field_truthy "job-rc-explicit" '.finished_at'

    # Routing fields survive untouched — reconcile is not an escalation.
    assert_job_field "job-rc-explicit" '.current_tier' "tier_2"
    assert_job_field "job-rc-explicit" '.escalation_count' "2"

    assert_event_kind "job-rc-explicit" "reconciled"
    assert_event_kind "job-rc-explicit" "succeeded"

    local events_file="$EVENTS_DIR/job-rc-explicit.jsonl"
    run grep '"reconciled"' "$events_file"
    [[ "$output" =~ '"pr_url":"'"$pr_url"'"' ]]
    [[ "$output" =~ '"previous_state":"failed"' ]]
    [[ "$output" =~ '"match_kind":"branch"' ]]
    [[ "$output" =~ '"source":"manual"' ]]

    # reconciled must land strictly before succeeded in the events trail.
    local reconciled_line succeeded_line
    reconciled_line=$(grep -n '"reconciled"' "$events_file" | head -1 | cut -d: -f1)
    succeeded_line=$(grep -n '"kind":"succeeded"' "$events_file" | head -1 | cut -d: -f1)
    [ -n "$reconciled_line" ]
    [ -n "$succeeded_line" ]
    [ "$reconciled_line" -lt "$succeeded_line" ]
}

@test "--pr-url does not set .actual_branch when the PR's head branch matches the job branch" {
    local branch="feature/job-rc-samebranch"
    local pr_url="https://github.com/thehammer/mother/pull/71"
    _rc_install_mock_gh "$branch" ""
    _rc_make_job "job-rc-samebranch" ".branch = \"$branch\""

    run mother reconcile "job-rc-samebranch" --pr-url "$pr_url"
    [ "$status" -eq 0 ]
    run jq -r '.actual_branch // "absent"' "$JOBS_DIR/job-rc-samebranch.json"
    [ "$output" = "absent" ]
}

# ===========================================================================
# --pr-url — explicit adoption, verified by SHA containment (real git)
# ===========================================================================

@test "--pr-url adopts an explicit PR verified by commit containment when the head branch differs" {
    local repo_dir="$MOTHER_ROOT/rc-repo-sha"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" commit -q --allow-empty -m init
    git -C "$repo_dir" branch -M main
    git -C "$repo_dir" checkout -q -b "feature/job-rc-sha"
    git -C "$repo_dir" commit -q --allow-empty -m "work"
    local head_sha
    head_sha=$(git -C "$repo_dir" rev-parse HEAD)

    local pr_url="https://github.com/thehammer/mother/pull/72"
    _rc_install_mock_gh "some-other-pr-branch" "$head_sha"
    _rc_make_job "job-rc-sha" ".branch = \"feature/job-rc-sha\" | .base_ref = \"main\" | .work_dir = \"$repo_dir\""

    run mother reconcile "job-rc-sha" --pr-url "$pr_url"
    [ "$status" -eq 0 ]

    assert_job_field "job-rc-sha" '.state' "succeeded"
    assert_job_field "job-rc-sha" '.pr_url' "$pr_url"
    assert_job_field "job-rc-sha" '.actual_branch' "some-other-pr-branch"

    local events_file="$EVENTS_DIR/job-rc-sha.jsonl"
    run grep '"reconciled"' "$events_file"
    [[ "$output" =~ '"match_kind":"commit"' ]]
    [[ "$output" =~ '"matched_sha":"'"$head_sha"'"' ]]
}

# ===========================================================================
# Auto-detect (no --pr-url)
# ===========================================================================

@test "auto-detect without --auto adopts a verifiable PR found via branch match; source=manual" {
    local repo_dir="$MOTHER_ROOT/rc-repo-autodetect"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" commit -q --allow-empty -m init
    git -C "$repo_dir" remote add origin "https://github.com/thehammer/mother.git"

    local branch="feature/job-rc-autodetect"
    local pr_url="https://github.com/thehammer/mother/pull/80"
    _rc_install_mock_gh "$branch" "" "$pr_url"
    _rc_make_job "job-rc-autodetect" ".branch = \"$branch\" | .work_dir = \"$repo_dir\""

    run mother reconcile "job-rc-autodetect"
    [ "$status" -eq 0 ]

    assert_job_field "job-rc-autodetect" '.state' "succeeded"
    assert_job_field "job-rc-autodetect" '.pr_url' "$pr_url"

    local events_file="$EVENTS_DIR/job-rc-autodetect.jsonl"
    run grep '"reconciled"' "$events_file"
    [[ "$output" =~ '"source":"manual"' ]]
}

@test "--auto adopts a verifiable PR found via prd_detect_pr; source=auto" {
    local repo_dir="$MOTHER_ROOT/rc-repo-auto-flag"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" commit -q --allow-empty -m init
    git -C "$repo_dir" remote add origin "https://github.com/thehammer/mother.git"

    local branch="feature/job-rc-auto-flag"
    local pr_url="https://github.com/thehammer/mother/pull/81"
    _rc_install_mock_gh "$branch" "" "$pr_url"
    _rc_make_job "job-rc-auto-flag" ".branch = \"$branch\" | .work_dir = \"$repo_dir\""

    run mother reconcile "job-rc-auto-flag" --auto
    [ "$status" -eq 0 ]

    assert_job_field "job-rc-auto-flag" '.state' "succeeded"
    local events_file="$EVENTS_DIR/job-rc-auto-flag.jsonl"
    run grep '"reconciled"' "$events_file"
    [[ "$output" =~ '"source":"auto"' ]]
}

@test "--auto does not adopt a commit-matched PR that prd_pr_for_commit only found via its closed/merged fallback" {
    # prd_pr_for_commit prefers an OPEN PR but falls back to the most
    # recently updated PR (open or not) when none is open. A branch hit is
    # always OPEN by construction (prd_pr_for_branch queries --state open),
    # but a commit hit is not -- --auto's non-interactive contract must
    # never unattendedly adopt a merged/closed PR just because it was the
    # only thing prd_pr_for_commit's fallback returned.
    local repo_dir="$MOTHER_ROOT/rc-repo-auto-commit-closed"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" commit -q --allow-empty -m init
    git -C "$repo_dir" branch -M main
    git -C "$repo_dir" checkout -q -b "feature/job-rc-auto-commit-closed"
    git -C "$repo_dir" commit -q --allow-empty -m "work"
    git -C "$repo_dir" remote add origin "https://github.com/thehammer/mother.git"
    local head_sha
    head_sha=$(git -C "$repo_dir" rev-parse HEAD)

    local pr_url="https://github.com/thehammer/mother/pull/82"
    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOTHER_ROOT:?}/mock-gh-calls"
case "\$*" in
    *"pr list"*)
        echo ""
        ;;
    *"commits/$head_sha/pulls"*)
        printf '[{"state":"closed","updated_at":"2026-01-01T00:00:00Z","html_url":"$pr_url"}]\n'
        ;;
    *"pr view $pr_url --json state"*)
        echo "CLOSED"
        ;;
    *)
        echo ""
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"
    _rc_make_job "job-rc-auto-commit-closed" ".branch = \"feature/job-rc-auto-commit-closed\" | .base_ref = \"main\" | .work_dir = \"$repo_dir\""

    local before_json
    before_json=$(cat "$JOBS_DIR/job-rc-auto-commit-closed.json")

    run mother reconcile "job-rc-auto-commit-closed" --auto
    [ "$status" -eq 3 ]

    local after_json
    after_json=$(cat "$JOBS_DIR/job-rc-auto-commit-closed.json")
    [ "$before_json" = "$after_json" ]

    run bash -c "[ -f '$EVENTS_DIR/job-rc-auto-commit-closed.jsonl' ]"
    if [ "$status" -eq 0 ]; then
        run grep -c '"reconciled"' "$EVENTS_DIR/job-rc-auto-commit-closed.jsonl"
        [ "$output" -eq 0 ]
    fi
}

@test "--auto exits 3 and mutates nothing when nothing is detected" {
    local repo_dir="$MOTHER_ROOT/rc-repo-auto-nothing"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" commit -q --allow-empty -m init
    git -C "$repo_dir" remote add origin "https://github.com/thehammer/mother.git"

    _rc_install_mock_gh "irrelevant" "" ""
    _rc_make_job "job-rc-auto-nothing" ".work_dir = \"$repo_dir\""

    local before_json
    before_json=$(cat "$JOBS_DIR/job-rc-auto-nothing.json")

    run mother reconcile "job-rc-auto-nothing" --auto
    [ "$status" -eq 3 ]

    local after_json
    after_json=$(cat "$JOBS_DIR/job-rc-auto-nothing.json")
    [ "$before_json" = "$after_json" ]

    run bash -c "[ -f '$EVENTS_DIR/job-rc-auto-nothing.jsonl' ]"
    if [ "$status" -eq 0 ]; then
        run grep -c '"reconciled"' "$EVENTS_DIR/job-rc-auto-nothing.jsonl"
        [ "$output" -eq 0 ]
    fi
}

# ===========================================================================
# Unverifiable PR — refused without --yes, adopted with --yes
# ===========================================================================

@test "an unverifiable PR is refused without --yes" {
    local pr_url="https://github.com/thehammer/mother/pull/90"
    # Head branch differs from the job's branch, AND commit containment is a
    # clean miss (a sha that will never appear in the mocked commit list).
    _rc_install_mock_gh "totally-different-branch" "0000000000000000000000000000000000000000"
    _rc_make_job "job-rc-unverifiable" ".branch = \"feature/job-rc-unverifiable\" | .work_dir = \"/nonexistent/no-such-dir\""

    run mother reconcile "job-rc-unverifiable" --pr-url "$pr_url"
    [ "$status" -ne 0 ]

    assert_job_field "job-rc-unverifiable" '.state' "failed"
    run jq -r '.pr_url // "absent"' "$JOBS_DIR/job-rc-unverifiable.json"
    [ "$output" != "$pr_url" ]
}

@test "an unverifiable PR is adopted when --yes is passed" {
    local pr_url="https://github.com/thehammer/mother/pull/91"
    _rc_install_mock_gh "totally-different-branch" "0000000000000000000000000000000000000000"
    _rc_make_job "job-rc-unverifiable-yes" ".branch = \"feature/job-rc-unverifiable-yes\" | .work_dir = \"/nonexistent/no-such-dir\""

    run mother reconcile "job-rc-unverifiable-yes" --pr-url "$pr_url" --yes
    [ "$status" -eq 0 ]

    assert_job_field "job-rc-unverifiable-yes" '.state' "succeeded"
    assert_job_field "job-rc-unverifiable-yes" '.pr_url' "$pr_url"
    assert_job_field "job-rc-unverifiable-yes" '.force_start // "absent"' "absent"
    assert_job_field "job-rc-unverifiable-yes" '.adherence_attempts' "0"
    assert_job_field "job-rc-unverifiable-yes" '.current_tier' "tier_2"
    assert_job_field "job-rc-unverifiable-yes" '.escalation_count' "2"
}

# ===========================================================================
# --dry-run
# ===========================================================================

@test "--dry-run leaves the job file byte-for-byte unchanged and appends no events" {
    local branch="feature/job-rc-dryrun"
    local pr_url="https://github.com/thehammer/mother/pull/92"
    _rc_install_mock_gh "$branch" ""
    _rc_make_job "job-rc-dryrun" ".branch = \"$branch\""

    local before_json
    before_json=$(cat "$JOBS_DIR/job-rc-dryrun.json")

    run mother reconcile "job-rc-dryrun" --pr-url "$pr_url" --dry-run
    [ "$status" -eq 0 ]

    local after_json
    after_json=$(cat "$JOBS_DIR/job-rc-dryrun.json")
    [ "$before_json" = "$after_json" ]

    # No event appended — safe against the events file not existing at all.
    run bash -c "grep -c '\"reconciled\"' '$EVENTS_DIR/job-rc-dryrun.jsonl' 2>/dev/null; true"
    [ "$output" = "0" ] || [ -z "$output" ]
}
