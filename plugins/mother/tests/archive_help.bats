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
