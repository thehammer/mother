#!/usr/bin/env bats
# rate_limit_backoff.bats — a 429 (and 529 / 5xx) means "wait and retry the SAME
# tier", never a failed attempt that escalates.
#
# Incident: three 429 `api_error` failures (result subtype "success", is_error
# true, $0 cost) escalated a job tier_0 -> tier_2 in one minute, then
# `reconcile --auto` "adopted" a pre-existing PR so a job that did no work
# became `succeeded`.
#
# Contract under test (the classify-exit rules and the failure_route.bats class
# table live in usage.bats / failure_reasons.bats / failure_route.bats):
#
#   mother route-failure <id>   reason rate_limited | api_overloaded (class backoff)
#       state -> ready (queued while a dependency hasn't succeeded), run fields cleared,
#       current_tier / escalation_count / retry_count / auto_retry_count untouched,
#       .backoff_count +1, .backoff_first_at set once (epoch s), .not_before = now + delay
#       (epoch s): delay = retry_after_s when the failed detail has one (> 0), else
#       min(CAP 300, BASE 30 * 2^count_before) + jitter 0..20% (MOTHER_BACKOFF_JITTER_PCT).
#       Event failure_routed {action: backed_off, reason, delay_s, backoff_count}.
#       rate_limited only: shared pause $MOTHER_ROOT/ratelimit-until = max(existing, not_before).
#       Never reconciles. Gives up after MOTHER_BACKOFF_MAX_S (default 900) of backing off:
#       operator hold (sub_reason backoff_exhausted) with an exact question.
#       billing / auth_error -> ordinary operator hold (sub_reason == the reason).
#       The worker's tail_excerpt never reaches the question, the hold detail or an event.
#       MOTHER_BACKOFF_ENABLED=0 -> the old routing (escalate).
#   mother-runner --dispatch-tick   a ready job with a future .not_before, or any job while
#       ratelimit-until is in the future, is not spawned.
#   mother list / status            `ready [BACKOFF <N>m|<N>s]` for a backed-off job.
#   mother-run-job                  a result with a 429/529 is a failed run, whatever the exit code.
#   mother review-lens / adherence-review  rate limits are errors (never passes), wait on the pause.
#   mother-runner adherence pass    does not start a review during the pause.

load 'test_helper'
load 'gh_mock'

FIXTURES="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd -P)/fixtures/usage"
LENS_FIX="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd -P)/fixtures/lenses"

CANARY="CANARY-9f3a"

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_ESCALATION_ENABLED=1
    export MOTHER_POSTURE_ENABLED=0
    unset MOTHER_RECONCILE_ENABLED MOTHER_BACKOFF_ENABLED MOTHER_BACKOFF_BASE_S MOTHER_BACKOFF_CAP_S \
          MOTHER_BACKOFF_MAX_S MOTHER_REVIEW_RATELIMIT_RETRIES MOTHER_ADHERENCE_MAX_RUNS_PER_SHA
    # Exact delays unless a test is about jitter.
    export MOTHER_BACKOFF_JITTER_PCT=0
    gh_mock_install
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_now() { date +%s; }

