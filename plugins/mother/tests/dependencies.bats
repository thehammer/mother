#!/usr/bin/env bats
# dependencies.bats — behavioral contract for dependency gating.
#
# A queued job with `depends_on` must not start until every dependency has
# actually SHIPPED — not merely "state == succeeded". A succeeded dependency
# whose PR is still open (or closed unmerged) has not delivered its work, so
# dependents wait (or are flagged blocked) instead of racing ahead. The
# system never cancels a dependent on its own; the operator decides.
#
# Interfaces exercised (lib/state.sh, sourced directly):
#   _dep_state <id>           — job state, falling back to the archive, else "missing"
#   _dep_record <id>          — path of the dependency's JSON (jobs, else archive); empty if missing
#   _dep_pr_merge_state <url> — merged | open | closed | unknown  (via `gh pr view`)
#   _dep_gate <id>            — satisfied | wait:<reason> | blocked:<reason>
#   _promote_ready            — queued -> ready when all deps satisfied; records .dep_wait otherwise
#
# Time-dependent tests (poll-interval expiry) sleep a couple of seconds; that
# is the price of not reaching into cache internals.

load 'test_helper'

PR_URL="https://github.com/Carefeed/test/pull/77"

setup() {
    setup_mother_env
    # Short, explicit defaults; individual tests override.
    export MOTHER_DEP_PR_POLL_INTERVAL=3600
    export MOCK_GH_STATE=OPEN
    export MOCK_GH_EXIT=0
    _install_gh
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# helpers

# Mock `gh`: records every invocation to $MOTHER_ROOT/gh-calls; answers
# `pr view ... state` with $MOCK_GH_STATE; fails when MOCK_GH_EXIT != 0.
_install_gh() {
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOTHER_ROOT:?}/gh-calls"
if [ "${MOCK_GH_EXIT:-0}" != "0" ]; then
    echo "gh: simulated failure" >&2
    exit "${MOCK_GH_EXIT}"
fi
case "$*" in
    *"pr view"*)
        printf '%s\n' "${MOCK_GH_STATE:-OPEN}"
        ;;
    *) echo "" ;;
esac
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
}

_gh_call_count() {
    if [ -f "$MOTHER_ROOT/gh-calls" ]; then
        wc -l < "$MOTHER_ROOT/gh-calls" | tr -d ' '
    else
        echo 0
    fi
}

# Run a snippet with lib/state.sh sourced, the way bin/mother would.
_st() {
    bash -c "set -u; source '$_LIB_DIR/state.sh'; $*"
}

# A succeeded dependency that opened a PR.
_make_dep_with_pr() {
    make_job "$1" "succeeded" ".pr_url = \"$PR_URL\""
}

# A queued dependent on the given dependency ids.
_make_dependent() {
    local id="$1"; shift
    local deps
    deps=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
    make_job "$id" "queued" ".depends_on = $deps"
}

_event_count() {
    local id="$1" kind="$2"
    if [ -f "$EVENTS_DIR/$id.jsonl" ]; then
        jq -c "select(.kind == \"$kind\")" "$EVENTS_DIR/$id.jsonl" | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# ---------------------------------------------------------------------------
# _dep_record

@test "_dep_record: prints the live job JSON path" {
    make_job "dep-live" "succeeded"
    run _st "_dep_record dep-live"
    [ "$status" -eq 0 ]
    [ "$output" = "$JOBS_DIR/dep-live.json" ]
}

@test "_dep_record: finds a dependency that exists only in the archive" {
    mkdir -p "$ARCHIVE_DIR/2026-09"
    jq -n '{id:"dep-arch", state:"succeeded", no_pr:true}' > "$ARCHIVE_DIR/2026-09/dep-arch.json"
    run _st "_dep_record dep-arch"
    [ "$status" -eq 0 ]
    [ "$output" = "$ARCHIVE_DIR/2026-09/dep-arch.json" ]
}

@test "_dep_record: prints nothing for an unknown dependency" {
    run _st "_dep_record no-such-dep"
    [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _dep_pr_merge_state

@test "_dep_pr_merge_state: reports merged, open and closed" {
    MOCK_GH_STATE=MERGED run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "merged" ]

    rm -rf "$RUNNER_DIR/dep-pr-cache"
    MOCK_GH_STATE=OPEN run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "open" ]

    rm -rf "$RUNNER_DIR/dep-pr-cache"
    MOCK_GH_STATE=CLOSED run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "closed" ]
}

