#!/usr/bin/env bats
# retro.bats — tests for `mother retro` / `mother-usage retro`.
#
# Builds a small synthetic $MOTHER_ROOT (mix of live jobs/ and
# archive/YYYY-MM/ jobs) covering the scenarios `mother retro` is supposed to
# summarize, then asserts on both the human-readable table output and
# --format json.
#
# Ambiguity flagged for reconciliation: the exact flag surface of `mother
# retro` (bin/mother's cmd_retro) vs `mother-usage retro` (the actual
# analysis engine) is spec'd loosely ("cmd_retro execs mother-usage retro
# --root $MOTHER_ROOT ... after a best-effort publish-rates"). These tests
# call `mother-usage retro --root "$MOTHER_ROOT" ...` directly for the
# --format json / --backfill / --since assertions (so they don't depend on
# cmd_retro's exact passthrough flag names), and separately call `mother
# retro` for the human-format table-titles assertion and to confirm the
# subcommand exists and wires through at all. If cmd_retro's flags end up
# named differently than `--since`/`--backfill`/`--format`, only the `mother
# retro` (not `mother-usage retro`) assertions below would need adjusting.

load 'test_helper'
load 'gh_mock'

setup() {
    setup_mother_env
    export METRICS_DIR="$MOTHER_ROOT/metrics"
    mkdir -p "$METRICS_DIR"
}

teardown() {
    teardown_mother_env
}

# ISO-8601 UTC timestamp N days before now. Tries BSD date (macOS) then GNU
# date, mirroring the repo's existing stat -f/-c portability pattern.
_days_ago() {
    local n="$1"
    date -u -v-"${n}"d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
        || date -u -d "-${n} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_append_metrics_line() {
    printf '%s\n' "$1" >> "$METRICS_DIR/runs.jsonl"
}

# ---------------------------------------------------------------------------
# Build the synthetic fleet. Six-ish jobs:
#   1. job-plain-succeeded    — live, succeeded, schema-2 runs.jsonl row.
#   2. job-legacy-failed      — live, failed, legacy bare {"reason":null}
#                                failed event + a log with reclassifiable
#                                tail text (rate-limit).
#   3. job-escalated          — live, succeeded, escalation_count=1,
#                                current_tier=tier_1.
#   4. job-adherence          — live, succeeded, adherence_status=passed
#                                after a prior failed_first, with a
#                                stage:"adherence" runs.jsonl row.
#   5. job-awaiting-costcap   — live, awaiting, paused_reason=cost_cap.
#   6. job-teardown-archived  — archived (archive/YYYY-MM/), terminal, with
#                                a pending teardown record in
#                                teardown-pending/.
#   7. job-out-of-window      — live, succeeded, created_at far in the past
#                                (excluded by --since).

_build_fleet() {
    local recent old
    recent=$(_days_ago 1)
    old=$(_days_ago 90)

    # 1. Plain succeeded job.
    make_job "job-plain-succeeded" "succeeded" \
        '.created_at = "'"$recent"'" | .finished_at = "'"$recent"'" | .pr_url = "https://github.com/x/y/pull/1"'
    _append_metrics_line "$(jq -nc --arg ts "$recent" '{
        ts: $ts, job_id: "job-plain-succeeded", stage: "cody", model: "sonnet",
        effort: "medium", tier: "tier_0", outcome: "succeeded", retry_count: 0,
        escalation_count: 0, wall_time_seconds: 600, log_size_bytes: 1000,
        tokens_in: 5000, tokens_out: 800, pr_url: "https://github.com/x/y/pull/1"
    }')"

    # 2. Legacy failed job — bare {"reason":null}, reclassifiable from log tail.
    make_job "job-legacy-failed" "failed" \
        '.created_at = "'"$recent"'" | .finished_at = "'"$recent"'" | .log_path = "'"$LOGS_DIR/job-legacy-failed.log"'"'
    cat > "$LOGS_DIR/job-legacy-failed.log" <<'EOF'
