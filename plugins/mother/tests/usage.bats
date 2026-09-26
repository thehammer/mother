#!/usr/bin/env bats
# usage.bats — tests for `mother-usage parse|classify-exit|publish-rates`.
#
# `mother-usage` is a stdlib-only Python 3 CLI at plugins/mother/bin/mother-usage.
# These tests drive it as a real subprocess (it's on PATH via
# setup_mother_env's MOTHER_BIN_DIR-on-PATH wiring) against the fixtures in
# tests/fixtures/usage/ (see that directory's README.md for the hand-computed
# expected values referenced below).

load 'test_helper'

FIXTURES="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd -P)/fixtures/usage"

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
}

_rates() { echo "$MOTHER_LIB_DIR/rates.json"; }

# ---------------------------------------------------------------------------
# Dedup by message.id (main_only.jsonl: msg_1 x3 identical + msg_2 x1)

@test "parse: duplicate message.id lines are deduped, not double-counted" {
    run mother-usage parse --log "$FIXTURES/main_only.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "3500" ]
    [ "$tokens_out" = "700" ]
}

@test "parse: main_only cost_usd matches hand-computed total (0.0131)" {
    run mother-usage parse --log "$FIXTURES/main_only.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    cost=$(printf '%s' "$output" | jq -r '.cost_usd')
    # Allow tiny float slop.
    awk -v c="$cost" 'BEGIN { exit !(c > 0.01309 && c < 0.01311) }'
}

@test "parse: main_only by_actor reports 2 deduped messages under the main actor" {
    run mother-usage parse --log "$FIXTURES/main_only.jsonl" --rates "$(_rates)" --main-actor cody-main
    [ "$status" -eq 0 ]
    messages=$(printf '%s' "$output" | jq -r '.by_actor["cody-main"].messages')
    [ "$messages" = "2" ]
}

# ---------------------------------------------------------------------------
# Main + subagent actor split with spawn counts

@test "parse: subagent turns attributed to their subagent_type, not the main actor" {
    run mother-usage parse --log "$FIXTURES/subagents.jsonl" --rates "$(_rates)" --main-actor cody-main
    [ "$status" -eq 0 ]

    main_in=$(printf '%s' "$output" | jq -r '.by_actor["cody-main"].tokens_in')
    main_out=$(printf '%s' "$output" | jq -r '.by_actor["cody-main"].tokens_out')
    redd_in=$(printf '%s' "$output" | jq -r '.by_actor["redd"].tokens_in')
    redd_out=$(printf '%s' "$output" | jq -r '.by_actor["redd"].tokens_out')
    marty_in=$(printf '%s' "$output" | jq -r '.by_actor["marty"].tokens_in')
    marty_out=$(printf '%s' "$output" | jq -r '.by_actor["marty"].tokens_out')

    [ "$main_in" = "1100" ]
    [ "$main_out" = "110" ]
    [ "$redd_in" = "300" ]
    [ "$redd_out" = "100" ]
    [ "$marty_in" = "400" ]
    [ "$marty_out" = "150" ]
}

@test "parse: each subagent actor's spawns count is 1 per distinct spawning tool_use id" {
    # Per the plan's own contract ("spawns applies to subagents and counts
    # distinct spawning tool_use ids") and retro table 11's use of
    # `by_actor.perri.spawns`, `spawns` lives on the CHILD actor's bucket
    # (how many times that subagent type was spawned), not on the spawning
    # main actor. The main actor's own spawns count is 0 — it's the one
    # doing the spawning, not being spawned.
    run mother-usage parse --log "$FIXTURES/subagents.jsonl" --rates "$(_rates)" --main-actor cody-main
    [ "$status" -eq 0 ]
    main_spawns=$(printf '%s' "$output" | jq -r '.by_actor["cody-main"].spawns')
    redd_spawns=$(printf '%s' "$output" | jq -r '.by_actor["redd"].spawns')
    marty_spawns=$(printf '%s' "$output" | jq -r '.by_actor["marty"].spawns')
    [ "$main_spawns" = "0" ]
    [ "$redd_spawns" = "1" ]
    [ "$marty_spawns" = "1" ]
}

@test "parse: overall totals sum across main + subagent actors" {
    run mother-usage parse --log "$FIXTURES/subagents.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "1800" ]
    [ "$tokens_out" = "360" ]
}

