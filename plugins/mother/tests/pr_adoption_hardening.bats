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

# ===========================================================================
# Hardening round 2 — fixtures
# ===========================================================================

AFTER_SPAWN_AT="2026-11-08T13:00:00Z"

# _ph_bind for a job WITHOUT expect_branch_mismatch (the ordinary case).
_ph_bind_plain() {
    _ph_bind "$1" "$2" "$3"
    jq '.expect_branch_mismatch = false' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
}

# _ph_set_clock <attempt-start|-> <spawned-at>  (job_file must be set)
_ph_set_clock() {
    local f='.current_run.spawned_at = $sp'
    [ "$1" = "-" ] || f="$f | .attempt_run = {key: \"0:0\", started_at: \$at}"
    jq --arg at "$1" --arg sp "$2" "$f" "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
}

# pr_url_rejected events as "<reason>:<transient>" lines.
_ph_rejections() {
    jq -r 'select(.kind=="pr_url_rejected") | "\(.detail.reason):\(.detail.transient // false)"' \
        "$EVENTS_DIR/$1.jsonl" 2>/dev/null || true
}

_ph_rejection_count() { _ph_rejections "$1" | grep -c . || true; }

# The job has no PR recorded (job file + shell variable).
_ph_clear_pr() {
    jq '.pr_url = null' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    pr_url=""
}

_ph_failed_reason() { jq -r 'select(.kind=="failed") | .detail.reason' "$EVENTS_DIR/$1.jsonl" 2>/dev/null | tail -1; }

# A pre-receive hook that records every push attempt and rejects it.
_ph_log_and_reject_pushes() {
    PH_PUSH_LOG="$MOTHER_ROOT/push-attempts"; : > "$PH_PUSH_LOG"
    printf '#!/bin/sh\necho push >> "%s"\nexit 1\n' "$PH_PUSH_LOG" > "$RA_BARE/hooks/pre-receive"
    chmod +x "$RA_BARE/hooks/pre-receive"
}

# A `git` shim first on PATH: records every invocation in $MOTHER_ROOT/git-calls
# and, while PH_GIT_SLOW is set, makes ls-remote/push/fetch hang (exec'd sleep,
# so killing the shim by its own pid leaves nothing behind). Everything else is
# real git. Install AFTER repo setup; export PH_GIT_SLOW only when ready.
_ph_install_git_shim() {
    local real; real=$(command -v git)
    mkdir -p "$MOTHER_ROOT/git-shim"
    cat > "$MOTHER_ROOT/git-shim/git" <<SHIM_EOF
#!/bin/sh
echo "\$*" >> "$MOTHER_ROOT/git-calls"
case "\$1" in
    ls-remote|push|fetch) [ -n "\${PH_GIT_SLOW:-}" ] && exec sleep 30 ;;
esac
exec "$real" "\$@"
SHIM_EOF
    chmod +x "$MOTHER_ROOT/git-shim/git"
    : > "$MOTHER_ROOT/git-calls"
    export PATH="$MOTHER_ROOT/git-shim:$PATH"
}

# Turn the job from _ph_unpushed_env into a held/failed unpushed_commit job.
_ph_hold_job() {
    local f='.failure_reason = "unpushed_commit" | .finished_at = "2026-11-08T12:00:00Z"
        | .needs_attention = {reason: "unpushed_commit", note: "n", since: "2026-11-08T12:00:00Z"}'
    if [ "${2:-failed}" = "awaiting" ]; then
        f="$f | .state = \"awaiting\" | .activity = \"operator_hold\" | .paused_reason = \"operator_hold\"
            | .operator_hold = {failure_reason: \"unpushed_commit\", held_at: \"2026-11-08T12:00:00Z\"}"
    else
        f="$f | .state = \"failed\""
    fi
    jq "$f" "$JOBS_DIR/$1.json" > "$JOBS_DIR/$1.json.tmp" && mv "$JOBS_DIR/$1.json.tmp" "$JOBS_DIR/$1.json"
}

# Number of job_flagged needs-attention items for a job, via the real renderer.
_ph_flagged_count() {
    mkdir -p "$MOTHER_ROOT/home"
    HOME="$MOTHER_ROOT/home" mother status --format json 2>/dev/null \
        | jq --arg id "$1" '[.needs_attention[]? | select(.kind == "job_flagged" and .job_id == $id)] | length'
}

# ===========================================================================
# 7. Stored pr_url is kept across a gh outage; the push check still guards it
# ===========================================================================

@test "gh outage: a stored pr_url survives finalize and the unpushed final commit still fails the job (never succeeded)" {
    _ph_unpushed_env "s1"
    _ph_reject_pushes
    gh_mock_remove_pr "$PH_PR"          # gh pr view <url> now fails

    _finalize_pr_url

    [ "$pr_url" = "$PH_PR" ]
    [ "$(jq -r '.pr_url' "$job_file")" = "$PH_PR" ]

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]
    [ "$(jq -r '.state' "$job_file")" = "failed" ]
    [ "$(_ph_failed_reason ph-s1)" = "unpushed_commit" ]
    [ "$(jq -r '.pr_url' "$job_file")" = "$PH_PR" ]
}