=== mother job job-legacy-failed starting ===
{"type":"assistant","message":{"id":"msg_1","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":20}}}
Error: 429 rate limit exceeded
EOF
    printf '%s\n' "$(jq -nc --arg ts "$recent" '{ts: $ts, kind: "failed", detail: {reason: null}}')" \
        >> "$EVENTS_DIR/job-legacy-failed.jsonl"

    # 3. Escalated-then-succeeded job.
    make_job "job-escalated" "succeeded" \
        '.created_at = "'"$recent"'" | .finished_at = "'"$recent"'"
         | .escalation_count = 1 | .current_tier = "tier_1"
         | .pr_url = "https://github.com/x/y/pull/3"'
    _append_metrics_line "$(jq -nc --arg ts "$recent" '{
        ts: $ts, job_id: "job-escalated", stage: "cody", model: "sonnet",
        effort: "high", tier: "tier_1", outcome: "succeeded", retry_count: 0,
        escalation_count: 1, wall_time_seconds: 900, log_size_bytes: 2000,
        tokens_in: 8000, tokens_out: 1200, pr_url: "https://github.com/x/y/pull/3"
    }')"

    # 4. Adherence-reviewed job: failed_first, then passed.
    make_job "job-adherence" "succeeded" \
        '.created_at = "'"$recent"'" | .finished_at = "'"$recent"'"
         | .adherence_status = "passed" | .adherence_attempts = 2
         | .pr_url = "https://github.com/x/y/pull/4"'
    _append_metrics_line "$(jq -nc --arg ts "$recent" '{
        ts: $ts, job_id: "job-adherence", stage: "adherence", model: "sonnet",
        effort: "medium", tier: "tier_0", outcome: "succeeded", retry_count: 0,
        escalation_count: 0, wall_time_seconds: 300, log_size_bytes: 500,
        tokens_in: 2000, tokens_out: 400, pr_url: "https://github.com/x/y/pull/4"
    }')"

    # 5. Awaiting, cost-cap-paused job.
    make_job "job-awaiting-costcap" "awaiting" \
        '.created_at = "'"$recent"'" | .paused_reason = "cost_cap"
         | .max_cost_usd = 5.00 | .actual_cost_usd = 5.10'

    # 6. Archived job with a pending teardown record.
    local ym dest_dir
    ym=$(printf '%s' "$recent" | cut -c1-7)
    dest_dir="$ARCHIVE_DIR/$ym"
    mkdir -p "$dest_dir"
    jq -n --arg ts "$recent" --arg id "job-teardown-archived" '{
        id: $id, title: "archived job", repo: "testrepo", state: "succeeded",
        created_at: $ts, finished_at: $ts, pr_url: "https://github.com/x/y/pull/6"
    }' > "$dest_dir/job-teardown-archived.json"
    touch "$dest_dir/job-teardown-archived.events.jsonl"
    jq -n --arg id "job-teardown-archived" '{
        id: $id, repo_path: "/tmp/testrepo", branch: "feature/x",
        work_dir: "/tmp/testrepo-wt", isolation: "worktree",
        pr_url: "https://github.com/x/y/pull/6", state: "succeeded",
        no_pr: false, deferrals: 2, stall_deferrals: 0
    }' > "$TEARDOWN_DIR/job-teardown-archived.json"

    # 7. Out-of-window job (90 days old) — must be excluded by --since 7d.
    make_job "job-out-of-window" "succeeded" \
        '.created_at = "'"$old"'" | .finished_at = "'"$old"'"'
    _append_metrics_line "$(jq -nc --arg ts "$old" '{
        ts: $ts, job_id: "job-out-of-window", stage: "cody", model: "sonnet",
        effort: "medium", tier: "tier_0", outcome: "succeeded", retry_count: 0,
        escalation_count: 0, wall_time_seconds: 100, log_size_bytes: 100,
        tokens_in: 100, tokens_out: 10, pr_url: null
    }')"
}

# ===========================================================================
# Table-format titles
# ===========================================================================

@test "mother retro: table output contains the expected section titles" {
    _build_fleet
    run mother retro --since 7d
    [ "$status" -eq 0 ]

    for title in "outcome" "failure reason" "escalation" "adherence" "await" \
                 "token" "cost" "turn" "context" "wall" "repo" "teardown" "perri"; do
        printf '%s\n' "$output" | grep -qi "$title" \
            || { echo "missing section matching /$title/i in retro output" >&2; return 1; }
    done
}

# ===========================================================================
# --format json recognizable keys
# ===========================================================================

@test "mother-usage retro --format json: outcomes key present with first-attempt success count" {
    _build_fleet
    run mother-usage retro --root "$MOTHER_ROOT" --since 7d --format json
    [ "$status" -eq 0 ]
    has_outcomes=$(printf '%s' "$output" | jq 'has("outcomes")')
    [ "$has_outcomes" = "true" ]
    fas=$(printf '%s' "$output" | jq -r '.outcomes.first_attempt_success')
    [ -n "$fas" ] && [ "$fas" != "null" ]
}

@test "mother-usage retro --format json: failure_reasons includes the reclassified legacy failure" {
    _build_fleet
    run mother-usage retro --root "$MOTHER_ROOT" --since 7d --format json
    [ "$status" -eq 0 ]
    reasons=$(printf '%s' "$output" | jq -r '.failure_reasons | keys[]' 2>/dev/null)
    [[ "$reasons" == *"rate_limited"* ]]
}

@test "mother-usage retro --format json: adherence block reports a first-pass fail rate" {
    _build_fleet
    run mother-usage retro --root "$MOTHER_ROOT" --since 7d --format json
    [ "$status" -eq 0 ]
    has_key=$(printf '%s' "$output" | jq '.adherence | has("first_pass_fail_rate")')
    [ "$has_key" = "true" ]
}

@test "mother-usage retro --format json: tokens/cost broken out by actor" {
    _build_fleet
    run mother-usage retro --root "$MOTHER_ROOT" --since 7d --format json
    [ "$status" -eq 0 ]
    has_by_actor=$(printf '%s' "$output" | jq '(.tokens_cost.by_actor // .tokens.by_actor // .cost.by_actor // .tokens_by_actor // .cost_by_actor) != null')
    [ "$has_by_actor" = "true" ]
}