# _between <value> <lo> <hi> — inclusive integer range check with a message.
_between() {
    if [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; then return 0; fi
    echo "FAIL: $1 not in [$2, $3]" >&2
    return 1
}

_is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

_jf() { jq -r "$2" "$JOBS_DIR/$1.json"; }

# Last event of <kind>'s detail as compact JSON ('' if none).
_ev() {
    [ -f "$EVENTS_DIR/$1.jsonl" ] || { echo ""; return 0; }
    jq -c --arg k "$2" 'select(.kind==$k) | .detail' "$EVENTS_DIR/$1.jsonl" | tail -1
}

_ev_count() {
    local n
    n=$(grep -c "\"kind\":\"$2\"" "$EVENTS_DIR/$1.jsonl" 2>/dev/null || true)
    echo "${n:-0}"
}

_ev_lines() { wc -l < "$EVENTS_DIR/$1.jsonl" 2>/dev/null | tr -d ' ' || echo 0; }

_set_job() {
    local id="$1" filter="$2" merged
    merged=$(jq "$filter" "$JOBS_DIR/$id.json") && printf '%s\n' "$merged" > "$JOBS_DIR/$id.json"
}

# A failed job, as the runner would find it after a worker run died with <reason>.
# The job's last `failed` event carries <detail> (merged over {reason, exit_code}).
# Nothing is adoptable on GitHub (work_dir doesn't exist). Tier/escalation/retry
# counters are deliberately non-zero so "untouched" is observable.
# Usage: _bo_job <id> <reason> [extra-jq-filter] [failed-detail-json]
_bo_job() {
    local id="$1" reason="$2" extra="${3:-.}" detail="${4:-}"
    [ -n "$detail" ] || detail='{}'
    make_job "$id" "failed" '
        .failure_reason = "'"$reason"'"
        | .branch = "feature/'"$id"'"
        | .base_ref = "main"
        | .repo_path = "/nonexistent/bo-'"$id"'"
        | .work_dir = "/nonexistent/bo-'"$id"'"
        | .finished_at = "2026-09-01T00:00:00Z"
        | .worker_pid = 4242
        | .cancel_requested = true
        | .pause_requested = true
        | .final_result_at = "2026-09-01T00:00:00Z"
        | .current_tier = "tier_1"
        | .escalation_count = 1
        | .retry_count = 3
        | .auto_retry_count = 1
        | ('"$extra"')'
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg r "$reason" --argjson d "$detail" \
        '{ts: $ts, kind: "failed", detail: ({reason: $r, exit_code: 1} + $d)}' >> "$EVENTS_DIR/$id.jsonl"
}

# Like _bo_job, but the work is adoptable: a repo whose HEAD is on an open PR's
# branch with one worker commit on top (exactly failure_route.bats'
# _fr_make_adoptable_job). A reconcile attempt would adopt it. Sets BO_PR_URL.
_bo_adoptable_job() {
    local id="$1" reason="$2" extra="${3:-.}" detail="${4:-}"
    local repo="$MOTHER_ROOT/bo-repo-$id"
    BO_PR_URL="https://github.com/thehammer/mother/pull/7$(printf '%02d' $((RANDOM % 100)))"
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
    gh_mock_set_commit_pulls "$head" "$BO_PR_URL" open
    gh_mock_set_pr "$BO_PR_URL" OPEN "pr-head" "$head"
    _bo_job "$id" "$reason" \
        '.work_dir = "'"$repo"'" | .repo_path = "'"$repo"'" | .base_ref = "pr-head" | ('"$extra"')' "$detail"
}

# A job held for the operator (copy of failure_route.bats' _fr_assert_held).
# Usage: _bo_assert_held <id> <failure_reason> <sub_reason>
_bo_assert_held() {
    local id="$1" reason="$2" sub="$3"
    assert_job_field "$id" '.state' "awaiting"
    assert_job_field "$id" '.activity' "operator_hold"
    assert_job_field "$id" '.paused_reason' "operator_hold"
    assert_job_field "$id" '.operator_hold.failure_reason' "$reason"
    assert_job_field "$id" '.operator_hold.sub_reason' "$sub"
    local q; q=$(jq -r '.question // ""' "$JOBS_DIR/$id.json")
    [[ "$q" == *"$id"* ]]
    [[ "$q" =~ mother\ (resume|reconcile|retry|cancel) ]]
    [ "$(_ev "$id" failure_routed | jq -r '.action')" = "held" ]
    [ "$(_ev_count "$id" escalated)" = "0" ]
}

# Counters route-failure must leave alone in every backoff/hold path.
_bo_assert_counters_untouched() {
    local id="$1"
    assert_job_field "$id" '.current_tier' "tier_1"
    assert_job_field "$id" '.escalation_count' "1"
    assert_job_field "$id" '.retry_count' "3"
    assert_job_field "$id" '.auto_retry_count' "1"
    [ "$(_ev_count "$id" escalated)" = "0" ]
}

# ===========================================================================
# route-failure: backing off
# ===========================================================================

@test "backoff: a rate_limited job goes back to ready at the SAME tier with not_before = now + 30s and the counters untouched" {
    _bo_job "bo-1" "rate_limited" . '{"api_error_status":429}'

    local t0; t0=$(_now)
    run mother route-failure "bo-1"
    [ "$status" -eq 0 ]
    local t1; t1=$(_now)

    assert_job_field "bo-1" '.state' "ready"
    # The failed run's leftovers are cleared like an as-is retry.
    assert_job_field "bo-1" '.finished_at' "null"
    assert_job_field "bo-1" '.worker_pid' "null"
    assert_job_field "bo-1" '.cancel_requested' "null"
    assert_job_field "bo-1" '.pause_requested' "null"
    assert_job_field "bo-1" '.final_result_at' "null"
    # Nothing about routing moves: same tier, no escalation, no retry budget spent.
    _bo_assert_counters_untouched "bo-1"

    assert_job_field "bo-1" '.backoff_count' "1"
    local nb first
    nb=$(_jf bo-1 '.not_before'); first=$(_jf bo-1 '.backoff_first_at')
    _is_int "$nb"; _is_int "$first"
    _between "$nb" $((t0 + 30)) $((t1 + 30))
    _between "$first" "$t0" "$t1"
}

@test "backoff: route-failure emits failure_routed {action, reason, delay_s, backoff_count} and no other keys" {
    _bo_job "bo-ev" "rate_limited" . '{"api_error_status":429}'

    run mother route-failure "bo-ev"
    [ "$status" -eq 0 ]

    local d; d=$(_ev "bo-ev" failure_routed)
    printf '%s' "$d" | jq -e '
        (keys | sort) == ["action", "backoff_count", "delay_s", "reason"]
        and .action == "backed_off" and .reason == "rate_limited"
        and .delay_s == 30 and .backoff_count == 1' >/dev/null
    # The event's count is the job's stored count.
    [ "$(printf '%s' "$d" | jq -r '.backoff_count')" = "$(_jf bo-ev '.backoff_count')" ]
}

@test "backoff: the delay doubles from 30s and is capped at 300s (30, 60, 120, 240, 300, 300)" {
    local pair n want t0 t1 id
    for pair in 0:30 1:60 2:120 3:240 4:300 5:300 8:300; do
        n="${pair%%:*}"; want="${pair##*:}"
        id="bo-exp-$n"
        if [ "$n" = "0" ]; then
            _bo_job "$id" "rate_limited"
        else
            _bo_job "$id" "rate_limited" ".backoff_count = $n | .backoff_first_at = $(_now)"
        fi
        t0=$(_now)
        run mother route-failure "$id"
        [ "$status" -eq 0 ]
        t1=$(_now)

        assert_job_field "$id" '.state' "ready"
        assert_job_field "$id" '.backoff_count' "$((n + 1))"
        [ "$(_ev "$id" failure_routed | jq -r '.delay_s')" = "$want" ] || { echo "count $n: delay_s != $want" >&2; return 1; }
        _between "$(_jf "$id" '.not_before')" $((t0 + want)) $((t1 + want))
    done
}

@test "backoff: MOTHER_BACKOFF_BASE_S and MOTHER_BACKOFF_CAP_S override the 30s base and 300s cap" {
    export MOTHER_BACKOFF_BASE_S=2 MOTHER_BACKOFF_CAP_S=5
    local pair n want id
    for pair in 0:2 1:4 2:5 3:5; do
        n="${pair%%:*}"; want="${pair##*:}"
        id="bo-env-$n"
        _bo_job "$id" "rate_limited" ".backoff_count = $n | .backoff_first_at = $(_now)"
        run mother route-failure "$id"
        [ "$status" -eq 0 ]
        [ "$(_ev "$id" failure_routed | jq -r '.delay_s')" = "$want" ] || { echo "count $n: delay_s != $want" >&2; return 1; }
    done
}

@test "backoff: a retry_after_s on the failed detail is used exactly (not jittered, not capped)" {
    # Jitter left at its default (20%): a server-given wait is never padded.
    unset MOTHER_BACKOFF_JITTER_PCT
    local n id t0 t1
    for n in 90 600; do
        id="bo-ra-$n"
        _bo_job "$id" "rate_limited" . '{"api_error_status":429,"retry_after_s":'"$n"'}'
        t0=$(_now)
        run mother route-failure "$id"
        [ "$status" -eq 0 ]
        t1=$(_now)

        assert_job_field "$id" '.state' "ready"
        [ "$(_ev "$id" failure_routed | jq -r '.delay_s')" = "$n" ]
        _between "$(_jf "$id" '.not_before')" $((t0 + n)) $((t1 + n))
    done
}

@test "backoff: retry_after_s of 0 (or absent) falls back to the exponential delay" {
    _bo_job "bo-ra-zero" "rate_limited" . '{"api_error_status":429,"retry_after_s":0}'
    run mother route-failure "bo-ra-zero"
    [ "$status" -eq 0 ]
    [ "$(_ev "bo-ra-zero" failure_routed | jq -r '.delay_s')" = "30" ]
}

@test "backoff: with the default jitter the delay stays within [base, base * 1.2]" {
    unset MOTHER_BACKOFF_JITTER_PCT
    local i id t0 t1 d nb
    for i in 1 2 3 4 5 6; do
        id="bo-jit-$i"
        _bo_job "$id" "rate_limited"
        t0=$(_now)
        run mother route-failure "$id"
        [ "$status" -eq 0 ]
        t1=$(_now)
        d=$(_ev "$id" failure_routed | jq -r '.delay_s')
        jq -ne --argjson d "$d" '$d >= 30 and $d <= 36' >/dev/null || { echo "delay $d outside [30,36]" >&2; return 1; }
        nb=$(_jf "$id" '.not_before')
        _is_int "$nb"
        _between "$nb" $((t0 + 30)) $((t1 + 36))
    done
    # And a later rung (count 2, base 120).
    _bo_job "bo-jit-120" "rate_limited" ".backoff_count = 2 | .backoff_first_at = $(_now)"
    run mother route-failure "bo-jit-120"
    d=$(_ev "bo-jit-120" failure_routed | jq -r '.delay_s')
    jq -ne --argjson d "$d" '$d >= 120 and $d <= 144' >/dev/null || { echo "delay $d outside [120,144]" >&2; return 1; }
}

@test "backoff: api_overloaded backs off exactly like rate_limited (same tier, ready, not_before)" {
    _bo_job "bo-ovl" "api_overloaded" . '{"api_error_status":529}'

    local t0; t0=$(_now)
    run mother route-failure "bo-ovl"
    [ "$status" -eq 0 ]
    local t1; t1=$(_now)

    assert_job_field "bo-ovl" '.state' "ready"
    _bo_assert_counters_untouched "bo-ovl"
    assert_job_field "bo-ovl" '.backoff_count' "1"
    _between "$(_jf bo-ovl '.not_before')" $((t0 + 30)) $((t1 + 30))
    local d; d=$(_ev "bo-ovl" failure_routed)
    [ "$(printf '%s' "$d" | jq -r '.action')" = "backed_off" ]
    [ "$(printf '%s' "$d" | jq -r '.reason')" = "api_overloaded" ]
}

@test "backoff: backoff_first_at is set once — a second back-off keeps the first timestamp" {
    local first=$(( $(_now) - 100 ))
    _bo_job "bo-first" "rate_limited" ".backoff_count = 1 | .backoff_first_at = $first"

    run mother route-failure "bo-first"
    [ "$status" -eq 0 ]

    assert_job_field "bo-first" '.state' "ready"
    assert_job_field "bo-first" '.backoff_count' "2"
    assert_job_field "bo-first" '.backoff_first_at' "$first"
}

@test "backoff: a job whose dependency has not succeeded goes to queued, not ready (back-off fields still set)" {
    make_job "bo-q-dep" "running"
    _bo_job "bo-q" "rate_limited" '.depends_on = ["bo-q-dep"]'

    run mother route-failure "bo-q"
    [ "$status" -eq 0 ]

    assert_job_field "bo-q" '.state' "queued"
    assert_job_field "bo-q" '.backoff_count' "1"
    assert_job_field_truthy "bo-q" '.not_before'
    _bo_assert_counters_untouched "bo-q"
}

@test "backoff: a failed event with no detail at all (no status, no retry_after) still backs off with the base delay" {
    _bo_job "bo-bare" "rate_limited"
    rm -f "$EVENTS_DIR/bo-bare.jsonl"

    run mother route-failure "bo-bare"
    [ "$status" -eq 0 ]

    assert_job_field "bo-bare" '.state' "ready"
    [ "$(_ev "bo-bare" failure_routed | jq -r '.delay_s')" = "30" ]
}

@test "backoff: the escalation cap does not matter — a rate-limited job at escalation_count 2 still backs off (nothing is escalated)" {
    _bo_job "bo-cap" "rate_limited" '.escalation_count = 2 | .current_tier = "tier_2"'

    run mother route-failure "bo-cap"
    [ "$status" -eq 0 ]

    assert_job_field "bo-cap" '.state' "ready"
    assert_job_field "bo-cap" '.escalation_count' "2"
    assert_job_field "bo-cap" '.current_tier' "tier_2"
    assert_job_field "bo-cap" '.failure_routed' "null"
}

# ---------------------------------------------------------------------------
# The shared pause file
# ---------------------------------------------------------------------------

@test "pause file: a rate_limited route-failure writes ratelimit-until = the job's not_before as one integer line" {
    _bo_job "bo-p1" "rate_limited"

    run mother route-failure "bo-p1"
    [ "$status" -eq 0 ]

    local f="$MOTHER_ROOT/ratelimit-until"
    [ -f "$f" ]
    grep -Eqx '[0-9]+' "$f"
    [ "$(wc -l < "$f" | tr -d ' ')" -le 1 ]
    [ "$(tr -d '[:space:]' < "$f")" = "$(_jf bo-p1 '.not_before')" ]
}

@test "pause file: an existing later pause is kept (max of existing and not_before)" {
    local later=$(( $(_now) + 5000 ))
    echo "$later" > "$MOTHER_ROOT/ratelimit-until"
    _bo_job "bo-p2" "rate_limited"

    run mother route-failure "bo-p2"
    [ "$status" -eq 0 ]

    [ "$(tr -d '[:space:]' < "$MOTHER_ROOT/ratelimit-until")" = "$later" ]
}

@test "pause file: an existing earlier (stale) pause is extended to the job's not_before" {
    echo "$(( $(_now) - 500 ))" > "$MOTHER_ROOT/ratelimit-until"
    _bo_job "bo-p3" "rate_limited"

    run mother route-failure "bo-p3"
    [ "$status" -eq 0 ]

    [ "$(tr -d '[:space:]' < "$MOTHER_ROOT/ratelimit-until")" = "$(_jf bo-p3 '.not_before')" ]
}

@test "pause file: api_overloaded does NOT write the shared pause (only rate limits are account-wide)" {
    _bo_job "bo-p4" "api_overloaded" . '{"api_error_status":529}'

    run mother route-failure "bo-p4"
    [ "$status" -eq 0 ]

    assert_job_field "bo-p4" '.state' "ready"
    [ ! -e "$MOTHER_ROOT/ratelimit-until" ]
}

# ---------------------------------------------------------------------------
# Never reconcile (the incident's second half)
# ---------------------------------------------------------------------------

@test "backoff: rate_limited / api_overloaded never reconcile — an adoptable PR is not adopted and the job is not 'succeeded'" {
    local reason
    for reason in rate_limited api_overloaded; do
        local id="bo-norec-$reason"
        _bo_adoptable_job "$id" "$reason" . '{"api_error_status":429}'

        run mother route-failure "$id"
        [ "$status" -eq 0 ]

        assert_job_field "$id" '.state' "ready"
        assert_job_field "$id" '.pr_url' "null"
        [ "$(_ev_count "$id" succeeded)" = "0" ]
        [ "$(_ev_count "$id" reconciled)" = "0" ]
        [ "$(_ev "$id" failure_routed | jq -r '.action')" = "backed_off" ]
    done
    # No PR detection queries were made at all.
    run bash -c "grep -Ec '^(pr list|api )' '$MOTHER_ROOT/mock-gh-calls'; true"
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# billing / auth_error: a hold, not a retry and not an escalation
# ---------------------------------------------------------------------------

@test "billing and auth_error are held for the operator (sub_reason = the reason): no reconcile, no escalation, no back-off" {
    local reason
    for reason in billing auth_error; do
        local id="bo-hold-$reason"
        _bo_adoptable_job "$id" "$reason" . '{"api_error_status":402}'

        run mother route-failure "$id"
        [ "$status" -eq 0 ]

        _bo_assert_held "$id" "$reason" "$reason"
        _bo_assert_counters_untouched "$id"
        assert_job_field "$id" '.pr_url' "null"
        assert_job_field "$id" '.not_before' "null"
        assert_job_field "$id" '.backoff_count' "null"
        [ "$(_ev_count "$id" succeeded)" = "0" ]
        [ "$(_ev_count "$id" reconciled)" = "0" ]
    done
    [ ! -e "$MOTHER_ROOT/ratelimit-until" ]
}

# ---------------------------------------------------------------------------
# Giving up
# ---------------------------------------------------------------------------

@test "give-up: rate limited for over 900s -> operator hold backoff_exhausted with the exact question, counters untouched" {
    local first=$(( $(_now) - 1000 ))
    _bo_job "bo-gu1" "rate_limited" ".backoff_count = 4 | .backoff_first_at = $first" '{"api_error_status":429}'

    run mother route-failure "bo-gu1"
    [ "$status" -eq 0 ]

    assert_job_field "bo-gu1" '.state' "awaiting"
    assert_job_field "bo-gu1" '.activity' "operator_hold"
    assert_job_field "bo-gu1" '.paused_reason' "operator_hold"
    assert_job_field "bo-gu1" '.operator_hold.failure_reason' "rate_limited"
    assert_job_field "bo-gu1" '.operator_hold.sub_reason' "backoff_exhausted"
    assert_job_field "bo-gu1" '.question' \
        "Job bo-gu1 was rate limited for 16 minutes (HTTP 429). Options: mother resume bo-gu1 go (retry now) | mother cancel bo-gu1"
    _bo_assert_counters_untouched "bo-gu1"
    [ "$(_ev_count bo-gu1 succeeded)" = "0" ]
    [ "$(_ev_count bo-gu1 reconciled)" = "0" ]
}

@test "give-up: the hold opens an unresolved decision offering resume_with_guidance and cancel" {
    _bo_job "bo-gu-dec" "rate_limited" ".backoff_count = 4 | .backoff_first_at = $(( $(_now) - 1000 ))"

    run mother route-failure "bo-gu-dec"
    [ "$status" -eq 0 ]

    jq -e '(.decision | type == "object")
           and ([.decision.options[].id] == ["resume_with_guidance", "cancel"])
           and .decision.resolved_at == null' "$JOBS_DIR/bo-gu-dec.json" >/dev/null
}

@test "give-up: without an api_error_status on the failed detail a rate_limited give-up says HTTP 429" {
    _bo_job "bo-gu2" "rate_limited" ".backoff_count = 4 | .backoff_first_at = $(( $(_now) - 1000 ))"

    run mother route-failure "bo-gu2"
    [ "$status" -eq 0 ]

    [[ "$(_jf bo-gu2 '.question')" == *"(HTTP 429)"* ]]
}

@test "give-up: an api_overloaded give-up reports the failed detail's own status (503) and the elapsed minutes (21)" {
    _bo_job "bo-gu3" "api_overloaded" ".backoff_count = 5 | .backoff_first_at = $(( $(_now) - 1260 ))" '{"api_error_status":503}'

    run mother route-failure "bo-gu3"
    [ "$status" -eq 0 ]

    assert_job_field "bo-gu3" '.operator_hold.sub_reason' "backoff_exhausted"
    assert_job_field "bo-gu3" '.question' \
        "Job bo-gu3 was rate limited for 21 minutes (HTTP 503). Options: mother resume bo-gu3 go (retry now) | mother cancel bo-gu3"
}

@test "give-up: still inside the 900s window the job keeps backing off" {
    _bo_job "bo-gu4" "rate_limited" ".backoff_count = 3 | .backoff_first_at = $(( $(_now) - 800 ))"

    run mother route-failure "bo-gu4"
    [ "$status" -eq 0 ]

    assert_job_field "bo-gu4" '.state' "ready"
    assert_job_field "bo-gu4" '.backoff_count' "4"
}

@test "give-up: MOTHER_BACKOFF_MAX_S overrides the 900s window" {
    export MOTHER_BACKOFF_MAX_S=60
    _bo_job "bo-gu5" "rate_limited" ".backoff_count = 2 | .backoff_first_at = $(( $(_now) - 125 ))"

    run mother route-failure "bo-gu5"
    [ "$status" -eq 0 ]

    assert_job_field "bo-gu5" '.operator_hold.sub_reason' "backoff_exhausted"
    [[ "$(_jf bo-gu5 '.question')" == "Job bo-gu5 was rate limited for 2 minutes"* ]]
}

@test "mother resume <id> go after a give-up clears the back-off state, readies the job, and the next failure starts a fresh window" {
    _bo_job "bo-go" "rate_limited" \
        ".backoff_count = 4 | .backoff_first_at = $(( $(_now) - 1000 )) | .not_before = $(( $(_now) + 3600 ))"
    run mother route-failure "bo-go"
    assert_job_field "bo-go" '.operator_hold.sub_reason' "backoff_exhausted"

    run mother resume "bo-go" go
    [ "$status" -eq 0 ]

    assert_job_field "bo-go" '.state' "ready"
    assert_job_field "bo-go" '.not_before' "null"
    assert_job_field "bo-go" '.backoff_first_at' "null"
    local bc; bc=$(_jf bo-go '.backoff_count')
    [ "$bc" = "null" ] || [ "$bc" = "0" ]

    # It fails again: a brand-new window, not an instant give-up.
    _set_job "bo-go" '.state = "failed" | .failure_reason = "rate_limited"'
    jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{ts: $ts, kind: "failed", detail: {reason: "rate_limited", api_error_status: 429}}' >> "$EVENTS_DIR/bo-go.jsonl"
    run mother route-failure "bo-go"
    [ "$status" -eq 0 ]
    assert_job_field "bo-go" '.state' "ready"
    assert_job_field "bo-go" '.backoff_count' "1"
    [ "$(_ev "bo-go" failure_routed | jq -r '.delay_s')" = "30" ]
}

# ---------------------------------------------------------------------------
# The worker's output never reaches the question, the hold or an event (CANARY)
# ---------------------------------------------------------------------------

# _bo_canary_job <id> <reason> [extra-jq] — a failed job whose failed event's
# tail_excerpt is the canary. Prints the event-file line count to use with
# _bo_assert_no_canary after route-failure.
_bo_canary_job() {
    local id="$1" reason="$2" extra="${3:-.}"
    _bo_job "$id" "$reason" "$extra" \
        '{"api_error_status":429,"tail_excerpt":"... '"$CANARY"' sk-live-secret ..."}'
    # Not vacuous: the seeded event really carries it.
    grep -q "$CANARY" "$EVENTS_DIR/$id.jsonl"
}

# _bo_assert_no_canary <id> <events-line-count-before>
_bo_assert_no_canary() {
    local id="$1" before="$2" q hold appended
    q=$(jq -r '.question // ""' "$JOBS_DIR/$id.json")
    [[ "$q" != *"$CANARY"* ]]
    hold=$(jq -c '.operator_hold // {}' "$JOBS_DIR/$id.json")
    [[ "$hold" != *"$CANARY"* ]]
    appended=$(tail -n +"$((before + 1))" "$EVENTS_DIR/$id.jsonl")
    [ -n "$appended" ]    # route-failure did append events
    [[ "$appended" != *"$CANARY"* ]]
}

@test "canary: the back-off path leaks no tail_excerpt into any event it appends" {
    _bo_canary_job "bo-can1" "rate_limited"
    local before; before=$(_ev_lines bo-can1)

    run mother route-failure "bo-can1"
    [ "$status" -eq 0 ]

    assert_job_field "bo-can1" '.state' "ready"
    _bo_assert_no_canary "bo-can1" "$before"
}

@test "canary: the give-up path leaks no tail_excerpt into the question, the hold detail or any event" {
    _bo_canary_job "bo-can2" "rate_limited" ".backoff_count = 4 | .backoff_first_at = $(( $(_now) - 1000 ))"
    local before; before=$(_ev_lines bo-can2)

    run mother route-failure "bo-can2"
    [ "$status" -eq 0 ]

    assert_job_field "bo-can2" '.operator_hold.sub_reason' "backoff_exhausted"
    _bo_assert_no_canary "bo-can2" "$before"
}

@test "canary: the billing and auth_error hold paths leak no tail_excerpt either" {
    local reason
    for reason in billing auth_error; do
        _bo_canary_job "bo-can-$reason" "$reason"
        local before; before=$(_ev_lines "bo-can-$reason")

        run mother route-failure "bo-can-$reason"
        [ "$status" -eq 0 ]

        assert_job_field "bo-can-$reason" '.operator_hold.sub_reason' "$reason"
        _bo_assert_no_canary "bo-can-$reason" "$before"
    done
}

@test "canary: the api_overloaded back-off path leaks no tail_excerpt" {
    _bo_canary_job "bo-can3" "api_overloaded"
    local before; before=$(_ev_lines bo-can3)

    run mother route-failure "bo-can3"
    [ "$status" -eq 0 ]

    _bo_assert_no_canary "bo-can3" "$before"
}

# ---------------------------------------------------------------------------
# Kill switch
# ---------------------------------------------------------------------------

@test "kill switch: MOTHER_BACKOFF_ENABLED=0 escalates a rate_limited / api_overloaded failure as before (no not_before, no pause file)" {
    export MOTHER_BACKOFF_ENABLED=0
    local reason
    for reason in rate_limited api_overloaded; do
        local id="bo-off-$reason"
        _bo_job "$id" "$reason" '.current_tier = "tier_0" | .escalation_count = 0'

        run mother route-failure "$id"
        [ "$status" -eq 0 ]

        assert_job_field "$id" '.state' "ready"
        assert_job_field "$id" '.current_tier' "tier_1"
        assert_job_field "$id" '.escalation_count' "1"
        assert_job_field "$id" '.not_before' "null"
        assert_job_field "$id" '.backoff_count' "null"
        [ "$(_ev "$id" failure_routed | jq -r '.action')" = "escalated" ]
    done
    [ ! -e "$MOTHER_ROOT/ratelimit-until" ]
}

# ===========================================================================
# Dispatcher (mother-runner --dispatch-tick, same harness as low_disk_guard.bats)
# ===========================================================================

# Fake daemon collaborators: mother-run-job is what `_spawn_job` execs; it only
# logs its argument. df is not faked, so the disk guard is switched off.
_dispatch_env() {
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_MIN_FREE_GB=0
    export MOTHER_CONCURRENCY=2
    _FAKE_BIN="$MOTHER_ROOT/fake-bin"
    mkdir -p "$_FAKE_BIN"
    export MOTHER_BIN_DIR="$_FAKE_BIN"
    cat > "$_FAKE_BIN/mother-run-job" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$MOTHER_ROOT/run-job-calls"
exit 0
EOF
    cat > "$_FAKE_BIN/mother" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$MOTHER_ROOT/mother-calls"
exit 0
EOF
    chmod +x "$_FAKE_BIN/mother-run-job" "$_FAKE_BIN/mother"
}

_dispatch_tick() { mother-runner --dispatch-tick >/dev/null 2>&1 || true; }

_wait_for_spawn() {
    local i=0
    while [ ! -s "$MOTHER_ROOT/run-job-calls" ] && [ "$i" -lt 100 ]; do
        sleep 0.1; i=$((i + 1))
    done
    [ -s "$MOTHER_ROOT/run-job-calls" ]
}

# A ready job (oldest first by created_at) with an optional jq filter.
_ready_job() {
    local id="$1" created="${2:-2026-09-01T00:00:00Z}" extra="${3:-.}"
    make_job "$id" "ready" ".created_at = \"$created\" | ($extra)"
}

@test "dispatch: a ready job whose not_before is in the future is not spawned and stays ready" {
    _dispatch_env
    _ready_job "dp-future" "2026-09-01T00:00:00Z" ".not_before = $(( $(_now) + 3600 ))"

    _dispatch_tick

    assert_job_field "dp-future" '.state' "ready"
    [ ! -e "$MOTHER_ROOT/run-job-calls" ]
}

@test "dispatch: a ready job whose not_before has passed (or is null) is spawned" {
    _dispatch_env
    _ready_job "dp-past" "2026-09-01T00:00:00Z" ".not_before = $(( $(_now) - 10 ))"
    _ready_job "dp-null" "2026-09-02T00:00:00Z" ".not_before = null"

    _dispatch_tick
    _wait_for_spawn

    assert_job_field "dp-past" '.state' "running"
    assert_job_field "dp-null" '.state' "running"
}

@test "dispatch: a backed-off job does not hold up a ready job behind it" {
    _dispatch_env
    # The older job is waiting out a back-off; the newer one is free to run.
    _ready_job "dp-waiting" "2026-09-01T00:00:00Z" ".not_before = $(( $(_now) + 3600 ))"
    _ready_job "dp-free" "2026-09-02T00:00:00Z"

    _dispatch_tick
    _wait_for_spawn

    assert_job_field "dp-free" '.state' "running"
    assert_job_field "dp-waiting" '.state' "ready"
    grep -Fq "dp-free" "$MOTHER_ROOT/run-job-calls"
    [ "$(grep -Fc "dp-waiting" "$MOTHER_ROOT/run-job-calls" || true)" = "0" ]
}

@test "dispatch: while ratelimit-until is in the future NO ready job is spawned" {
    _dispatch_env
    echo "$(( $(_now) + 3600 ))" > "$MOTHER_ROOT/ratelimit-until"
    _ready_job "dp-pause-a" "2026-09-01T00:00:00Z"
    _ready_job "dp-pause-b" "2026-09-02T00:00:00Z"

    _dispatch_tick

    assert_job_field "dp-pause-a" '.state' "ready"
    assert_job_field "dp-pause-b" '.state' "ready"
    [ ! -e "$MOTHER_ROOT/run-job-calls" ]
}

@test "dispatch: the shared pause does not touch jobs that are already running" {
    _dispatch_env
    echo "$(( $(_now) + 3600 ))" > "$MOTHER_ROOT/ratelimit-until"
    make_job "dp-busy" "running" '.worker_pid = 999999 | .started_at = "2026-09-01T00:00:00Z"'
    local before; before=$(cat "$JOBS_DIR/dp-busy.json")
    _ready_job "dp-pause-c"

    _dispatch_tick

    [ "$(cat "$JOBS_DIR/dp-busy.json")" = "$before" ]
    assert_job_field "dp-pause-c" '.state' "ready"
}

@test "dispatch: once ratelimit-until is in the past the ready job dispatches, and the pause file is left alone" {
    _dispatch_env
    local past=$(( $(_now) - 30 ))
    echo "$past" > "$MOTHER_ROOT/ratelimit-until"
    _ready_job "dp-expired"

    _dispatch_tick
    _wait_for_spawn

    assert_job_field "dp-expired" '.state' "running"
    [ "$(tr -d '[:space:]' < "$MOTHER_ROOT/ratelimit-until")" = "$past" ]
}

@test "dispatch: a garbage ratelimit-until does not block dispatch" {
    _dispatch_env
    echo "not-a-number" > "$MOTHER_ROOT/ratelimit-until"
    _ready_job "dp-garbage"

    _dispatch_tick
    _wait_for_spawn

    assert_job_field "dp-garbage" '.state' "running"
}

# ===========================================================================
# mother list / mother status
# ===========================================================================

_list_line() { printf '%s\n' "$output" | grep -F "$1"; }

@test "list: a ready job with not_before ~150s away shows [BACKOFF 3m] in its STATE column" {
    make_job "bl-min" "ready" ".not_before = $(( $(_now) + 150 ))"

    run mother list
    [ "$status" -eq 0 ]
    local line; line=$(_list_line "bl-min")
    [[ "$line" =~ \[BACKOFF\ 3m\] ]] || { echo "line: $line" >&2; return 1; }
}

@test "list: under a minute the marker counts seconds ([BACKOFF <N>s])" {
    make_job "bl-sec" "ready" ".not_before = $(( $(_now) + 45 ))"

    run mother list
    [ "$status" -eq 0 ]
    local line; line=$(_list_line "bl-sec")
    [[ "$line" =~ \[BACKOFF\ ([0-9]+)s\] ]] || { echo "line: $line" >&2; return 1; }
    _between "${BASH_REMATCH[1]}" 30 45
}

@test "list: a ready job with a past or no not_before shows no BACKOFF marker" {
    make_job "bl-past" "ready" ".not_before = $(( $(_now) - 60 ))"
    make_job "bl-none" "ready"

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" == *"bl-past"* ]]
    [[ "$output" == *"bl-none"* ]]
    [[ "$output" != *"BACKOFF"* ]]
}

@test "status: mother status <id> mentions BACKOFF for a backed-off job and not for a plain ready one" {
    make_job "bs-wait" "ready" ".not_before = $(( $(_now) + 150 )) | .backoff_count = 1"
    make_job "bs-plain" "ready"

    run mother status "bs-wait"
    [ "$status" -eq 0 ]
    [[ "$output" == *"BACKOFF"* ]]

    run mother status "bs-plain"
    [ "$status" -eq 0 ]
    [[ "$output" != *"BACKOFF"* ]]
}

# ===========================================================================
# Success must mean work happened (a real mother-run-job with tests/mock_claude)
# ===========================================================================

_bo_init_repo() {
    TEST_REPO_DIR="$MOTHER_ROOT/run-repo"
    mkdir -p "$TEST_REPO_DIR"
    (
        cd "$TEST_REPO_DIR"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        git add .
        git commit -q -m "init"
    ) >/dev/null 2>&1
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120
}

_bo_seed_branch() {
    local branch="$1"
    (
        cd "$TEST_REPO_DIR"
        git checkout -q -B "$branch" main
        git commit -q --allow-empty -m "seed for $branch"
        git checkout -q main
    ) >/dev/null 2>&1
}

_bo_run_job_fields() {
    local id="$1" extra="${2:-.}"
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-'"$id"'"
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }
         | ('"$extra"')'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"
}

# A no_pr job with a real seeded commit ahead of base: the old code's idea of "work happened".
_bo_make_no_pr_job() {
    local id="$1"
    _bo_seed_branch "feature/test-$id"
    _bo_run_job_fields "$id" '.no_pr = true'
}

# Failed-event reason of the job's (last) failed transition.
_failed_reason() {
    jq -r 'select(.kind == "failed") | .detail.reason' "$EVENTS_DIR/$1.jsonl" 2>/dev/null | tail -1
}

@test "run-job: a 429 result with the worker exiting 0 is NOT succeeded — failed, failure_reason rate_limited" {
    _bo_init_repo
    _bo_make_no_pr_job "rj-429-exit0"
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_rate_limited_429.jsonl"
    export MOCK_CLAUDE_EXIT=0

    run mother-run-job "rj-429-exit0"

    assert_job_field "rj-429-exit0" '.state' "failed"
    assert_job_field "rj-429-exit0" '.failure_reason' "rate_limited"
    [ "$(_failed_reason rj-429-exit0)" = "rate_limited" ]
    [ "$(_ev_count rj-429-exit0 succeeded)" = "0" ]
}

@test "run-job: a 429 result with the worker exiting 1 is failed, failure_reason rate_limited" {
    _bo_init_repo
    _bo_make_no_pr_job "rj-429-exit1"
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_rate_limited_429.jsonl"
    export MOCK_CLAUDE_EXIT=1

    run mother-run-job "rj-429-exit1"

    assert_job_field "rj-429-exit1" '.state' "failed"
    assert_job_field "rj-429-exit1" '.failure_reason' "rate_limited"
    [ "$(_failed_reason rj-429-exit1)" = "rate_limited" ]
}

@test "run-job: a 529 result with the worker exiting 0 is failed, failure_reason api_overloaded" {
    _bo_init_repo
    _bo_make_no_pr_job "rj-529"
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_overloaded_529.jsonl"
    export MOCK_CLAUDE_EXIT=0

    run mother-run-job "rj-529"

    assert_job_field "rj-529" '.state' "failed"
    assert_job_field "rj-529" '.failure_reason' "api_overloaded"
    [ "$(_failed_reason rj-529)" = "api_overloaded" ]
}

@test "run-job: a job that already has an open PR and no new commit is still not succeeded when the run was rate limited" {
    _bo_init_repo
    local id="rj-429-pr" url="https://github.com/thehammer/mother/pull/9001"
    _bo_seed_branch "feature/test-$id"
    local head; head=$(git -C "$TEST_REPO_DIR" rev-parse "feature/test-$id")
    gh_mock_set_pr "$url" OPEN "feature/test-$id" "$head"
    gh_mock_set_branch_pr "feature/test-$id" "$url"
    _bo_run_job_fields "$id" '.pr_url = "'"$url"'"'
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_rate_limited_429.jsonl"
    export MOCK_CLAUDE_EXIT=0

    run mother-run-job "$id"

    local st; st=$(_jf "$id" '.state')
    [ "$st" != "succeeded" ] || { echo "job became succeeded" >&2; return 1; }
    assert_job_field "$id" '.state' "failed"
    assert_job_field "$id" '.failure_reason' "rate_limited"
    [ "$(_ev_count "$id" succeeded)" = "0" ]
}

@test "run-job control: a normal result (is_error false) from a worker that exits 0 still ends succeeded" {
    _bo_init_repo
    _bo_make_no_pr_job "rj-ok"
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/full_run.jsonl"
    export MOCK_CLAUDE_EXIT=0

    run mother-run-job "rj-ok"

    assert_job_field "rj-ok" '.state' "succeeded"
    assert_job_field "rj-ok" '.failure_reason' "null"
}

@test "end to end: a 429 worker run followed by route-failure backs the job off at tier_0 — it is never escalated" {
    _bo_init_repo
    _bo_make_no_pr_job "rj-e2e"
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_rate_limited_429.jsonl"
    export MOCK_CLAUDE_EXIT=1
    run mother-run-job "rj-e2e"
    assert_job_field "rj-e2e" '.state' "failed"

    local t0; t0=$(_now)
    run mother route-failure "rj-e2e"
    [ "$status" -eq 0 ]
    local t1; t1=$(_now)

    assert_job_field "rj-e2e" '.state' "ready"
    assert_job_field "rj-e2e" '.current_tier' "tier_0"
    assert_job_field "rj-e2e" '.escalation_count' "0"
    assert_job_field "rj-e2e" '.backoff_count' "1"
    _between "$(_jf rj-e2e '.not_before')" $((t0 + 30)) $((t1 + 30))
    [ "$(_ev_count rj-e2e escalated)" = "0" ]
}

# ===========================================================================
# Reviewers: rate limits are errors, never passes, and wait on the pause
# ===========================================================================

_bo_lens_repo() {
    REPO="$MOTHER_ROOT/work/lensrepo"
    mkdir -p "$REPO"
    (
        cd "$REPO"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        git add .
        git commit -q -m "init"
        git checkout -q -b feature/x
        mkdir -p app
        printf '<?php\nfunction provision() { return 1; }\n' > app/Foo.php
        git add .
        git commit -q -m "feature work"
    ) >/dev/null 2>&1
}

# A succeeded job whose work_dir is $REPO (as lenses.bats' _make_lens_job).
_bo_lens_job() {
    local id="$1"
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    make_job "$id" succeeded \
        ".repo = \"lensrepo\" | .repo_path = \"$REPO\" | .work_dir = \"$REPO\" | .base_ref = \"main\" | .branch = \"feature/x\" | .plan_path = \"$MOTHER_ROOT/plans/$id.md\" | .log_path = \"$LOGS_DIR/$id.log\""
    touch "$LOGS_DIR/$id.log"
}

_side_file() { echo "$MOTHER_ROOT/crew/$1/wave/c0/$2.json"; }

_assert_rate_limited_lens() {
    local id="$1" t0="$2"
    [ "$status" -eq 2 ]
    local sf; sf=$(_side_file "$id" correctness)
    [ -f "$sf" ]
    jq -e '.state == "error" and .error_reason == "rate_limited" and (.findings | length) == 0
           and .decision != "ship"' "$sf" >/dev/null
    # Never recorded as a reviewed (clean) lens.
    [ "$(_ev_count "$id" reviewed)" = "0" ]
    # The pause now covers everyone.
    local f="$MOTHER_ROOT/ratelimit-until"
    [ -f "$f" ]
    _is_int "$(tr -d '[:space:]' < "$f")"
    [ "$(tr -d '[:space:]' < "$f")" -gt "$t0" ]
}

@test "review-lens: a rate-limited lens (429, exit 1) is an error lens with error_reason rate_limited, extends the pause and is never a clean pass" {
    _bo_lens_repo
    _bo_lens_job "rv-1"
    export MOTHER_REVIEW_RATELIMIT_RETRIES=0 MOTHER_BACKOFF_BASE_S=1
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_rate_limited_429.jsonl"
    export MOCK_CLAUDE_EXIT=1
    local t0; t0=$(_now)

    run mother review-lens "rv-1" --lens correctness

    _assert_rate_limited_lens "rv-1" "$t0"
}

@test "review-lens: a rate-limited lens whose claude exits 0 is still an error lens (rate_limited)" {
    _bo_lens_repo
    _bo_lens_job "rv-2"
    export MOTHER_REVIEW_RATELIMIT_RETRIES=0 MOTHER_BACKOFF_BASE_S=1
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_rate_limited_429.jsonl"
    export MOCK_CLAUDE_EXIT=0
    local t0; t0=$(_now)

    run mother review-lens "rv-2" --lens correctness

    _assert_rate_limited_lens "rv-2" "$t0"
}

@test "review-lens: with MOTHER_REVIEW_RATELIMIT_RETRIES=1 a rate-limited lens waits out the pause and is re-spawned once, then reports its clean result" {
    _bo_lens_repo
    _bo_lens_job "rv-3"
    export MOTHER_REVIEW_RATELIMIT_RETRIES=1 MOTHER_BACKOFF_BASE_S=1
    # First attempt: a 429. Second attempt: the usual clean lens reply.
    cat > "$_MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
n=\$(cat "$MOTHER_ROOT/claude-n" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "$MOTHER_ROOT/claude-n"
date +%s >> "$MOTHER_ROOT/claude-times"
if [ "\$n" -eq 1 ]; then cat "$FIXTURES/result_rate_limited_429.jsonl"; exit 1; fi
cat "$LENS_FIX/reply_clean.jsonl"
exit 0
EOF
    chmod +x "$_MOCK_BIN/claude"

    run mother review-lens "rv-3" --lens correctness

    [ "$status" -eq 0 ]
    [ "$(cat "$MOTHER_ROOT/claude-n")" = "2" ]
    # The second spawn waited for the pause the first one wrote (base 1s).
    local t_first t_second
    t_first=$(sed -n 1p "$MOTHER_ROOT/claude-times"); t_second=$(sed -n 2p "$MOTHER_ROOT/claude-times")
    [ $((t_second - t_first)) -ge 1 ]
    local sf; sf=$(_side_file "rv-3" correctness)
    jq -e '(.findings | length) == 0 and .decision == "ship" and ((.state // "ok") != "error")' "$sf" >/dev/null
}

@test "review-lens: with ratelimit-until ~3s away the lens waits for the pause to lapse before it invokes claude" {
    _bo_lens_repo
    _bo_lens_job "rv-4"
    # A claude stand-in that notes WHEN it was invoked (total elapsed time would
    # also count mother's own startup, which is not what is being asserted).
    cat > "$_MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
date +%s > "$MOTHER_ROOT/claude-invoked-at"
cat "$LENS_FIX/reply_clean.jsonl"
exit 0
EOF
    chmod +x "$_MOCK_BIN/claude"
    local until=$(( $(_now) + 3 ))
    echo "$until" > "$MOTHER_ROOT/ratelimit-until"

    run mother review-lens "rv-4" --lens correctness

    [ "$status" -eq 0 ]
    [ -f "$MOTHER_ROOT/claude-invoked-at" ]
    # claude only started once the pause had lapsed.
    [ "$(cat "$MOTHER_ROOT/claude-invoked-at")" -ge "$until" ]
    jq -e '.decision == "ship"' "$(_side_file rv-4 correctness)" >/dev/null
}

# --- adherence-review ------------------------------------------------------

# A succeeded job with a PR url, a plan and a suggested_config (as adherence_loop.bats).
_bo_adherence_job() {
    local id="$1" extra="${2:-.}"
    make_job "$id" "succeeded" \
        '.pr_url = "https://github.com/Carefeed/test/pull/42"
         | .adherence_attempts = 0 | .adherence_status = null | .adherence_pending = null
         | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"t"},"redd":{"model":"sonnet","effort":"medium","rationale":"t"},"marty":{"model":"sonnet","effort":"medium","rationale":"t"},"perri":{"model":"sonnet","effort":"medium","rationale":"t"}}
         | ('"$extra"')'
    local plan_file="$EVENTS_DIR/${id}-plan.md"
    cat > "$plan_file" <<'PLAN'
# Test plan

## Context
A test plan.

## Target
- **Repo:** testrepo
- **Branch:** feature/test

## Files to change
- `foo.sh` — add something

## Acceptance criteria
- It works.
PLAN
    _set_job "$id" ".plan_path = \"$plan_file\""
}

