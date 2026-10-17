#!/usr/bin/env bats
# decisions.bats — HC-02: structured operator decisions on held jobs.
#
# Contract: docs/design.md "Headless crew contract (Phase 1)".
# A job in `awaiting` may carry `.decision`; `mother resume --option <id>`
# resolves it. These tests are RED until HC-02 is implemented.

load 'test_helper'

setup() {
    setup_mother_env
    unset MOTHER_JOB_ID CLAUDE_SESSION_ID MOTHER_ORIGIN_SESSION CLAUDE_AGENT_NAME
}

teardown() {
    teardown_mother_env
}

# make_job with a decision attached (resolved or not)
_make_decision_job() {
    local id="$1" state="${2:-awaiting}" resolved="${3:-0}"
    local filt res='null' at='null'
    if [ "$resolved" = "1" ]; then
        res='{"option":"cancel","source":"cli","session":"","agent":""}'
        at='"2026-01-01T00:00:00.000Z"'
    fi
    filt=". + {decision: {id:\"d-1\", kind:\"operator_hold\", options:[
      {id:\"resume_with_guidance\",label:\"Resume with guidance\",consequence:\"Job resumes with your text.\",takes_text:true},
      {id:\"escalate\",label:\"Escalate\",consequence:\"Job escalates a tier.\",takes_text:false},
      {id:\"override_open\",label:\"Override\",consequence:\"Job proceeds anyway.\",takes_text:false},
      {id:\"cancel\",label:\"Cancel\",consequence:\"Job is cancelled.\",takes_text:false}],
      opened_at:\"2026-01-01T00:00:00.000Z\", resolved_at:$at, resolution:$res}}"
    make_job "$id" "$state" "$filt"
}

_sum() { # checksum of a file, or "absent"
    if [ -f "$1" ]; then cksum < "$1"; else echo absent; fi
}

_snapshot() { # sets _JOB_SUM _EV_SUM
    _JOB_SUM=$(_sum "$JOBS_DIR/$1.json")
    _EV_SUM=$(_sum "$EVENTS_DIR/$1.jsonl")
}

_assert_unchanged() {
    [ "$(_sum "$JOBS_DIR/$1.json")" = "$_JOB_SUM" ]
    [ "$(_sum "$EVENTS_DIR/$1.jsonl")" = "$_EV_SUM" ]
}

_event() { # _event <id> <kind> -> last matching event JSON
    jq -c --arg k "$2" 'select(.kind==$k)' "$EVENTS_DIR/$1.jsonl" | tail -1
}

# ---------------------------------------------------------------------------

@test "a: --option cancel resolves the decision and cancels the job" {
    _make_decision_job j awaiting
    run mother resume j --option cancel
    [ "$status" -eq 0 ]
    assert_job_field j .state cancelled
    assert_job_field j .decision.resolution.option cancel
    assert_job_field j .decision.resolution.source cli
    [ "$(jq -r '.decision.resolved_at' "$JOBS_DIR/j.json")" != "null" ]
    assert_job_field j .last_answer.option cancel
    ev=$(_event j decision_resolved)
    [ -n "$ev" ]
    [ "$(echo "$ev" | jq -r .detail.option)" = cancel ]
    [ "$(echo "$ev" | jq -r .detail.source)" = cli ]
    [ "$(echo "$ev" | jq -r .detail.decision_id)" = d-1 ]
}

@test "b: plain text answer on a decision job resumes with guidance and records it" {
    _make_decision_job j awaiting
    run mother resume j "please use approach B"
    [ "$status" -eq 0 ]
    assert_job_field j .state ready
    assert_job_field j .pending_answer "please use approach B"
    assert_job_field j .decision.resolution.option resume_with_guidance
    [ "$(jq -r '.decision.resolved_at' "$JOBS_DIR/j.json")" != "null" ]
    ev=$(_event j resumed)
    [ "$(echo "$ev" | jq -r .detail.answer)" = "please use approach B" ]
    [ "$(echo "$ev" | jq -r .detail.option)" = resume_with_guidance ]
    [ "$(echo "$ev" | jq -r .detail.source)" = cli ]
}

@test "c: unknown option is rejected with invalid_state and nothing changes" {
    _make_decision_job j awaiting
    _snapshot j
    run mother resume j --option bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *invalid_state* ]]
    [[ "$output" == *"not offered"* ]]
    _assert_unchanged j
}

@test "d1: already-resolved decision rejects --option with invalid_state, unchanged" {
    _make_decision_job j awaiting 1
    _snapshot j
    run mother resume j --option cancel
    [ "$status" -eq 1 ]
    [[ "$output" == *invalid_state* ]]
    _assert_unchanged j
}

@test "d2: already-resolved decision rejects a plain text answer with invalid_state, unchanged" {
    # The job is still sitting in the hold the decision belongs to.
    _make_decision_job j awaiting 1
    jq '.paused_reason = "operator_hold"' "$JOBS_DIR/j.json" > "$JOBS_DIR/j.tmp" && mv "$JOBS_DIR/j.tmp" "$JOBS_DIR/j.json"
    _snapshot j
    run mother resume j "some text"
    [ "$status" -eq 1 ]
    [[ "$output" == *invalid_state* ]]
    _assert_unchanged j
}

@test "d3: a spent decision does not lock out a later, unrelated awaiting (plain text still works)" {
    # Decision resolved earlier; the job is now awaiting for another reason
    # (e.g. the worker asked a question). Text must resume it as it always did,
    # and the old resolution must not be rewritten.
    _make_decision_job j awaiting 1
    run mother resume j "an answer"
    [ "$status" -eq 0 ]
    assert_job_field j .state ready
    assert_job_field j .pending_answer "an answer"
    assert_job_field j .decision.resolution.option cancel
    assert_job_field j .decision.resolved_at 2026-01-01T00:00:00.000Z
    assert_job_field j .last_answer.source cli
}

@test "e1: resume from inside a Mother job (MOTHER_JOB_ID set) is refused, decision job unchanged" {
    _make_decision_job j awaiting
    _snapshot j
    MOTHER_JOB_ID=other run mother resume j "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *refused* ]]
    _assert_unchanged j
}

@test "e2: resume from inside a Mother job is refused for a decision-less job too" {
    make_job j awaiting
    _snapshot j
    MOTHER_JOB_ID=other run mother resume j "x"
    [ "$status" -ne 0 ]
    [[ "$output" == *refused* ]]
    _assert_unchanged j
}

@test "e3: the worker guard runs before anything else (even a nonexistent job is refused)" {
    MOTHER_JOB_ID=other run mother resume nope "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *refused* ]]
}

@test "e4: cancel is not guarded by MOTHER_JOB_ID" {
    make_job j awaiting
    MOTHER_JOB_ID=other run mother cancel j
    [ "$status" -eq 0 ]
    assert_job_field j .state cancelled
}

@test "f: CLAUDE_SESSION_ID and CLAUDE_AGENT_NAME are attributed on the answer" {
    _make_decision_job j awaiting
    CLAUDE_SESSION_ID=s1 CLAUDE_AGENT_NAME=claudia run mother resume j "go"
    [ "$status" -eq 0 ]
    assert_job_field j .last_answer.session s1
    assert_job_field j .last_answer.agent claudia
    assert_job_field j .decision.resolution.session s1
    assert_job_field j .decision.resolution.agent claudia
}

@test "f2: MOTHER_ORIGIN_SESSION is the session fallback when CLAUDE_SESSION_ID is unset" {
    make_job j awaiting
    MOTHER_ORIGIN_SESSION=os9 run mother resume j "go"
    [ "$status" -eq 0 ]
    assert_job_field j .last_answer.session os9
}

@test "g: job without a decision resumes exactly as before and records last_answer" {
    make_job j awaiting
    run mother resume j "carry on"
    [ "$status" -eq 0 ]
    assert_job_field j .state ready
    assert_job_field j .pending_answer "carry on"
    assert_job_field j .resume_count 1
    [ "$(jq 'has("decision")' "$JOBS_DIR/j.json")" = false ]
    ev=$(_event j resumed)
    [ "$(echo "$ev" | jq -r .detail.answer)" = "carry on" ]
    assert_job_field j .last_answer.source cli
}

@test "h: --option on a decision-less awaiting job is invalid_state, unchanged" {
    make_job j awaiting
    _snapshot j
    run mother resume j --option cancel
    [ "$status" -eq 1 ]
    [[ "$output" == *invalid_state* ]]
    _assert_unchanged j
}

@test "i1: --source/--session/--agent are recorded verbatim" {
    _make_decision_job j awaiting
    run mother resume j --option cancel --source nostromo_app --session x --agent y
    [ "$status" -eq 0 ]
    assert_job_field j .decision.resolution.source nostromo_app
    assert_job_field j .decision.resolution.session x
    assert_job_field j .decision.resolution.agent y
    assert_job_field j .last_answer.source nostromo_app
    assert_job_field j .last_answer.session x
    assert_job_field j .last_answer.agent y
    ev=$(_event j decision_resolved)
    [ "$(echo "$ev" | jq -r .detail.source)" = nostromo_app ]
}

@test "i2: --option escalate with no handler for this hold is invalid_state and leaves the decision open" {
    _make_decision_job j awaiting
    _snapshot j
    run mother resume j --option escalate
    [ "$status" -eq 1 ]
    [[ "$output" == *invalid_state* ]]
    [[ "$output" == *"not supported for this hold"* ]]
    _assert_unchanged j
    [ "$(jq -r '.decision.resolved_at' "$JOBS_DIR/j.json")" = null ]
}

@test "i3: --option override_open with no handler is invalid_state, unchanged" {
    _make_decision_job j awaiting
    _snapshot j
    run mother resume j --option override_open
    [ "$status" -eq 1 ]
    [[ "$output" == *"not supported for this hold"* ]]
    _assert_unchanged j
}

@test "j1: --option resume_with_guidance takes its text from stdin" {
    _make_decision_job j awaiting
    run bash -c "printf 'from stdin' | mother resume j --option resume_with_guidance -"
    [ "$status" -eq 0 ]
    assert_job_field j .state ready
    assert_job_field j .pending_answer "from stdin"
    assert_job_field j .decision.resolution.option resume_with_guidance
}

@test "j2: --option resume_with_guidance without text is an error and changes nothing" {
    _make_decision_job j awaiting
    _snapshot j
    run mother resume j --option resume_with_guidance
    [ "$status" -ne 0 ]
    [[ "$output" != *"unknown flag"* ]]
    _assert_unchanged j
}

# ---------------------------------------------------------------------------
# lib/decision.sh helpers
# ---------------------------------------------------------------------------

_load_decision_lib() {
    source "$_LIB_DIR/state.sh"
    source "$_LIB_DIR/decision.sh"
}

@test "k1: mother_decision_open attaches an unresolved decision, emits decision_opened, prints id" {
    _load_decision_lib
    make_job j awaiting
    id=$(mother_decision_open j operator_hold '["resume_with_guidance","escalate","override_open","cancel"]')
    [[ "$id" =~ ^d-[0-9]+$ ]]
    assert_job_field j .decision.id "$id"
    assert_job_field j .decision.kind operator_hold
    [ "$(jq -r '.decision.opened_at' "$JOBS_DIR/j.json")" != null ]
    [ "$(jq -r '.decision.resolved_at' "$JOBS_DIR/j.json")" = null ]
    [ "$(jq -r '[.decision.options[].id]|join(",")' "$JOBS_DIR/j.json")" = "resume_with_guidance,escalate,override_open,cancel" ]
    # every option is filled in from the constants table
    [ "$(jq '[.decision.options[] | select((.label|length)>0 and (.consequence|length)>0 and (.takes_text|type)=="boolean")] | length' "$JOBS_DIR/j.json")" = 4 ]
    [ "$(jq -r '.decision.options[] | select(.id=="resume_with_guidance") | .takes_text' "$JOBS_DIR/j.json")" = true ]
    [ "$(jq -r '[.decision.options[] | select(.id!="resume_with_guidance") | .takes_text] | any' "$JOBS_DIR/j.json")" = false ]
    ev=$(_event j decision_opened)
    [ "$(echo "$ev" | jq -r .detail.decision_id)" = "$id" ]
    [ "$(echo "$ev" | jq -r .detail.kind)" = operator_hold ]
    [ "$(echo "$ev" | jq -c .detail.options)" = '["resume_with_guidance","escalate","override_open","cancel"]' ]
}

@test "k2: mother_decision_option prints the option object, fails for unknown ids" {
    _load_decision_lib
    make_job j awaiting
    mother_decision_open j operator_hold '["resume_with_guidance","cancel"]' >/dev/null
    run mother_decision_option j resume_with_guidance
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r .id)" = resume_with_guidance ]
    [ "$(echo "$output" | jq -r .takes_text)" = true ]
    [ "$(echo "$output" | jq -r '.label|length>0')" = true ]
    [ "$(echo "$output" | jq -r '.consequence|length>0')" = true ]
    run mother_decision_option j escalate   # real option id, but not offered here
    [ "$status" -ne 0 ]
    run mother_decision_option j bogus
    [ "$status" -ne 0 ]
}

@test "k3: mother_decision_resolve records resolution, last_answer and emits decision_resolved" {
    _load_decision_lib
    make_job j awaiting
    id=$(mother_decision_open j operator_hold '["resume_with_guidance","cancel"]')
    mother_decision_resolve j cancel nostromo_app sess1 agentA
    assert_job_field j .decision.resolution.option cancel
    assert_job_field j .decision.resolution.source nostromo_app
    assert_job_field j .decision.resolution.session sess1
    assert_job_field j .decision.resolution.agent agentA
    [ "$(jq -r '.decision.resolved_at' "$JOBS_DIR/j.json")" != null ]
    assert_job_field j .last_answer.option cancel
    assert_job_field j .last_answer.source nostromo_app
    assert_job_field j .last_answer.session sess1
    assert_job_field j .last_answer.agent agentA
    [ "$(jq -r '.last_answer.at' "$JOBS_DIR/j.json")" != null ]
    ev=$(_event j decision_resolved)
    [ "$(echo "$ev" | jq -r .detail.decision_id)" = "$id" ]
    [ "$(echo "$ev" | jq -r .detail.option)" = cancel ]
    [ "$(echo "$ev" | jq -r .detail.source)" = nostromo_app ]
}
