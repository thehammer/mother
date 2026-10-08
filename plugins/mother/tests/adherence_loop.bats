#!/usr/bin/env bats
# adherence_loop.bats — the adherence-review loop must terminate.
#
# Incident: Archie's pass-verdict notes contained a backslash
# (`App\Support\RequiredConfig`). `mother adherence-review` interpolated the
# notes into a jq filter string, jq errored, so `.adherence_status`,
# `.adherence_pending` and `.adherence_attempts` were never persisted and the
# runner re-reviewed the same job on every tick, forever (1532 Opus reviews).
# The same endless loop happens whenever the verdict cannot be parsed.
#
# Contract under test (all black-box, via `mother-runner --adherence-tick`, a
# mock `gh`, and MOCK_CLAUDE_STDOUT as Archie's reply):
#
#   * verdict notes with backslashes / quotes / newlines / $ / backticks are
#     persisted faithfully and the verdict state is recorded;
#   * a job is reviewed at most MOTHER_ADHERENCE_MAX_RUNS_PER_SHA times
#     (default 3) per PR head SHA; beyond that the runner stops spawning,
#     clears adherence_pending, flags needs_attention
#     {reason: "adherence_loop_capped"} and emits `adherence_capped`;
#   * a new head SHA earns a fresh review budget;
#   * a `passed` job whose head SHA is unchanged is never re-reviewed;
#   * the attention list and `scripts/doctor.sh` surface any job with more than
#     5 `adherence_review_spawned` events in the last hour.

load 'test_helper'

setup() {
    setup_mother_env
    export MOCK_CLAUDE_ARGS_FILE="$MOTHER_ROOT/mock-claude-args"
    unset MOTHER_ADHERENCE_MAX_RUNS_PER_SHA

    # Mock `gh`:
    #   pr view <url> --json state -q .state        -> $MOTHER_ROOT/gh-state (default OPEN)
    #   pr view <url> --json headRefOid -q ...      -> $MOTHER_ROOT/gh-head.<urlkey>,
    #                                                  else $MOTHER_ROOT/gh-head,
    #                                                  else "default-head-sha";
    #                                                  exits 1 if $MOTHER_ROOT/gh-head-fail exists
    #   anything else (pr diff / checks / --comments) -> junk, exit 0
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    url="${3:-}"
    shift 3
    fields=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) fields="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    case "$fields" in
        state)
            if [ -f "$MOTHER_ROOT/gh-state" ]; then cat "$MOTHER_ROOT/gh-state"; else echo OPEN; fi
            exit 0 ;;
        headRefOid)
            [ -f "$MOTHER_ROOT/gh-head-fail" ] && exit 1
            key=$(printf '%s' "$url" | tr -c 'a-zA-Z0-9' '_')
            if [ -f "$MOTHER_ROOT/gh-head.$key" ]; then cat "$MOTHER_ROOT/gh-head.$key"
            elif [ -f "$MOTHER_ROOT/gh-head" ]; then cat "$MOTHER_ROOT/gh-head"
            else echo "default-head-sha"; fi
            exit 0 ;;
    esac
fi
echo "(mock gh output)"
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# helpers

_PR_URL="https://github.com/Carefeed/test/pull/42"

