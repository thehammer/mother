#!/usr/bin/env bash
# segment.sh — opt-in statusline segment for Mother.
#
# Source this file from your own statusline.sh and call `mother_segment` at the
# point in the line where you want the queue state to render. Writes a short
# ANSI-coloured string like:  Q ▶2 ⏸5 ?1  (running, queued, awaiting),
# with a trailing  !3 in red for any failures.
#
# Hidden entirely when all counts are zero.
#
# Cache:
#   $MOTHER_STATUSLINE_CACHE (default: /tmp/.mother-statusline) — single line,
#   colon-separated "RUNNING:QUEUED:FAILED:AWAITING" counts. The awaiting
#   field was added later and lives at the end so old caches written by an
#   older version still parse: a missing fourth field defaults to zero, and
#   a fresh refresh (TTL ~10s) overwrites the cache in the new format.
#   TTL-based refresh in the background keeps the statusline fast.

: "${MOTHER_STATUSLINE_CACHE:=/tmp/.mother-statusline}"
: "${MOTHER_STATUSLINE_TTL:=10}"  # seconds
: "${MOTHER_ROOT:=$HOME/.mother}"
: "${MOTHER_RATE_LIMIT_CACHE:=$MOTHER_ROOT/rate-limits.json}"
: "${MOTHER_QUOTA_CAP_5H_PCT:=90}"
: "${MOTHER_QUOTA_CAP_7D_PCT:=90}"

# mother_capture_rate_limits: persist the rate_limits portion of a statusline
# JSON payload so tooling that runs outside an interactive Claude Code
# session (notably mother-runner's quota gate) can read the user's true
# rolling quota state. Call from your statusline.sh with the same JSON
# input you pipe through your own jq calls — it's one extra jq invocation.
#
# Schema written:
#   { "five_hour": {"used_percentage": N, "resets_at": <epoch>},
#     "seven_day": {"used_percentage": N, "resets_at": <epoch>} }
#
# Older Claude Code versions may not include `rate_limits` in the payload
# — in that case the cache file is left untouched (so a stale-but-real
# cache from a recent render isn't wiped on a payload that lacks the
# field).
mother_capture_rate_limits() {
    local input="$1"
    local cache="$MOTHER_RATE_LIMIT_CACHE"
    mkdir -p "$(dirname "$cache")" 2>/dev/null
    local tmp="$cache.tmp.$$"
    printf '%s' "$input" \
        | jq -c 'select(.rate_limits) | .rate_limits' > "$tmp" 2>/dev/null
    if [ -s "$tmp" ]; then
        mv "$tmp" "$cache"
    else
        rm -f "$tmp"
    fi
}

