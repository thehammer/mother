#!/usr/bin/env bats
# hook_inject.bats — end-to-end regression coverage for the UserPromptSubmit
# hook (hooks/mother-inject.sh), which is what actually injects queue-update
# banners into a live Claude Code session's context.
#
# Regression coverage for the 2026-07-14 bug where the hook replayed
# two-month-old archived-job events as if they were live failures, because
# an unreadable/stale session cursor silently degraded `mother events
# --since-cursor` into "return everything ever recorded."

load 'test_helper'

setup() {
    setup_mother_env
    export CLAUDE_PLUGIN_ROOT="$MOTHER_PLUGIN_DIR"
    HOOK="$MOTHER_PLUGIN_DIR/hooks/mother-inject.sh"
}

teardown() {
    teardown_mother_env
}

# Reproduce the orphaned-events-file shape from the real bug: a job's JSON
# record has already been archived (not in $JOBS_DIR, only in $ARCHIVE_DIR),
# but its raw events .jsonl file is still sitting in $EVENTS_DIR (this is a
# real, currently-existing state on disk -- archiving code doesn't always
# carry the events file along, and some append paths recreate it after
# archival). The hook must not treat this as "news."
seed_stale_archived_job() {
    local id="20260519T153212Z-cd243508"
    mkdir -p "$ARCHIVE_DIR/2026-05"
    jq -n --arg id "$id" '{id: $id, title: "old job", state: "failed",
                           finished_at: "2026-05-19T16:23:32Z"}' \
        > "$ARCHIVE_DIR/2026-05/$id.json"
    printf '%s\n' \
        '{"ts":"2026-05-19T16:19:22.496266Z","kind":"running","detail":{}}' \
        '{"ts":"2026-05-19T16:23:32Z","kind":"failed","detail":{"reason":"no_pr_no_push"}}' \
        > "$EVENTS_DIR/$id.jsonl"
    echo "$id"
}

@test "the hook emits nothing for a long-archived job when the session cursor is unreadable" {
    seed_stale_archived_job >/dev/null
    : > "$CURSORS_DIR/sess-hook.json"   # zero-byte cursor: unreadable

    run bash -c "printf '%s' '{\"session_id\":\"sess-hook\"}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the hook emits nothing for a long-archived job when the session cursor is valid but months stale" {
    seed_stale_archived_job >/dev/null
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' '{"last_seen": "2026-05-01T00:00:00Z"}' > "$CURSORS_DIR/sess-hook.json"

    run bash -c "printf '%s' '{\"session_id\":\"sess-hook\"}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the hook emits nothing and bootstraps the cursor when it is missing entirely" {
    seed_stale_archived_job >/dev/null
    [ ! -f "$CURSORS_DIR/sess-hook.json" ]

    run bash -c "printf '%s' '{\"session_id\":\"sess-hook\"}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$CURSORS_DIR/sess-hook.json" ]
}

@test "positive control: the hook still reports a genuinely fresh failure" {
    make_job "job-live" "failed"
    ts=$(/usr/bin/perl -MPOSIX=strftime -e '
        my @t = gmtime(time() - 60);
        printf "%sT%s.000Z\n", strftime("%Y-%m-%d", @t), strftime("%H:%M:%S", @t);
    ')
    printf '%s\n' "$(jq -nc --arg ts "$ts" '{ts: $ts, kind: "failed", detail: {reason: "no_pr_no_push"}}')" \
        > "$EVENTS_DIR/job-live.jsonl"
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' '{"last_seen": "2020-01-01T00:00:00Z"}' > "$CURSORS_DIR/sess-hook.json"

    run bash -c "printf '%s' '{\"session_id\":\"sess-hook\"}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Queue updates since your last message"* ]]
    [[ "$output" == *"[failed]"* ]]
}

