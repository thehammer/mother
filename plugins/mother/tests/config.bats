#!/usr/bin/env bats
# config.bats — contract tests for lib/config.sh (durable config.env).
#
# Parser rules under test: `MOTHER_[A-Z0-9_]*=value` lines only, `#` comments
# and blanks ignored, one pair of surrounding quotes stripped, the value is
# everything after the FIRST `=`, the file is parsed (never sourced), and the
# environment always wins over the file — even an env var set to "".
# Plist-migration tests live in launchd_plist.bats.

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"

setup() {
    export MOTHER_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$MOTHER_ROOT"
    CONF="$MOTHER_ROOT/config.env"
    unset MOTHER_T_A MOTHER_T_B MOTHER_T_C MOTHER_CONCURRENCY
    source "$PLUGIN_DIR/lib/config.sh"
}

_runner_effective() {
    # What a freshly started runner resolves, as "<value>|<source>".
    env -u MOTHER_CONCURRENCY MOTHER_ROOT="$MOTHER_ROOT" \
        "$PLUGIN_DIR/bin/mother-runner" --publish-config-tick >/dev/null 2>&1
    jq -r '"\(.concurrency)|\(.concurrency_source)"' "$MOTHER_ROOT/runner/effective-config.json"
}

@test "comment and blank lines are ignored" {
    printf '# MOTHER_T_A=nope\n\n   \n  # indented comment\nMOTHER_T_B=yes\n' > "$CONF"
    mother_config_load
    [ -z "${MOTHER_T_A:-}" ]
    [ "$MOTHER_T_B" = "yes" ]
}

@test "lines whose key is not MOTHER_[A-Z0-9_]* are ignored" {
    printf 'OTHER_T=1\nmother_t_lower=2\nMOTHER_T-A=3\nMOTHER_Tx=4\n MOTHER_T_A=5\nMOTHER_T_B=ok\n' > "$CONF"
    mother_config_load
    [ -z "${OTHER_T:-}" ]
    [ -z "${mother_t_lower:-}" ]
    [ -z "${MOTHER_T_A:-}" ]
    [ "$MOTHER_T_B" = "ok" ]
}

@test "double quotes are stripped" {
    echo 'MOTHER_T_A="hello world"' > "$CONF"
    mother_config_load
    [ "$MOTHER_T_A" = "hello world" ]
}

@test "single quotes are stripped" {
    echo "MOTHER_T_A='hello world'" > "$CONF"
    mother_config_load
    [ "$MOTHER_T_A" = "hello world" ]
}

@test "mismatched or inner quotes are left alone" {
    printf 'MOTHER_T_A="abc\x27\nMOTHER_T_B=a"b"c\n' > "$CONF"
    mother_config_load
    [ "$MOTHER_T_A" = "\"abc'" ]
    [ "$MOTHER_T_B" = 'a"b"c' ]
}

@test "a value containing '=' keeps everything after the first '='" {
    echo 'MOTHER_T_A=a=b=c' > "$CONF"
    mother_config_load
    [ "$MOTHER_T_A" = "a=b=c" ]
    [ "$(mother_config_get MOTHER_T_A)" = "a=b=c" ]
}

@test "the last line is read when the file has no trailing newline" {
    printf 'MOTHER_T_A=1\nMOTHER_T_B=2' > "$CONF"
    mother_config_load
    [ "$MOTHER_T_B" = "2" ]
    [ "$(mother_config_get MOTHER_T_B)" = "2" ]
}

@test "an env var set to the empty string still wins over the file" {
    echo 'MOTHER_T_A=fromfile' > "$CONF"
    export MOTHER_T_A=""
    mother_config_load
    [ -z "$MOTHER_T_A" ]
    [ "$(mother_config_source MOTHER_T_A)" = "env" ]
}

@test "an unset env var takes the file value and reports 'config file'" {
    echo 'MOTHER_T_A=fromfile' > "$CONF"
    mother_config_load
    [ "$MOTHER_T_A" = "fromfile" ]
    [ "$(mother_config_source MOTHER_T_A)" = "config file" ]
}

@test "source is 'default' when neither env nor file set the var" {
    mother_config_load
    [ "$(mother_config_source MOTHER_T_C)" = "default" ]
}

@test "a missing config.env is not an error" {
    run mother_config_load
    [ "$status" -eq 0 ]
    [ -z "$(mother_config_get MOTHER_T_A)" ]
}

@test "values are never executed" {
    printf 'MOTHER_T_A=$(touch %s/pwned)\nMOTHER_T_B=`touch %s/pwned2`\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$CONF"
    mother_config_load
    [ "$MOTHER_T_A" = "\$(touch $BATS_TEST_TMPDIR/pwned)" ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
}

@test "mother_config_set adds a new key" {
    mother_config_set MOTHER_T_A 1
    [ "$(cat "$CONF")" = "MOTHER_T_A=1" ]
}

@test "mother_config_set replaces an existing key instead of duplicating it" {
    printf 'MOTHER_T_A=1\nMOTHER_T_B=2\n' > "$CONF"
    mother_config_set MOTHER_T_A 9
    [ "$(grep -c '^MOTHER_T_A=' "$CONF")" = "1" ]
    [ "$(mother_config_get MOTHER_T_A)" = "9" ]
    [ "$(mother_config_get MOTHER_T_B)" = "2" ]
}

@test "runner defaults to concurrency 2 from 'default' with no env or config" {
    run _runner_effective
    [ "$output" = "2|default" ]
}

@test "environment variable wins over config.env and is reported as env" {
    mkdir -p "$MOTHER_ROOT/runner"
    echo "MOTHER_CONCURRENCY=3" > "$CONF"
    MOTHER_CONCURRENCY=7 "$PLUGIN_DIR/bin/mother-runner" --publish-config-tick >/dev/null 2>&1
    run jq -r '"\(.concurrency)|\(.concurrency_source)"' "$MOTHER_ROOT/runner/effective-config.json"
    [ "$output" = "7|env" ]
}

@test "config.env is parsed, not executed, by the runner" {
    printf 'MOTHER_CONCURRENCY="3"\nMOTHER_EVIL=$(touch %s/pwned)\n' "$BATS_TEST_TMPDIR" > "$CONF"
    run _runner_effective
    [ "$output" = "3|config file" ]
    [ ! -e "$BATS_TEST_TMPDIR/pwned" ]
}

@test "mother status reports effective concurrency and its source" {
    echo "MOTHER_CONCURRENCY=3" > "$CONF"
    run env -u MOTHER_CONCURRENCY MOTHER_ROOT="$MOTHER_ROOT" "$PLUGIN_DIR/bin/mother" status --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.concurrency.value')" = "3" ]
    [ "$(printf '%s' "$output" | jq -r '.concurrency.source')" = "config file" ]
}