@test "gh outage: a transient failure then recovery keeps the stored pr_url and the job verifies once the commit can be pushed" {
    _ph_unpushed_env "s2"
    local head; head=$(git -C "$RA_WT" rev-parse HEAD)
    gh_mock_remove_pr "$PH_PR"

    _finalize_pr_url
    [ "$(jq -r '.pr_url' "$job_file")" = "$PH_PR" ]

    gh_mock_set_pr "$PH_PR" OPEN "$RA_BRANCH"      # gh recovers
    _finalize_pr_url
    [ "$pr_url" = "$PH_PR" ]
    [ "$(jq -r '.pr_url' "$job_file")" = "$PH_PR" ]
    # Not a new capture: no second pr_opened.
    [ "$(_ph_events ph-s2 pr_opened)" = "0" ]

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]
    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    [ "$(git -C "$RA_BARE" rev-parse "refs/heads/$RA_BRANCH")" = "$head" ]
}

@test "gh outage (GH_MOCK_FAIL_VIEW): the stored pr_url is retained while gh pr view fails everywhere" {
    _ph_unpushed_env "s3"
    export GH_MOCK_FAIL_VIEW=1

    _finalize_pr_url
    _finalize_pr_url

    [ "$pr_url" = "$PH_PR" ]
    [ "$(jq -r '.pr_url' "$job_file")" = "$PH_PR" ]
}

# ===========================================================================
# 2. A branch on origin proves nothing without the job's final commit
# ===========================================================================

@test "verify (no pr_url): branch exists on origin but the final commit is not in it and cannot be pushed -> failed unpushed_commit" {
    _ph_unpushed_env "n1"
    _ph_clear_pr
    _ph_reject_pushes

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    [ "$(jq -r '.state' "$job_file")" = "failed" ]
    [ "$(_ph_failed_reason ph-n1)" = "unpushed_commit" ]
    [ "$(jq -r '.needs_attention.reason' "$job_file")" = "unpushed_commit" ]
    [ "$(_ph_events ph-n1 no_pr_url_but_branch_pushed)" = "0" ]
}

@test "verify (no pr_url): branch on origin, final commit pushable -> pushed, passes, no_pr_url_but_branch_pushed" {
    _ph_unpushed_env "n2"
    _ph_clear_pr
    local head; head=$(git -C "$RA_WT" rev-parse HEAD)

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    [ "$(git -C "$RA_BARE" rev-parse "refs/heads/$RA_BRANCH")" = "$head" ]
    [ "$(_ph_events ph-n2 no_pr_url_but_branch_pushed)" = "1" ]
}

# Job branch absent from origin; HEAD pushed under another name.
_ph_other_branch_env() {
    _ph_unpushed_env "$1"
    _ph_clear_pr
    PH_OTHER="renamed/$1"
    git -C "$RA_WT" push -q origin ":refs/heads/$RA_BRANCH"
    git -C "$RA_WT" push -q origin "HEAD:refs/heads/$PH_OTHER"
}

@test "verify (no pr_url): HEAD live on a differently named origin branch -> pushed_to_other_branch, passes" {
    _ph_other_branch_env "o1"

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    [ "$(_ph_events ph-o1 pushed_to_other_branch)" = "1" ]
}

@test "verify (no pr_url): the other origin branch was deleted (stale remote-tracking ref) -> not success" {
    _ph_other_branch_env "o2"
    git -C "$RA_BARE" update-ref -d "refs/heads/$PH_OTHER"
    # The local tracking ref still says origin/$PH_OTHER contains HEAD.
    git -C "$RA_WT" branch -r --contains HEAD | grep -q "origin/$PH_OTHER"

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    [ "$(jq -r '.state' "$job_file")" = "failed" ]
    [ "$(_ph_events ph-o2 pushed_to_other_branch)" = "0" ]
}

@test "verify (no pr_url): the other origin branch was force-moved off HEAD (stale remote-tracking ref) -> not success" {
    _ph_other_branch_env "o3"
    git -C "$RA_BARE" update-ref "refs/heads/$PH_OTHER" "$(git -C "$RA_BARE" rev-parse refs/heads/main)"

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    [ "$(jq -r '.state' "$job_file")" = "failed" ]
    [ "$(_ph_events ph-o3 pushed_to_other_branch)" = "0" ]
}

# ===========================================================================
# 3. expect_branch_mismatch fix-up jobs adopt a pre-existing PR that holds
#    their own commits, and only that one
# ===========================================================================

@test "finalize: a fix-up job adopts a PRE-EXISTING PR that contains its own commit (pr_opened once, actual_branch recorded)" {
    local repo="$MOTHER_ROOT/ph-repo-f1"
    _ph_make_repo "$repo" "feature/ph-f1"
    _ph_bind "ph-job-f1" "$repo" "feature/ph-f1"
    gh_mock_set_pr "$OTHER_PR" OPEN "existing/pr-branch" "$(git -C "$repo" rev-parse HEAD)"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _finalize_pr_url

    [ "$pr_url" = "$OTHER_PR" ]
    [ "$(jq -r '.pr_url' "$job_file")" = "$OTHER_PR" ]
    [ "$(jq -r '.actual_branch' "$job_file")" = "existing/pr-branch" ]
    [ "$(_ph_events ph-job-f1 pr_opened)" = "1" ]
}