@test "adherence-review: a rate-limited review exits 2, records no verdict, does not burn the per-SHA cap and writes the pause" {
    _bo_adherence_job "ad-1" '.adherence_sha_runs = 2 | .adherence_reviewed_sha = "abc123"'
    export MOTHER_REVIEW_RATELIMIT_RETRIES=0 MOTHER_BACKOFF_BASE_S=1
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_rate_limited_429.jsonl"
    export MOCK_CLAUDE_EXIT=1
    # Cost bookkeeping (actual_*) legitimately follows every recorded usage row; everything else must hold.
    local rest='del(.adherence_sha_runs, .actual_cost_usd, .actual_cost_complete, .actual_tokens)'
    local before_rest; before_rest=$(jq -S "$rest" "$JOBS_DIR/ad-1.json")
    local t0; t0=$(_now)

    run mother adherence-review "ad-1"

    [ "$status" -eq 2 ]
    # The runner counted this attempt before spawning; a rate-limited one is handed back.
    assert_job_field "ad-1" '.adherence_sha_runs' "1"
    # Nothing else about the job changed: no verdict, not pending, no attempt consumed.
    assert_job_field "ad-1" '.adherence_status' "null"
    local after_rest; after_rest=$(jq -S "$rest" "$JOBS_DIR/ad-1.json")
    [ "$after_rest" = "$before_rest" ] || { diff <(printf '%s\n' "$before_rest") <(printf '%s\n' "$after_rest") >&2; return 1; }
    [ "$(_ev_count ad-1 adherence_reviewed)" = "0" ]
    # The pause now covers everyone.
    [ -f "$MOTHER_ROOT/ratelimit-until" ]
    [ "$(tr -d '[:space:]' < "$MOTHER_ROOT/ratelimit-until")" -gt "$t0" ]
}