# ===========================================================================
# --backfill idempotence
# ===========================================================================

@test "mother-usage retro --backfill: running twice leaves usage-backfill.jsonl line count unchanged" {
    _build_fleet
    run mother-usage retro --root "$MOTHER_ROOT" --since 30d --backfill
    [ "$status" -eq 0 ]
    [ -f "$METRICS_DIR/usage-backfill.jsonl" ]

    local first_count
    first_count=$(wc -l < "$METRICS_DIR/usage-backfill.jsonl" | tr -d ' ')
    [ "$first_count" -gt 0 ]

    run mother-usage retro --root "$MOTHER_ROOT" --since 30d --backfill
    [ "$status" -eq 0 ]
    local second_count
    second_count=$(wc -l < "$METRICS_DIR/usage-backfill.jsonl" | tr -d ' ')

    [ "$first_count" = "$second_count" ]
}

# ===========================================================================
# --since filtering
# ===========================================================================

@test "mother-usage retro --since 7d: excludes a job created 90 days ago from Outcomes" {
    _build_fleet
    run mother-usage retro --root "$MOTHER_ROOT" --since 7d --format json
    [ "$status" -eq 0 ]

    # The retro summary is aggregate-only (no per-job id listing in most
    # sections), so filtering is verified via the total job count rather
    # than an id substring search: 6 in-window jobs (job-out-of-window is 90
    # days old and must be excluded).
    jobs=$(printf '%s' "$output" | jq -r '.outcomes.jobs')
    [ "$jobs" = "6" ]
}

@test "mother-usage retro --since 365d: includes the 90-day-old job" {
    _build_fleet
    run mother-usage retro --root "$MOTHER_ROOT" --since 365d --format json
    [ "$status" -eq 0 ]
    jobs=$(printf '%s' "$output" | jq -r '.outcomes.jobs')
    [ "$jobs" = "7" ]
}

# ===========================================================================
# Never writes to metrics/runs.jsonl
# ===========================================================================

@test "mother-usage retro / --backfill never appends to metrics/runs.jsonl" {
    _build_fleet
    local before after
    before=$(wc -l < "$METRICS_DIR/runs.jsonl" | tr -d ' ')

    run mother-usage retro --root "$MOTHER_ROOT" --since 30d --format json
    [ "$status" -eq 0 ]
    run mother-usage retro --root "$MOTHER_ROOT" --since 30d --backfill
    [ "$status" -eq 0 ]

    after=$(wc -l < "$METRICS_DIR/runs.jsonl" | tr -d ' ')
    [ "$before" = "$after" ]
}

@test "mother retro (bin/mother subcommand) exists and exits 0 against the synthetic fleet" {
    _build_fleet
    run mother retro --since 30d
    [ "$status" -eq 0 ]
}

# ===========================================================================
# HC-07: gates, gates_ci_agreement, red_at_presentation, interruptions
# ===========================================================================

_ev() {  # _ev <job> <kind> <detail-json> [ts]
    jq -nc --arg ts "${4:-$(_now_iso)}" --arg k "$2" --argjson d "$3" \
        '{ts: $ts, kind: $k, detail: $d}' >> "$EVENTS_DIR/$1.jsonl"
}

# _gated_job <id> <repo> <sha> <status> <pr#> [gate-duration-s] [budget-min]
_gated_job() {
    local id="$1" repo="$2" sha="$3" status="$4" pr="$5" dur="${6:-60}" budget="${7:-15}" recent
    recent=$(_days_ago 1)
    local res="passed"; [ "$status" = "failed" ] && res="failed"; [ "$status" = "incomplete" ] && res="unavailable"
    make_job "$id" "succeeded" '.repo = "'"$repo"'" | .created_at = "'"$recent"'" | .finished_at = "'"$recent"'"
        | .pr_url = "https://github.com/x/'"$repo"'/pull/'"$pr"'"
        | .crew = {gates: {budget_minutes: '"$budget"', checks: [{name: "unit"}]}}
        | .gates = {status: "'"$status"'", head_sha: "'"$sha"'",
                    results: [{name: "unit", result: "'"$res"'", duration_s: '"$dur"'}]}'
    _ev "$id" gates_started '{"attempt":1,"head_sha":"'"$sha"'","gates":["unit"]}'
    _ev "$id" gate_result '{"attempt":1,"name":"unit","result":"'"$res"'","duration_s":'"$dur"'}'
    _ev "$id" gates_completed '{"attempt":1,"status":"'"$status"'"}'
}

_retro_json() { mother-usage retro --root "$MOTHER_ROOT" --since 3w --format json "$@"; }

@test "HC07-1: retro prints and json-keys the four new tables" {
    run mother-usage retro --root "$MOTHER_ROOT" --since 3w
    [ "$status" -eq 0 ]
    for t in "Quality gates" "Gates vs CI agreement" "Red PRs at presentation" "Operator interruptions"; do
        [[ "$output" == *"## $t"* ]]
    done
    run _retro_json
    for k in gates gates_ci_agreement red_at_presentation interruptions; do
        echo "$output" | jq -e --arg k "$k" 'has($k)' >/dev/null
    done
}

