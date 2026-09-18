#!/usr/bin/env bats
# resume_continuity.bats — behavioral contract for carrying an operator's
# `mother resume` answer forward through idle-timeout continuations.
#
# Bug: .claude/bugs/open/2026-09-10-resume-answer-lost-when-worker-idle-times-out-before-acting-continuation-prompt-omits-it.md
#
# None of the functions under test exist yet in lib/state.sh. Every test in
# this file is expected to FAIL (red) until Cody implements them. This file
# IS the acceptance bar for that work — do not weaken an assertion because
# the implementation doesn't exist; that's the point of red/green.
#
# Functions under test (all in plugins/mother/lib/state.sh):
#   _iso_to_epoch <iso8601>
#   _resume_qa_history <job-id>
#   _resume_not_yet_acted_on <job-id> <work_dir>
#   _continuation_preamble <job-id> <attempt> <max> <reason> <git_log_summary> <not_acted_flag>
#
# Required-case index -> test name:
#   1  missing/empty events file                      "1: _resume_qa_history returns nothing..."
#   2  no resumed event at all                         "2: _resume_qa_history returns nothing..."
#   3  one Q&A pair, labelled most recent               "3: _resume_qa_history renders one Q&A pair..."
#   4  verbatim fidelity (fences/backticks/$/%%/quotes) "4: _resume_qa_history preserves multi-line..."
#   5  two Q&A pairs, chronological, only last "most recent" "5: _resume_qa_history renders two Q&A pairs..."
#   6  resumed with no preceding question               "6: _resume_qa_history renders a resumed event..."
#   7  awaiting_input via notes, no question key         "7: _resume_qa_history falls back to notes..."
#   8  no resumed_at at all                              "8: _resume_not_yet_acted_on exits 1..."
#   9  resumed 60s before a later... (commit before answer -> detected) "9: _resume_not_yet_acted_on detects..."
#   10 commit postdates resume -> not detected           "10: _resume_not_yet_acted_on does not detect..."
#   11 work_dir missing/unusable -> detected, "0 " prefix "11: _resume_not_yet_acted_on detects when work_dir..."
#   12 not_acted_flag=1 -> warning present, ordered       "12: _continuation_preamble includes the operator's..."
#   13 not_acted_flag=0 with history -> warning absent    "13: _continuation_preamble omits the unresolved..."
#   14 no resume history at all -> regression, no Q&A/warning "14: _continuation_preamble with no resume history..."

load 'test_helper'