@test "live capture: a fix-up job adopts a PRE-EXISTING PR that contains its own commit (pr_opened once)" {
    local repo="$MOTHER_ROOT/ph-repo-f2"
    _ph_make_repo "$repo" "feature/ph-f2"
    _ph_bind "ph-job-f2" "$repo" "feature/ph-f2"
    gh_mock_set_pr "$OTHER_PR" OPEN "existing/pr-branch" "$(git -C "$repo" rev-parse HEAD)"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _live_capture_pr_url

    [ "$(jq -r '.pr_url' "$job_file")" = "$OTHER_PR" ]
    [ "$(_ph_events ph-job-f2 pr_opened)" = "1" ]
}

@test "finalize + live capture: a pre-existing PR whose commits lack the job's own is rejected as pr_predates_run" {
    local repo="$MOTHER_ROOT/ph-repo-f3"
    _ph_make_repo "$repo" "feature/ph-f3"
    _ph_bind "ph-job-f3" "$repo" "feature/ph-f3"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch" "0123456789abcdef0123456789abcdef01234567"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _finalize_pr_url || true
    _ph_assert_not_adopted ph-job-f3
    [ "$(_ph_rejections ph-job-f3)" = "pr_predates_run:false" ]

    _pr_rejected_urls=""
    _live_capture_pr_url
    _ph_assert_not_adopted ph-job-f3
}

@test "finalize: a pre-existing PR listing the base commit is not adopted by a job with no commits of its own" {
    local repo="$MOTHER_ROOT/ph-repo-f4"
    _ph_make_repo "$repo" "feature/ph-f4" nocommits
    _ph_bind "ph-job-f4" "$repo" "feature/ph-f4"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch" "$(git -C "$repo" rev-parse HEAD)"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _finalize_pr_url || true
    _ph_assert_not_adopted ph-job-f4

    _pr_rejected_urls=""
    _live_capture_pr_url
    _ph_assert_not_adopted ph-job-f4
}

# ===========================================================================
# 5. Fork PRs are never the job's PR
# ===========================================================================

@test "finalize: a fork PR carrying the job's branch name is rejected (cross_repository) and nothing is pushed on its behalf" {
    _ph_unpushed_env "k1"
    _ph_clear_pr
    git -C "$RA_WT" push -q origin ":refs/heads/$RA_BRANCH"     # the real branch never reached origin
    _ph_log_and_reject_pushes
    log_path="$MOTHER_ROOT/ph-k1.log"
    echo "opened $PH_PR" > "$log_path"
    log_offset_at_spawn=0; _pr_rejected_urls=""; _pr_transient_failures=""
    gh_mock_set_pr "$PH_PR" OPEN "$RA_BRANCH"
    gh_mock_set_pr_cross "$PH_PR" true

    _finalize_pr_url

    [ -z "$pr_url" ]
    [ "$(jq -r '.pr_url // "null"' "$job_file")" = "null" ]
    [ "$(_ph_events ph-k1 pr_opened)" = "0" ]
    [ "$(_ph_rejections ph-k1)" = "cross_repository:false" ]

    # With no PR of its own the job is not shipped, and no push was tried for the fork's PR.
    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]
    [ "$(jq -r '.state' "$job_file")" = "failed" ]
    [ "$(_ph_failed_reason ph-k1)" = "no_pr_no_push" ]
    [ ! -s "$PH_PUSH_LOG" ]
}

@test "finalize: a stored fork PR is dropped, not kept" {
    _ph_unpushed_env "k2"
    gh_mock_set_pr_cross "$PH_PR" true

    _finalize_pr_url

    [ -z "$pr_url" ]
    [ "$(jq -r '.pr_url // "null"' "$job_file")" = "null" ]
    [ "$(_ph_rejections ph-k2)" = "cross_repository:false" ]
}

@test "live capture: a fork PR carrying the job's branch name is rejected (cross_repository), no pr_url, no pr_opened" {
    local repo="$MOTHER_ROOT/ph-repo-k3"
    _ph_make_repo "$repo" "feature/ph-k3"
    _ph_bind_plain "ph-job-k3" "$repo" "feature/ph-k3"
    gh_mock_set_pr "$OTHER_PR" OPEN "feature/ph-k3"
    gh_mock_set_pr_cross "$OTHER_PR" true

    _live_capture_pr_url

    _ph_assert_not_adopted ph-job-k3
    [ "$(_ph_rejections ph-job-k3)" = "cross_repository:false" ]
}

@test "live capture control: the same PR as a same-repo PR IS adopted" {
    local repo="$MOTHER_ROOT/ph-repo-k4"
    _ph_make_repo "$repo" "feature/ph-k4"
    _ph_bind_plain "ph-job-k4" "$repo" "feature/ph-k4"
    gh_mock_set_pr "$OTHER_PR" OPEN "feature/ph-k4"
    gh_mock_set_pr_cross "$OTHER_PR" false

    _live_capture_pr_url

    [ "$(jq -r '.pr_url' "$job_file")" = "$OTHER_PR" ]
    [ "$(_ph_events ph-job-k4 pr_opened)" = "1" ]
}

