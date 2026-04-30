# state.sh — shared state primitives for Mother's CLI and daemon.
#
# Sourced by bin/mother and bin/mother-runner (siblings of this lib dir).
# Do not invoke directly.
#
# All callers get the same constants and helpers so there's one source of
# truth for the on-disk state layout. The caller owns shell options (we
# don't `set -u` here — leave that to the script that sources us).

# ---------- state paths ----------

: "${MOTHER_ROOT:=${MOTHER_ROOT:-$HOME/.mother}}"
: "${JOBS_DIR:=$MOTHER_ROOT/jobs}"
: "${EVENTS_DIR:=$MOTHER_ROOT/events}"
: "${LOGS_DIR:=$MOTHER_ROOT/logs}"
: "${DRAFTS_DIR:=$MOTHER_ROOT/drafts}"
: "${CURSORS_DIR:=$MOTHER_ROOT/cursors}"
: "${RUNNER_DIR:=$MOTHER_ROOT/runner}"
: "${ARCHIVE_DIR:=$MOTHER_ROOT/archive}"

mkdir -p "$JOBS_DIR" "$EVENTS_DIR" "$LOGS_DIR" "$DRAFTS_DIR" "$CURSORS_DIR" "$RUNNER_DIR" "$ARCHIVE_DIR"

# ---------- primitives ----------

# Microsecond-precision ISO timestamp so events emitted in the same second
# sort correctly and the hook's cursor advances past all of them. Always
# include fractional seconds so lexicographic and chronological orders match.
# Uses /usr/bin/perl (universal on macOS, Time::HiRes in core) with an
# absolute path so subshells with restricted PATH still get timestamps.
_iso_now() {
    /usr/bin/perl -MTime::HiRes=gettimeofday -MPOSIX=strftime -e '
        my ($s, $us) = gettimeofday();
        my @t = gmtime($s);
        printf "%sT%s.%06dZ\n",
            strftime("%Y-%m-%d", @t),
            strftime("%H:%M:%S", @t),
            $us;
    '
}

_job_path()   { echo "$JOBS_DIR/$1.json"; }
_events_path(){ echo "$EVENTS_DIR/$1.jsonl"; }
_log_path()   { echo "$LOGS_DIR/$1.log"; }
_plan_path()  { echo "$EVENTS_DIR/$1-plan.md"; }
_draft_path() { echo "$DRAFTS_DIR/$1.md"; }

_atomic_write() {
    # NB: avoid the local name `path` — zsh's special array `path` is bound to
    # PATH, so `local path` wipes the function's PATH and jq/other tools go
    # "command not found".
    local _target="$1" content="$2" tmp
    tmp="${_target}.tmp.$$"
    printf '%s' "$content" > "$tmp" && mv "$tmp" "$_target"
}

# Portable mkdir-based mutex (macOS lacks flock).
# Usage: _with_lock <path> <command...>
_with_lock() {
    local target="$1"; shift
    local lockdir="${target}.lockdir"
    local tries=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        sleep 0.05
        tries=$((tries + 1))
        [ "$tries" -gt 200 ] && { echo "mother: could not acquire lock for $target after 10s" >&2; return 1; }
    done
    "$@"
    local rc=$?
    rmdir "$lockdir" 2>/dev/null || true
    return $rc
}

_append_line() {
    printf '%s\n' "$2" >> "$1"
}

# Append one JSON event line to events/<id>.jsonl with mkdir-based locking.
# Usage: _append_event <id> <kind> <detail-json>
# Note: don't use ${3:-{\}} as the default — zsh parses the brace-escape
# differently than bash, which fails with `command not found: jq` when
# sourced into a zsh-run context (e.g. Claude Code's Bash tool on macOS).
_append_event() {
    local id="$1" kind="$2" detail="${3:-}"
    [ -z "$detail" ] && detail='{}'
    local ev _eventpath
    ev=$(jq -nc --arg ts "$(_iso_now)" --arg kind "$kind" --argjson detail "$detail" \
        '{ts: $ts, kind: $kind, detail: $detail}') || return 1
    _eventpath=$(_events_path "$id")
    _with_lock "$_eventpath" _append_line "$_eventpath" "$ev"
}

_job_exists() { [ -f "$(_job_path "$1")" ]; }

# Merge a JSON patch into the job file (atomic read-modify-write).
# Usage: _job_update <id> <jq-filter>
_job_update() {
    local id="$1" filter="$2"
    local _jobpath merged
    _jobpath=$(_job_path "$id")
    [ -f "$_jobpath" ] || { echo "mother: no such job: $id" >&2; return 1; }
    merged=$(jq "$filter" "$_jobpath") || return 1
    _atomic_write "$_jobpath" "$merged"
}

# Transition job state and emit matching event.
# Usage: _job_transition <id> <new-state> [<detail-json>]
_job_transition() {
    local id="$1" new="$2" detail="${3:-}"
    [ -z "$detail" ] && detail='{}'
    _job_update "$id" ".state = \"$new\""
    case "$new" in
        running)    _job_update "$id" ".started_at = \"$(_iso_now)\"" ;;
        succeeded|failed|cancelled)
                    _job_update "$id" ".finished_at = \"$(_iso_now)\"" ;;
    esac
    _append_event "$id" "$new" "$detail"
}

