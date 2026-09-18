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

# Write an event with a timestamp N minutes in the past (default 0 = ~now).
write_event_ago() {
    local id="$1" kind="$2" mins="${3:-0}"
    local ts
    ts=$(/usr/bin/perl -MPOSIX=strftime -e '
        my @t = gmtime(time() - ($ARGV[0] * 60));
        printf "%sT%s.000Z\n", strftime("%Y-%m-%d", @t), strftime("%H:%M:%S", @t);
    ' "$mins")
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
    # The age floor (tested separately below) would otherwise suppress both
    # of these 2021 events under a default floor; disable it here so this
    # test stays focused on cursor semantics in isolation.
    export MOTHER_EVENTS_MAX_AGE_HOURS=0
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

# ---------------------------------------------------------------------------
# Regression: an unreadable/invalid cursor must be treated exactly like a
# brand-new session (bootstrap to "now"), never as "no floor, replay
# everything." This is the core of the 2026-07-14 stale-event-replay bug.

@test "events --since-cursor re-bootstraps on a zero-byte cursor file instead of replaying history" {
    : > "$CURSORS_DIR/sess-zero.json"

    write_event "job-old" "2026-05-19T16:19:19Z" "queued"

    run mother events --since-cursor sess-zero
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 0 ]

    [ -f "$CURSORS_DIR/sess-zero.json" ]
    local seen
    seen=$(jq -r '.last_seen' "$CURSORS_DIR/sess-zero.json")
    [ -n "$seen" ]
    [ "$seen" \> "2026-05-19T16:19:19Z" ]
}

@test "events --since-cursor re-bootstraps when the cursor has no last_seen key" {
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' '{}' > "$CURSORS_DIR/sess-nokey.json"

    write_event "job-old" "2026-05-19T16:19:19Z" "queued"

    run mother events --since-cursor sess-nokey
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 0 ]

    [ -f "$CURSORS_DIR/sess-nokey.json" ]
    local seen
    seen=$(jq -r '.last_seen' "$CURSORS_DIR/sess-nokey.json")
    [ -n "$seen" ]
    [ "$seen" \> "2026-05-19T16:19:19Z" ]
}

@test "events --since-cursor re-bootstraps when last_seen is null" {
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' '{"last_seen": null}' > "$CURSORS_DIR/sess-null.json"

    write_event "job-old" "2026-05-19T16:19:19Z" "queued"

    run mother events --since-cursor sess-null
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 0 ]

    [ -f "$CURSORS_DIR/sess-null.json" ]
    local seen
    seen=$(jq -r '.last_seen' "$CURSORS_DIR/sess-null.json")
    [ -n "$seen" ]
    [ "$seen" \> "2026-05-19T16:19:19Z" ]
}

@test "events --since-cursor re-bootstraps on a non-JSON cursor file" {
    mkdir -p "$CURSORS_DIR"
    printf 'not json at all' > "$CURSORS_DIR/sess-badjson.json"

    write_event "job-old" "2026-05-19T16:19:19Z" "queued"

    run mother events --since-cursor sess-badjson
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 0 ]

    [ -f "$CURSORS_DIR/sess-badjson.json" ]
    local seen
    seen=$(jq -r '.last_seen' "$CURSORS_DIR/sess-badjson.json")
    [ -n "$seen" ]
    [ "$seen" \> "2026-05-19T16:19:19Z" ]
}

@test "events --since-cursor re-bootstraps when last_seen is not an ISO timestamp" {
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' '{"last_seen": "yesterday"}' > "$CURSORS_DIR/sess-badts.json"

    write_event "job-old" "2026-05-19T16:19:19Z" "queued"

    run mother events --since-cursor sess-badts
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 0 ]

    [ -f "$CURSORS_DIR/sess-badts.json" ]
    local seen
    seen=$(jq -r '.last_seen' "$CURSORS_DIR/sess-badts.json")
    [ -n "$seen" ]
    [ "$seen" \> "2026-05-19T16:19:19Z" ]
}

# ---------------------------------------------------------------------------
# Age floor: MOTHER_EVENTS_MAX_AGE_HOURS bounds how far back --since-cursor
# will ever reach, even under a syntactically valid but very stale cursor.
# This is the second line of defense: it caps the blast radius of any single
# ancient orphaned events file, regardless of cursor validity.

@test "events --since-cursor age floor suppresses an ancient event even under a valid, stale cursor" {
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' '{"last_seen": "2020-01-01T00:00:00Z"}' > "$CURSORS_DIR/sess-stale.json"

    write_event "job-ancient" "2026-05-19T16:19:19Z" "succeeded"

    run mother events --since-cursor sess-stale
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 0 ]

    # The cursor must still advance to (at least) the ancient
    # (floor-suppressed) event's own timestamp, based on the full unfiltered
    # event set -- otherwise a single ancient orphaned event file would pin
    # the cursor in the past forever. Equality, not strict advance past it,
    # is the correct and sufficient outcome here: the aggregation filter
    # excludes events with .ts > $since (strict), so a cursor sitting exactly
    # on this event's timestamp already guarantees it is never replayed
    # again on a subsequent call -- which is the actual invariant this test
    # protects. (Contrast with the bootstrap tests above, which advance the
    # cursor to "now" and can assert strict advance because "now" truly is
    # later than any seeded event.)
    local seen
    seen=$(jq -r '.last_seen' "$CURSORS_DIR/sess-stale.json")
    [ -n "$seen" ]
    [ "$seen" = "2026-05-19T16:19:19Z" ] || [ "$seen" \> "2026-05-19T16:19:19Z" ]
}

@test "events --since-cursor age floor does not suppress a recent event" {
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' '{"last_seen": "2020-01-01T00:00:00Z"}' > "$CURSORS_DIR/sess-stale2.json"

    write_event_ago "job-recent" "succeeded" 1

    run mother events --since-cursor sess-stale2
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 1 ]
}

@test "MOTHER_EVENTS_MAX_AGE_HOURS=0 disables the age floor" {
    export MOTHER_EVENTS_MAX_AGE_HOURS=0
    mkdir -p "$CURSORS_DIR"
    printf '%s\n' '{"last_seen": "2020-01-01T00:00:00Z"}' > "$CURSORS_DIR/sess-nofloor.json"

    write_event "job-ancient" "2026-05-19T16:19:19Z" "succeeded"

    run mother events --since-cursor sess-nofloor
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 1 ]
}

@test "the age floor does not apply to --since" {
    write_event "job-ancient" "2026-05-19T16:19:19Z" "succeeded"

    run mother events --since 2020-01-01T00:00:00Z
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 1 ]
}

@test "the age floor does not apply to plain mother events" {
    write_event "job-ancient" "2026-05-19T16:19:19Z" "succeeded"

    run mother events
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq 'length')" -eq 1 ]
}