@test "reconcile: a fork PR with the job's branch name is not adopted (--pr-url, --auto, and auto-detect)" {
    local repo="$MOTHER_ROOT/ph-repo-k5"
    _ph_make_repo "$repo" "feature/ph-k5"
    make_job "ph-k5" "failed" \
        ".branch = \"feature/ph-k5\" | .base_ref = \"main\" | .isolation = \"worktree\" | .work_dir = \"$repo\" | .repo_path = \"$repo\" | .failure_reason = \"no_pr_no_push\""
    gh_mock_set_pr "$OTHER_PR" OPEN "feature/ph-k5"
    gh_mock_set_pr_cross "$OTHER_PR" true
    gh_mock_set_branch_pr "feature/ph-k5" "$OTHER_PR"

    run mother reconcile ph-k5 --pr-url "$OTHER_PR"
    [ "$status" -eq 1 ]
    run mother reconcile ph-k5 --pr-url "$OTHER_PR" --auto
    [ "$status" -eq 3 ]
    run mother reconcile ph-k5 --auto
    [ "$status" -eq 3 ]
    [ "$(jq -r '.state' "$JOBS_DIR/ph-k5.json")" = "failed" ]
    [ "$(jq -r '.pr_url // "null"' "$JOBS_DIR/ph-k5.json")" = "null" ]

    # Control: the same PR from the same repo reconciles.
    gh_mock_set_pr_cross "$OTHER_PR" false
    run mother reconcile ph-k5 --pr-url "$OTHER_PR"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.pr_url' "$JOBS_DIR/ph-k5.json")" = "$OTHER_PR" ]
}

# ===========================================================================
# 6. The right clock: this attempt's first spawn, not the latest spawn
# ===========================================================================

@test "finalize: a mismatched PR created after the attempt started but before the latest respawn is adopted (attempt_run clock)" {
    local repo="$MOTHER_ROOT/ph-repo-c1"
    _ph_make_repo "$repo" "feature/ph-c1"
    _ph_bind "ph-job-c1" "$repo" "feature/ph-c1"
    _ph_set_clock "$SPAWN_AT" "$AFTER_SPAWN_AT"
    gh_mock_set_pr "$OTHER_PR" OPEN "landed/here"
    gh_mock_set_pr_created "$OTHER_PR" "$AFTER_AT"

    _finalize_pr_url

    [ "$(jq -r '.pr_url' "$job_file")" = "$OTHER_PR" ]
    [ "$(_ph_events ph-job-c1 pr_opened)" = "1" ]
}

@test "live capture: a mismatched PR created after the attempt started but before the latest respawn is adopted" {
    local repo="$MOTHER_ROOT/ph-repo-c2"
    _ph_make_repo "$repo" "feature/ph-c2"
    _ph_bind "ph-job-c2" "$repo" "feature/ph-c2"
    _ph_set_clock "$SPAWN_AT" "$AFTER_SPAWN_AT"
    gh_mock_set_pr "$OTHER_PR" OPEN "landed/here"
    gh_mock_set_pr_created "$OTHER_PR" "$AFTER_AT"

    _live_capture_pr_url

    [ "$(jq -r '.pr_url' "$job_file")" = "$OTHER_PR" ]
    [ "$(_ph_events ph-job-c2 pr_opened)" = "1" ]
}

@test "finalize + live: without attempt_run the latest spawn is the clock (a PR older than it is not adopted); a PR older than the attempt is not adopted either" {
    local repo="$MOTHER_ROOT/ph-repo-c3"
    _ph_make_repo "$repo" "feature/ph-c3"
    _ph_bind "ph-job-c3" "$repo" "feature/ph-c3"
    _ph_set_clock "-" "$AFTER_SPAWN_AT"
    [ "$(jq -r '.attempt_run // "none"' "$job_file")" = "none" ]
    gh_mock_set_pr "$OTHER_PR" OPEN "landed/here"
    gh_mock_set_pr_created "$OTHER_PR" "$AFTER_AT"        # after SPAWN_AT, before the latest spawn

    _finalize_pr_url || true
    _ph_assert_not_adopted ph-job-c3
    [ "$(_ph_rejections ph-job-c3)" = "pr_predates_run:false" ]

    # And with the attempt clock present, a PR from before the attempt is still refused.
    _ph_set_clock "$SPAWN_AT" "$AFTER_SPAWN_AT"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"
    _pr_rejected_urls=""
    _live_capture_pr_url
    _ph_assert_not_adopted ph-job-c3
}

# ===========================================================================
# 7. Rejection reasons say what actually happened
# ===========================================================================

@test "finalize + live: gh failing for a mismatch job is a transient pr_unresolved, never pr_predates_run" {
    local repo="$MOTHER_ROOT/ph-repo-r1"
    _ph_make_repo "$repo" "feature/ph-r1"
    _ph_bind "ph-job-r1" "$repo" "feature/ph-r1"
    gh_mock_set_pr "$OTHER_PR" OPEN "landed/here"
    gh_mock_set_pr_created "$OTHER_PR" "$AFTER_AT"
    export GH_MOCK_FAIL_VIEW=1

    _finalize_pr_url || true
    _ph_assert_not_adopted ph-job-r1
    [ "$(_ph_rejections ph-job-r1)" = "pr_unresolved:true" ]

    _pr_transient_failures=""
    _live_capture_pr_url
    _ph_assert_not_adopted ph-job-r1
    ! _ph_rejections ph-job-r1 | grep -q pr_predates_run
}