@test "adherence-review: a rate-limited review never takes the per-SHA count below zero" {
    _bo_adherence_job "ad-2" '.adherence_sha_runs = 0'
    export MOTHER_REVIEW_RATELIMIT_RETRIES=0 MOTHER_BACKOFF_BASE_S=1
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_rate_limited_429.jsonl"
    export MOCK_CLAUDE_EXIT=1

    run mother adherence-review "ad-2"
    [ "$status" -eq 2 ]
    assert_job_field "ad-2" '.adherence_sha_runs // 0' "0"

    _bo_adherence_job "ad-3"   # no adherence_sha_runs key at all
    run mother adherence-review "ad-3"
    [ "$status" -eq 2 ]
    assert_job_field "ad-3" '.adherence_sha_runs // 0' "0"
}

# --- the runner's adherence pass -------------------------------------------

# Mock gh for the runner's adherence pass (adherence_loop.bats): PR OPEN, a fixed head.
_bo_adherence_gh() {
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    shift 3
    fields=""
    while [ $# -gt 0 ]; do
        case "$1" in --json) fields="$2"; shift 2 ;; *) shift ;; esac
    done
    case "$fields" in
        state) echo OPEN; exit 0 ;;
        headRefOid) echo "head-sha-1"; exit 0 ;;
    esac