@test "HC07-2: 20 gated jobs with 19 agreeing is enforce-ready; 5 jobs is not" {
    gh_mock_install
    local i
    for i in $(seq 1 20); do
        _gated_job "big-$i" bigrepo "sha-big-$i" passed "$i" 60 15
        if [ "$i" -le 19 ]; then gh_mock_set_check_runs "sha-big-$i" unit:success lint:success
        else gh_mock_set_check_runs "sha-big-$i" unit:success lint:failure; fi
    done
    for i in $(seq 1 5); do
        _gated_job "small-$i" smallrepo "sha-small-$i" passed "$((100+i))" 60 15
        gh_mock_set_check_runs "sha-small-$i" unit:success
    done
    run _retro_json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.bigrepo.n')" = "20" ]
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.bigrepo.agreement_pct')" = "95.0" ]
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.bigrepo.enforce_ready')" = "yes" ]
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.smallrepo.enforce_ready')" = "no" ]
}

@test "HC07-2: gate time over budget blocks enforce-ready" {
    gh_mock_install
    local i
    for i in $(seq 1 20); do
        _gated_job "slow-$i" slowrepo "sha-slow-$i" passed "$i" 1200 15
        gh_mock_set_check_runs "sha-slow-$i" unit:success
    done
    run _retro_json
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.slowrepo.agreement_pct')" = "100.0" ]
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.slowrepo.enforce_ready')" = "no" ]
}

@test "HC07-2/3: incomplete gates and pending CI are excluded from the ratio, never passed" {
    gh_mock_install
    _gated_job inc-1 r1 sha-inc incomplete 1
    gh_mock_set_check_runs sha-inc unit:success
    _gated_job pend-1 r1 sha-pend passed 2
    gh_mock_set_check_runs sha-pend unit:pending
    _gated_job ok-1 r1 sha-ok failed 3
    gh_mock_set_check_runs sha-ok unit:failure
    run _retro_json
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.r1.n')" = "1" ]
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.r1.incomplete')" = "1" ]
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.r1.ci_pending')" = "1" ]
    [ "$(echo "$output" | jq -r '.gates_ci_agreement.r1.agreement_pct')" = "100.0" ]
    # unavailable counted as unavailable in the per-gate table, never passed
    [ "$(echo "$output" | jq -r '.gates.r1.gates.unit.unavailable')" = "1" ]
    [ "$(echo "$output" | jq -r '.gates.r1.gates.unit.passed')" = "1" ]
}

@test "HC07-4: fix-loop job counts as fixed within budget and G5 ratio comes from rows" {
    local recent; recent=$(_days_ago 1)
    make_job fix-1 succeeded '.repo = "fr" | .created_at = "'"$recent"'"
        | .gates = {status: "passed", head_sha: "s2", results: [{name: "unit", result: "passed", duration_s: 30}]}'
    _ev fix-1 gates_started '{"attempt":1,"head_sha":"s1"}' 2026-10-01T10:00:00Z
    _ev fix-1 gate_result '{"attempt":1,"name":"unit","result":"failed","duration_s":30}'
    _ev fix-1 gates_completed '{"attempt":1,"status":"failed"}'
    _ev fix-1 gate_fix_started '{"attempt":1}'
    _ev fix-1 gates_started '{"attempt":2,"head_sha":"s2"}'
    _ev fix-1 gate_result '{"attempt":2,"name":"unit","result":"passed","duration_s":30}'
    _ev fix-1 gates_completed '{"attempt":2,"status":"passed"}'
    _append_metrics_line '{"schema":2,"job_id":"fix-1","stage":"cody","run_kind":"worker","cost_usd":4.0}'
    _append_metrics_line '{"schema":2,"job_id":"fix-1","stage":"cody","run_kind":"gate_fix","cost_usd":0.5}'
    _append_metrics_line '{"schema":2,"job_id":"fix-1","stage":"cody","run_kind":"gate_fix","cost_usd":0.5}'
    run _retro_json
    [ "$(echo "$output" | jq -r '.gates.fr.jobs_with_gate_failure')" = "1" ]
    [ "$(echo "$output" | jq -r '.gates.fr.fixed_within_budget')" = "1" ]
    [ "$(echo "$output" | jq -r '.gates.fr.exhausted')" = "0" ]
    [ "$(echo "$output" | jq -r '.gates.fr.g5_fix_cost_ratio_median')" = "0.25" ]
}

@test "HC07-4: a pass after gates_exhausted is not fixed within budget; overrides counted" {
    local recent; recent=$(_days_ago 1)
    make_job ex-1 succeeded '.repo = "er" | .created_at = "'"$recent"'" | .gates = {status: "passed", results: []}'
    _ev ex-1 gates_completed '{"attempt":1,"status":"failed"}'
    _ev ex-1 gates_exhausted '{}'
    _ev ex-1 gates_overridden '{}'
    _ev ex-1 gates_completed '{"attempt":2,"status":"passed"}'
    run _retro_json
    [ "$(echo "$output" | jq -r '.gates.er.fixed_within_budget')" = "0" ]
    [ "$(echo "$output" | jq -r '.gates.er.exhausted')" = "1" ]
    [ "$(echo "$output" | jq -r '.gates.er.overridden')" = "1" ]
}