# ---------------------------------------------------------------------------
# 5m/1h cache tokens are priced using rates.json's own per-tier rates
#
# NOTE: rates.json currently calibrates cache_write_1h == cache_write_5m for
# claude-sonnet-5 (a deliberate, log-calibrated pricing decision — see the
# "source" field in lib/rates.json — not a parser bug), so this assertion
# derives the expected cost from whatever rates.json actually says rather
# than hardcoding an assumption that the two tiers differ. The point of this
# test is that the parser multiplies each tier's tokens by *that tier's own*
# configured rate (not, e.g., always the 5m rate regardless of which tier the
# tokens came from) — not to pin a specific pricing calibration.

@test "parse: 5m and 1h cache-write tokens are each priced at their own configured rate" {
    run mother-usage parse --log "$FIXTURES/cache_split.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    cost=$(printf '%s' "$output" | jq -r '.cost_usd')

    expected=$(jq -r '.models["claude-sonnet-5"] | (1000 * .cache_write_5m / 1000000) + (1000 * .cache_write_1h / 1000000)' "$(_rates)")
    awk -v c="$cost" -v e="$expected" 'BEGIN { d = c - e; if (d < 0) d = -d; exit !(d < 0.00001) }'
}

@test "parse: cache_create_5m and cache_create_1h are reported as distinct token buckets" {
    run mother-usage parse --log "$FIXTURES/cache_split.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    c5m=$(printf '%s' "$output" | jq -r '.tokens.cache_create_5m')
    c1h=$(printf '%s' "$output" | jq -r '.tokens.cache_create_1h')
    [ "$c5m" = "1000" ]
    [ "$c1h" = "1000" ]
}

# ---------------------------------------------------------------------------
# Multi-model / unpriced model

@test "parse: opus model priced at its own distinct rate (0.008)" {
    run mother-usage parse --log "$FIXTURES/opus_model.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    cost=$(printf '%s' "$output" | jq -r '.by_model["claude-opus-5-5"].cost_usd')
    awk -v c="$cost" 'BEGIN { exit !(c > 0.00799 && c < 0.00801) }'
}

@test "parse: unpriced model yields cost_complete:false and lists the model" {
    run mother-usage parse --log "$FIXTURES/unpriced_model.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    complete=$(printf '%s' "$output" | jq -r '.cost_complete')
    [ "$complete" = "false" ]
    unpriced=$(printf '%s' "$output" | jq -r '.unpriced_models | index("claude-made-up-9") != null')
    [ "$unpriced" = "true" ]
    # Tokens are still counted even though cost is incomplete.
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    [ "$tokens_in" = "1000" ]
}

@test "parse: fully-priced fixture yields cost_complete:true" {
    run mother-usage parse --log "$FIXTURES/main_only.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    complete=$(printf '%s' "$output" | jq -r '.cost_complete')
    [ "$complete" = "true" ]
}

# ---------------------------------------------------------------------------
# cli_cost_usd extraction from a result event

@test "parse: cli_cost_usd extracted from the result event's total_cost_usd" {
    run mother-usage parse --log "$FIXTURES/full_run.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    cli_cost=$(printf '%s' "$output" | jq -r '.cli_cost_usd')
    awk -v c="$cli_cost" 'BEGIN { exit !(c > 0.00399 && c < 0.00401) }'
}

@test "parse: banner (non-JSON) lines preceding JSON events are tolerated" {
    run mother-usage parse --log "$FIXTURES/full_run.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    [ "$tokens_in" = "1000" ]
}

@test "parse: result event's own usage/cost fields are never folded into tokens_in/out" {
    # full_run.jsonl's result event carries total_cost_usd/modelUsage but no
    # separate top-level usage block distinct from the one assistant event —
    # the assertion is that tokens_in reflects ONLY the assistant event's
    # usage (1000), not e.g. double-counted via the result event.
    run mother-usage parse --log "$FIXTURES/full_run.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "1000" ]
    [ "$tokens_out" = "200" ]
}

# ---------------------------------------------------------------------------
# result{} block surfaced

@test "parse: result subtype/is_error surfaced in the .result block" {
    run mother-usage parse --log "$FIXTURES/full_run.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    subtype=$(printf '%s' "$output" | jq -r '.result.subtype')
    is_error=$(printf '%s' "$output" | jq -r '.result.is_error')
    [ "$subtype" = "success" ]
    [ "$is_error" = "false" ]
}

# ---------------------------------------------------------------------------
# --offset isolates the second run of a two-run log