fi
echo "(mock gh output)"
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
}

@test "runner adherence pass: while ratelimit-until is in the future no review is started and the SHA run count is not bumped; after expiry it reviews" {
    _bo_adherence_gh
    _bo_adherence_job "ad-run"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."
    # A short horizon: if the pause is ignored the tick would run (and fail this test) fast.
    echo "$(( $(_now) + 30 ))" > "$MOTHER_ROOT/ratelimit-until"

    run mother-runner --adherence-tick
    [ "$status" -eq 0 ]

    [ "$(_ev_count ad-run adherence_review_spawned)" = "0" ]
    assert_job_field "ad-run" '.adherence_sha_runs // 0' "0"
    assert_job_field "ad-run" '.adherence_status' "null"
    [ ! -s "$MOCK_CLAUDE_ARGS_FILE" ]

    # The pause lapses: the very next pass reviews it.
    echo "$(( $(_now) - 5 ))" > "$MOTHER_ROOT/ratelimit-until"
    run mother-runner --adherence-tick
    [ "$status" -eq 0 ]

    [ "$(_ev_count ad-run adherence_review_spawned)" = "1" ]
    assert_job_field "ad-run" '.adherence_sha_runs' "1"
    assert_job_field "ad-run" '.adherence_status' "passed"
}