# Refresh the cache by scanning $MOTHER_ROOT/jobs/*.json and counting by state.
# Writes "R:Q:F" atomically. Safe to call from the background.
mother_statusline_refresh() {
    local cache="${1:-$MOTHER_STATUSLINE_CACHE}"
    local tmp="${cache}.tmp.$$"
    local jobs_dir="$MOTHER_ROOT/jobs"

    # If there's no jobs dir at all, empty cache (nothing to show).
    if [ ! -d "$jobs_dir" ]; then
        : > "$cache"
        return 0
    fi

    local counts
    counts=$(find "$jobs_dir" -maxdepth 1 -name '*.json' -type f 2>/dev/null \
        | while read -r f; do
            jq -r '.state' "$f" 2>/dev/null
        done \
        | awk '
            /^running$/  { r++ }
            /^queued$/   { q++ }
            /^ready$/    { q++ }
            /^failed$/   { fa++ }
            /^awaiting$/ { a++ }
            END { printf "%d:%d:%d:%d\n", r+0, q+0, fa+0, a+0 }
        ')

    printf '%s\n' "$counts" > "$tmp" && mv "$tmp" "$cache"
}

# Render the statusline segment. Trailing space, no separator — callers add
# their own. Empty output when all counts are zero.
mother_segment() {
    local cache="$MOTHER_STATUSLINE_CACHE"
    local ttl="$MOTHER_STATUSLINE_TTL"

    if [ ! -f "$cache" ]; then
        # First run — trigger a refresh so future renders have data. Return empty.
        ( mother_statusline_refresh "$cache" >/dev/null 2>&1 ) &
        return 0
    fi

    local age
    age=$(( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
    if [ "$age" -ge "$ttl" ]; then
        ( mother_statusline_refresh "$cache" >/dev/null 2>&1 ) &
    fi

    local _mr _mq _mf _ma
    # Read up to 4 fields. Old caches (3 fields, no awaiting) leave _ma empty,
    # which the default below maps to 0 — correct until the next refresh
    # overwrites the cache in the new format.
    IFS=: read -r _mr _mq _mf _ma < "$cache" 2>/dev/null \
        || { _mr=0; _mq=0; _mf=0; _ma=0; }
    : "${_mr:=0}" "${_mq:=0}" "${_mf:=0}" "${_ma:=0}"

    # Only render if something non-zero.
    if ! { [ "$_mr" -gt 0 ] 2>/dev/null \
        || [ "$_mq" -gt 0 ] 2>/dev/null \
        || [ "$_mf" -gt 0 ] 2>/dev/null \
        || [ "$_ma" -gt 0 ] 2>/dev/null; }; then
        return 0
    fi

    local reset='\033[38;5;245m'
    local out=" ${reset}Q"
    [ "$_mr" -gt 0 ] && out="${out} \033[38;5;220m▶${_mr}${reset}"  # yellow — running
    [ "$_mq" -gt 0 ] && out="${out} \033[38;5;75m⏸${_mq}${reset}"   # blue — queued/ready
    # Awaiting jobs come BEFORE failures because they need operator action
    # to make progress — surfacing them with a question-mark glyph in
    # orange makes them stand out without crying wolf the way red would.
    [ "$_ma" -gt 0 ] && out="${out} \033[38;5;208m?${_ma}${reset}"  # orange — awaiting input
    [ "$_mf" -gt 0 ] && out="${out} \033[38;5;203m!${_mf}${reset}"  # red — failed

    # Quota gate indicator: 🚦 if either rolling window is over its cap.
    # Rendered last so it sits next to the failure count, signalling that
    # Mother is currently holding new dispatches back. Cheap inline check —
    # one jq call against the small rate_limits cache. We don't surface the
    # actual percentages here; `mother list` / popup peek can show those.
    if [ -r "$MOTHER_RATE_LIMIT_CACHE" ]; then
        local _rl_p5 _rl_r5 _rl_p7 _rl_r7
        IFS=$'\t' read -r _rl_p5 _rl_r5 _rl_p7 _rl_r7 < <(jq -r '
            [(.five_hour.used_percentage // 0),
             (.five_hour.resets_at // 0),
             (.seven_day.used_percentage // 0),
             (.seven_day.resets_at // 0)] | @tsv
        ' "$MOTHER_RATE_LIMIT_CACHE" 2>/dev/null) || true
        : "${_rl_p5:=0}" "${_rl_r5:=0}" "${_rl_p7:=0}" "${_rl_r7:=0}"
        local _now; _now=$(date +%s)
        # If a window has rolled over since the cache was written, treat
        # its percentage as 0 (in our favor — the new window is fresh).
        [ "${_rl_r5%.*}" -gt 0 ] && [ "$_now" -gt "${_rl_r5%.*}" ] && _rl_p5=0
        [ "${_rl_r7%.*}" -gt 0 ] && [ "$_now" -gt "${_rl_r7%.*}" ] && _rl_p7=0
        if [ "${_rl_p5%.*}" -ge "$MOTHER_QUOTA_CAP_5H_PCT" ] \
            || [ "${_rl_p7%.*}" -ge "$MOTHER_QUOTA_CAP_7D_PCT" ]; then
            out="${out} \033[38;5;208m🚦${reset}"
        fi
    fi

    out="${out} "

    printf '%b' "$out"
}
