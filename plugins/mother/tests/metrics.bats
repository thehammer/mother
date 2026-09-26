#!/usr/bin/env bats
# metrics.bats — behavioral coverage for token accounting feeding runs.jsonl.
#
# Historically this file drove mother-run-job's internal `_sum_tokens` jq
# pipeline directly (SOURCE_ONLY-style heredoc fixtures). That pipeline has
# been replaced by `mother-usage parse` (see tests/usage.bats for the full
# parse/classify-exit/publish-rates contract) — this file keeps the same
# *behavioral* assertions (dedup by id, result-event usage never folded into
# totals, null/zero on absent/empty/banner-only logs, corrupt lines
# tolerated) but drives them through the real `mother-usage` CLI instead of
# reaching into mother-run-job's internals.

load 'test_helper'

setup() {
    setup_mother_env
    export METRICS_DIR="$MOTHER_ROOT/metrics"
    mkdir -p "$METRICS_DIR"
}

teardown() {
    teardown_mother_env
}

_rates() { echo "$MOTHER_LIB_DIR/rates.json"; }

# ---------------------------------------------------------------------------
# Multi-turn sum: two distinct assistant message ids

@test "mother-usage parse: two distinct assistant turns sums tokens correctly" {
    local log_file="$MOTHER_ROOT/two-turns.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
{"type":"assistant","message":{"id":"msg_aaa","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50}}}
{"type":"assistant","message":{"id":"msg_bbb","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":5}}}
EOF
    # tokens_in = (100+200+300) + (10+20+30) = 600 + 60 = 660
    # tokens_out = 50 + 5 = 55
    run mother-usage parse --log "$log_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "660" ]
    [ "$tokens_out" = "55" ]
}

# ---------------------------------------------------------------------------
# Dedup by message.id: same id appears multiple times (stream-json pattern)

@test "mother-usage parse: duplicate message.id events are counted only once" {
    local log_file="$MOTHER_ROOT/dedup.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
{"type":"assistant","message":{"id":"msg_aaa","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
{"type":"assistant","message":{"id":"msg_aaa","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
{"type":"assistant","message":{"id":"msg_aaa","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
EOF
    # Despite 3 lines, all same id — should count as 1 message.
    run mother-usage parse --log "$log_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "100" ]
    [ "$tokens_out" = "50" ]
}

# ---------------------------------------------------------------------------
# Dedup + multi-turn: mix of repeated and unique ids

@test "mother-usage parse: mix of duplicate and unique ids deduplicates correctly" {
    local log_file="$MOTHER_ROOT/mixed.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
{"type":"assistant","message":{"id":"msg_aaa","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":0,"output_tokens":100}}}
{"type":"assistant","message":{"id":"msg_aaa","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":0,"output_tokens":100}}}
{"type":"assistant","message":{"id":"msg_bbb","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":800,"output_tokens":75}}}
EOF
    # msg_aaa counted once: in=1000+500+0=1500, out=100
    # msg_bbb counted once: in=200+0+800=1000, out=75
    # total: in=2500, out=175
    run mother-usage parse --log "$log_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "2500" ]
    [ "$tokens_out" = "175" ]
}

# ---------------------------------------------------------------------------
# Cache fields: all three input sub-fields contribute to tokens_in

@test "mother-usage parse: all three input token sub-fields are summed into tokens_in" {
    local log_file="$MOTHER_ROOT/cache.log"
    cat > "$log_file" <<'EOF'
{"type":"assistant","message":{"id":"msg_ccc","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":100,"cache_creation_input_tokens":50000,"cache_read_input_tokens":200000,"output_tokens":1234}}}
EOF
    # tokens_in = 100 + 50000 + 200000 = 250100
    # tokens_out = 1234
    run mother-usage parse --log "$log_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "250100" ]
    [ "$tokens_out" = "1234" ]
}

# ---------------------------------------------------------------------------
# result event is NOT used for totals (it only has the last turn's usage)

@test "mother-usage parse: result event usage is ignored; totals come from assistant events" {
    local log_file="$MOTHER_ROOT/with-result.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
{"type":"assistant","message":{"id":"msg_aaa","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":100}}}
{"type":"assistant","message":{"id":"msg_bbb","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":100}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.5,"usage":{"input_tokens":500,"output_tokens":100},"modelUsage":{}}
EOF
    # Should sum the two assistant turns: in=1000, out=200
    # The result event's own usage field (input_tokens=500, output_tokens=100)
    # must NOT be folded into these totals.
    run mother-usage parse --log "$log_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "1000" ]
    [ "$tokens_out" = "200" ]
}

# ---------------------------------------------------------------------------
# Absent log → null (usage_available:false)

@test "mother-usage parse: absent log file yields null tokens" {
    run mother-usage parse --log "/tmp/mother-test-nonexistent-$$" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "null" ]
    [ "$tokens_out" = "null" ]
}

# ---------------------------------------------------------------------------
# Empty log → null

@test "mother-usage parse: empty log file yields null tokens" {
    local log_file="$MOTHER_ROOT/empty.log"
    touch "$log_file"
    run mother-usage parse --log "$log_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "null" ]
    [ "$tokens_out" = "null" ]
}

# ---------------------------------------------------------------------------
# Banner-only log (no JSON lines) → null

@test "mother-usage parse: banner-only log (no JSON) yields null tokens" {
    local log_file="$MOTHER_ROOT/banner-only.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
Job ID: test-job
Branch: feature/test
Spawning claude worker...
EOF
    run mother-usage parse --log "$log_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "null" ]
    [ "$tokens_out" = "null" ]
}

# ---------------------------------------------------------------------------
# Unparseable / corrupt JSON lines are tolerated and skipped

@test "mother-usage parse: corrupt JSON lines are tolerated and skipped" {
    local log_file="$MOTHER_ROOT/corrupt.log"
    cat > "$log_file" <<'EOF'
=== banner ===
{invalid json here
{"type":"system","content":"not an assistant event"}
EOF
    run mother-usage parse --log "$log_file" --rates "$(_rates)"
    [ "$status" -eq 0 ]
    tokens_in=$(printf '%s' "$output" | jq -r '.tokens_in')
    tokens_out=$(printf '%s' "$output" | jq -r '.tokens_out')
    [ "$tokens_in" = "null" ]
    [ "$tokens_out" = "null" ]
}

# ---------------------------------------------------------------------------
# jq --argjson null / integer literals still valid for runs.jsonl construction
# (kept from the original file: mother-run-job still needs to embed
# mother-usage's null/number outputs into the runs.jsonl metrics line via jq
# --argjson, so this sanity check on the underlying mechanism stays useful).

@test "jq --argjson with null literal produces JSON null in output" {
    result=$(jq -nc --argjson tokens_in null --argjson tokens_out null \
        '{tokens_in: $tokens_in, tokens_out: $tokens_out}')
    [ "$result" = '{"tokens_in":null,"tokens_out":null}' ]
}

@test "jq --argjson with integer values produces JSON numbers in output" {
    result=$(jq -nc --argjson tokens_in 12345 --argjson tokens_out 678 \
        '{tokens_in: $tokens_in, tokens_out: $tokens_out}')
    [ "$result" = '{"tokens_in":12345,"tokens_out":678}' ]
}