# ---------------------------------------------------------------------------
# Pipeline reviewer (review-phase) and retro
# ---------------------------------------------------------------------------

@test "review-phase: a rate-limited reviewer (429 result, exit 0) records no findings and no clean pass, and extends the pause" {
    export TEST_REPO_DIR="$MOTHER_ROOT/testrepo"
    git init -q "$TEST_REPO_DIR"
    git -C "$TEST_REPO_DIR" config user.email t@t.com
    git -C "$TEST_REPO_DIR" config user.name T
    git -C "$TEST_REPO_DIR" commit -q --allow-empty -m init
    make_pipeline_job "rp-1" "cody" '.state = "succeeded"'
    export MOTHER_REVIEW_RATELIMIT_RETRIES=0 MOTHER_BACKOFF_BASE_S=1
    export MOCK_CLAUDE_STDOUT_FILE="$FIXTURES/result_rate_limited_429.jsonl"
    export MOCK_CLAUDE_EXIT=0
    local t0; t0=$(_now)

    run mother review-phase "rp-1" --reviewer perri

    [ "$status" -ne 0 ]
    [ "$(_ev_count rp-1 reviewed)" = "0" ]
    [ "$(_ev_count rp-1 review_failed)" = "1" ]
    [ "$(jq -r 'select(.kind=="review_failed") | .detail.reason' "$EVENTS_DIR/rp-1.jsonl")" = "rate_limited" ]
    jq -e '(.pipeline.reviewer_findings.perri // []) | length == 0' "$JOBS_DIR/rp-1.json" >/dev/null
    [ "$(tr -d '[:space:]' < "$MOTHER_ROOT/ratelimit-until")" -gt "$t0" ]
}

