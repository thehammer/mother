#!/usr/bin/env bash
# segment.sh — opt-in statusline segment for Mother.
#
# Source this file from your own statusline.sh and call `mother_segment` at the
# point in the line where you want the queue state to render. Writes a short
# coloured string like:  Q ▶2 ⏸5   (running, queued)
#
# Trailing  !3  in red is appended if there are unseen failures.
#
# Hidden entirely when all counts are zero.

: "${MOTHER_STATUSLINE_CACHE:=/tmp/.mother-statusline}"
: "${MOTHER_STATUSLINE_TTL:=10}"  # seconds

mother_segment() {
    # TODO: port the real implementation from
    # ~/.claude/bin/statusline-queue-refresh (if merged into the statusline)
    # or the statusline.sh queue block. Should:
    #   - read $MOTHER_STATUSLINE_CACHE (a JSON blob with running/queued/failed counts)
    #   - if older than MOTHER_STATUSLINE_TTL, spawn a background refresher
    #     that writes fresh counts to the cache (non-blocking)
    #   - render the segment with ANSI colour escapes matching the user's theme
    #   - return empty string if all counts are zero (caller can conditionally
    #     insert a separator)
    echo ""  # no-op stub
}

# Also export a refresher that can be cron'd or launchd'd for out-of-band updates.
mother_statusline_refresh() {
    local counts
    counts=$(mother list --format json 2>/dev/null \
        | jq -c '{
            running: map(select(.state=="running")) | length,
            queued:  map(select(.state=="queued" or .state=="ready")) | length,
            failed:  map(select(.state=="failed")) | length
        }') || return 1
    echo "$counts" > "$MOTHER_STATUSLINE_CACHE.tmp.$$" \
        && mv "$MOTHER_STATUSLINE_CACHE.tmp.$$" "$MOTHER_STATUSLINE_CACHE"
}