@test "HC07-1: interruptions are counted per the PRD definition" {
    local recent; recent=$(_days_ago 1)
    make_job int-1 succeeded '.repo = "ir" | .created_at = "'"$recent"'"'
    make_job int-2 succeeded '.repo = "ir" | .created_at = "'"$recent"'"'
    _ev int-1 awaiting_input '{"question":"q","paused_reason":"gate_hold"}'
    _ev int-1 awaiting_input '{"question":"q"}'
    _ev int-1 awaiting_input '{"paused_reason":"adherence_blocked"}'
    _ev int-1 awaiting_input '{"paused_reason":"operator_hold"}'
    _ev int-1 awaiting_input '{"paused_reason":"review_hold"}'
    _ev int-1 awaiting_input '{"paused_reason":"cost_cap"}'
    _ev int-1 paused_for_quota '{}'
    run _retro_json
    [ "$(echo "$output" | jq -r '.interruptions.interruptions')" = "5" ]
    [ "$(echo "$output" | jq -r '.interruptions.per_job_counts["int-1"]')" = "5" ]
    [ "$(echo "$output" | jq -r '.interruptions.by_repo.ir.jobs')" = "2" ]
    [ "$(echo "$output" | jq -r '.interruptions.by_repo.ir.per_job')" = "2.5" ]
}

@test "HC07-5: --backfill uses stubbed gh, writes the sha cache, and a rerun makes no gh calls" {
    gh_mock_install
    local recent; recent=$(_days_ago 1)
    make_job bf-1 succeeded '.repo = "bf" | .created_at = "'"$recent"'" | .finished_at = "'"$recent"'"
        | .pr_url = "https://github.com/x/bf/pull/9"'
    make_job bf-2 succeeded '.repo = "bf" | .created_at = "'"$recent"'" | .finished_at = "'"$recent"'"
        | .pr_url = "https://github.com/x/bf/pull/10"'
    gh_mock_set_pr "https://github.com/x/bf/pull/9" OPEN feature/a sha-bf1
    gh_mock_set_pr "https://github.com/x/bf/pull/10" OPEN feature/b sha-bf2
    gh_mock_set_check_runs sha-bf1 unit:failure
    gh_mock_set_check_runs sha-bf2 unit:success

    run _retro_json --backfill
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '[.red_at_presentation.bf[].prs] | add')" = "2" ]
    [ "$(echo "$output" | jq -r '[.red_at_presentation.bf[].any_red] | add')" = "1" ]
    [ "$(echo "$output" | jq -r '[.red_at_presentation.bf[].backfilled] | add')" = "2" ]
    [ -s "$METRICS_DIR/ci-cache.jsonl" ]
    [ "$(wc -l < "$METRICS_DIR/ci-cache.jsonl" | tr -d ' ')" = "2" ]

    : > "$MOTHER_ROOT/mock-gh-calls"
    run _retro_json --backfill
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '[.red_at_presentation.bf[].any_red] | add')" = "1" ]
    # pr view (sha lookup) may repeat; CI lookups for completed shas may not.
    run grep -c "check-runs" "$MOTHER_ROOT/mock-gh-calls"
    [ "$output" = "0" ]
}

@test "HC07-5: without --backfill, PRs lacking gate data are not evaluated" {
    gh_mock_install
    make_job nb-1 succeeded '.repo = "nb" | .pr_url = "https://github.com/x/nb/pull/1"'
    run _retro_json
    [ "$(echo "$output" | jq -r '.red_at_presentation | length')" = "0" ]
    [ ! -s "$MOTHER_ROOT/mock-gh-calls" ]
}

@test "HC07: red_at_presentation flags a red check named like a gate; pr_marked_ready picks the sha" {
    gh_mock_install
    _gated_job rd-1 rr sha-final passed 1
    _ev rd-1 gates_started '{"attempt":2,"head_sha":"sha-early"}' 2026-10-01T09:00:00Z
    _ev rd-1 gates_started '{"attempt":3,"head_sha":"sha-late"}' 2026-10-01T11:00:00Z
    _ev rd-1 pr_marked_ready '{}' 2026-10-01T10:00:00Z
    gh_mock_set_check_runs sha-early unit:failure
    gh_mock_set_check_runs sha-late unit:success
    gh_mock_set_check_runs sha-final unit:success
    run mother-usage retro --root "$MOTHER_ROOT" --since 2026-09-01 --format json
    [ "$(echo "$output" | jq -r '.red_at_presentation.rr["2026-W40"].any_red')" = "1" ]
    [ "$(echo "$output" | jq -r '.red_at_presentation.rr["2026-W40"].red_on_gate_check')" = "1" ]
}

# ====================================================================