@test "_dep_pr_merge_state: reports unknown when gh fails" {
    MOCK_GH_EXIT=1 run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "unknown" ]
}

@test "_dep_pr_merge_state: an open answer is cached within MOTHER_DEP_PR_POLL_INTERVAL" {
    export MOTHER_DEP_PR_POLL_INTERVAL=3600
    run _st "_dep_pr_merge_state '$PR_URL'; _dep_pr_merge_state '$PR_URL'; _dep_pr_merge_state '$PR_URL'"
    [ "$status" -eq 0 ]
    [ "$(_gh_call_count)" -eq 1 ]
}

@test "_dep_pr_merge_state: an open answer is re-queried once the poll interval has elapsed" {
    export MOTHER_DEP_PR_POLL_INTERVAL=1
    MOCK_GH_STATE=OPEN run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "open" ]
    sleep 2
    MOCK_GH_STATE=MERGED run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "merged" ]
    [ "$(_gh_call_count)" -eq 2 ]
}

@test "_dep_pr_merge_state: an unknown answer is retried after the poll interval, not cached forever" {
    export MOTHER_DEP_PR_POLL_INTERVAL=1
    MOCK_GH_EXIT=1 run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "unknown" ]
    sleep 2
    MOCK_GH_STATE=MERGED MOCK_GH_EXIT=0 run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "merged" ]
}

@test "_dep_pr_merge_state: merged is cached permanently (no further gh calls even with interval 0)" {
    export MOTHER_DEP_PR_POLL_INTERVAL=0
    MOCK_GH_STATE=MERGED run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "merged" ]
    [ "$(_gh_call_count)" -eq 1 ]

    # Even if gh would now lie or fail, the merged answer stands.
    MOCK_GH_STATE=OPEN run _st "_dep_pr_merge_state '$PR_URL'; _dep_pr_merge_state '$PR_URL'"
    [ "$(echo "$output" | sort -u)" = "merged" ]
    [ "$(_gh_call_count)" -eq 1 ]
}