@test "finalize: a mismatch job's PR with no createdAt is a transient pr_unresolved, never pr_predates_run" {
    local repo="$MOTHER_ROOT/ph-repo-r2"
    _ph_make_repo "$repo" "feature/ph-r2"
    _ph_bind "ph-job-r2" "$repo" "feature/ph-r2"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch"     # no createdAt

    _finalize_pr_url || true

    _ph_assert_not_adopted ph-job-r2
    [ "$(_ph_rejections ph-job-r2)" = "pr_unresolved:true" ]
}

@test "live capture: a mismatch job's PR with no createdAt is a transient pr_unresolved, never pr_predates_run" {
    local repo="$MOTHER_ROOT/ph-repo-r3"
    _ph_make_repo "$repo" "feature/ph-r3"
    _ph_bind "ph-job-r3" "$repo" "feature/ph-r3"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch"     # no createdAt

    _live_capture_pr_url

    _ph_assert_not_adopted ph-job-r3
    [ "$(_ph_rejections ph-job-r3)" = "pr_unresolved:true" ]
}

@test "live capture: a PR created before the attempt with none of the job's commits is a definitive pr_predates_run" {
    local repo="$MOTHER_ROOT/ph-repo-r4"
    _ph_make_repo "$repo" "feature/ph-r4"
    _ph_bind "ph-job-r4" "$repo" "feature/ph-r4"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _live_capture_pr_url

    _ph_assert_not_adopted ph-job-r4
    [ "$(_ph_rejections ph-job-r4)" = "pr_predates_run:false" ]
}

# ===========================================================================
# 10. pr_url_rejected is logged once per (url, reason), however often the gate runs
# ===========================================================================

@test "finalize twice (a later spawn forgets its in-memory memo): exactly one pr_url_rejected for the same (url, reason)" {
    local repo="$MOTHER_ROOT/ph-repo-d1"
    _ph_make_repo "$repo" "feature/ph-d1"
    _ph_bind "ph-job-d1" "$repo" "feature/ph-d1"
    gh_mock_set_pr "$OTHER_PR" OPEN "someone/elses-branch"
    gh_mock_set_pr_created "$OTHER_PR" "$BEFORE_AT"

    _finalize_pr_url || true
    _pr_rejected_urls=""; _pr_transient_failures=""
    _finalize_pr_url || true
    _pr_rejected_urls=""; _pr_transient_failures=""
    _live_capture_pr_url

    [ "$(_ph_rejection_count ph-job-d1)" = "1" ]
}

@test "finalize twice: a transient rejection (pr_unresolved) is also logged once per url" {
    local repo="$MOTHER_ROOT/ph-repo-d2"
    _ph_make_repo "$repo" "feature/ph-d2"
    _ph_bind "ph-job-d2" "$repo" "feature/ph-d2"      # no fixture: gh pr view fails

    _finalize_pr_url || true
    _pr_rejected_urls=""; _pr_transient_failures=""
    _finalize_pr_url || true

    [ "$(_ph_rejection_count ph-job-d2)" = "1" ]
}

@test "finalize twice: a cross_repository rejection of a detected PR is logged once" {
    local repo="$MOTHER_ROOT/ph-repo-d3"
    _ph_make_repo "$repo" "feature/ph-d3"
    _ph_bind_plain "ph-job-d3" "$repo" "feature/ph-d3"
    gh_mock_set_branch_pr "feature/ph-d3" "$OTHER_PR"       # detected by branch, not scraped
    gh_mock_set_pr "$OTHER_PR" OPEN "feature/ph-d3"
    gh_mock_set_pr_cross "$OTHER_PR" true

    _finalize_pr_url || true
    _finalize_pr_url || true

    [ "$(_ph_rejections ph-job-d3)" = "cross_repository:false" ]
}

# ===========================================================================
# 4. unpushed_commit holds clean up after themselves, and are honest
# ===========================================================================

@test "retry clears the unpushed_commit flag, and the attention list stops showing it" {
    make_job "ph-ret" "failed"
    _ph_hold_job "ph-ret" failed
    [ "$(_ph_flagged_count ph-ret)" = "1" ]

    run mother retry ph-ret --yes
    [ "$status" -eq 0 ]

    [ "$(jq -r '.needs_attention // "null"' "$JOBS_DIR/ph-ret.json")" = "null" ]
    [ "$(_ph_flagged_count ph-ret)" = "0" ]
}

@test "retry of a held (operator_hold) unpushed_commit job clears the flag" {
    make_job "ph-ret2" "awaiting"
    _ph_hold_job "ph-ret2" awaiting

    run mother retry ph-ret2 --yes
    [ "$status" -eq 0 ]

    [ "$(jq -r '.needs_attention // "null"' "$JOBS_DIR/ph-ret2.json")" = "null" ]
    [ "$(_ph_flagged_count ph-ret2)" = "0" ]
}