# HC-11: stage_calibration, progress_accuracy, progress_flags
#
# JSON shapes assumed (retro tables are keyed like the other retro tables):
#   stage_calibration : { fleet: {n, stages:{<stage>:{n, median_s, p90_s}}}, "<repo>": {...} }
#                       (repo entries only for repos with n >= 20)
#   progress_accuracy : { overall: {n, coverage_pct, coverage_result, width_ratio,
#                         width_target, width_result}, "<repo>": {...} (n >= 20 only) }
#   progress_flags    : { raised, real, real_pct, target_pct, result, by_reason }
# ===========================================================================

_epoch_iso() {  # <epoch>
    date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

_HC11_BASE=""
_hc11_base() { [ -n "$_HC11_BASE" ] || _HC11_BASE=$(( $(date +%s) - 172800 )); echo "$_HC11_BASE"; }

# _evat <job> <offset-s> <kind> [detail-json]   (offset from two days ago)
_evat() {
    _ev "$1" "$3" "${4:-{\}}" "$(_epoch_iso $(( $(_hc11_base) + $2 )))"
}

# _stage_job <id> <repo> <build-seconds>   finished job with one build interval
_stage_job() {
    local recent; recent=$(_days_ago 1)
    make_job "$1" succeeded '.repo = "'"$2"'" | .created_at = "'"$recent"'" | .finished_at = "'"$recent"'"'
    _evat "$1" -100 queued
    _evat "$1" 0 worker_spawned
    _evat "$1" "$3" final_result_observed
    _evat "$1" "$(( $3 + 1 ))" succeeded
}

# _acc_job <id> <repo> <remaining-s> <eta_lo> <eta_hi> [state]
# A job whose ≈50% moment came after 600 active seconds, then ran <remaining-s> more.
_acc_job() {
    local recent state="${6:-succeeded}"; recent=$(_days_ago 1)
    make_job "$1" "$state" '.repo = "'"$2"'" | .created_at = "'"$recent"'" | .finished_at = "'"$recent"'"'
    _evat "$1" -100 queued
    _evat "$1" 0 worker_spawned
    _evat "$1" 600 progress_half '{"eta_lo_s":'"$4"',"eta_hi_s":'"$5"',"elapsed_active_s":600}'
    _evat "$1" "$(( 600 + $3 ))" final_result_observed
    case "$state" in
        succeeded|failed|cancelled) _evat "$1" "$(( 601 + $3 ))" "$state" ;;
    esac
}

@test "HC11-1: retro prints and json-keys the three progress tables" {
    run mother-usage retro --root "$MOTHER_ROOT" --since 3w
    [ "$status" -eq 0 ]
    [[ "$output" =~ "## "[^$'\n']*"Stage calibration" ]]
    [[ "$output" =~ "## "[^$'\n']*"Progress accuracy" ]]
    [[ "$output" =~ "## "[^$'\n']*"Progress flags" ]]
    run _retro_json
    for k in stage_calibration progress_accuracy progress_flags; do
        echo "$output" | jq -e --arg k "$k" 'has($k)' >/dev/null
    done
}

@test "HC11-2: stage_calibration reports fleet n and per-stage median/p90, and a repo entry only at n >= 20" {
    local i
    for i in $(seq 0 19); do _stage_job "big-$i" bigrepo "$(( 600 + 30 * i ))"; done
    for i in $(seq 1 5); do _stage_job "small-$i" smallrepo 600; done
    run _retro_json
    [ "$status" -eq 0 ]
    sc=$(echo "$output" | jq -c .stage_calibration)
    [ "$(echo "$sc" | jq '.fleet.n')" = "25" ]
    [ "$(echo "$sc" | jq '.bigrepo.n')" = "20" ]
    [ "$(echo "$sc" | jq 'has("smallrepo")')" = "false" ]
    [ "$(echo "$sc" | jq '.bigrepo.stages.build.n')" = "20" ]
    echo "$sc" | jq -e '(.bigrepo.stages.build.median_s - 885) | fabs < 2' >/dev/null
    echo "$sc" | jq -e '.bigrepo.stages.build.p90_s >= 1100 and .bigrepo.stages.build.p90_s <= 1170' >/dev/null
    echo "$sc" | jq -e '.fleet.stages.build.median_s >= 600 and .fleet.stages.build.median_s <= 1170' >/dev/null
}

# 10 jobs: 8 remaining times inside the 300..1000 s band, 2 outside (100, 2000).
# coverage 80%; median(band width 700) / median(remaining 575) = 1.217.
_ten_accuracy_jobs() {
    local r i=0
    for r in 400 450 500 550 600 650 700 750 100 2000; do
        i=$((i + 1)); _acc_job "acc-$i" solo "$r" 300 1000
    done
}

@test "HC11-3: progress_accuracy coverage is the share of actual remaining times inside the band" {
    _ten_accuracy_jobs
    run _retro_json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '.progress_accuracy.overall.n')" = "10" ]
    echo "$output" | jq -e '(.progress_accuracy.overall.coverage_pct - 80) | fabs < 0.1' >/dev/null
    [ "$(echo "$output" | jq -r '.progress_accuracy.overall.coverage_result')" = "PASS" ]
}