@test "parse: --offset over a two-run log counts only the second run's tokens" {
    local offset
    offset=$(grep -bo '=== mother job job-two starting at RUN2 ===' "$FIXTURES/two_runs.jsonl" | head -1 | cut -d: -f1)
    [ -n "$offset" ]

    run mother-usage parse --log "$FIXTURES/two_runs.jsonl" --offset "$offset" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "9999" ]
    [ "$tokens_out" = "999" ]
}

@test "parse: whole two-run log (no offset) sums both runs' tokens" {
    run mother-usage parse --log "$FIXTURES/two_runs.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "10099" ]
    [ "$tokens_out" = "1009" ]
}

# ---------------------------------------------------------------------------
# Incremental (--state) mode == one-shot mode, across 3 chunks

@test "parse --state: 3 incremental chunks equal one-shot parsing of the same log" {
    local log="$FIXTURES/two_runs.jsonl"
    local total_bytes
    total_bytes=$(wc -c < "$log" | tr -d ' ')
    local third=$((total_bytes / 3))

    local state_file="$MOTHER_ROOT/incremental.state.json"
    rm -f "$state_file"

    run mother-usage parse --log "$log" --end "$third" --state "$state_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    run mother-usage parse --log "$log" --offset "$third" --end $((third * 2)) --state "$state_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    run mother-usage parse --log "$log" --offset $((third * 2)) --state "$state_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]

    incremental_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    incremental_out=$(printf '%s' "$output" | jq -r '.tokens_out')

    run mother-usage parse --log "$log" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    oneshot_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    oneshot_out=$(printf '%s' "$output" | jq -r '.tokens_out')

    [ "$incremental_in" = "$oneshot_in" ]
    [ "$incremental_out" = "$oneshot_out" ]
}

# ---------------------------------------------------------------------------
# Corrupt line tolerated

@test "parse: a corrupt JSON line is skipped, not fatal" {
    run mother-usage parse --log "$FIXTURES/corrupt_line.jsonl" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "300" ]
    [ "$tokens_out" = "50" ]
}

# ---------------------------------------------------------------------------
# Empty / missing / banner-only logs

@test "parse: missing log file -> usage_available:false, exit 0" {
    run mother-usage parse --log "/tmp/mother-usage-test-nonexistent-$$" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    avail=$(printf '%s' "$output" | jq -r '.usage_available')
    [ "$avail" = "false" ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    [ "$tokens_in" = "null" ]
}

@test "parse: empty log file -> usage_available:false, exit 0" {
    local log="$MOTHER_ROOT/empty.log"
    touch "$log"
    run mother-usage parse --log "$log" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    avail=$(printf '%s' "$output" | jq -r '.usage_available')
    [ "$avail" = "false" ]
}

@test "parse: banner-only log (no JSON at all) -> usage_available:false, exit 0" {
    local log="$MOTHER_ROOT/banner-only.log"
    cat > "$log" <<'EOF'
=== mother job test-job starting ===
Job ID: test-job
Branch: feature/test
Spawning claude worker...
EOF
    run mother-usage parse --log "$log" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    avail=$(printf '%s' "$output" | jq -r '.usage_available')
    [ "$avail" = "false" ]
}

# ---------------------------------------------------------------------------
# Never a non-zero exit on bad input

@test "parse: nonexistent --rates path never crashes (still exits 0)" {
    run mother-usage parse --log "$FIXTURES/main_only.jsonl" --rates "/tmp/mother-usage-nonexistent-rates-$$"
    [ "$status" -eq 0 ]
}

@test "parse: garbage argv values do not produce a non-zero exit" {
    run mother-usage parse --log "" --rates "$(_rates)"
    [ "$status" -eq 0 ]
}

# ===========================================================================
# classify-exit
# ===========================================================================

@test "classify-exit: exit 127 -> worker_command_not_found" {
    run mother-usage classify-exit --log "$FIXTURES/main_only.jsonl" --offset 0 --exit-code 127
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "worker_command_not_found" ]
}

@test "classify-exit: exit 143 -> worker_sigterm" {
    run mother-usage classify-exit --log "$FIXTURES/main_only.jsonl" --offset 0 --exit-code 143
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "worker_sigterm" ]
}

@test "classify-exit: exit 137 -> worker_sigkill" {
    run mother-usage classify-exit --log "$FIXTURES/main_only.jsonl" --offset 0 --exit-code 137
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "worker_sigkill" ]
}

@test "classify-exit: exit 130 (other >=128 signal) -> worker_signal_2" {
    run mother-usage classify-exit --log "$FIXTURES/main_only.jsonl" --offset 0 --exit-code 130
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "worker_signal_2" ]
}