@test "the hook stays silent and exits 0 on a payload with no session_id" {
    run bash -c "printf '%s' '{}' | '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ===========================================================================
# CLI resolution and event age floor
#
# The hook must talk to the CLI the running daemon uses, not whatever stale
# copy a plugin cache happens to hold (a stale cached CLI once replayed
# two-month-old failures into a live session), and independently of the CLI it
# ends up with it must never surface an event older than
# MOTHER_EVENTS_MAX_AGE_HOURS (default 6; 0 disables the floor).
#
# Resolution order: $MOTHER_CLI -> $MOTHER_ROOT/runner/cli-path ->
# $CLAUDE_PLUGIN_ROOT/bin/mother -> `command -v mother`.
# ===========================================================================

# A fake plugin dir whose bin/mother records that it ran and prints a canned
# event array (read from $MOTHER_ROOT/fake-events.json). Echoes the dir.
# Usage: _make_fake_plugin_root <name>
_make_fake_plugin_root() {
    local dir="$MOTHER_ROOT/$1"
    mkdir -p "$dir/bin"
    cat > "$dir/bin/mother" <<FAKE
#!/usr/bin/env bash
echo "invoked \$*" >> "$dir/invoked"
cat "$MOTHER_ROOT/fake-events.json" 2>/dev/null || echo '[]'
FAKE
    chmod +x "$dir/bin/mother"
    echo "$dir"
}

# ISO timestamp <seconds> ago in one of the three precisions the event log
# really contains: plain (…:18Z), micro (…:12.219777Z), milli (…:35.573Z).
# Usage: _ts_ago <seconds> [plain|micro|milli]
_ts_ago() {
    /usr/bin/perl -MPOSIX=strftime -e '
        my ($ago, $fmt) = @ARGV;
        my $t = strftime("%Y-%m-%dT%H:%M:%S", gmtime(time() - $ago));
        my $frac = $fmt eq "micro" ? ".219777" : $fmt eq "milli" ? ".573" : "";
        print "${t}${frac}Z\n";
    ' "$1" "${2:-plain}"
}

# Write the fake CLI's canned events: one failed event per "<title>|<ts>" arg.
# Usage: _fake_events "<title>|<ts>" ...
_fake_events() {
    local arg out="[]"
    for arg in "$@"; do
        out=$(printf '%s' "$out" | jq -c --arg t "${arg%%|*}" --arg ts "${arg#*|}" \
            '. + [{ts: $ts, kind: "failed", job_id: ("job-" + $t), title: $t, detail: {reason: "no_pr_no_push"}}]')
    done
    printf '%s\n' "$out" > "$MOTHER_ROOT/fake-events.json"
}

_run_hook() {
    run bash -c "printf '%s' '{\"session_id\":\"sess-hook\"}' | '$HOOK'"
}

@test "the hook prefers the daemon's CLI from runner/cli-path over a stale CLAUDE_PLUGIN_ROOT copy" {
    local stale; stale=$(_make_fake_plugin_root "stale-plugin")
    _fake_events "STALE-FAILURE|2026-05-19T16:23:32Z"
    printf '%s\n' "$_BIN_DIR/mother" > "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$stale"
    unset MOTHER_CLI
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' '{"last_seen": "2020-01-01T00:00:00Z"}' > "$CURSORS_DIR/sess-hook.json"

    _run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # The stale CLI was never even consulted.
    [ ! -e "$stale/invoked" ]
}

@test "an explicit MOTHER_CLI wins over runner/cli-path" {
    local stale; stale=$(_make_fake_plugin_root "explicit-cli")
    _fake_events "EXPLICIT-CLI-JOB|$(_ts_ago 60)"
    printf '%s\n' "$_BIN_DIR/mother" > "$RUNNER_DIR/cli-path"
    export MOTHER_CLI="$stale/bin/mother"
    unset CLAUDE_PLUGIN_ROOT

    _run_hook
    [ "$status" -eq 0 ]
    [ -e "$stale/invoked" ]
    [[ "$output" == *"EXPLICIT-CLI-JOB"* ]]
}

@test "a runner/cli-path that points at a missing or non-executable file is ignored" {
    local plugin; plugin=$(_make_fake_plugin_root "fallback-plugin")
    _fake_events "FALLBACK-PLUGIN-JOB|$(_ts_ago 60)"
    printf '%s\n' "$MOTHER_ROOT/does-not-exist/mother" > "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$plugin"
    unset MOTHER_CLI

    _run_hook
    [ "$status" -eq 0 ]
    [ -e "$plugin/invoked" ]
    [[ "$output" == *"FALLBACK-PLUGIN-JOB"* ]]
}

@test "with no cli-path the hook falls back to CLAUDE_PLUGIN_ROOT/bin/mother" {
    local plugin; plugin=$(_make_fake_plugin_root "plain-plugin")
    _fake_events "PLAIN-PLUGIN-JOB|$(_ts_ago 60)"
    rm -f "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$plugin"
    unset MOTHER_CLI

    _run_hook
    [ "$status" -eq 0 ]
    [ -e "$plugin/invoked" ]
    [[ "$output" == *"PLAIN-PLUGIN-JOB"* ]]
}

@test "the age floor keeps a stale CLI from replaying months-old failures" {
    local stale; stale=$(_make_fake_plugin_root "stale-plugin-floor")
    _fake_events "OLD-A|2026-05-19T16:23:32Z" "OLD-B|2026-05-19T16:19:22.496266Z"
    rm -f "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$stale"
    unset MOTHER_CLI

    _run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "MOTHER_EVENTS_MAX_AGE_HOURS=0 disables the hook's age floor" {
    local stale; stale=$(_make_fake_plugin_root "stale-plugin-nofloor")
    _fake_events "OLD-NOFLOOR|2026-05-19T16:23:32Z"
    rm -f "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$stale"
    export MOTHER_EVENTS_MAX_AGE_HOURS=0
    unset MOTHER_CLI

    _run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"Queue updates since your last message"* ]]
    [[ "$output" == *"OLD-NOFLOOR"* ]]
}

