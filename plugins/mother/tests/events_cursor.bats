#!/usr/bin/env bats
# events_cursor.bats — `mother events --since-cursor` cursor handling.

load 'test_helper'

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
}

# Write a single event line into a job's events file.
# Usage: write_event <job_id> <iso_ts> <kind>
write_event() {
    local id="$1" ts="$2" kind="$3"
    printf '%s\n' "$(jq -nc --arg ts "$ts" --arg k "$kind" '{ts: $ts, kind: $k, detail: {}}')" \
        >> "$EVENTS_DIR/$id.jsonl"
}

# ---------------------------------------------------------------------------
# Brand-new session: bootstrap the cursor to "now" instead of replaying all
# history (which would flood a session's first --since-cursor call).

@test "events --since-cursor bootstraps a brand-new session's cursor and does not replay history" {
    # Historical event well in the past.
    write_event "job-old" "2020-01-01T00:00:00Z" "queued"

    # No cursor file exists for this session yet.
    [ ! -f "$CURSORS_DIR/sess-new.json" ]

    run mother events --since-cursor sess-new
    [ "$status" -eq 0 ]

    # Old history is NOT replayed (bootstrap set the floor to ~now).
    [ "$(echo "$output" | jq 'length')" -eq 0 ]

    # The cursor file was created, with a last_seen at/after the historical event.
    [ -f "$CURSORS_DIR/sess-new.json" ]
    local seen
    seen=$(jq -r '.last_seen' "$CURSORS_DIR/sess-new.json")
    [ -n "$seen" ]
    [ "$seen" \> "2020-01-01T00:00:00Z" ]
}

@test "events --since-cursor on a fresh session still surfaces events emitted after bootstrap" {
    # Bootstrap the session (no prior cursor, no events yet).
    run mother events --since-cursor sess-live
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 0 ]

    # An event emitted in the far future (guaranteed after the bootstrap floor).
    write_event "job-future" "2999-01-01T00:00:00Z" "succeeded"

    run mother events --since-cursor sess-live
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.[0].kind')" = "succeeded" ]
}

# ---------------------------------------------------------------------------
# Regression: an EXISTING cursor still drives replay from its last_seen
# (the bootstrap branch must not shadow the existing-cursor branch).

@test "events --since-cursor honors an existing cursor's last_seen" {
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' "$(jq -nc '{last_seen: "2021-06-01T00:00:00Z"}')" > "$CURSORS_DIR/sess-existing.json"

    write_event "job-before" "2021-01-01T00:00:00Z" "queued"
    write_event "job-after"  "2021-12-01T00:00:00Z" "succeeded"

    run mother events --since-cursor sess-existing
    [ "$status" -eq 0 ]
    # Only the event after last_seen is returned.
    [ "$(echo "$output" | jq 'length')" -eq 1 ]
    [ "$(echo "$output" | jq -r '.[0].kind')" = "succeeded" ]
}
