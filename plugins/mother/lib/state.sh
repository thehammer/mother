# mother/state.sh — shared state primitives for the queue CLI and daemon.
#
# Sourced by the mother CLI and ~/.claude/bin/mother-runner. Do not
# invoke directly.
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
