#!/usr/bin/env bash
# segment.sh — opt-in statusline segment for Mother.
#
# Source this file from your own statusline.sh and call `mother_segment` at the
# point in the line where you want the queue state to render. Writes a short
# ANSI-coloured string like:  Q ▶2 ⏸5  (running, queued), with a trailing  !3
# in red for any failures.
#
# Hidden entirely when all counts are zero.
#
# Cache:
#   $MOTHER_STATUSLINE_CACHE (default: /tmp/.mother-statusline) — single line,
#   colon-separated "RUNNING:QUEUED:FAILED" counts. TTL-based refresh in the
#   background keeps the statusline fast.

: "${MOTHER_STATUSLINE_CACHE:=/tmp/.mother-statusline}"
: "${MOTHER_STATUSLINE_TTL:=10}"  # seconds
: "${MOTHER_ROOT:=$HOME/.mother}"

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
            /^running$/ { r++ }
            /^queued$/  { q++ }
            /^ready$/   { q++ }
            /^failed$/  { fa++ }
            END { printf "%d:%d:%d\n", r+0, q+0, fa+0 }
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

    local _mr _mq _mf
    IFS=: read -r _mr _mq _mf < "$cache" 2>/dev/null || { _mr=0; _mq=0; _mf=0; }
    : "${_mr:=0}" "${_mq:=0}" "${_mf:=0}"

    # Only render if something non-zero.
    if ! { [ "$_mr" -gt 0 ] 2>/dev/null || [ "$_mq" -gt 0 ] 2>/dev/null || [ "$_mf" -gt 0 ] 2>/dev/null; }; then
        return 0
    fi

    local reset='\033[38;5;245m'
    local out=" ${reset}Q"
    [ "$_mr" -gt 0 ] && out="${out} \033[38;5;220m▶${_mr}${reset}"  # yellow — running
    [ "$_mq" -gt 0 ] && out="${out} \033[38;5;75m⏸${_mq}${reset}"   # blue — queued/ready
    [ "$_mf" -gt 0 ] && out="${out} \033[38;5;203m!${_mf}${reset}"  # red — failed
    out="${out} "

    printf '%b' "$out"
}