# _make_succeeded_job <id> — succeeded job with a PR url, plan file and
# suggested_config, never reviewed.
_make_succeeded_job() {
    local id="$1"
    make_job "$id" "succeeded" \
        ".pr_url = \"$_PR_URL\" | .adherence_attempts = 0 | .adherence_status = null | .adherence_pending = null | .suggested_config = {\"cody\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"t\"},\"redd\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"t\"},\"marty\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"t\"},\"perri\":{\"model\":\"sonnet\",\"effort\":\"medium\",\"rationale\":\"t\"}}"

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
    local merged
    merged=$(jq --arg p "$plan_file" '.plan_path = $p' "$JOBS_DIR/$id.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/$id.json"
}

# _patch_job <id> <jq-filter> — mutate a job file (test seeding only).
_patch_job() {
    local id="$1" filter="$2" merged
    merged=$(jq "$filter" "$JOBS_DIR/$id.json") && printf '%s' "$merged" > "$JOBS_DIR/$id.json"
}

# _set_head <sha> — what `gh pr view --json headRefOid` returns from now on.
_set_head() { printf '%s\n' "$1" > "$MOTHER_ROOT/gh-head"; }

# _spawns <id> — number of adherence_review_spawned events for the job.
_spawns() { _count_events "$1" adherence_review_spawned; }

_count_events() {
    local f="$EVENTS_DIR/$1.jsonl"
    [ -f "$f" ] || { echo 0; return 0; }
    jq -rs --arg k "$2" '[.[] | select(.kind == $k)] | length' "$f"
}

# _tick [n] — run n adherence ticks (default 1); each must exit 0.
_tick() {
    local n="${1:-1}" i
    for ((i = 0; i < n; i++)); do
        run mother-runner --adherence-tick
        [ "$status" -eq 0 ] || { echo "tick $((i + 1)) failed: $output" >&2; return 1; }
    done
}

# _iso_ago <seconds> — ISO-8601 UTC timestamp N seconds in the past.
_iso_ago() {
    local secs="$1" epoch
    epoch=$(( $(date -u +%s) - secs ))
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%S.000Z
}

# _seed_spawn_events <id> <count> <seconds-ago>
_seed_spawn_events() {
    local id="$1" count="$2" ago="$3" i ts
    ts=$(_iso_ago "$ago")
    for ((i = 0; i < count; i++)); do
        printf '{"ts":"%s","kind":"adherence_review_spawned","detail":{}}\n' "$ts" \
            >> "$EVENTS_DIR/$id.jsonl"
    done
}

# _attention_items_for <id> — adherence_loop attention items for the job.
_attention_items_for() {
    mother status --format json | jq -c --arg id "$1" \
        '[.needs_attention[] | select(.kind == "adherence_loop" and .job_id == $id)]'
}

# Verdict text whose notes are hostile to naive string interpolation.
_NASTY_NOTES='Missing `App\Support\RequiredConfig` per plan; saw "quoted" text, $HOME and $(whoami).
Second line: path C:\tmp\new, literal \n and a trailing backslash \'

_nasty_verdict() {
    printf 'ADHERENCE: %s\nNOTES:\n%s' "$1" "$_NASTY_NOTES"
}

# ---------------------------------------------------------------------------
# 1. Notes containing jq-hostile characters must not lose the verdict

@test "adherence loop: pass verdict with backslash/quote/newline/dollar/backtick notes is recorded and never re-reviewed" {
    _make_succeeded_job "nasty-pass"
    export MOCK_CLAUDE_STDOUT
    MOCK_CLAUDE_STDOUT="$(_nasty_verdict pass)"

    _tick
    assert_job_field "nasty-pass" '.adherence_status' "passed"
    assert_job_field "nasty-pass" '.adherence_pending' "false"
    assert_job_field "nasty-pass" '.adherence_attempts' "1"
    [ "$(_spawns nasty-pass)" = "1" ]

    # The loop must now be quiet: further ticks spawn no further reviews.
    _tick 3
    [ "$(_spawns nasty-pass)" = "1" ]
    assert_job_field "nasty-pass" '.adherence_status' "passed"
}

@test "adherence loop: pass verdict stores the notes verbatim in the adherence_reviewed event" {
    _make_succeeded_job "nasty-pass-ev"
    export MOCK_CLAUDE_STDOUT
    MOCK_CLAUDE_STDOUT="$(_nasty_verdict pass)"

    run mother adherence-review "nasty-pass-ev"
    [ "$status" -eq 0 ]
    assert_job_field "nasty-pass-ev" '.adherence_status' "passed"
    assert_job_field "nasty-pass-ev" '.adherence_attempts' "1"
    assert_event_kind "nasty-pass-ev" "adherence_reviewed"

    local got
    got=$(jq -r 'select(.kind == "adherence_reviewed") | .detail.notes' "$EVENTS_DIR/nasty-pass-ev.jsonl")
    [ "$got" = "$_NASTY_NOTES" ]
}

@test "adherence loop: fail verdict with hostile notes records failed_first, attempts 1 and the exact notes as pending_answer" {
    _make_succeeded_job "nasty-fail"
    export MOCK_CLAUDE_STDOUT
    MOCK_CLAUDE_STDOUT="$(_nasty_verdict fail)"

    _tick
    assert_job_field "nasty-fail" '.adherence_status' "failed_first"
    assert_job_field "nasty-fail" '.adherence_attempts' "1"

    local pa notes
    pa=$(jq -r '.pending_answer' "$JOBS_DIR/nasty-fail.json")
    [ "$pa" = "$_NASTY_NOTES" ]
    notes=$(jq -r '.adherence_notes' "$JOBS_DIR/nasty-fail.json")
    [ "$notes" = "$_NASTY_NOTES" ]

    # Normal first-failure behaviour still applies: re-queued for rework.
    assert_job_field "nasty-fail" '.state' "ready"
    assert_job_field "nasty-fail" '.activity' "cody_rework"
    [ "$(_spawns nasty-fail)" = "1" ]
}

# ---------------------------------------------------------------------------
# 2. Fix-up jobs sharing a PR: each reviewed once, neither starved

@test "adherence loop: two succeeded jobs on the same PR and head SHA are each reviewed exactly once" {
    _make_succeeded_job "shared-a"
    _make_succeeded_job "shared-b"
    _set_head "samesha111"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."

    _tick 6

    [ "$(_spawns shared-a)" = "1" ]
    [ "$(_spawns shared-b)" = "1" ]
    assert_job_field "shared-a" '.adherence_status' "passed"
    assert_job_field "shared-b" '.adherence_status' "passed"
}

@test "adherence loop: a job stuck on an unparsable verdict does not starve a sibling job on the same PR" {
    _make_succeeded_job "stuck-a"
    _make_succeeded_job "stuck-b"
    _set_head "samesha222"
    export MOCK_CLAUDE_STDOUT="garbage"

    _tick 12

    # Each job gets its own capped budget (3) and then stops.
    [ "$(_spawns stuck-a)" = "3" ]
    [ "$(_spawns stuck-b)" = "3" ]
    [ "$(_count_events stuck-a adherence_capped)" = "1" ]
    [ "$(_count_events stuck-b adherence_capped)" = "1" ]
}

# ---------------------------------------------------------------------------
# 3. The cap holds when the verdict never lands

@test "adherence loop: unparsable verdict on an unchanged head is reviewed at most 3 times, then capped and flagged" {
    _make_succeeded_job "cap-default"
    _set_head "stablesha"
    export MOCK_CLAUDE_STDOUT="garbage"

    _tick 6

    [ "$(_spawns cap-default)" = "3" ]
    assert_job_field "cap-default" '.adherence_pending' "false"
    assert_job_field "cap-default" '.needs_attention.reason' "adherence_loop_capped"
    assert_job_field_truthy "cap-default" '.needs_attention.note'
    assert_job_field_truthy "cap-default" '.needs_attention.since'
    [ "$(_count_events cap-default adherence_capped)" = "1" ]
    # The job itself is untouched: still succeeded, nothing requeued.
    assert_job_field "cap-default" '.state' "succeeded"

    # Later ticks stay quiet: no spawn, no repeated cap event, still not pending.
    _tick 4
    [ "$(_spawns cap-default)" = "3" ]
    [ "$(_count_events cap-default adherence_capped)" = "1" ]
    assert_job_field "cap-default" '.adherence_pending' "false"
}

@test "adherence loop: the cap is configurable via MOTHER_ADHERENCE_MAX_RUNS_PER_SHA" {
    _make_succeeded_job "cap-two"
    _set_head "stablesha"
    export MOCK_CLAUDE_STDOUT="garbage"
    export MOTHER_ADHERENCE_MAX_RUNS_PER_SHA=2

    _tick 6

    [ "$(_spawns cap-two)" = "2" ]
    assert_job_field "cap-two" '.needs_attention.reason' "adherence_loop_capped"
    [ "$(_count_events cap-two adherence_capped)" = "1" ]
}

@test "adherence loop: when gh cannot report a head SHA the cap still applies" {
    _make_succeeded_job "cap-nogh"
    : > "$MOTHER_ROOT/gh-head-fail"
    export MOCK_CLAUDE_STDOUT="garbage"

    _tick 6

    [ "$(_spawns cap-nogh)" = "3" ]
    assert_job_field "cap-nogh" '.adherence_pending' "false"
    assert_job_field "cap-nogh" '.needs_attention.reason' "adherence_loop_capped"
    [ "$(_count_events cap-nogh adherence_capped)" = "1" ]
}

@test "adherence loop: the runner records the head SHA and spawn count it reviewed against" {
    _make_succeeded_job "sha-track"
    _set_head "abc123"
    export MOCK_CLAUDE_STDOUT="garbage"

    _tick 1
    assert_job_field "sha-track" '.adherence_reviewed_sha' "abc123"
    assert_job_field "sha-track" '.adherence_sha_runs' "1"

    _tick 1
    assert_job_field "sha-track" '.adherence_reviewed_sha' "abc123"
    assert_job_field "sha-track" '.adherence_sha_runs' "2"
}

# ---------------------------------------------------------------------------
# 4. A new commit earns exactly one fresh review

@test "adherence loop: a new head SHA resets the budget and triggers exactly one more review" {
    _make_succeeded_job "newcommit"
    _patch_job "newcommit" '.adherence_pending = true | .adherence_reviewed_sha = "old" | .adherence_sha_runs = 3 | .adherence_status = null'
    _set_head "new"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
Looks right now."

    _tick 1
    [ "$(_spawns newcommit)" = "1" ]
    assert_job_field "newcommit" '.adherence_reviewed_sha' "new"
    assert_job_field "newcommit" '.adherence_sha_runs' "1"
    assert_job_field "newcommit" '.adherence_status' "passed"
    [ "$(_count_events newcommit adherence_capped)" = "0" ]

    _tick 3
    [ "$(_spawns newcommit)" = "1" ]
}

@test "adherence loop: an exhausted SHA budget is not spent again while the head is unchanged" {
    _make_succeeded_job "exhausted"
    _patch_job "exhausted" '.adherence_pending = true | .adherence_reviewed_sha = "same" | .adherence_sha_runs = 3 | .adherence_status = null'
    _set_head "same"
    export MOCK_CLAUDE_STDOUT="garbage"

    _tick 3

    [ "$(_spawns exhausted)" = "0" ]
    assert_job_field "exhausted" '.adherence_pending' "false"
    assert_job_field "exhausted" '.needs_attention.reason' "adherence_loop_capped"
    [ "$(_count_events exhausted adherence_capped)" = "1" ]
}

# ---------------------------------------------------------------------------
# 5. Passed + unchanged head is never re-reviewed

@test "adherence loop: a passed job with an unchanged head is skipped (head_unchanged) even if pending is set again" {
    _make_succeeded_job "passed-again"
    _patch_job "passed-again" '.adherence_status = "passed" | .adherence_attempts = 1 | .adherence_pending = true | .adherence_reviewed_sha = "abc" | .adherence_sha_runs = 1'
    _set_head "abc"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: fail
NOTES:
Should never be asked."

    _tick 1

    [ "$(_spawns passed-again)" = "0" ]
    assert_job_field "passed-again" '.adherence_pending' "false"
    assert_job_field "passed-again" '.adherence_status' "passed"
    assert_job_field "passed-again" '.state' "succeeded"
    [ "$(_count_events passed-again adherence_skipped)" = "1" ]
    local reason
    reason=$(jq -r 'select(.kind == "adherence_skipped") | .detail.reason' "$EVENTS_DIR/passed-again.jsonl")
    [ "$reason" = "head_unchanged" ]
}

# ---------------------------------------------------------------------------
# 6. Needs-attention surfacing

@test "attention: exactly 5 adherence reviews in the last hour is not flagged" {
    make_job "adh-five" "succeeded" '.pr_url = "https://github.com/x/y/pull/1" | .adherence_status = "passed" | .adherence_pending = false'
    _seed_spawn_events "adh-five" 5 60

    output=$(_attention_items_for "adh-five")
    [ "$(printf '%s' "$output" | jq 'length')" = "0" ]
}

@test "attention: more than 5 adherence reviews in the last hour is flagged as adherence_loop" {
    make_job "adh-six" "succeeded" '.pr_url = "https://github.com/x/y/pull/1" | .adherence_status = "passed" | .adherence_pending = false'
    _seed_spawn_events "adh-six" 6 60

    output=$(_attention_items_for "adh-six")
    [ "$(printf '%s' "$output" | jq 'length')" = "1" ]
    [ "$(printf '%s' "$output" | jq -r '.[0].job_id')" = "adh-six" ]
    [ "$(printf '%s' "$output" | jq -r '.[0].reason | test("adherence"; "i")')" = "true" ]
}

@test "attention: six adherence reviews older than an hour are not flagged" {
    make_job "adh-old" "succeeded" '.pr_url = "https://github.com/x/y/pull/1" | .adherence_status = "passed" | .adherence_pending = false'
    _seed_spawn_events "adh-old" 6 10800

    output=$(_attention_items_for "adh-old")
    [ "$(printf '%s' "$output" | jq 'length')" = "0" ]
}

@test "attention: only reviews inside the one-hour window count toward the threshold" {
    make_job "adh-mixed" "succeeded" '.pr_url = "https://github.com/x/y/pull/1" | .adherence_status = "passed" | .adherence_pending = false'
    _seed_spawn_events "adh-mixed" 10 10800
    _seed_spawn_events "adh-mixed" 3 120

    output=$(_attention_items_for "adh-mixed")
    [ "$(printf '%s' "$output" | jq 'length')" = "0" ]
}

@test "attention: the adherence_loop item is published to attention.json by the daemon tick" {
    make_job "adh-tick" "succeeded" '.pr_url = "https://github.com/x/y/pull/1" | .adherence_status = "passed" | .adherence_pending = false'
    _seed_spawn_events "adh-tick" 7 30

    run mother-runner --attention-tick
    [ "$status" -eq 0 ]
    [ -f "$MOTHER_ROOT/attention.json" ]
    [ "$(jq -r '[.[] | select(.kind == "adherence_loop" and .job_id == "adh-tick")] | length' "$MOTHER_ROOT/attention.json")" = "1" ]
}

@test "attention: a job capped by the runner surfaces as needs-attention without any hand-seeding" {
    _make_succeeded_job "adh-e2e"
    _set_head "stablesha"
    export MOCK_CLAUDE_STDOUT="garbage"
    _tick 5

    run mother status --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '[.needs_attention[] | select(.job_id == "adh-e2e")] | length')" -ge 1 ]
}

# ---------------------------------------------------------------------------
# doctor

@test "doctor: reports a job with more than 5 adherence reviews in the last hour" {
    make_job "adh-doctor-job" "succeeded" '.pr_url = "https://github.com/x/y/pull/1" | .adherence_status = "passed" | .adherence_pending = false'
    _seed_spawn_events "adh-doctor-job" 8 45

    run bash "$_PLUGIN_DIR/scripts/doctor.sh"
    # doctor's exit status reflects missing tools on the host; only the
    # report content matters here.
    printf '%s\n' "$output" | grep -i 'adherence' | grep -q 'adh-doctor-job'
}