@test "retro: the backoffs table counts jobs backed off, the median wait and give-ups per repo" {
    local recent; recent=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    make_job "bo-a" "ready" '.repo = "repo-x" | .created_at = "'"$recent"'"'
    make_job "bo-b" "awaiting" '.repo = "repo-x" | .created_at = "'"$recent"'"'
    make_job "bo-none" "succeeded" '.repo = "repo-y" | .created_at = "'"$recent"'"'
    _fr_add_event_bo() {
        jq -nc --arg ts "$recent" --arg k "$2" --argjson d "$3" '{ts: $ts, kind: $k, detail: $d}' >> "$EVENTS_DIR/$1.jsonl"
    }
    _fr_add_event_bo bo-a failure_routed '{"action":"backed_off","reason":"rate_limited","delay_s":30,"backoff_count":1}'
    _fr_add_event_bo bo-a failure_routed '{"action":"backed_off","reason":"rate_limited","delay_s":60,"backoff_count":2}'
    _fr_add_event_bo bo-a failure_routed '{"action":"backed_off","reason":"rate_limited","delay_s":120,"backoff_count":3}'
    _fr_add_event_bo bo-b failure_routed '{"action":"backed_off","reason":"rate_limited","delay_s":300,"backoff_count":1}'
    _fr_add_event_bo bo-b failure_routed '{"action":"held","sub_reason":"backoff_exhausted"}'

    run mother-usage retro --root "$MOTHER_ROOT" --since 7d --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c '.backoffs')" = '{"repo-x":{"jobs_backed_off":2,"backoffs":4,"median_wait_s":90.0,"give_ups":1}}' ]
}

@test "backoff: an absurd retry_after_s (a day) is clamped to MOTHER_BACKOFF_RETRY_AFTER_MAX_S (default 3600) so it cannot stall the queue" {
    _bo_job "bo-ra-huge" "rate_limited" . '{"api_error_status":429,"retry_after_s":86400}'
    run mother route-failure "bo-ra-huge"
    [ "$status" -eq 0 ]
    [ "$(_ev "bo-ra-huge" failure_routed | jq -r '.delay_s')" = "3600" ]
    [ "$(tr -d '[:space:]' < "$MOTHER_ROOT/ratelimit-until")" -le $(( $(_now) + 3600 )) ]
}