# ---------- quota awareness ----------
#
# Claude Code's statusline payload exposes the user's rolling 5h/7d quota
# usage with reset epochs. Outside an interactive Claude Code session that
# data is unreachable directly — but the user's statusline can dump the
# `rate_limits` slice to a cache file (see plugins/mother/statusline/segment.sh
# `mother_capture_rate_limits`), and the daemon reads that cache here.
#
# Cache schema (the `rate_limits` object as Claude Code emits it):
#   { "five_hour": {"used_percentage": N, "resets_at": <epoch>},
#     "seven_day": {"used_percentage": N, "resets_at": <epoch>} }
#
# Caps are operator-tunable percentages. Default 90% means "Mother stops
# dispatching when either window reaches 90% of the quota." Set lower to
# leave more headroom for interactive use.

: "${MOTHER_RATE_LIMIT_CACHE:=$MOTHER_ROOT/rate-limits.json}"
: "${MOTHER_QUOTA_CAP_5H_PCT:=90}"
: "${MOTHER_QUOTA_CAP_7D_PCT:=90}"

# _quota_pct_for_window: stdout the effective used_percentage for a given
# window name ("five_hour" or "seven_day"). Smart staleness: if the
# window's resets_at is in the past, the window has rolled over since the
# cache was written, so we treat its percentage as 0 (in our favor).
# Returns 0 (silently) if the cache is missing/empty/malformed — no signal
# means no gating.
_quota_pct_for_window() {
    local field="$1"
    local cache="$MOTHER_RATE_LIMIT_CACHE"
    [ -r "$cache" ] || { echo 0; return; }
    local rl; rl=$(cat "$cache" 2>/dev/null)
    [ -n "$rl" ] || { echo 0; return; }
    local pct reset now
    pct=$(printf '%s' "$rl" | jq -r --arg f "$field" '.[$f].used_percentage // 0' 2>/dev/null || echo 0)
    reset=$(printf '%s' "$rl" | jq -r --arg f "$field" '.[$f].resets_at // 0' 2>/dev/null || echo 0)
    now=$(date +%s)
    # Strip fractional seconds defensively; bash arithmetic only handles ints.
    pct="${pct%.*}"
    case "$pct" in ''|null) pct=0 ;; esac
    case "$reset" in ''|null) reset=0 ;; esac
    if [ "$reset" -gt 0 ] && [ "$now" -gt "$reset" ]; then
        echo 0
    else
        echo "$pct"
    fi
}

# _quota_check: returns 0 (under cap, dispatch OK) or 1 (at-or-over cap,
# hold). Both windows are checked; either tripping is enough to gate.
_quota_check() {
    local p5 p7
    p5=$(_quota_pct_for_window five_hour)
    p7=$(_quota_pct_for_window seven_day)
    if [ "$p5" -ge "$MOTHER_QUOTA_CAP_5H_PCT" ] \
        || [ "$p7" -ge "$MOTHER_QUOTA_CAP_7D_PCT" ]; then
        return 1
    fi
    return 0
}

# _quota_offending_window: the window name that's over cap, in the form
# `quota_5h` or `quota_7d`. 5h takes precedence (it has the shorter reset,
# so it's the one auto-resume can react to soonest). Empty if neither.
_quota_offending_window() {
    local p5 p7
    p5=$(_quota_pct_for_window five_hour)
    p7=$(_quota_pct_for_window seven_day)
    if [ "$p5" -ge "$MOTHER_QUOTA_CAP_5H_PCT" ]; then echo "quota_5h"; return; fi
    if [ "$p7" -ge "$MOTHER_QUOTA_CAP_7D_PCT" ]; then echo "quota_7d"; return; fi
    echo ""
}

# _quota_resume_at_for: stdout the resets_at epoch for a given window name
# (`quota_5h` or `quota_7d`). 0 if the cache is missing.
_quota_resume_at_for() {
    local cache="$MOTHER_RATE_LIMIT_CACHE"
    [ -r "$cache" ] || { echo 0; return; }
    local rl; rl=$(cat "$cache" 2>/dev/null)
    case "$1" in
        quota_5h) printf '%s' "$rl" | jq -r '.five_hour.resets_at // 0' 2>/dev/null || echo 0 ;;
        quota_7d) printf '%s' "$rl" | jq -r '.seven_day.resets_at // 0' 2>/dev/null || echo 0 ;;
        *) echo 0 ;;
    esac
}

# Promote queued jobs whose dependencies are all succeeded to ready.
_promote_ready() {
    find "$JOBS_DIR" -maxdepth 1 -name '*.json' -type f | while read -r f; do
        local state; state=$(jq -r .state "$f")
        [ "$state" = "queued" ] || continue
        local deps; deps=$(jq -c '.depends_on' "$f")
        local id; id=$(jq -r .id "$f")
        local blocked=0
        for dep in $(echo "$deps" | jq -r '.[]'); do
            local dep_state="missing"
            [ -f "$(_job_path "$dep")" ] && dep_state=$(jq -r .state "$(_job_path "$dep")")
            case "$dep_state" in succeeded) ;; *) blocked=1; break ;; esac
        done
        [ "$blocked" -eq 0 ] && _job_transition "$id" ready '{}'
    done
}