@test "the age floor defaults to 6 hours: a 7h-old event is dropped, a 5h-old one is shown" {
    local plugin; plugin=$(_make_fake_plugin_root "floor-boundary")
    _fake_events "SEVEN-HOURS-OLD|$(_ts_ago 25200)" "FIVE-HOURS-OLD|$(_ts_ago 18000)"
    rm -f "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$plugin"
    unset MOTHER_CLI MOTHER_EVENTS_MAX_AGE_HOURS

    _run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"FIVE-HOURS-OLD"* ]]
    [[ "$output" != *"SEVEN-HOURS-OLD"* ]]
}

@test "MOTHER_EVENTS_MAX_AGE_HOURS tunes the floor" {
    local plugin; plugin=$(_make_fake_plugin_root "floor-tuned")
    _fake_events "TWO-HOURS-OLD|$(_ts_ago 7200)" "TEN-MINUTES-OLD|$(_ts_ago 600)"
    rm -f "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$plugin"
    export MOTHER_EVENTS_MAX_AGE_HOURS=1
    unset MOTHER_CLI

    _run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"TEN-MINUTES-OLD"* ]]
    [[ "$output" != *"TWO-HOURS-OLD"* ]]
}

@test "fresh events parse in all three timestamp precisions and are all shown" {
    local plugin; plugin=$(_make_fake_plugin_root "precisions")
    _fake_events "PREC-PLAIN|$(_ts_ago 60 plain)" \
                 "PREC-MICRO|$(_ts_ago 60 micro)" \
                 "PREC-MILLI|$(_ts_ago 60 milli)"
    rm -f "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$plugin"
    unset MOTHER_CLI

    _run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"PREC-PLAIN"* ]]
    [[ "$output" == *"PREC-MICRO"* ]]
    [[ "$output" == *"PREC-MILLI"* ]]
}

@test "old events are dropped in all three timestamp precisions" {
    local plugin; plugin=$(_make_fake_plugin_root "precisions-old")
    _fake_events "OLD-PLAIN|2026-05-19T10:00:18Z" \
                 "OLD-MICRO|2026-05-19T10:00:12.219777Z" \
                 "OLD-MILLI|2026-05-19T10:00:35.573Z"
    rm -f "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$plugin"
    unset MOTHER_CLI

    _run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "an event with an unparseable timestamp is dropped without breaking the fresh ones" {
    local plugin; plugin=$(_make_fake_plugin_root "bad-ts")
    _fake_events "BAD-TS-JOB|not-a-timestamp" "GOOD-TS-JOB|$(_ts_ago 60)"
    rm -f "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$plugin"
    unset MOTHER_CLI

    _run_hook
    [ "$status" -eq 0 ]
    [[ "$output" == *"GOOD-TS-JOB"* ]]
    [[ "$output" != *"BAD-TS-JOB"* ]]
}

@test "an event that has no timestamp at all is dropped and the hook stays silent" {
    local plugin; plugin=$(_make_fake_plugin_root "no-ts")
    printf '%s\n' '[{"kind":"failed","job_id":"job-nots","title":"NO-TS-JOB","detail":{}}]' \
        > "$MOTHER_ROOT/fake-events.json"
    rm -f "$RUNNER_DIR/cli-path"
    export CLAUDE_PLUGIN_ROOT="$plugin"
    unset MOTHER_CLI

    _run_hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