@test "_dep_pr_merge_state: closed is cached permanently" {
    export MOTHER_DEP_PR_POLL_INTERVAL=0
    MOCK_GH_STATE=CLOSED run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "closed" ]
    MOCK_GH_STATE=OPEN run _st "_dep_pr_merge_state '$PR_URL'"
    [ "$output" = "closed" ]
    [ "$(_gh_call_count)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# _dep_gate — one test per row of the table

@test "_dep_gate: a missing dependency is blocked:dep_missing" {
    run _st "_dep_gate ghost-dep"
    [ "$output" = "blocked:dep_missing" ]
}

@test "_dep_gate: a queued dependency is wait:dep_not_finished" {
    make_job "dep-x" "queued"
    run _st "_dep_gate dep-x"
    [ "$output" = "wait:dep_not_finished" ]
}

@test "_dep_gate: a ready dependency is wait:dep_not_finished" {
    make_job "dep-x" "ready"
    run _st "_dep_gate dep-x"
    [ "$output" = "wait:dep_not_finished" ]
}

@test "_dep_gate: a running dependency is wait:dep_not_finished" {
    make_job "dep-x" "running"
    run _st "_dep_gate dep-x"
    [ "$output" = "wait:dep_not_finished" ]
}

@test "_dep_gate: an awaiting dependency is wait:dep_not_finished" {
    make_job "dep-x" "awaiting"
    run _st "_dep_gate dep-x"
    [ "$output" = "wait:dep_not_finished" ]
}

@test "_dep_gate: a failed dependency is blocked:dep_failed" {
    make_job "dep-x" "failed" '.reason = "x"'
    run _st "_dep_gate dep-x"
    [ "$output" = "blocked:dep_failed" ]
}

@test "_dep_gate: a cancelled dependency is blocked:dep_cancelled" {
    make_job "dep-x" "cancelled"
    run _st "_dep_gate dep-x"
    [ "$output" = "blocked:dep_cancelled" ]
}

@test "_dep_gate: a succeeded no_pr dependency is satisfied without asking gh" {
    make_job "dep-x" "succeeded" '.no_pr = true'
    run _st "_dep_gate dep-x"
    [ "$output" = "satisfied" ]
    [ "$(_gh_call_count)" -eq 0 ]
}

@test "_dep_gate: a succeeded dependency whose PR is merged is satisfied" {
    _make_dep_with_pr "dep-x"
    MOCK_GH_STATE=MERGED run _st "_dep_gate dep-x"
    [ "$output" = "satisfied" ]
}

@test "_dep_gate: a succeeded dependency whose PR is still open is wait:pr_open" {
    _make_dep_with_pr "dep-x"
    MOCK_GH_STATE=OPEN run _st "_dep_gate dep-x"
    [ "$output" = "wait:pr_open" ]
}

@test "_dep_gate: a succeeded dependency whose PR was closed unmerged is blocked:pr_closed_unmerged" {
    _make_dep_with_pr "dep-x"
    MOCK_GH_STATE=CLOSED run _st "_dep_gate dep-x"
    [ "$output" = "blocked:pr_closed_unmerged" ]
}

@test "_dep_gate: a succeeded dependency with gh failing is wait:pr_state_unknown (never blocked on a network wobble)" {
    _make_dep_with_pr "dep-x"
    MOCK_GH_EXIT=1 run _st "_dep_gate dep-x"
    [ "$output" = "wait:pr_state_unknown" ]
}

@test "_dep_gate: a succeeded dependency with no PR url and not no_pr is blocked:dep_no_pr_url" {
    make_job "dep-x" "succeeded"
    run _st "_dep_gate dep-x"
    [ "$output" = "blocked:dep_no_pr_url" ]
}

@test "_dep_gate: an archived succeeded no_pr dependency is found and satisfied" {
    mkdir -p "$ARCHIVE_DIR/2026-09"
    jq -n '{id:"dep-arch", state:"succeeded", no_pr:true}' > "$ARCHIVE_DIR/2026-09/dep-arch.json"
    run _st "_dep_gate dep-arch"
    [ "$output" = "satisfied" ]
}

@test "_dep_gate: an archived dependency with a merged PR is satisfied" {
    mkdir -p "$ARCHIVE_DIR/2026-09"
    jq -n --arg u "$PR_URL" '{id:"dep-arch", state:"succeeded", pr_url:$u}' > "$ARCHIVE_DIR/2026-09/dep-arch.json"
    MOCK_GH_STATE=MERGED run _st "_dep_gate dep-arch"
    [ "$output" = "satisfied" ]
}

# ---------------------------------------------------------------------------
# _promote_ready

@test "_promote_ready: promotes a dependent to ready once all deps are satisfied and clears dep_wait" {
    make_job "dep-a" "succeeded" '.no_pr = true'
    make_job "dep-b" "succeeded" '.no_pr = true'
    make_job "child" "queued" '.depends_on = ["dep-a","dep-b"] | .dep_wait = {dep_id:"dep-a", status:"wait", reason:"dep_not_finished"}'

    run _st "_promote_ready"
    [ "$status" -eq 0 ]

    assert_job_field "child" '.state' "ready"
    assert_job_field "child" '.dep_wait // "null"' "null"
    assert_event_kind "child" "dependency_satisfied"
    run jq -c 'select(.kind=="dependency_satisfied") | .detail.dep_ids | sort' "$EVENTS_DIR/child.jsonl"
    [ "$output" = '["dep-a","dep-b"]' ]
}

@test "_promote_ready: a job with no dependencies is promoted" {
    make_job "solo" "queued"
    run _st "_promote_ready"
    assert_job_field "solo" '.state' "ready"
}

@test "_promote_ready: a running dependency keeps the dependent queued with dep_wait recorded" {
    make_job "dep-a" "running"
    _make_dependent "child" "dep-a"

    run _st "_promote_ready"
    [ "$status" -eq 0 ]

    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.dep_id' "dep-a"
    assert_job_field "child" '.dep_wait.status' "wait"
    assert_job_field "child" '.dep_wait.reason' "dep_not_finished"
    assert_job_field_truthy "child" '.dep_wait.checked_at'
    assert_event_kind "child" "dependency_waiting"
}

@test "_promote_ready: a succeeded dependency with an OPEN PR keeps the dependent queued (reason pr_open)" {
    _make_dep_with_pr "dep-a"
    _make_dependent "child" "dep-a"

    MOCK_GH_STATE=OPEN run _st "_promote_ready"
    [ "$status" -eq 0 ]

    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.status' "wait"
    assert_job_field "child" '.dep_wait.reason' "pr_open"
    assert_job_field "child" '.dep_wait.pr_url' "$PR_URL"
}

@test "_promote_ready: once the dependency's PR merges the dependent is promoted" {
    export MOTHER_DEP_PR_POLL_INTERVAL=1
    _make_dep_with_pr "dep-a"
    _make_dependent "child" "dep-a"

    MOCK_GH_STATE=OPEN run _st "_promote_ready"
    assert_job_field "child" '.state' "queued"

    sleep 2
    MOCK_GH_STATE=MERGED run _st "_promote_ready"
    assert_job_field "child" '.state' "ready"
    assert_job_field "child" '.dep_wait // "null"' "null"
    assert_event_kind "child" "dependency_satisfied"
}

@test "_promote_ready: a failed dependency leaves the dependent queued and flagged blocked, never cancelled" {
    make_job "dep-a" "failed" '.reason = "x"'
    _make_dependent "child" "dep-a"

    run _st "_promote_ready"
    [ "$status" -eq 0 ]

    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.status' "blocked"
    assert_job_field "child" '.dep_wait.reason' "dep_failed"
    assert_job_field "child" '.dep_wait.dep_id' "dep-a"
    assert_event_kind "child" "dependency_blocked"
    [ "$(_event_count child cancelled)" -eq 0 ]
}

@test "_promote_ready: a cancelled dependency blocks (not cancels) the dependent" {
    make_job "dep-a" "cancelled"
    _make_dependent "child" "dep-a"
    run _st "_promote_ready"
    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.status' "blocked"
    assert_job_field "child" '.dep_wait.reason' "dep_cancelled"
}

@test "_promote_ready: a missing dependency blocks the dependent" {
    _make_dependent "child" "ghost-dep"
    run _st "_promote_ready"
    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.status' "blocked"
    assert_job_field "child" '.dep_wait.reason' "dep_missing"
}

@test "_promote_ready: a PR closed unmerged blocks the dependent" {
    _make_dep_with_pr "dep-a"
    _make_dependent "child" "dep-a"
    MOCK_GH_STATE=CLOSED run _st "_promote_ready"
    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.status' "blocked"
    assert_job_field "child" '.dep_wait.reason' "pr_closed_unmerged"
}

@test "_promote_ready: records the FIRST non-satisfied dependency, in depends_on order" {
    make_job "dep-ok" "succeeded" '.no_pr = true'
    make_job "dep-run" "running"
    make_job "dep-bad" "failed" '.reason = "x"'
    _make_dependent "child" "dep-ok" "dep-run" "dep-bad"

    run _st "_promote_ready"
    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.dep_id' "dep-run"
    assert_job_field "child" '.dep_wait.status' "wait"
}

@test "_promote_ready: one unsatisfied dependency among several keeps the dependent queued" {
    make_job "dep-a" "succeeded" '.no_pr = true'
    make_job "dep-b" "queued"
    _make_dependent "child" "dep-a" "dep-b"
    run _st "_promote_ready"
    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.dep_id' "dep-b"
}

@test "_promote_ready: repeated passes over an unchanged wait emit exactly one dependency_waiting event" {
    make_job "dep-a" "running"
    _make_dependent "child" "dep-a"

    run _st "_promote_ready"
    run _st "_promote_ready"
    run _st "_promote_ready"

    [ "$(_event_count child dependency_waiting)" -eq 1 ]
}

@test "_promote_ready: repeated passes over an unchanged block emit exactly one dependency_blocked event" {
    make_job "dep-a" "failed" '.reason = "x"'
    _make_dependent "child" "dep-a"

    run _st "_promote_ready"
    run _st "_promote_ready"
    run _st "_promote_ready"

    [ "$(_event_count child dependency_blocked)" -eq 1 ]
}

@test "_promote_ready: a wait that escalates to a block emits a dependency_blocked event and updates dep_wait" {
    make_job "dep-a" "running"
    _make_dependent "child" "dep-a"
    run _st "_promote_ready"
    assert_job_field "child" '.dep_wait.status' "wait"

    # The dependency then fails.
    jq '.state = "failed" | .reason = "x"' "$JOBS_DIR/dep-a.json" > "$JOBS_DIR/dep-a.json.new" && mv "$JOBS_DIR/dep-a.json.new" "$JOBS_DIR/dep-a.json"
    run _st "_promote_ready"

    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.status' "blocked"
    assert_job_field "child" '.dep_wait.reason' "dep_failed"
    [ "$(_event_count child dependency_blocked)" -eq 1 ]
}

@test "_promote_ready: finds a dependency that has been archived" {
    mkdir -p "$ARCHIVE_DIR/2026-09"
    jq -n '{id:"dep-arch", state:"succeeded", no_pr:true}' > "$ARCHIVE_DIR/2026-09/dep-arch.json"
    _make_dependent "child" "dep-arch"
    run _st "_promote_ready"
    assert_job_field "child" '.state' "ready"
}

@test "_promote_ready: a dependency whose only record is an archived merged PR promotes the dependent" {
    mkdir -p "$ARCHIVE_DIR/2026-09"
    jq -n --arg u "$PR_URL" '{id:"dep-arch", state:"succeeded", pr_url:$u}' > "$ARCHIVE_DIR/2026-09/dep-arch.json"
    _make_dependent "child" "dep-arch"
    MOCK_GH_STATE=MERGED run _st "_promote_ready"
    assert_job_field "child" '.state' "ready"
    # The PR state is what justified promotion, so it must have been consulted.
    [ "$(_gh_call_count)" -ge 1 ]
}

@test "_promote_ready: gh being called only once across passes while the PR stays open (poll interval honoured)" {
    export MOTHER_DEP_PR_POLL_INTERVAL=3600
    _make_dep_with_pr "dep-a"
    _make_dependent "child" "dep-a"

    MOCK_GH_STATE=OPEN run _st "_promote_ready"
    MOCK_GH_STATE=OPEN run _st "_promote_ready"
    MOCK_GH_STATE=OPEN run _st "_promote_ready"

    assert_job_field "child" '.state' "queued"
    [ "$(_gh_call_count)" -eq 1 ]
}

@test "_promote_ready: after the PR merges, later passes never call gh again for it" {
    export MOTHER_DEP_PR_POLL_INTERVAL=0
    _make_dep_with_pr "dep-a"
    _make_dependent "child1" "dep-a"
    _make_dependent "child2" "dep-a"

    MOCK_GH_STATE=MERGED run _st "_promote_ready"
    assert_job_field "child1" '.state' "ready"
    assert_job_field "child2" '.state' "ready"
    local calls_after_first; calls_after_first=$(_gh_call_count)
    [ "$calls_after_first" -ge 1 ]

    make_job "child3" "queued" '.depends_on = ["dep-a"]'
    MOCK_GH_STATE=OPEN run _st "_promote_ready"
    assert_job_field "child3" '.state' "ready"
    [ "$(_gh_call_count)" -eq "$calls_after_first" ]
}

@test "_promote_ready: a gh outage leaves the dependent waiting (pr_state_unknown), not blocked" {
    _make_dep_with_pr "dep-a"
    _make_dependent "child" "dep-a"
    MOCK_GH_EXIT=1 run _st "_promote_ready"
    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.status' "wait"
    assert_job_field "child" '.dep_wait.reason' "pr_state_unknown"
}

@test "_promote_ready: non-queued jobs are left alone" {
    make_job "dep-a" "running"
    make_job "already" "ready" '.depends_on = ["dep-a"]'
    run _st "_promote_ready"
    assert_job_field "already" '.state' "ready"
    assert_job_field "already" '.dep_wait // "null"' "null"
}

# ---------------------------------------------------------------------------
# operator escape hatch

@test "force-start --ignore-deps: an operator can push a blocked queued dependent through" {
    make_job "dep-a" "failed" '.reason = "x"'
    _make_dependent "child" "dep-a"
    run _st "_promote_ready"
    assert_job_field "child" '.dep_wait.status' "blocked"

    run mother force-start "child" --ignore-deps --yes
    [ "$status" -eq 0 ]
    [[ "$output" =~ "bypassing dependency gates" ]]
    assert_job_field "child" '.force_start' "true"
    assert_job_field "child" '.force_ignore_deps' "true"

    # After the next promotion pass the job is dispatchable (ready).
    run _st "_promote_ready"
    assert_job_field "child" '.state' "ready"
    [ "$(_event_count child dependency_gate_bypassed)" -ge 1 ]
}

@test "force-start: plain force-start leaves a blocked dependent queued" {
    make_job "dep-a" "failed" '.reason = "x"'
    _make_dependent "child" "dep-a"
    run _st "_promote_ready"

    run mother force-start "child" --yes
    [ "$status" -eq 0 ]
    assert_job_field "child" '.force_start' "true"
    assert_job_field "child" '.force_ignore_deps // "absent"' "absent"

    run _st "_promote_ready"
    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.status' "blocked"
}

@test "force-start: quota override on a dependent with an unmerged dep waits, then promotes once merged" {
    export MOTHER_DEP_PR_POLL_INTERVAL=1
    _make_dep_with_pr "dep-a"
    _make_dependent "child" "dep-a"

    MOCK_GH_STATE=OPEN run mother force-start "child" --yes
    [ "$status" -eq 0 ]
    [[ "$output" =~ "quota override set; still waiting on dep-a" ]]
    assert_job_field "child" '.force_start' "true"
    assert_job_field "child" '.force_ignore_deps // "absent"' "absent"

    MOCK_GH_STATE=OPEN run _st "_promote_ready"
    assert_job_field "child" '.state' "queued"
    assert_job_field "child" '.dep_wait.status' "wait"

    sleep 2
    MOCK_GH_STATE=MERGED run _st "_promote_ready"
    assert_job_field "child" '.state' "ready"
    assert_job_field "child" '.force_start' "true"
    [ "$(_event_count child dependency_satisfied)" -ge 1 ]
    [ "$(_event_count child dependency_gate_bypassed)" -eq 0 ]
}

@test "force-start: force_ignore_deps is cleared on terminal transition" {
    make_job "child" "running" '.force_start = true | .force_ignore_deps = true'
    run _st "_job_transition child succeeded '{}'"
    [ "$status" -eq 0 ]
    assert_job_field "child" '.force_start // "absent"' "absent"
    assert_job_field "child" '.force_ignore_deps // "absent"' "absent"
}
