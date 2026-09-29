#!/usr/bin/env bats
# failure_route.bats — failed jobs are routed by WHY they failed, not blindly
# escalated up the model-tier ladder.
#
# Escalating to a bigger model is the right answer to "the worker tried and
# couldn't". It is the wrong answer to a PR that already exists (job
# 20260910T130607Z-773bf2c4), a dependency whose PR isn't merged yet (job
# 20260902T183748Z-4779f4b6), a rework that never pushed, or an infra hiccup —
# each of those burned model tiers (and money) for nothing.
#
# Contract:
#   lib/failure-route.sh   mother_failure_class <reason>  (pure, prints the class)
#   mother route-failure <id>   (internal CLI, called by mother-runner for each
#                                failed job; exits 0 in every handled case;
#                                requires state == failed)
#
# A "hold" is an operator handoff, not a failure: state=awaiting,
# activity=operator_hold, paused_reason=operator_hold, with a concrete
# question — so teardown never reaps the worktree that holds the work.
#
# gh is mocked via tests/gh_mock.bash. Everything here is expected to FAIL
# until the feature exists.

load 'test_helper'
load 'gh_mock'

setup() {
    setup_mother_env
    export MOTHER_ESCALATION_ENABLED=1
    unset MOTHER_RECONCILE_ENABLED
    export MOTHER_POSTURE_ENABLED=0
    gh_mock_install
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Fixtures & helpers
# ---------------------------------------------------------------------------

# A failed job with a recorded failure_reason and nothing adoptable on GitHub
# (work_dir doesn't exist, so PR detection finds nothing).
# Usage: _fr_make_job <id> <failure_reason> [extra-jq-filter]
_fr_make_job() {
    local id="$1" reason="$2" extra="${3:-.}"
    make_job "$id" "failed" '
        .failure_reason = "'"$reason"'"
        | .branch = "feature/'"$id"'"
        | .base_ref = "main"
        | .repo_path = "/nonexistent/fr-'"$id"'"
        | .work_dir = "/nonexistent/fr-'"$id"'"
        | .finished_at = "2026-09-01T00:00:00Z"
        | ('"$extra"')'
}

# Append an event line to a job's log, in order.
# Usage: _fr_add_event <id> <kind> [detail-json]
_fr_add_event() {
    local id="$1" kind="$2" detail="${3:-\{\}}"
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg k "$kind" --argjson d "$detail" \
        '{ts: $ts, kind: $k, detail: $d}' >> "$EVENTS_DIR/$id.jsonl"
}

# Most recent event of <kind>'s detail as compact JSON ('' if none).
_fr_ev() {
    [ -f "$EVENTS_DIR/$1.jsonl" ] || { echo ""; return 0; }
    jq -c --arg k "$2" 'select(.kind==$k) | .detail' "$EVENTS_DIR/$1.jsonl" | tail -1
}

_fr_ev_count() {
    local n
    n=$(grep -c "\"kind\":\"$2\"" "$EVENTS_DIR/$1.jsonl" 2>/dev/null || true)
    echo "${n:-0}"
}

_fr_line_of() {
    grep -n "\"kind\":\"$2\"" "$EVENTS_DIR/$1.jsonl" | head -1 | cut -d: -f1
}

# A repo + failed job shaped like 20260910T130607Z-773bf2c4: the worker built
# on top of an existing PR's branch (base_ref == that PR's head branch) and
# pushed HEAD there; GitHub says that open PR contains HEAD.
# Usage: _fr_make_adoptable_job <id> <failure_reason> [extra-jq-filter]
# Sets FR_PR_URL.
_fr_make_adoptable_job() {
    local id="$1" reason="$2" extra="${3:-.}"
    local repo="$MOTHER_ROOT/fr-repo-$id"
    FR_PR_URL="https://github.com/thehammer/mother/pull/7$(printf '%02d' $((RANDOM % 100)))"
    git init -q "$repo"
    git -C "$repo" config user.email "test@test.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" commit -q --allow-empty -m init
    git -C "$repo" branch -M main
    git -C "$repo" remote add origin "https://github.com/thehammer/mother.git"
    git -C "$repo" branch pr-head
    git -C "$repo" checkout -q -b "feature/$id" pr-head
    git -C "$repo" commit -q --allow-empty -m "worker commit on top of the PR branch"
    local head; head=$(git -C "$repo" rev-parse HEAD)
    gh_mock_set_commit_pulls "$head" "$FR_PR_URL" open
    gh_mock_set_pr "$FR_PR_URL" OPEN "pr-head" "$head"
    _fr_make_job "$id" "$reason" \
        '.work_dir = "'"$repo"'" | .repo_path = "'"$repo"'" | .base_ref = "pr-head" | ('"$extra"')'
}

# Assert a job is held for the operator with the given reasons.
# Usage: _fr_assert_held <id> <failure_reason> <sub_reason>
_fr_assert_held() {
    local id="$1" reason="$2" sub="$3"
    assert_job_field "$id" '.state' "awaiting"
    assert_job_field "$id" '.activity' "operator_hold"
    assert_job_field "$id" '.paused_reason' "operator_hold"
    assert_job_field_truthy "$id" '.paused_at'
    assert_job_field "$id" '.operator_hold.failure_reason' "$reason"
    assert_job_field "$id" '.operator_hold.sub_reason' "$sub"
    assert_job_field_truthy "$id" '.operator_hold.held_at'
    jq -e '.operator_hold.detail | type == "object"' "$JOBS_DIR/$id.json" >/dev/null

    # The question is actionable: it names the job and offers concrete commands.
    local q; q=$(jq -r '.question // ""' "$JOBS_DIR/$id.json")
    [[ "$q" == *"$id"* ]]
    [[ "$q" =~ mother\ (resume|reconcile|retry|cancel) ]]

    local h; h=$(_fr_ev "$id" held_for_operator)
    [ "$(printf '%s' "$h" | jq -r '.failure_reason')" = "$reason" ]
    [ "$(printf '%s' "$h" | jq -r '.sub_reason')" = "$sub" ]
    printf '%s' "$h" | jq -e 'has("detail")' >/dev/null

    local a; a=$(_fr_ev "$id" awaiting_input)
    [ "$(printf '%s' "$a" | jq -r '.paused_reason')" = "operator_hold" ]
    [ "$(printf '%s' "$a" | jq -r '.question')" = "$q" ]

    local r; r=$(_fr_ev "$id" failure_routed)
    [ "$(printf '%s' "$r" | jq -r '.action')" = "held" ]
    [ "$(printf '%s' "$r" | jq -r '.sub_reason')" = "$sub" ]

    # A hold is never an escalation.
    [ "$(_fr_ev_count "$id" escalated)" = "0" ]
}

# ===========================================================================
# mother_failure_class — the reason -> class table
# ===========================================================================

_fr_class() {
    bash -uc 'source "$1" && mother_failure_class "$2"' _ "$_LIB_DIR/failure-route.sh" "$1" 2>/dev/null
}

@test "mother_failure_class: no_pr_no_push -> reconcile_then_hold" {
    run _fr_class no_pr_no_push
    [ "$output" = "reconcile_then_hold" ]
}

@test "mother_failure_class: rework_no_new_commit, branch_create_failed, checkout_failed -> hold" {
    local r
    for r in rework_no_new_commit branch_create_failed checkout_failed; do
        run _fr_class "$r"
        if [ "$output" != "hold" ]; then echo "$r -> '$output'" >&2; return 1; fi
    done
}

@test "mother_failure_class: worktree_create_failed, runner_died_early, unspecified and empty -> retry_once" {
    local r
    for r in worktree_create_failed runner_died_early unspecified ""; do
        run _fr_class "$r"
        if [ "$output" != "retry_once" ]; then echo "'$r' -> '$output'" >&2; return 1; fi
    done
}

@test "mother_failure_class: any other reason (max_turns, api_error, unknown...) -> escalate" {
    local r
    for r in max_turns api_error execution_error runner_died idle_timeout claude_exit_nonzero some_reason_nobody_has_heard_of; do
        run _fr_class "$r"
        if [ "$output" != "escalate" ]; then echo "$r -> '$output'" >&2; return 1; fi
    done
}

# ===========================================================================
# reconcile_then_hold  (no_pr_no_push)
# ===========================================================================

@test "regression 773bf2c4: no_pr_no_push whose work sits on an existing PR is reconciled — succeeded, never escalated" {
    _fr_make_adoptable_job "fr-773" "no_pr_no_push" '.current_tier = "tier_1" | .escalation_count = 1'

    run mother route-failure "fr-773"
    [ "$status" -eq 0 ]

    assert_job_field "fr-773" '.state' "succeeded"
    assert_job_field "fr-773" '.pr_url' "$FR_PR_URL"
    assert_job_field "fr-773" '.current_tier' "tier_1"
    assert_job_field "fr-773" '.escalation_count' "1"

    [ "$(_fr_ev_count fr-773 escalated)" = "0" ]
    assert_event_kind "fr-773" "reconciled"
    assert_event_kind "fr-773" "failure_routed"
    [ "$(_fr_ev fr-773 failure_routed | jq -r '.action')" = "reconciled" ]
    [ "$(_fr_line_of fr-773 reconciled)" -lt "$(_fr_line_of fr-773 failure_routed)" ]
}

@test "regression 4779f4b6: no_pr_no_push with nothing to reconcile and an UNMERGED dependency is held, not escalated" {
    make_job "fr-4779-dep" "succeeded" '.pr_url = "https://github.com/thehammer/mother/pull/810"'
    gh_mock_set_pr "https://github.com/thehammer/mother/pull/810" OPEN "feature/fr-4779-dep"
    _fr_make_job "fr-4779" "no_pr_no_push" '.depends_on = ["fr-4779-dep"]'

    run mother route-failure "fr-4779"
    [ "$status" -eq 0 ]

    _fr_assert_held "fr-4779" "no_pr_no_push" "unmerged_dependency"
    assert_job_field "fr-4779" '.operator_hold.detail.dependencies[0].job_id' "fr-4779-dep"
    assert_job_field "fr-4779" '.operator_hold.detail.dependencies[0].pr_url' "https://github.com/thehammer/mother/pull/810"
    assert_job_field "fr-4779" '.operator_hold.detail.dependencies[0].pr_state' "OPEN"
    assert_job_field "fr-4779" '.escalation_count' "0"
    assert_job_field "fr-4779" '.current_tier' "tier_0"
    [ "$(_fr_ev_count fr-4779 reconciled)" = "0" ]
}

@test "unmerged_dependency: a dependency whose PR state cannot be determined (gh fails) counts as unmerged (UNKNOWN)" {
    make_job "fr-unk-dep" "succeeded" '.pr_url = "https://github.com/thehammer/mother/pull/811"'
    # No gh fixture registered for that URL -> the mock's `gh pr view` fails.
    _fr_make_job "fr-unk" "no_pr_no_push" '.depends_on = ["fr-unk-dep"]'

    run mother route-failure "fr-unk"
    [ "$status" -eq 0 ]

    _fr_assert_held "fr-unk" "no_pr_no_push" "unmerged_dependency"
    assert_job_field "fr-unk" '.operator_hold.detail.dependencies[0].pr_state' "UNKNOWN"
}

@test "unmerged_dependency: an ARCHIVED dependency is found and checked too" {
    mkdir -p "$ARCHIVE_DIR/2026-09"
    make_job "fr-arch-dep" "succeeded" '.pr_url = "https://github.com/thehammer/mother/pull/812"'
    mv "$JOBS_DIR/fr-arch-dep.json" "$ARCHIVE_DIR/2026-09/fr-arch-dep.json"
    gh_mock_set_pr "https://github.com/thehammer/mother/pull/812" OPEN "feature/fr-arch-dep"
    _fr_make_job "fr-arch" "no_pr_no_push" '.depends_on = ["fr-arch-dep"]'

    run mother route-failure "fr-arch"
    [ "$status" -eq 0 ]

    _fr_assert_held "fr-arch" "no_pr_no_push" "unmerged_dependency"
    assert_job_field "fr-arch" '.operator_hold.detail.dependencies[0].job_id' "fr-arch-dep"
}

@test "no_pr_no_push with a dependency whose PR IS merged is held as nothing_to_reconcile, not unmerged_dependency" {
    make_job "fr-merged-dep" "succeeded" '.pr_url = "https://github.com/thehammer/mother/pull/813"'
    gh_mock_set_pr "https://github.com/thehammer/mother/pull/813" MERGED "feature/fr-merged-dep"
    _fr_make_job "fr-merged" "no_pr_no_push" '.depends_on = ["fr-merged-dep"]'

    run mother route-failure "fr-merged"
    [ "$status" -eq 0 ]

    _fr_assert_held "fr-merged" "no_pr_no_push" "nothing_to_reconcile"
}

@test "no_pr_no_push with nothing to reconcile and no dependencies is held as nothing_to_reconcile" {
    _fr_make_job "fr-nothing" "no_pr_no_push"

    run mother route-failure "fr-nothing"
    [ "$status" -eq 0 ]

    _fr_assert_held "fr-nothing" "no_pr_no_push" "nothing_to_reconcile"
    assert_job_field "fr-nothing" '.escalation_count' "0"
    assert_job_field "fr-nothing" '.current_tier' "tier_0"
}

@test "no_pr_no_push with MOTHER_RECONCILE_ENABLED=0 skips reconciliation and holds even when a PR is adoptable" {
    _fr_make_adoptable_job "fr-norec" "no_pr_no_push"
    export MOTHER_RECONCILE_ENABLED=0

    run mother route-failure "fr-norec"
    [ "$status" -eq 0 ]

    _fr_assert_held "fr-norec" "no_pr_no_push" "nothing_to_reconcile"
    [ "$(_fr_ev_count fr-norec reconciled)" = "0" ]
}

# ===========================================================================
# hold  (rework_no_new_commit, branch_create_failed, checkout_failed)
# ===========================================================================

@test "rework_no_new_commit is held immediately and reconcile is NOT attempted (even when a PR is adoptable)" {
    # An adoptable PR exists — a reconcile attempt would happily adopt it and
    # bless a rework that never pushed anything.
    _fr_make_adoptable_job "fr-rework" "rework_no_new_commit" \
        '.pr_url = "https://github.com/thehammer/mother/pull/820"'

    run mother route-failure "fr-rework"
    [ "$status" -eq 0 ]

    _fr_assert_held "fr-rework" "rework_no_new_commit" "rework_no_new_commit"
    assert_job_field "fr-rework" '.state' "awaiting"
    [ "$(_fr_ev_count fr-rework reconciled)" = "0" ]
    # No PR detection queries at all.
    run bash -c "grep -Ec '^(pr list|api )' '$MOTHER_ROOT/mock-gh-calls'; true"
    [ "$output" = "0" ]
    # The PR pointer is preserved for the operator.
    assert_job_field "fr-rework" '.pr_url' "https://github.com/thehammer/mother/pull/820"
}

@test "branch_create_failed and checkout_failed are held immediately without a retry" {
    local reason
    for reason in branch_create_failed checkout_failed; do
        _fr_make_job "fr-hold-$reason" "$reason"

        run mother route-failure "fr-hold-$reason"
        [ "$status" -eq 0 ]

        _fr_assert_held "fr-hold-$reason" "$reason" "$reason"
        assert_job_field "fr-hold-$reason" '.auto_retry_count // 0' "0"
        assert_job_field "fr-hold-$reason" '.escalation_count' "0"
    done
}

# ===========================================================================
# retry_once  (worktree_create_failed, runner_died_early, unspecified)
# ===========================================================================

_fr_make_retryable() {
    local id="$1" reason="$2" extra="${3:-.}"
    _fr_make_job "$id" "$reason" '
        .current_tier = "tier_2"
        | .escalation_count = 1
        | .adherence_attempts = 1
        | .adherence_status = "failed_first"
        | .activity = "cody_rework"
        | .pr_url = "https://github.com/thehammer/mother/pull/830"
        | .worker_pid = 4242
        | .cancel_requested = true
        | .pause_requested = true
        | .final_result_at = "2026-09-01T00:00:00Z"
        | ('"$extra"')'
}

@test "worktree_create_failed gets ONE as-is retry: back to ready, auto_retry_count=1, no tier bump, adherence state untouched" {
    _fr_make_retryable "fr-retry" "worktree_create_failed"

    run mother route-failure "fr-retry"
    [ "$status" -eq 0 ]

    assert_job_field "fr-retry" '.state' "ready"
    assert_job_field "fr-retry" '.auto_retry_count' "1"
    assert_job_field "fr-retry" '.finished_at' "null"
    assert_job_field "fr-retry" '.worker_pid' "null"
    assert_job_field "fr-retry" '.cancel_requested' "null"
    assert_job_field "fr-retry" '.pause_requested' "null"
    assert_job_field "fr-retry" '.final_result_at' "null"

    # As-is: nothing about routing or adherence moves.
    assert_job_field "fr-retry" '.current_tier' "tier_2"
    assert_job_field "fr-retry" '.escalation_count' "1"
    assert_job_field "fr-retry" '.adherence_attempts' "1"
    assert_job_field "fr-retry" '.adherence_status' "failed_first"
    assert_job_field "fr-retry" '.activity' "cody_rework"
    assert_job_field "fr-retry" '.pr_url' "https://github.com/thehammer/mother/pull/830"

    local r; r=$(_fr_ev "fr-retry" failure_routed)
    [ "$(printf '%s' "$r" | jq -r '.action')" = "retried_as_is" ]
    [ "$(printf '%s' "$r" | jq -r '.auto_retry_count')" = "1" ]
    [ "$(_fr_ev_count fr-retry escalated)" = "0" ]
}

@test "a retried job that fails the same way again is held as retry_exhausted (worktree_create_failed, runner_died_early, unspecified)" {
    local reason
    for reason in worktree_create_failed runner_died_early unspecified; do
        local id="fr-exhaust-$reason"
        _fr_make_retryable "$id" "$reason"

        run mother route-failure "$id"
        assert_job_field "$id" '.state' "ready"

        # The retry failed for the same reason.
        jq '.state = "failed"' "$JOBS_DIR/$id.json" > "$JOBS_DIR/$id.json.new" && mv "$JOBS_DIR/$id.json.new" "$JOBS_DIR/$id.json"
        run mother route-failure "$id"
        [ "$status" -eq 0 ]

        _fr_assert_held "$id" "$reason" "retry_exhausted"
        assert_job_field "$id" '.auto_retry_count' "1"
        assert_job_field "$id" '.current_tier' "tier_2"
        assert_job_field "$id" '.escalation_count' "1"
    done
}

@test "a failed job with no recorded failure_reason at all is treated as unspecified: one as-is retry" {
    make_job "fr-noreason" "failed" '.branch = "feature/fr-noreason"'

    run mother route-failure "fr-noreason"
    [ "$status" -eq 0 ]

    assert_job_field "fr-noreason" '.state' "ready"
    assert_job_field "fr-noreason" '.auto_retry_count' "1"
    assert_job_field "fr-noreason" '.current_tier' "tier_0"
}

@test "an as-is retry goes to queued (not ready) when a dependency has not succeeded" {
    make_job "fr-q-dep" "running"
    _fr_make_job "fr-q" "worktree_create_failed" '.depends_on = ["fr-q-dep"]'

    run mother route-failure "fr-q"
    [ "$status" -eq 0 ]

    assert_job_field "fr-q" '.state' "queued"
    assert_job_field "fr-q" '.auto_retry_count' "1"
}

@test "an as-is retry replays the operator answer the failed run consumed at spawn" {
    _fr_make_job "fr-replay" "runner_died_early"
    _fr_add_event "fr-replay" "running" '{}'
    _fr_add_event "fr-replay" "resumed_from_input" '{"question":"Which schema?","answer":"Use the v2 schema."}'
    _fr_add_event "fr-replay" "failed" '{"reason":"runner_died_early"}'

    run mother route-failure "fr-replay"
    [ "$status" -eq 0 ]

    assert_job_field "fr-replay" '.state' "ready"
    assert_job_field "fr-replay" '.pending_answer' "Use the v2 schema."
    assert_job_field "fr-replay" '.question' "Which schema?"
}

@test "an as-is retry does NOT replay an answer consumed by an EARLIER run" {
    _fr_make_job "fr-noreplay" "runner_died_early"
    _fr_add_event "fr-noreplay" "resumed_from_input" '{"question":"Old question","answer":"Old answer"}'
    _fr_add_event "fr-noreplay" "started" '{}'
    _fr_add_event "fr-noreplay" "failed" '{"reason":"runner_died_early"}'

    run mother route-failure "fr-noreplay"
    [ "$status" -eq 0 ]

    assert_job_field "fr-noreplay" '.state' "ready"
    assert_job_field "fr-noreplay" '.pending_answer' "null"
}

# ===========================================================================
# escalate  (everything else)
# ===========================================================================

@test "a genuine failure (max_turns) with escalation budget left is escalated one tier" {
    _fr_make_job "fr-esc" "max_turns"

    run mother route-failure "fr-esc"
    [ "$status" -eq 0 ]

    assert_job_field "fr-esc" '.state' "ready"
    assert_job_field "fr-esc" '.current_tier' "tier_1"
    assert_job_field "fr-esc" '.escalation_count' "1"
    assert_event_kind "fr-esc" "escalated"
    [ "$(_fr_ev "fr-esc" failure_routed | jq -r '.action')" = "escalated" ]
}

@test "a genuine failure whose work is nonetheless adoptable is reconciled instead of escalated" {
    _fr_make_adoptable_job "fr-esc-rec" "max_turns"

    run mother route-failure "fr-esc-rec"
    [ "$status" -eq 0 ]

    assert_job_field "fr-esc-rec" '.state' "succeeded"
    assert_job_field "fr-esc-rec" '.escalation_count' "0"
    [ "$(_fr_ev_count fr-esc-rec escalated)" = "0" ]
    [ "$(_fr_ev "fr-esc-rec" failure_routed | jq -r '.action')" = "reconciled" ]
}

@test "a genuine failure at the escalation cap stays failed, is marked routed, and records left_failed/escalation_cap" {
    _fr_make_job "fr-cap" "max_turns" '.escalation_count = 2 | .current_tier = "tier_2"'

    run mother route-failure "fr-cap"
    [ "$status" -eq 0 ]

    assert_job_field "fr-cap" '.state' "failed"
    assert_job_field "fr-cap" '.failure_routed' "true"
    assert_job_field "fr-cap" '.escalation_count' "2"
    assert_job_field "fr-cap" '.current_tier' "tier_2"
    local r; r=$(_fr_ev "fr-cap" failure_routed)
    [ "$(printf '%s' "$r" | jq -r '.action')" = "left_failed" ]
    [ "$(printf '%s' "$r" | jq -r '.why')" = "escalation_cap" ]
}

@test "with MOTHER_ESCALATION_ENABLED=0 a genuine failure stays failed and records left_failed/escalation_disabled" {
    _fr_make_job "fr-esc-off" "max_turns"
    export MOTHER_ESCALATION_ENABLED=0

    run mother route-failure "fr-esc-off"
    [ "$status" -eq 0 ]

    assert_job_field "fr-esc-off" '.state' "failed"
    assert_job_field "fr-esc-off" '.failure_routed' "true"
    assert_job_field "fr-esc-off" '.escalation_count' "0"
    [ "$(_fr_ev "fr-esc-off" failure_routed | jq -r '.why')" = "escalation_disabled" ]
}

@test "route-failure refuses a job that is not failed and changes nothing" {
    make_job "fr-running" "running"
    local before; before=$(cat "$JOBS_DIR/fr-running.json")

    run mother route-failure "fr-running"

    [ "$(cat "$JOBS_DIR/fr-running.json")" = "$before" ]
    [ "$(_fr_ev_count fr-running failure_routed)" = "0" ]
}

# ===========================================================================
# The hold is a real operator handoff
# ===========================================================================

@test "mother status renders an [OPERATOR-HOLD] marker for a held job" {
    _fr_make_job "fr-status" "branch_create_failed"
    run mother route-failure "fr-status"
    [ "$status" -eq 0 ]

    run mother status "fr-status"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[OPERATOR-HOLD]"* ]]
}

@test "a held job can be adopted with mother reconcile --pr-url --yes, which clears the hold markers" {
    _fr_make_job "fr-hold-rec" "rework_no_new_commit"
    run mother route-failure "fr-hold-rec"
    _fr_assert_held "fr-hold-rec" "rework_no_new_commit" "rework_no_new_commit"

    local url="https://github.com/thehammer/mother/pull/840"
    gh_mock_set_pr "$url" OPEN "feature/fr-hold-rec"

    run mother reconcile "fr-hold-rec" --pr-url "$url" --yes
    [ "$status" -eq 0 ]

    assert_job_field "fr-hold-rec" '.state' "succeeded"
    assert_job_field "fr-hold-rec" '.pr_url' "$url"
    assert_job_field "fr-hold-rec" '.activity' "null"
    assert_job_field "fr-hold-rec" '.paused_reason' "null"
}

@test "a held job can be re-dispatched with mother retry, which clears the hold markers" {
    _fr_make_job "fr-hold-retry" "branch_create_failed"
    run mother route-failure "fr-hold-retry"
    _fr_assert_held "fr-hold-retry" "branch_create_failed" "branch_create_failed"

    run mother retry "fr-hold-retry"
    [ "$status" -eq 0 ]

    assert_job_field "fr-hold-retry" '.state' "ready"
    assert_job_field "fr-hold-retry" '.activity' "null"
    assert_job_field "fr-hold-retry" '.paused_reason' "null"
}

@test "an ordinary awaiting job (not an operator hold) is still refused by both retry and reconcile" {
    make_job "fr-plain-await" "awaiting" \
        '.paused_reason = "user" | .question = "Which schema should I use?"'

    run mother retry "fr-plain-await"
    [ "$status" -ne 0 ]
    assert_job_field "fr-plain-await" '.state' "awaiting"

    run mother reconcile "fr-plain-await" --pr-url "https://github.com/thehammer/mother/pull/850" --yes
    [ "$status" -ne 0 ]
    assert_job_field "fr-plain-await" '.state' "awaiting"
}