@test "retry leaves an unrelated needs_attention flag alone" {
    make_job "ph-ret3" "failed" '.needs_attention = {reason: "something_else", note: "n", since: "2026-11-08T12:00:00Z"}'

    run mother retry ph-ret3 --yes
    [ "$status" -eq 0 ]

    [ "$(jq -r '.needs_attention.reason' "$JOBS_DIR/ph-ret3.json")" = "something_else" ]
}

@test "escalate clears the unpushed_commit flag" {
    make_job "ph-esc" "failed"
    _ph_hold_job "ph-esc" failed

    run mother escalate ph-esc --yes
    [ "$status" -eq 0 ]

    [ "$(jq -r '.needs_attention // "null"' "$JOBS_DIR/ph-esc.json")" = "null" ]
    [ "$(_ph_flagged_count ph-esc)" = "0" ]
}

@test "resume of a held unpushed_commit job clears the flag (the held job is back in play)" {
    make_job "ph-res" "awaiting"
    _ph_hold_job "ph-res" awaiting
    [ "$(_ph_flagged_count ph-res)" = "1" ]

    run mother resume ph-res "push the commit from the worktree"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.state' "$JOBS_DIR/ph-res.json")" = "ready" ]

    [ "$(jq -r '.needs_attention // "null"' "$JOBS_DIR/ph-res.json")" = "null" ]
    [ "$(_ph_flagged_count ph-res)" = "0" ]
}

@test "a job that later succeeds no longer carries the unpushed_commit flag; other flags survive" {
    make_job "ph-ok" "running"
    _ph_hold_job "ph-ok" failed
    jq '.state = "running"' "$JOBS_DIR/ph-ok.json" > "$JOBS_DIR/ph-ok.json.tmp" && mv "$JOBS_DIR/ph-ok.json.tmp" "$JOBS_DIR/ph-ok.json"
    id="ph-ok"; job_file="$JOBS_DIR/ph-ok.json"

    _transition succeeded '{}'

    [ "$(jq -r '.state' "$job_file")" = "succeeded" ]
    [ "$(jq -r '.needs_attention // "null"' "$job_file")" = "null" ]
    [ "$(jq -r '.failure_reason // "null"' "$job_file")" = "null" ]

    make_job "ph-ok2" "running" '.needs_attention = {reason: "something_else", note: "n", since: "2026-11-08T12:00:00Z"}'
    id="ph-ok2"; job_file="$JOBS_DIR/ph-ok2.json"
    _transition succeeded '{}'
    [ "$(jq -r '.needs_attention.reason' "$job_file")" = "something_else" ]
}

@test "reconcile refuses an unpushed_commit hold whose final commit is not on origin (exit 1; exit 3 with --auto), nothing mutated" {
    _ph_unpushed_env "rc1"
    _ph_hold_job "ph-rc1" failed
    local before; before=$(cksum < "$JOBS_DIR/ph-rc1.json")

    run mother reconcile ph-rc1 --pr-url "$PH_PR"
    [ "$status" -eq 1 ]
    [[ "$output" == *unpushed_commit* ]]

    run mother reconcile ph-rc1 --pr-url "$PH_PR" --yes
    [ "$status" -eq 1 ]
    [[ "$output" == *unpushed_commit* ]]

    run mother reconcile ph-rc1 --pr-url "$PH_PR" --auto
    [ "$status" -eq 3 ]

    [ "$(cksum < "$JOBS_DIR/ph-rc1.json")" = "$before" ]
    [ "$(_ph_flagged_count ph-rc1)" = "1" ]
}

@test "reconcile of a held unpushed_commit job succeeds once the final commit is on origin, and the flag is gone" {
    _ph_unpushed_env "rc2"
    _ph_hold_job "ph-rc2" awaiting
    run mother reconcile ph-rc2 --pr-url "$PH_PR"
    [ "$status" -eq 1 ]

    git -C "$RA_WT" push -q origin "$RA_BRANCH"       # the operator pushes it

    run mother reconcile ph-rc2 --pr-url "$PH_PR" --yes
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$JOBS_DIR/ph-rc2.json")" = "succeeded" ]
    [ "$(jq -r '.needs_attention // "null"' "$JOBS_DIR/ph-rc2.json")" = "null" ]
    [ "$(_ph_flagged_count ph-rc2)" = "0" ]
}

@test "reconcile of an unpushed_commit hold accepts a final commit that origin already has plus more on top" {
    _ph_unpushed_env "rc3"
    _ph_hold_job "ph-rc3" failed
    git -C "$RA_WT" push -q origin "$RA_BRANCH"
    local other="$MOTHER_ROOT/ph-rc3-other"
    git clone -q "$RA_BARE" "$other"
    git -C "$other" config user.email t@t.com; git -C "$other" config user.name T
    git -C "$other" checkout -q "$RA_BRANCH"
    git -C "$other" commit -q --allow-empty -m "someone else's follow-up"
    git -C "$other" push -q origin "$RA_BRANCH"

    run mother reconcile ph-rc3 --pr-url "$PH_PR"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.state' "$JOBS_DIR/ph-rc3.json")" = "succeeded" ]
}