setup() {
    setup_mother_env
    source "$_LIB_DIR/state.sh"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Append one raw event line to a job's events file.
# Usage: _append_test_event <id> <kind> <detail-json> [ts]
_append_test_event() {
    local id="$1" kind="$2" detail="$3" ts="${4:-$(date -u +%Y-%m-%dT%H:%M:%S.000Z)}"
    jq -nc --arg ts "$ts" --arg kind "$kind" --argjson detail "$detail" \
        '{ts:$ts, kind:$kind, detail:$detail}' >> "$EVENTS_DIR/$id.jsonl"
}

# Real, throwaway one-commit git repo (never mocked — these are the safety
# net for real commit-timestamp math). Usage: _make_resume_repo <repo_dir>
_make_resume_repo() {
    local repo_dir="$1"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" commit -q --allow-empty -m init
}

# Convert a Unix epoch to an RFC3339 millisecond timestamp, matching the
# format _iso_now produces. Mirrors the existing epoch<->ISO idiom used
# elsewhere in this repo (see bin/mother's cutoff_iso / bin/mother-run-job's
# started_epoch conversions): BSD `date -r` on macOS, GNU `date -d @epoch`
# as the portable fallback.
_epoch_to_iso() {
    local epoch="$1"
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null
}

# ===========================================================================
# _iso_to_epoch — light direct-call sanity (not part of the numbered index;
# this function is mostly exercised indirectly via _resume_not_yet_acted_on).
# ===========================================================================

@test "_iso_to_epoch: parses a millisecond RFC3339 timestamp" {
    run _iso_to_epoch "2026-09-09T21:05:31.456Z"
    [ "$status" -eq 0 ]
    [ "$output" -gt 0 ]
}

@test "_iso_to_epoch: parses a second-precision RFC3339 timestamp" {
    run _iso_to_epoch "2026-09-09T21:05:31Z"
    [ "$status" -eq 0 ]
    [ "$output" -gt 0 ]
}

@test "_iso_to_epoch: echoes 0 for empty or unparseable input" {
    run _iso_to_epoch ""
    [ "$output" = "0" ]
    run _iso_to_epoch "not-a-timestamp"
    [ "$output" = "0" ]
}

# ===========================================================================
# _resume_qa_history
# ===========================================================================

@test "1: _resume_qa_history returns nothing and exits 1 when the events file is missing" {
    make_job "qa-missing"
    run _resume_qa_history "qa-missing"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "2: _resume_qa_history returns nothing and exits 1 when there is no resumed event" {
    make_job "qa-no-resume"
    _append_test_event "qa-no-resume" "awaiting_input" '{"question":"Should we do X or Y?"}'
    run _resume_qa_history "qa-no-resume"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "3: _resume_qa_history renders one Q&A pair labelled most recent" {
    make_job "qa-one-pair"
    _append_test_event "qa-one-pair" "awaiting_input" '{"question":"Should we do X or Y?"}'
    _append_test_event "qa-one-pair" "resumed" '{"answer":"Do X."}'

    run _resume_qa_history "qa-one-pair"
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Operator Answers"* ]]
    [[ "$output" == *"Should we do X or Y?"* ]]
    [[ "$output" == *"Do X."* ]]
    [[ "$output" == *"Q&A 1 (most recent)"* ]]
}

@test "4: _resume_qa_history preserves a multi-line, fenced, quoted, \$-and-%-bearing answer byte-for-byte" {
    make_job "qa-verbatim"
    local answer_text
    answer_text=$(cat <<'EOF'
Use envelope-first precedence, NOT header-first.
SENTINEL_MARKER_9f3a
```bash
echo "cost is 5% of $BUDGET"
```
Say "yes" exactly.
EOF
)
    _append_test_event "qa-verbatim" "awaiting_input" '{"question":"Envelope or header first?"}'
    local detail
    detail=$(jq -nc --arg a "$answer_text" '{answer:$a}')
    _append_test_event "qa-verbatim" "resumed" "$detail"

    run _resume_qa_history "qa-verbatim"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$answer_text"* ]]
}

@test "5: _resume_qa_history renders two Q&A pairs in chronological order, only the second labelled most recent" {
    make_job "qa-two-pairs"
    _append_test_event "qa-two-pairs" "awaiting_input" '{"question":"First question?"}'
    _append_test_event "qa-two-pairs" "resumed" '{"answer":"First answer."}'
    _append_test_event "qa-two-pairs" "awaiting_input" '{"question":"Second question?"}'
    _append_test_event "qa-two-pairs" "resumed" '{"answer":"Second answer."}'

    run _resume_qa_history "qa-two-pairs"
    [ "$status" -eq 0 ]
    [[ "$output" == *"First question?"* ]]
    [[ "$output" == *"First answer."* ]]
    [[ "$output" == *"Second question?"* ]]
    [[ "$output" == *"Second answer."* ]]
    [[ "$output" == *"Q&A 1 —"* ]]
    [[ "$output" != *"Q&A 1 (most recent)"* ]]
    [[ "$output" == *"Q&A 2 (most recent)"* ]]

    # Chronological order: the Q&A 1 heading must appear before Q&A 2's.
    local before_second="${output%%Q&A 2*}"
    [[ "$before_second" == *"Q&A 1"* ]]
}

@test "6: _resume_qa_history renders a resumed event with no preceding question as (no question recorded)" {
    make_job "qa-orphan-resume"
    _append_test_event "qa-orphan-resume" "resumed" '{"answer":"Answer with no question."}'

    run _resume_qa_history "qa-orphan-resume"
    [ "$status" -eq 0 ]
    [[ "$output" == *"_(no question recorded)_"* ]]
    [[ "$output" == *"Answer with no question."* ]]
}

@test "7: _resume_qa_history falls back to notes when awaiting_input carries no question key" {
    make_job "qa-notes-fallback"
    _append_test_event "qa-notes-fallback" "awaiting_input" \
        '{"notes":"Archie flagged a design gap.","paused_reason":"adherence_blocked"}'
    _append_test_event "qa-notes-fallback" "resumed" '{"answer":"Fixed the gap."}'

    run _resume_qa_history "qa-notes-fallback"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Archie flagged a design gap."* ]]
    [[ "$output" == *"Fixed the gap."* ]]
}

# ===========================================================================
# _resume_not_yet_acted_on
# ===========================================================================

@test "8: _resume_not_yet_acted_on exits 1 when the job has no resumed_at" {
    make_job "rnyao-no-resumed-at" "succeeded" '.resumed_at = null'
    run _resume_not_yet_acted_on "rnyao-no-resumed-at" "$MOTHER_ROOT/does-not-exist-for-8"
    [ "$status" -eq 1 ]
}

@test "9: _resume_not_yet_acted_on detects an answer with no later commit (resume postdates last commit)" {
    local repo_dir="$MOTHER_ROOT/repo-rnyao-9"
    _make_resume_repo "$repo_dir"
    local commit_epoch commit_sha
    commit_epoch=$(git -C "$repo_dir" log -1 --format=%ct)
    commit_sha=$(git -C "$repo_dir" log -1 --format=%h)
    local resumed_iso
    resumed_iso=$(_epoch_to_iso $((commit_epoch + 60)))

    make_job "rnyao-9" "running" ".resumed_at = \"$resumed_iso\""

    run _resume_not_yet_acted_on "rnyao-9" "$repo_dir"
    [ "$status" -eq 0 ]
    [ "$output" = "$commit_epoch $commit_sha" ]
}

@test "10: _resume_not_yet_acted_on does not detect when a commit postdates the resume" {
    local repo_dir="$MOTHER_ROOT/repo-rnyao-10"
    _make_resume_repo "$repo_dir"
    local commit_epoch
    commit_epoch=$(git -C "$repo_dir" log -1 --format=%ct)
    local resumed_iso
    resumed_iso=$(_epoch_to_iso $((commit_epoch - 60)))

    make_job "rnyao-10" "running" ".resumed_at = \"$resumed_iso\""

    run _resume_not_yet_acted_on "rnyao-10" "$repo_dir"
    [ "$status" -eq 1 ]
}

@test "11: _resume_not_yet_acted_on detects when work_dir does not exist, echoing a zero epoch" {
    local missing_dir="$MOTHER_ROOT/does-not-exist-11"
    local resumed_iso
    resumed_iso=$(_epoch_to_iso $(($(date -u +%s) - 3600)))

    make_job "rnyao-11" "running" ".resumed_at = \"$resumed_iso\""

    run _resume_not_yet_acted_on "rnyao-11" "$missing_dir"
    [ "$status" -eq 0 ]
    [[ "$output" == "0 "* ]]
}

# ===========================================================================
# _continuation_preamble
# ===========================================================================

@test "12: _continuation_preamble includes the operator's answer and an unresolved-answer warning when not_acted_flag=1" {
    make_job "preamble-12" "running" '.branch = "feature/preamble-12"'
    _append_test_event "preamble-12" "awaiting_input" '{"question":"Envelope or header first?"}'
    _append_test_event "preamble-12" "resumed" '{"answer":"Use envelope-first precedence, full stop."}'

    run _continuation_preamble "preamble-12" 2 3 "idle_timeout" "abc1234 do the thing" 1
    [ "$status" -eq 0 ]

    [[ "$output" == *"# Continuation (attempt 2 of 3)"* ]]
    [[ "$output" == *'`feature/preamble-12`'* ]]
    [[ "$output" == *"abc1234 do the thing"* ]]
    [[ "$output" == *"Use envelope-first precedence, full stop."* ]]
    [[ "$output" == *"### ⚠️ The operator's answer may not have been implemented yet"* ]]
    [[ "$output" == *"## Original Plan"* ]]

    # Ordering: answer text, then the warning, then the trailing heading.
    local after_answer="${output#*"Use envelope-first precedence, full stop."}"
    [[ "$after_answer" == *"### ⚠️ The operator's answer may not have been implemented yet"* ]]
    local after_warning="${after_answer#*"### ⚠️ The operator's answer may not have been implemented yet"}"
    [[ "$after_warning" == *"## Original Plan"* ]]
}

@test "13: _continuation_preamble omits the unresolved-answer warning when not_acted_flag=0" {
    make_job "preamble-13" "running" '.branch = "feature/preamble-13"'
    _append_test_event "preamble-13" "awaiting_input" '{"question":"Envelope or header first?"}'
    _append_test_event "preamble-13" "resumed" '{"answer":"Use envelope-first precedence, full stop."}'

    run _continuation_preamble "preamble-13" 1 3 "idle_timeout" "abc1234 do the thing" 0
    [ "$status" -eq 0 ]

    [[ "$output" == *"## Operator Answers"* ]]
    [[ "$output" == *"Use envelope-first precedence, full stop."* ]]
    [[ "$output" != *"### ⚠️ The operator's answer may not have been implemented yet"* ]]
}

@test "14: _continuation_preamble with no resume history and not_acted_flag=0 renders the plain continuation preamble" {
    make_job "preamble-14" "running" '.branch = "feature/preamble-14"'

    run _continuation_preamble "preamble-14" 1 3 "idle_timeout" "def5678 other work" 0
    [ "$status" -eq 0 ]

    [[ "$output" != *"## Operator Answers"* ]]
    [[ "$output" != *"### ⚠️ The operator's answer may not have been implemented yet"* ]]
    [[ "$output" == *"# Continuation (attempt 1 of 3)"* ]]
    [[ "$output" == *"def5678 other work"* ]]
    [[ "$output" == *"Resume from the first uncommitted step"* ]]
    [[ "$output" == *"## Original Plan"* ]]
}

# ===========================================================================
# Adherence-prompt wiring (mother adherence-review <id>)
# ===========================================================================

# Helper: a succeeded job with a plan file and pr_url, ready for
# `mother adherence-review`. Mirrors adherence.bats' _make_succeeded_job.
_make_resume_adherence_job() {
    local id="$1"
    make_job "$id" "succeeded" \
        '.pr_url = "https://github.com/Carefeed/test/pull/1" | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"t"},"redd":{"model":"sonnet","effort":"medium","rationale":"t"},"marty":{"model":"sonnet","effort":"medium","rationale":"t"},"perri":{"model":"sonnet","effort":"medium","rationale":"t"}}'
    local plan_file; plan_file=$(_plan_path "$id")
    cat > "$plan_file" <<'PLAN'
# Test plan

## Context
A test plan.

## Target
- **Repo:** testrepo
- **Branch:** feature/test

## Files to change
- `foo.sh` — add something

## Approach
1. Do the thing.

## Acceptance criteria
- It works.

## Out of scope
- Nothing.
PLAN
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
echo "(mock gh output)"
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
}

@test "15: adherence-review passes the verbatim operator answer to Archie via an Operator Answers section" {
    _make_resume_adherence_job "adh-resume-15"
    _append_test_event "adh-resume-15" "awaiting_input" '{"question":"Envelope or header first?"}'
    _append_test_event "adh-resume-15" "resumed" '{"answer":"Use envelope-first precedence, full stop."}'

    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."

    run mother adherence-review "adh-resume-15"
    [ "$status" -eq 0 ]

    run cat "$MOCK_CLAUDE_ARGS_FILE"
    [[ "$output" == *"## Operator Answers"* ]]
    [[ "$output" == *"Use envelope-first precedence, full stop."* ]]
}

@test "16: adherence-review with no resume events records (none recorded) and still passes" {
    _make_resume_adherence_job "adh-resume-16"

    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
All good."

    run mother adherence-review "adh-resume-16"
    [ "$status" -eq 0 ]

    run cat "$MOCK_CLAUDE_ARGS_FILE"
    [[ "$output" == *"(none recorded"* ]]
}

# ===========================================================================
# `mother status` banner
# ===========================================================================

@test "17: mother status shows the RESUME-MAY-BE-UNAPPLIED banner when the flag is true" {
    make_job "status-flag-true" "running" '.resume_not_yet_acted_on = true'

    run mother status "status-flag-true"
    [ "$status" -eq 0 ]
    [[ "$output" == *"RESUME-MAY-BE-UNAPPLIED"* ]]
}

@test "18: mother status omits the RESUME-MAY-BE-UNAPPLIED banner when the flag is absent" {
    make_job "status-flag-absent" "running"

    run mother status "status-flag-absent"
    [ "$status" -eq 0 ]
    [[ "$output" != *"RESUME-MAY-BE-UNAPPLIED"* ]]
}