@test "HC11-3: the default width target is 5x median remaining (user decision); a stricter MOTHER_I13_WIDTH_TARGET FAILs it" {
    _ten_accuracy_jobs
    run _retro_json
    echo "$output" | jq -e '(.progress_accuracy.overall.width_ratio - 1.22) | fabs < 0.03' >/dev/null
    [ "$(echo "$output" | jq -r '.progress_accuracy.overall.width_target')" = "5" ] || \
        [ "$(echo "$output" | jq -r '.progress_accuracy.overall.width_target')" = "5.0" ]
    [ "$(echo "$output" | jq -r '.progress_accuracy.overall.width_result')" = "PASS" ]
    MOTHER_I13_WIDTH_TARGET=1 run _retro_json
    [ "$(echo "$output" | jq -r '.progress_accuracy.overall.width_result')" = "FAIL" ]
}

@test "retro text never prints a literal None for a missing value" {
    run python3 - "$BATS_TEST_DIRNAME/../bin/mother-usage" <<'PY'
import sys, importlib.machinery, importlib.util
loader = importlib.machinery.SourceFileLoader("mu", sys.argv[1])
spec = importlib.util.spec_from_loader("mu", loader)
mu = importlib.util.module_from_spec(spec); loader.exec_module(mu)
lines = mu._render_value("overall", {"width_ratio": None, "rows": [{"a": None}]}, 0)
print("\n".join(lines))
PY
    [ "$status" -eq 0 ]
    [[ "$output" != *"None"* ]]
    [[ "$output" == *"n/a"* ]]
}

@test "HC11-3: coverage under 70% FAILs" {
    local i
    for i in 1 2 3 4 5 6; do _acc_job "in-$i" solo 500 300 1000; done
    for i in 1 2 3 4; do _acc_job "out-$i" solo 3000 300 1000; done   # 60% coverage
    run _retro_json
    echo "$output" | jq -e '(.progress_accuracy.overall.coverage_pct - 60) | fabs < 0.1' >/dev/null
    [ "$(echo "$output" | jq -r '.progress_accuracy.overall.coverage_result')" = "FAIL" ]
}

@test "HC11-3: only finished jobs that reached the half mark are sampled; repos need n >= 20" {
    local i
    for i in $(seq 1 20); do _acc_job "a-$i" arepo 500 300 1000; done
    for i in $(seq 1 5); do _acc_job "b-$i" brepo 500 300 1000; done
    _acc_job still-running brepo 500 300 1000 running      # no terminal state: excluded
    _stage_job no-half arepo 900                           # finished but never had a half event
    run _retro_json
    [ "$(echo "$output" | jq '.progress_accuracy.overall.n')" = "25" ]
    [ "$(echo "$output" | jq '.progress_accuracy.arepo.n')" = "20" ]
    [ "$(echo "$output" | jq '.progress_accuracy | has("brepo")')" = "false" ]
}

# _flag_job <id> <state> <reason> then optional extra events given as "kind" args,
# each placed after the raise; "CLEARED" inserts attention_cleared.
_flag_job() {
    local id="$1" state="$2" reason="$3" off=100 k; shift 3
    local recent; recent=$(_days_ago 1)
    make_job "$id" "$state" '.repo = "fr" | .created_at = "'"$recent"'" | .finished_at = "'"$recent"'"'
    _evat "$id" 0 worker_spawned
    _evat "$id" 50 attention_raised '{"reason":"'"$reason"'"}'
    for k in "$@"; do
        off=$((off + 10))
        if [ "$k" = CLEARED ]; then _evat "$id" "$off" attention_cleared '{"reason":"'"$reason"'"}'
        else _evat "$id" "$off" "$k"; fi
    done
}

@test "HC11-4: a flag is real when the operator acted while it was raised or the job later failed or was cancelled" {
    _flag_job f1 succeeded progress_stalled resumed CLEARED          # real: resumed while flagged
    _flag_job f2 succeeded burn_ahead cancel_requested CLEARED       # real
    _flag_job f3 failed progress_stalled CLEARED                     # real: job later failed
    _flag_job f4 succeeded progress_stalled CLEARED                  # not real
    _flag_job f5 succeeded progress_stalled CLEARED resumed          # not real: acted after it cleared
    _flag_job f6 succeeded gates_incomplete resumed                  # other reason: not counted at all
    run _retro_json
    [ "$status" -eq 0 ]
    pf=$(echo "$output" | jq -c .progress_flags)
    [ "$(echo "$pf" | jq .raised)" = "5" ]
    [ "$(echo "$pf" | jq .real)" = "3" ]
    echo "$pf" | jq -e '(.real_pct - 60) | fabs < 0.1' >/dev/null
    echo "$pf" | jq -e '.target_pct == 50' >/dev/null
    [ "$(echo "$pf" | jq -r .result)" = "PASS" ]
}

