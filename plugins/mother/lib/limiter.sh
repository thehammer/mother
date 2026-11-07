#!/usr/bin/env bash
# limiter.sh — the backpressure limiter's mode switch and the dispatcher's view of it (L3).
#
# The limiter (bin/mother-limiter, lib/limiter_core.py) computes, every tick, which ready jobs it
# admits. Mode `observe` only logs that; `enforce` lets dispatch use it; `off` is the kill switch.
#
#   mode file   $MOTHER_ROOT/limiter/mode.json  {mode, changed_at, changed_by}   (human-only writer)
#   audit       limiter/mode-audit.jsonl (changes), limiter/mode-refusals.jsonl (refused callers)
#   resolution  env MOTHER_LIMITER_MODE=off wins; else the file; default observe. Env `enforce` is
#               never honoured: enforcement is switched on at a terminal, not by a variable.
#
# Fails to today's behaviour (bet B6): a missing, stale or faulted limiter is "not enforcing".
#
# Sourced by bin/mother and bin/mother-runner after lib/state.sh. Never `exit`s.

: "${MOTHER_ROOT:=${MOTHER_LIVE_ROOT:-$HOME/.mother}}"

_limiter_dir() { printf '%s\n' "$MOTHER_ROOT/limiter"; }
_limiter_mode_file() { printf '%s\n' "$MOTHER_ROOT/limiter/mode.json"; }
_limiter_state_file() { printf '%s\n' "$MOTHER_ROOT/limiter/state.json"; }
_limiter_fault_file() { printf '%s\n' "$MOTHER_ROOT/runner/limiter-fault.json"; }

# mother_limiter_mode: observe | enforce | off.
mother_limiter_mode() {
    [ "${MOTHER_LIMITER_MODE:-}" = "off" ] && { echo off; return 0; }
    local m
    m=$(jq -r 'if type == "object" then (.mode // "") else "" end' "$(_limiter_mode_file)" 2>/dev/null) || m=""
    case "$m" in enforce|off) echo "$m" ;; *) echo observe ;; esac
}

# Seconds after which state.json counts as stale: 3 x the tick interval.
_limiter_stale_after_s() {
    local i="${MOTHER_LIMITER_INTERVAL:-10}"
    case "$i" in ''|*[!0-9]*) i=10 ;; esac
    echo $((3 * i))
}

# mother_limiter_unhealthy: true when the mode is enforce and the limiter cannot be relied on:
# a fault file exists, or state.json is missing, unreadable or its mtime is older than 3 x the interval.
mother_limiter_unhealthy() {
    [ "$(mother_limiter_mode)" = "enforce" ] || return 1
    [ -f "$(_limiter_fault_file)" ] && return 0
    # Same freshness rule as the L2 block (mother-limiter build_block): the file's mtime.
    local f mt now
    f=$(_limiter_state_file)
    jq -e 'type == "object" and .v == 1' "$f" >/dev/null 2>&1 || return 0
    mt=$(_file_mtime "$f"); now=$(date +%s)
    case "$mt" in ''|*[!0-9]*) return 0 ;; esac
    [ $((now - mt)) -le "$(_limiter_stale_after_s)" ] || return 0
    return 1
}

# mother_limiter_enforcing: the limiter controls admission right now: mode enforce, a fresh state
# that was written under enforce, and no fault.
mother_limiter_enforcing() {
    [ "$(mother_limiter_mode)" = "enforce" ] || return 1
    mother_limiter_unhealthy && return 1
    [ "$(jq -r '.mode // ""' "$(_limiter_state_file)" 2>/dev/null)" = "enforce" ]
}

# mother_limiter_admit_list: the ordered ids the limiter admits, one per line.
mother_limiter_admit_list() {
    jq -r '(.admit // []) | map(select(type == "string")) | .[]' "$(_limiter_state_file)" 2>/dev/null
}

# mother_limiter_allowed: the limiter's allowed concurrency (empty when unreadable).
mother_limiter_allowed() {
    jq -r 'if (.allowed | type) == "number" then (.allowed | floor) else empty end' "$(_limiter_state_file)" 2>/dev/null
}

# mother_limiter_mode_set <observe|enforce|off> <changed_by>: THE writer of mode.json. Same-mode calls
# write and audit nothing. The read, the comparison and the write happen inside one lock.
mother_limiter_mode_set() {
    local want="$1" by="${2:-cli}"
    case "$want" in observe|enforce|off) ;; *) echo "limiter: unknown mode: $want (expected observe, enforce or off)" >&2; return 1 ;; esac
    mkdir -p "$(_limiter_dir)" 2>/dev/null
    _switch_with_lock "$(_limiter_mode_file).lockdir" "limiter-mode" "${_LIMITER_LOCK_TRIES:-200}" \
        _limiter_mode_set_locked "$want" "$by"
}

_limiter_mode_set_locked() {
    local want="$1" by="$2" from iso
    from=$(jq -r 'if type == "object" and (.mode == "enforce" or .mode == "off") then .mode else "observe" end' \
        "$(_limiter_mode_file)" 2>/dev/null) || from=observe
    if [ "$from" = "$want" ]; then
        echo "limiter mode already $want"
        return 0
    fi
    iso=$(_iso_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    _atomic_write "$(_limiter_mode_file)" \
        "$(jq -nc --arg m "$want" --arg at "$iso" --arg by "$by" '{mode: $m, changed_at: $at, changed_by: $by}')" || return 1
    jq -nc --arg at "$iso" --arg by "$by" --arg from "$from" --arg to "$want" \
        '{ts: $at, changed_by: $by, from: $from, to: $to}' >> "$(_limiter_dir)/mode-audit.jsonl"
    echo "mother: limiter mode $from -> $want (by $by)" >&2
    echo "limiter mode $from -> $want"
}
