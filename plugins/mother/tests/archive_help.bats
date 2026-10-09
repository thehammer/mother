#!/usr/bin/env bats
# archive_help.bats — `mother --help` documents both archive forms, and the
# bulk form rejects a non-integer --older-than cleanly.

load 'test_helper'

setup() { setup_mother_env; }

@test "--help documents single-id and bulk archive forms" {
    run mother --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"mother archive <id>"* ]]
    [[ "$output" == *"mother archive [--older-than DAYS]"* ]]
}

@test "archive --older-than rejects a non-integer with a clear error" {
    run mother archive --older-than 1.5
    [ "$status" -ne 0 ]
    [[ "$output" == *"whole number of days"* ]]
    [[ "$output" != *"syntax error"* ]]
}

@test "archive --older-than with no value fails fast instead of hanging" {
    mother archive --older-than >"$BATS_TEST_TMPDIR/out" 2>&1 &
    local pid=$!
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.5
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
        echo "archive --older-than hung" >&2
        false
    fi
    local rc=0
    wait "$pid" || rc=$?
    [ "$rc" -ne 0 ]
    grep -q -- "--older-than" "$BATS_TEST_TMPDIR/out"
}

@test "archive --older-than 08 and 09 are valid decimal, not a raw octal arithmetic error" {
    for v in 08 09; do
        run mother archive --older-than "$v" --dry-run
        [ "$status" -eq 0 ]
        [[ "$output" != *"value too great for base"* ]]
    done
}

@test "archive --older-than 030 means 30 days, not octal 24" {
    run mother archive --older-than 30 --dry-run
    [ "$status" -eq 0 ]
    thirty="$(printf '%s\n' "$output" | grep -o 'cutoff: [0-9T:-]*' | head -1 | cut -c9-18)"
    run mother archive --older-than 030 --dry-run
    [ "$status" -eq 0 ]
    padded="$(printf '%s\n' "$output" | grep -o 'cutoff: [0-9T:-]*' | head -1 | cut -c9-18)"
    [ -n "$thirty" ]
    [ "$thirty" = "$padded" ]
}

@test "archive --older-than rejects an absurdly large number instead of overflowing" {
    run mother archive --older-than 99999999999999999999 --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"too large"* ]]
}