@test "classify-exit: result is_error+api_error_status -> api_error" {
    run mother-usage classify-exit --log "$FIXTURES/result_api_error.jsonl" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    api_status=$(printf '%s' "$output" | jq -r '.api_error_status')
    [ "$reason" = "api_error" ]
    [ "$api_status" = "529" ]
}

@test "classify-exit: result subtype error_max_turns -> max_turns" {
    run mother-usage classify-exit --log "$FIXTURES/result_max_turns.jsonl" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "max_turns" ]
}

@test "classify-exit: result subtype error_during_execution -> execution_error" {
    run mother-usage classify-exit --log "$FIXTURES/result_execution_error.jsonl" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "execution_error" ]
}

@test "classify-exit: result subtype success but nonzero exit -> nonzero_exit_after_result" {
    run mother-usage classify-exit --log "$FIXTURES/full_run.jsonl" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "nonzero_exit_after_result" ]
}

@test "classify-exit: no result event, tail matches context-overflow text -> context_overflow" {
    run mother-usage classify-exit --log "$FIXTURES/error_tail_context_overflow.jsonl" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "context_overflow" ]
}

@test "classify-exit: no result event, tail matches rate-limit text -> rate_limited" {
    run mother-usage classify-exit --log "$FIXTURES/error_tail_rate_limit.jsonl" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "rate_limited" ]
}

@test "classify-exit: no result event, tail matches overloaded/529 text -> api_overloaded" {
    run mother-usage classify-exit --log "$FIXTURES/error_tail_overloaded.jsonl" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "api_overloaded" ]
}

@test "classify-exit: no result event, tail matches billing text -> billing" {
    run mother-usage classify-exit --log "$FIXTURES/error_tail_billing.jsonl" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "billing" ]
}

@test "classify-exit: no result event, no matching tail text -> claude_exit_nonzero" {
    run mother-usage classify-exit --log "$FIXTURES/corrupt_line.jsonl" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
    reason=$(printf '%s' "$output" | jq -r '.reason')
    [ "$reason" = "claude_exit_nonzero" ]
}

@test "classify-exit: never exits non-zero regardless of input" {
    run mother-usage classify-exit --log "/tmp/nonexistent-$$" --offset 0 --exit-code 1
    [ "$status" -eq 0 ]
}

# ===========================================================================
# publish-rates
# ===========================================================================

@test "publish-rates: writes to destination when destination is missing" {
    local dest="$MOTHER_ROOT/dest-rates.json"
    rm -f "$dest"
    run mother-usage publish-rates --dest "$dest"
    [ "$status" -eq 0 ]
    [ -f "$dest" ]
    version=$(jq -r '.version' "$dest")
    [ -n "$version" ] && [ "$version" != "null" ]
}

@test "publish-rates: never downgrades a destination with a higher version" {
    local dest="$MOTHER_ROOT/dest-rates.json"
    # Destination is already at version 2 with distinguishable content.
    jq -n '{version: 2, models: {"claude-sentinel-model": {"input": 999, "output": 999}}}' > "$dest"

    # Source (lib/rates.json) is version 1 in this repo state.
    run mother-usage publish-rates --dest "$dest"
    [ "$status" -eq 0 ]

    # Destination must be byte-for-byte unchanged in content (still version 2,
    # still carrying the sentinel model that the real rates.json does not).
    version=$(jq -r '.version' "$dest")
    [ "$version" = "2" ]
    sentinel=$(jq -r '.models["claude-sentinel-model"].input' "$dest")
    [ "$sentinel" = "999" ]
}

@test "publish-rates: does upgrade a destination with a lower version" {
    local dest="$MOTHER_ROOT/dest-rates.json"
    jq -n '{version: 0}' > "$dest"

    run mother-usage publish-rates --dest "$dest"
    [ "$status" -eq 0 ]

    version=$(jq -r '.version' "$dest")
    [ "$version" != "0" ]
}

@test "publish-rates: writes atomically (no partial file left behind on repeated runs)" {
    local dest="$MOTHER_ROOT/dest-rates.json"
    run mother-usage publish-rates --dest "$dest"
    [ "$status" -eq 0 ]
    run mother-usage publish-rates --dest "$dest"
    [ "$status" -eq 0 ]
    # No stray .tmp files left in the destination's directory.
    tmp_count=$(find "$(dirname "$dest")" -maxdepth 1 -name '*.tmp*' | wc -l | tr -d ' ')
    [ "$tmp_count" = "0" ]
}
