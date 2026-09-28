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