@test "reconcile and retry are still refused for an adherence-blocked awaiting job; its flag and state are untouched" {
    make_job "ph-ab" "awaiting" \
        '.activity = "adherence_blocked" | .paused_reason = "adherence_blocked" | .needs_attention = {reason: "adherence_loop_capped", note: "n", since: "2026-11-08T12:00:00Z"}'
    local before; before=$(cksum < "$JOBS_DIR/ph-ab.json")

    run mother retry ph-ab --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *"can only retry failed/cancelled jobs"* ]]

    run mother reconcile ph-ab --pr-url "$OTHER_PR" --yes
    [ "$status" -eq 1 ]

    [ "$(cksum < "$JOBS_DIR/ph-ab.json")" = "$before" ]
}

# ===========================================================================
# 9. Edge cases around "is the final commit on the remote branch"
# ===========================================================================

@test "verify: a remote branch that is AHEAD of the job's final commit passes untouched (no push needed)" {
    _ph_unpushed_env "e1"
    git -C "$RA_WT" push -q origin "$RA_BRANCH"
    local other="$MOTHER_ROOT/ph-e1-other"
    git clone -q "$RA_BARE" "$other"
    git -C "$other" config user.email t@t.com; git -C "$other" config user.name T
    git -C "$other" checkout -q "$RA_BRANCH"
    git -C "$other" commit -q --allow-empty -m "reviewer's fixup"
    git -C "$other" push -q origin "$RA_BRANCH"
    local remote_tip; remote_tip=$(git -C "$RA_BARE" rev-parse "refs/heads/$RA_BRANCH")
    _ph_log_and_reject_pushes

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    [ ! -s "$PH_PUSH_LOG" ]
    [ "$(git -C "$RA_BARE" rev-parse "refs/heads/$RA_BRANCH")" = "$remote_tip" ]
}

@test "verify: a worker that rebased/amended without force-pushing holds as unpushed_commit; origin keeps the old tip" {
    _ph_unpushed_env "e2"
    git -C "$RA_WT" push -q origin "$RA_BRANCH"
    local old_tip; old_tip=$(git -C "$RA_BARE" rev-parse "refs/heads/$RA_BRANCH")
    git -C "$RA_WT" commit -q --amend --allow-empty -m "rewritten final commit"

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    [ "$(jq -r '.state' "$job_file")" = "failed" ]
    [ "$(_ph_failed_reason ph-e2)" = "unpushed_commit" ]
    [ "$(git -C "$RA_BARE" rev-parse "refs/heads/$RA_BRANCH")" = "$old_tip" ]
}

@test "verify: a merge of main into the branch (origin has the branch tip) passes once the merge commit is pushed" {
    _ph_unpushed_env "e3"
    git -C "$RA_WT" push -q origin "$RA_BRANCH"
    git -C "$RA_REPO" commit -q --allow-empty -m "main moved on"
    git -C "$RA_REPO" push -q origin main
    git -C "$RA_WT" commit -q --allow-empty -m "branch work after the push"
    git -C "$RA_WT" merge -q --no-ff -m "merge main" main
    local merge_sha; merge_sha=$(git -C "$RA_WT" rev-parse HEAD)
    [ "$(git -C "$RA_WT" rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" = "3" ]

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    [ "$(git -C "$RA_BARE" rev-parse "refs/heads/$RA_BRANCH")" = "$merge_sha" ]
}

@test "verify: a merge commit that cannot be pushed holds as unpushed_commit" {
    _ph_unpushed_env "e4"
    git -C "$RA_WT" push -q origin "$RA_BRANCH"
    git -C "$RA_REPO" commit -q --allow-empty -m "main moved on"
    git -C "$RA_REPO" push -q origin main
    git -C "$RA_WT" merge -q --no-ff -m "merge main" main
    _ph_reject_pushes

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    [ "$(_ph_failed_reason ph-e4)" = "unpushed_commit" ]
}

@test "verify (main-dir): the job's branch ref is checked, not the restored HEAD; unpushable -> unpushed_commit" {
    _ph_unpushed_env "e5"
    jq '.isolation = "main-dir" | .work_dir = $wd' --arg wd "$RA_REPO" "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    isolation="main-dir"; work_dir="$RA_REPO"
    # The main checkout is back on main (pushed); the branch's unpushed commit lives only in refs/heads/<branch>.
    [ "$(git -C "$RA_REPO" rev-parse --abbrev-ref HEAD)" = "main" ]
    local branch_tip; branch_tip=$(git -C "$RA_REPO" rev-parse "refs/heads/$RA_BRANCH")
    _ph_reject_pushes

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    [ "$(_ph_failed_reason ph-e5)" = "unpushed_commit" ]
    [ "$(jq -r 'select(.kind=="failed") | .detail.final_commit' "$EVENTS_DIR/ph-e5.jsonl" | tail -1)" = "$branch_tip" ]
}

@test "verify (main-dir): the branch's final commit is pushed to origin and the job passes" {
    _ph_unpushed_env "e6"
    jq '.isolation = "main-dir" | .work_dir = $wd' --arg wd "$RA_REPO" "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    isolation="main-dir"; work_dir="$RA_REPO"
    local branch_tip; branch_tip=$(git -C "$RA_REPO" rev-parse "refs/heads/$RA_BRANCH")

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(git -C "$RA_BARE" rev-parse "refs/heads/$RA_BRANCH")" = "$branch_tip" ]
}

