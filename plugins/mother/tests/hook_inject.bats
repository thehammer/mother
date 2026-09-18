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
