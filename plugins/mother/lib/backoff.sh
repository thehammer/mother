#!/usr/bin/env bash
# backoff.sh — rate-limit (429) / overload (529, 5xx) backoff primitives.
#
# A rate limit is not a failed attempt: the same worker, at the same tier, will
# succeed later. `mother route-failure` (bin/mother) puts the job back to `ready`
# with a `.not_before` (epoch seconds) and the dispatcher (bin/mother-runner)
# honors it. A `rate_limited` backoff also extends a shared pause,
# $MOTHER_ROOT/ratelimit-until (epoch seconds, one integer): every API caller
# shares the one limit, so no NEW worker or reviewer starts before it. Workers
# already running are unaffected. The file simply expires; nothing clears it.
#
# Sourced by bin/mother and bin/mother-runner after lib/state.sh (needs
# _with_lock and _atomic_write). Never `exit`s.
#
# Env (all optional):
#   MOTHER_BACKOFF_ENABLED=0     restore the old routing: rate limits escalate
#   MOTHER_BACKOFF_BASE_S=30     first delay; doubles per backoff
#   MOTHER_BACKOFF_CAP_S=300     ceiling on the exponential delay
#   MOTHER_BACKOFF_JITTER_PCT=20 extra random delay, 0..PCT% of the base
#   MOTHER_BACKOFF_RETRY_AFTER_MAX_S=3600  ceiling on a server-given retry-after
#   MOTHER_BACKOFF_MAX_S=900     give up (hold) once backing off this long
#   MOTHER_REVIEW_RATELIMIT_RETRIES=2  re-spawns of a rate-limited reviewer

: "${MOTHER_ROOT:=${MOTHER_LIVE_ROOT:-$HOME/.mother}}"

mother_backoff_enabled() { [ "${MOTHER_BACKOFF_ENABLED:-1}" != "0" ]; }

mother_ratelimit_file() { printf '%s\n' "$MOTHER_ROOT/ratelimit-until"; }

# Positive integer from <value>, else <default>.
_backoff_int() {
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s\n' "$2" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# Epoch the shared pause lasts until (0 when absent or unreadable).
mother_ratelimit_until() {
    local v
    v=$(head -n1 "$(mother_ratelimit_file)" 2>/dev/null | tr -d '[:space:]')
    _backoff_int "$v" 0
}

# Longest wait Mother itself ever schedules (a server retry-after is clamped to
# this when set). A stored `ratelimit-until` / `.not_before` further out than
# this was not written by us (corrupt file, clock jump, hand edit) and is
# treated as expired: nothing else would ever lift it, and it would block
# dispatch without bound.
mother_backoff_horizon_s() {
    _backoff_int "${MOTHER_BACKOFF_RETRY_AFTER_MAX_S:-}" 3600
}

# Seconds left on the shared pause (0 when none, or when implausibly far out).
mother_ratelimit_remaining() {
    local until now left
    until=$(mother_ratelimit_until)
    now=$(date +%s)
    [ "$until" -gt "$now" ] || { echo 0; return 0; }
    left=$((until - now))
    if [ "$left" -gt "$(mother_backoff_horizon_s)" ]; then echo 0; else echo "$left"; fi
}

# True while the shared pause is in force.
mother_ratelimit_active() { [ "$(mother_ratelimit_remaining)" -gt 0 ]; }

# mother_ratelimit_extend <epoch> — set the pause to max(current, <epoch>).
mother_ratelimit_extend() {
    local want; want=$(_backoff_int "${1:-}" 0)
    [ "$want" -gt 0 ] || return 0
    # shellcheck disable=SC2329  # invoked via _with_lock
    _backoff_extend_locked() {
        local cur; cur=$(mother_ratelimit_until)
        [ "$want" -gt "$cur" ] || return 0
        _atomic_write "$(mother_ratelimit_file)" "$want"
    }
    _with_lock "$(mother_ratelimit_file)" _backoff_extend_locked
}

# mother_backoff_delay <backoffs_so_far> [retry_after_s]
# Seconds to wait before the next attempt. A server-given retry-after wins
# verbatim; otherwise BASE * 2^n capped at CAP, plus up to JITTER_PCT% jitter.
mother_backoff_delay() {
    local n; n=$(_backoff_int "${1:-}" 0)
    local ra; ra=$(_backoff_int "${2:-}" 0)
    if [ "$ra" -gt 0 ]; then
        # A server-given wait wins, but a bogus huge one must not stall the queue.
        local ra_max; ra_max=$(_backoff_int "${MOTHER_BACKOFF_RETRY_AFTER_MAX_S:-}" 3600)
        [ "$ra" -le "$ra_max" ] || ra=$ra_max
        echo "$ra"; return 0
    fi
    local base cap jit_pct delay i
    base=$(_backoff_int "${MOTHER_BACKOFF_BASE_S:-}" 30)
    cap=$(_backoff_int "${MOTHER_BACKOFF_CAP_S:-}" 300)
    jit_pct=$(_backoff_int "${MOTHER_BACKOFF_JITTER_PCT:-}" 20)
    delay=$base
    i=0
    while [ "$i" -lt "$n" ] && [ "$delay" -lt "$cap" ]; do
        delay=$((delay * 2)); i=$((i + 1))
    done
    [ "$delay" -le "$cap" ] || delay=$cap
    echo $((delay + delay * jit_pct * (RANDOM % 1000) / 100000))
}

# mother_backoff_label <not_before_epoch> — "45s" / "3m" (minutes rounded up);
# empty when the time has passed.
mother_backoff_label() {
    local nb now left
    nb=$(_backoff_int "${1:-}" 0)
    now=$(date +%s)
    [ "$nb" -gt "$now" ] || return 0
    left=$((nb - now))
    [ "$left" -le "$(mother_backoff_horizon_s)" ] || return 0
    if [ "$left" -lt 60 ]; then echo "${left}s"; else echo "$(((left + 59) / 60))m"; fi
}

# mother_ratelimit_wait — block until the shared pause expires, for at most
# MOTHER_BACKOFF_MAX_S seconds. Used by reviewers, which wait on the pause
# rather than fail. Returns 0 when the pause cleared, 1 on timeout.
mother_ratelimit_wait() {
    local budget left
    budget=$(_backoff_int "${MOTHER_BACKOFF_MAX_S:-}" 900)
    while :; do
        left=$(mother_ratelimit_remaining)
        [ "$left" -gt 0 ] || return 0
        [ "$budget" -gt 0 ] || return 1
        [ "$left" -le "$budget" ] || left=$budget
        [ "$left" -le 5 ] || left=5
        sleep "$left"
        budget=$((budget - left))
    done
}

# mother_reviewer_rate_limited <log_path> [backoffs_so_far]
# True (rc 0) when a reviewer's run ended on an explicit 429 / overload result
# event; as a side effect extends the shared pause so nothing else starts
# before the limit lifts. Only a result event with an api_error_status counts:
# text that merely mentions a rate limit in a review never does.
mother_reviewer_rate_limited() {
    local log="$1" n="${2:-0}" c ra delay
    type mother_classify_exit >/dev/null 2>&1 || return 1
    c=$(mother_classify_exit "$log" 0 1 2>/dev/null) || return 1
    printf '%s' "$c" | jq -e '
        (.api_error_status != null) and (.reason | IN("rate_limited","api_overloaded"))' \
        >/dev/null 2>&1 || return 1
    ra=$(printf '%s' "$c" | jq -r '.retry_after_s // 0')
    delay=$(mother_backoff_delay "$n" "$ra")
    mother_ratelimit_extend $(($(date +%s) + delay))
    return 0
}
