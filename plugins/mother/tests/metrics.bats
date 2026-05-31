#!/usr/bin/env bats
# metrics.bats — tests for _sum_tokens jq pipeline and runs.jsonl token fields.
#
# _sum_tokens is defined inside mother-run-job (not separately sourceable),
# so we test the jq pipeline directly against fixture log content written
# via heredoc. This exercises the same logic without sourcing the full script.

load 'test_helper'

setup() {
    setup_mother_env
    export METRICS_DIR="$MOTHER_ROOT/metrics"
    mkdir -p "$METRICS_DIR"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helper: run the _sum_tokens jq pipeline against a log file.
# Echoes "<tokens_in> <tokens_out>" or "null null".
_run_sum_tokens() {
    local lp="$1"
    [ -n "$lp" ] && [ -s "$lp" ] || { echo "null null"; return 0; }
    local out
    out=$(jq -rR 'fromjson? // empty
              | select(.type == "assistant" and .message.usage != null)
              | {id: .message.id, u: .message.usage}' "$lp" 2>/dev/null \
        | jq -rs 'if length == 0 then "null null"
              else group_by(.id) | map(.[0].u)
                   | { ti: (map((.input_tokens//0)
                              + (.cache_creation_input_tokens//0)
                              + (.cache_read_input_tokens//0)) | add // 0),
                       to: (map(.output_tokens//0) | add // 0) }
                   | "\(.ti) \(.to)"
              end' 2>/dev/null)
    if [ -z "$out" ]; then echo "null null"; return 0; fi
    echo "$out"
}

# ---------------------------------------------------------------------------
# Multi-turn sum: two distinct assistant message ids

@test "sum_tokens: two distinct assistant turns sums tokens correctly" {
    local log_file="$MOTHER_ROOT/two-turns.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
{"type":"assistant","message":{"id":"msg_aaa","usage":{"input_tokens":100,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50}}}
{"type":"assistant","message":{"id":"msg_bbb","usage":{"input_tokens":10,"cache_creation_input_tokens":20,"cache_read_input_tokens":30,"output_tokens":5}}}
EOF
    # tokens_in = (100+200+300) + (10+20+30) = 600 + 60 = 660
    # tokens_out = 50 + 5 = 55
    result=$(_run_sum_tokens "$log_file")
    [ "$result" = "660 55" ]
}

# ---------------------------------------------------------------------------
# Dedup by message.id: same id appears multiple times (stream-json pattern)

@test "sum_tokens: duplicate message.id events are counted only once" {
    local log_file="$MOTHER_ROOT/dedup.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
{"type":"assistant","message":{"id":"msg_aaa","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
{"type":"assistant","message":{"id":"msg_aaa","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
{"type":"assistant","message":{"id":"msg_aaa","usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50}}}
EOF
    # Despite 3 lines, all same id — should count as 1 message
    # tokens_in = 100, tokens_out = 50
    result=$(_run_sum_tokens "$log_file")
    [ "$result" = "100 50" ]
}

# ---------------------------------------------------------------------------
# Dedup + multi-turn: mix of repeated and unique ids

@test "sum_tokens: mix of duplicate and unique ids deduplicates correctly" {
    local log_file="$MOTHER_ROOT/mixed.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
{"type":"assistant","message":{"id":"msg_aaa","usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":0,"output_tokens":100}}}
{"type":"assistant","message":{"id":"msg_aaa","usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":0,"output_tokens":100}}}
{"type":"assistant","message":{"id":"msg_bbb","usage":{"input_tokens":200,"cache_creation_input_tokens":0,"cache_read_input_tokens":800,"output_tokens":75}}}
EOF
    # msg_aaa counted once: in=1000+500+0=1500, out=100
    # msg_bbb counted once: in=200+0+800=1000, out=75
    # total: in=2500, out=175
    result=$(_run_sum_tokens "$log_file")
    [ "$result" = "2500 175" ]
}

# ---------------------------------------------------------------------------
# Cache fields: all three input sub-fields contribute to tokens_in

@test "sum_tokens: all three input token sub-fields are summed into tokens_in" {
    local log_file="$MOTHER_ROOT/cache.log"
    cat > "$log_file" <<'EOF'
{"type":"assistant","message":{"id":"msg_ccc","usage":{"input_tokens":100,"cache_creation_input_tokens":50000,"cache_read_input_tokens":200000,"output_tokens":1234}}}
EOF
    # tokens_in = 100 + 50000 + 200000 = 250100
    # tokens_out = 1234
    result=$(_run_sum_tokens "$log_file")
    [ "$result" = "250100 1234" ]
}

# ---------------------------------------------------------------------------
# result event is NOT used for totals (it only has the last turn's usage)

@test "sum_tokens: result event usage is ignored; totals come from assistant events" {
    local log_file="$MOTHER_ROOT/with-result.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
{"type":"assistant","message":{"id":"msg_aaa","usage":{"input_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":100}}}
{"type":"assistant","message":{"id":"msg_bbb","usage":{"input_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":100}}}
{"type":"result","subtype":"success","usage":{"input_tokens":500,"output_tokens":100},"modelUsage":{}}
EOF
    # Should sum the two assistant turns: in=1000, out=200
    # The result event (input_tokens=500, output_tokens=100) must NOT be used
    result=$(_run_sum_tokens "$log_file")
    [ "$result" = "1000 200" ]
}

# ---------------------------------------------------------------------------
# Absent log → null null

@test "sum_tokens: absent log file echoes null null" {
    result=$(_run_sum_tokens "/tmp/mother-test-nonexistent-$$")
    [ "$result" = "null null" ]
}

# ---------------------------------------------------------------------------
# Empty log → null null

@test "sum_tokens: empty log file echoes null null" {
    local log_file="$MOTHER_ROOT/empty.log"
    touch "$log_file"
    result=$(_run_sum_tokens "$log_file")
    [ "$result" = "null null" ]
}

# ---------------------------------------------------------------------------
# Banner-only log (no JSON lines) → null null

@test "sum_tokens: banner-only log (no JSON) echoes null null" {
    local log_file="$MOTHER_ROOT/banner-only.log"
    cat > "$log_file" <<'EOF'
=== mother job test-job starting ===
Job ID: test-job
Branch: feature/test
Spawning claude worker...
EOF
    result=$(_run_sum_tokens "$log_file")
    [ "$result" = "null null" ]
}

# ---------------------------------------------------------------------------
# Unparseable / corrupt JSON lines → null null (fromjson? drops bad lines)

@test "sum_tokens: corrupt JSON lines are tolerated and skipped" {
    local log_file="$MOTHER_ROOT/corrupt.log"
    cat > "$log_file" <<'EOF'
=== banner ===
{invalid json here
{"type":"system","content":"not an assistant event"}
EOF
    result=$(_run_sum_tokens "$log_file")
    [ "$result" = "null null" ]
}

# ---------------------------------------------------------------------------
# jq --argjson null is valid JSON null in the metrics record

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