@test "HC11-4: retried and escalated count as operator action; under 50% real FAILs" {
    _flag_job g1 succeeded progress_stalled retried CLEARED
    _flag_job g2 succeeded burn_ahead escalated CLEARED
    _flag_job g3 succeeded progress_stalled CLEARED
    _flag_job g4 succeeded progress_stalled CLEARED
    _flag_job g5 succeeded burn_ahead CLEARED
    run _retro_json
    pf=$(echo "$output" | jq -c .progress_flags)
    [ "$(echo "$pf" | jq .raised)" = "5" ]
    [ "$(echo "$pf" | jq .real)" = "2" ]
    [ "$(echo "$pf" | jq -r .result)" = "FAIL" ]
}

# ---------------------------------------------------------------------------
# HC-14 (HC14-5): review wave spend per lens, refuted claims

# _wave_job <id> — a succeeded job with one review wave cycle.
_wave_job() {
    local id="$1" recent; recent=$(_days_ago 1)
    make_job "$id" "succeeded" '.repo = "waverepo" | .created_at = "'"$recent"'" | .finished_at = "'"$recent"'"
        | .review_wave = {cycle: 0, status: "done"}'
    _ev "$id" review_cycle_started '{"cycle":0,"wave":true,"reviewers":["archie:adherence","perri:correctness","perri:phi-security"]}'
    _ev "$id" review_cycle_completed '{"cycle":0,"wave":true,"decision":"ship"}'
}

@test "HC14-5: review_wave reports runs, median cost and spend share per lens, and adherence separately" {
    _wave_job w1
    _append_metrics_line '{"schema":2,"job_id":"w1","stage":"review-perri:correctness","cost_usd":0.30,"outcome":"succeeded"}'
    _append_metrics_line '{"schema":2,"job_id":"w1","stage":"review-perri:phi-security","cost_usd":0.50,"outcome":"succeeded"}'
    _append_metrics_line '{"schema":2,"job_id":"w1","stage":"adherence","pre_ready":true,"cost_usd":1.20,"outcome":"succeeded"}'
    run _retro_json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r '.review_wave.jobs')" = "1" ]
    [ "$(echo "$output" | jq -r '.review_wave.lenses["perri:correctness"].runs')" = "1" ]
    echo "$output" | jq -e '(.review_wave.lenses["perri:phi-security"].median_cost_usd - 0.5) | fabs < 0.001' >/dev/null
    echo "$output" | jq -e '(.review_wave.lenses["perri:correctness"].spend_share_pct - 15.0) | fabs < 0.1' >/dev/null
    echo "$output" | jq -e '(.review_wave.adherence.spend_share_pct - 60.0) | fabs < 0.1' >/dev/null
    echo "$output" | jq -e '(.review_wave.review_cost_usd - 2.0) | fabs < 0.001' >/dev/null
}

@test "HC14-5: an errored lens run is counted as an error, and lens skips are counted by reason" {
    _wave_job w2
    _append_metrics_line '{"schema":2,"job_id":"w2","stage":"review-perri:correctness","cost_usd":0.10,"outcome":"error"}'
    _ev w2 lens_skipped '{"reviewer":"perri:ops-infra","lens":"ops-infra","reason":"path_scope"}'
    run _retro_json
    [ "$(echo "$output" | jq -r '.review_wave.lenses["perri:correctness"].errors')" = "1" ]
    [ "$(echo "$output" | jq -r '.review_wave.lenses["perri:ops-infra"].skips.path_scope')" = "1" ]
}

@test "HC14-5: refuted claims are counted per lens from merged.json, and refuted findings sent to a worker are reported" {
    _wave_job w3
    mkdir -p "$MOTHER_ROOT/crew/w3/wave/c0"
    printf '%s' '{"findings":[],"actionable":[],"refuted":[{"id":"f1","lenses":["correctness","tests"]},{"id":"f2","lenses":["correctness"]}],"coverage_gaps":[],"lens_errors":[],"claims":{"verified":0,"refuted":2,"unverified":0}}' \
        > "$MOTHER_ROOT/crew/w3/wave/c0/merged.json"
    _append_metrics_line '{"schema":2,"job_id":"w3","stage":"cody","run_kind":"review_rework","refuted_sent":0,"cost_usd":1.0}'
    run _retro_json
    [ "$(echo "$output" | jq -r '.refuted_claims.by_lens.correctness')" = "2" ]
    [ "$(echo "$output" | jq -r '.refuted_claims.by_lens.tests')" = "1" ]
    [ "$(echo "$output" | jq -r '.refuted_claims.total')" = "3" ]
    [ "$(echo "$output" | jq -r '.refuted_claims.refuted_sent_to_worker')" = "0" ]
}

@test "HC14-5: with no review-wave jobs both tables are empty, and the text report never prints None" {
    run _retro_json
    [ "$(echo "$output" | jq -c '.review_wave')" = "{}" ]
    [ "$(echo "$output" | jq -c '.refuted_claims')" = "{}" ]
    run mother-usage retro --root "$MOTHER_ROOT" --since 3w
    [ "$status" -eq 0 ]
    [[ "$output" != *": None"* ]]
}