@test "verify (no_pr): a no_pr job is judged on commits ahead of base alone; no gh, no ls-remote/push/fetch" {
    _ph_unpushed_env "e7"
    jq '.no_pr = true | .pr_url = null' "$job_file" > "$job_file.tmp" && mv "$job_file.tmp" "$job_file"
    pr_url=""
    _ph_reject_pushes
    _ph_install_git_shim
    : > "$MOTHER_ROOT/mock-gh-calls"

    run _verify_artifact_or_fail
    [ "$status" -eq 0 ]

    [ "$(jq -r '.state' "$job_file")" != "failed" ]
    [ "$(_ph_events ph-e7 no_pr_commits_verified)" = "1" ]
    [ ! -s "$MOTHER_ROOT/mock-gh-calls" ]
    ! grep -Eq '^(ls-remote|push|fetch)' "$MOTHER_ROOT/git-calls"
}

# ===========================================================================
# 11. A hung remote is a hold, never a success, and never a hang
# ===========================================================================

@test "verify: with the remote hanging, a PR job holds as unpushed_commit within seconds (MOTHER_GIT_REMOTE_TIMEOUT)" {
    _ph_unpushed_env "t1"
    _ph_install_git_shim
    export MOTHER_GIT_REMOTE_TIMEOUT=1
    export PH_GIT_SLOW=1
    local t0=$SECONDS

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    [ $((SECONDS - t0)) -lt 15 ]
    [ "$(jq -r '.state' "$job_file")" = "failed" ]
    [ "$(_ph_failed_reason ph-t1)" = "unpushed_commit" ]
    [ "$(jq -r '.needs_attention.reason' "$job_file")" = "unpushed_commit" ]
}

@test "verify: with the remote hanging, a job with no PR is not called succeeded either" {
    _ph_unpushed_env "t2"
    _ph_clear_pr
    _ph_install_git_shim
    export MOTHER_GIT_REMOTE_TIMEOUT=1
    export PH_GIT_SLOW=1
    local t0=$SECONDS

    run _verify_artifact_or_fail
    [ "$status" -eq 1 ]

    [ $((SECONDS - t0)) -lt 15 ]
    [ "$(jq -r '.state' "$job_file")" = "failed" ]
    [ "$(jq -r '.state' "$job_file")" != "succeeded" ]
}

# ===========================================================================
# 8. adherence-review cannot overwrite a job that moved on while it ran
# ===========================================================================

# Run `mother adherence-review` for a succeeded job whose "reviewer" flips the
# job to <newstate> mid-review and then reports a first FAIL.
_ph_adherence_race() {
    local newstate="$1"
    make_job "ph-race" "succeeded" \
        '.pr_url = "https://github.com/Carefeed/test/pull/42" | .adherence_attempts = 0 | .adherence_status = null | .adherence_pending = null | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"t"},"redd":{"model":"sonnet","effort":"medium","rationale":"t"},"marty":{"model":"sonnet","effort":"medium","rationale":"t"},"perri":{"model":"sonnet","effort":"medium","rationale":"t"}}'
    local plan="$EVENTS_DIR/ph-race-plan.md"
    printf '# Plan\n\n## Acceptance criteria\n- It works.\n' > "$plan"
    jq --arg p "$plan" '.plan_path = $p' "$JOBS_DIR/ph-race.json" > "$JOBS_DIR/ph-race.json.tmp" \
        && mv "$JOBS_DIR/ph-race.json.tmp" "$JOBS_DIR/ph-race.json"
    cat > "$_MOCK_BIN/claude" <<CLAUDE_EOF
#!/usr/bin/env bash
f="$JOBS_DIR/ph-race.json"
jq '.state = "$newstate"' "\$f" > "\$f.race" && mv "\$f.race" "\$f"
printf 'ADHERENCE: fail\nNOTES:\nSkipped the README criterion.\n'
CLAUDE_EOF
    chmod +x "$_MOCK_BIN/claude"
    run mother adherence-review "ph-race"
}

@test "adherence-review: a job cancelled while the review ran stays cancelled (no cody_rework, nonzero exit)" {
    _ph_adherence_race cancelled

    [ "$status" -ne 0 ]
    [ "$(jq -r '.state' "$JOBS_DIR/ph-race.json")" = "cancelled" ]
    [ "$(jq -r '.activity // "null"' "$JOBS_DIR/ph-race.json")" != "cody_rework" ]
    [ "$(jq -r '.pending_answer // "null"' "$JOBS_DIR/ph-race.json")" = "null" ]
    [ "$(jq -r '.adherence_status // "null"' "$JOBS_DIR/ph-race.json")" != "failed_first" ]
}

@test "adherence-review: a job reset by retry (ready) while the review ran is not rewritten into cody_rework" {
    _ph_adherence_race ready

    [ "$status" -ne 0 ]
    [ "$(jq -r '.state' "$JOBS_DIR/ph-race.json")" = "ready" ]
    [ "$(jq -r '.activity // "null"' "$JOBS_DIR/ph-race.json")" = "null" ]
    [ "$(jq -r '.pending_answer // "null"' "$JOBS_DIR/ph-race.json")" = "null" ]
}
