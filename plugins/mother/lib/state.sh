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

# ---------- Bishop budget-posture helpers ----------
#
# These helpers are the single source of truth for posture resolution and bias
# logic. Sourced by both bin/mother (adherence-review) and bin/mother-run-job
# (Cody spawn). Callers set MOTHER_POSTURE_ENABLED=0 to disable.

# _tier_index: map tier name to integer; -1 on unknown.
_tier_index() {
    case "$1" in
        tier_0) echo 0 ;;
        tier_1) echo 1 ;;
        tier_2) echo 2 ;;
        tier_3) echo 3 ;;
        *)      echo -1 ;;
    esac
}

_tier_from_index() {
    case "$1" in
        0) echo tier_0 ;;
        1) echo tier_1 ;;
        2) echo tier_2 ;;
        3) echo tier_3 ;;
        *) echo tier_0 ;;
    esac
}

# _resolve_posture: best-effort fetch of current Bishop posture.
# Echoes one of: conservative | normal | elevated | flush.
# Falls back to `normal` if bishop is not on PATH, the call fails, or output
# is unrecognized. Honors MOTHER_POSTURE_ENABLED=0 to disable entirely.
_resolve_posture() {
    if [ "${MOTHER_POSTURE_ENABLED:-1}" = "0" ]; then
        echo "normal"; return 0
    fi
    if ! command -v bishop >/dev/null 2>&1; then
        echo "normal"; return 0
    fi
    bishop --refresh >/dev/null 2>&1 || true
    local p
    p=$(bishop get posture 2>/dev/null | tr -d '[:space:]')
    case "$p" in
        conservative|normal|elevated|flush) echo "$p" ;;
        *) echo "normal" ;;
    esac
}

# _apply_posture_bias: given a resolved tier and a posture, return the biased
# tier per the rules. Echoes the new tier on stdout. Sets POSTURE_BIAS_ACTION
# in the caller's scope to one of: clamp | up1 | none.
_apply_posture_bias() {
    local resolved="$1" posture="$2"
    local idx; idx=$(_tier_index "$resolved")
    [ "$idx" -lt 0 ] && idx=0
    case "$posture" in
        conservative)
            POSTURE_BIAS_ACTION="clamp"
            _tier_from_index 0
            ;;
        elevated)
            local new=$((idx + 1))
            [ "$new" -gt 2 ] && new=2
            POSTURE_BIAS_ACTION="up1"
            _tier_from_index "$new"
            ;;
        flush)
            local new=$((idx + 1))
            [ "$new" -gt 3 ] && new=3
            POSTURE_BIAS_ACTION="up1"
            _tier_from_index "$new"
            ;;
        normal|*)
            POSTURE_BIAS_ACTION="none"
            echo "$resolved"
            ;;
    esac
}

# ---------- dependency helpers ----------

# Poll interval for PR-merge state cache (seconds). Lower this to check more
# frequently at the cost of more `gh` calls. Default: 60.
: "${MOTHER_DEP_PR_POLL_INTERVAL:=60}"

# Cache dir for PR-merge state responses, keyed by SHA-1 of the pr_url.
# Built lazily on first use.
_PR_CACHE_DIR="${MOTHER_ROOT}/cache/pr-state"

# _pr_is_merged <pr_url>
# Check whether a GitHub PR is merged. Echoes:
#   merged     — gh returned state=MERGED
#   not_merged — gh returned a non-MERGED state
#   unknown    — gh call failed (network, auth, 404, etc.)
# Caches the result under ${MOTHER_ROOT}/cache/pr-state/<sha1-of-url>.json
# and reuses it if checked_at is within MOTHER_DEP_PR_POLL_INTERVAL seconds.
# On unknown, returns non-zero so callers can treat it as pending.
_pr_is_merged() {
    local pr_url="$1"
    # Build cache dir lazily.
    mkdir -p "$_PR_CACHE_DIR"
    local key; key=$(printf '%s' "$pr_url" | shasum 2>/dev/null | awk '{print $1}')
    [ -z "$key" ] && key=$(printf '%s' "$pr_url" | sha1sum 2>/dev/null | awk '{print $1}')
    local cache_file="$_PR_CACHE_DIR/${key}.json"

    # Check for a fresh cached result.
    if [ -f "$cache_file" ]; then
        local checked_at now age
        checked_at=$(jq -r '.checked_at // 0' "$cache_file" 2>/dev/null || echo 0)
        now=$(date +%s)
        # Defensive: strip decimals if present.
        checked_at="${checked_at%.*}"
        case "$checked_at" in ''|null|0) checked_at=0 ;; esac
        age=$((now - checked_at))
        if [ "$age" -lt "$MOTHER_DEP_PR_POLL_INTERVAL" ]; then
            local cached_state; cached_state=$(jq -r '.state // "unknown"' "$cache_file" 2>/dev/null || echo unknown)
            echo "$cached_state"
            [ "$cached_state" = "unknown" ] && return 1
            return 0
        fi
    fi

    # Call gh with a 5-second timeout where available (timeout ships with
    # GNU coreutils; macOS only has it with homebrew coreutils as gtimeout).
    local _timeout_cmd=""
    command -v timeout  >/dev/null 2>&1 && _timeout_cmd="timeout 5"
    [ -z "$_timeout_cmd" ] && command -v gtimeout >/dev/null 2>&1 && _timeout_cmd="gtimeout 5"
    local raw_state
    if ! raw_state=$($_timeout_cmd gh pr view "$pr_url" --json state -q .state 2>/dev/null); then
        # gh failed — write unknown to cache so we don't hammer on errors.
        printf '{"state":"unknown","checked_at":%s}' "$(date +%s)" > "$cache_file"
        echo "unknown"
        return 1
    fi
    raw_state=$(printf '%s' "$raw_state" | tr -d '[:space:]')
    local result
    if [ "$raw_state" = "MERGED" ]; then
        result="merged"
    else
        result="not_merged"
    fi
    printf '{"state":"%s","checked_at":%s}' "$result" "$(date +%s)" > "$cache_file"
    echo "$result"
    return 0
}

# _dep_merge_state <dep_id>
# Determine whether a dependency job's work is ready for a child to start.
# Echoes one of:
#   satisfied        — dep is a no-PR job in succeeded, or dep's PR is merged
#   pending          — dep is still in progress or PR not yet merged
#   parent_cancelled — dep is in cancelled state
#   parent_failed    — dep is in failed state
#   missing          — dep job file does not exist
_dep_merge_state() {
    local dep_id="$1"
    local dep_file; dep_file=$(_job_path "$dep_id")

    if [ ! -f "$dep_file" ]; then
        echo "missing"
        return 0
    fi

    local dep_state; dep_state=$(jq -r .state "$dep_file")
    local no_pr; no_pr=$(jq -r '.no_pr // false' "$dep_file")
    local pr_url; pr_url=$(jq -r '.pr_url // empty' "$dep_file")

    case "$dep_state" in
        cancelled)
            echo "parent_cancelled"
            return 0
            ;;
        failed)
            echo "parent_failed"
            return 0
            ;;
        succeeded)
            if [ "$no_pr" = "true" ]; then
                echo "satisfied"
                return 0
            fi
            if [ -n "$pr_url" ]; then
                local merged; merged=$(_pr_is_merged "$pr_url") || true
                if [ "$merged" = "merged" ]; then
                    echo "satisfied"
                else
                    echo "pending"
                fi
                return 0
            fi
            # succeeded but no pr_url and no_pr is false — cannot confirm merge.
            echo "pending"
            return 0
            ;;
        *)
            # queued, ready, running, awaiting, waiting — not done yet.
            echo "pending"
            return 0
            ;;
    esac
}

# _cascade_parent_terminal <dep_id> <reason>
# Find every waiting job whose depends_on contains <dep_id> and cancel it
# with the given reason (parent_cancelled or parent_failed), unless the job
# has keep_on_parent_cancel: true, in which case it remains in waiting.
_cascade_parent_terminal() {
    local dep_id="$1" reason="$2"
    find "$JOBS_DIR" -maxdepth 1 -name '*.json' -type f | while read -r f; do
        local state; state=$(jq -r .state "$f")
        [ "$state" = "waiting" ] || continue
        # Check whether this job depends on dep_id.
        local has_dep; has_dep=$(jq -r --arg dep "$dep_id" \
            'if (.depends_on // []) | map(. == $dep) | any then "yes" else "no" end' "$f")
        [ "$has_dep" = "yes" ] || continue
        local child_id; child_id=$(jq -r .id "$f")
        local keep; keep=$(jq -r '.keep_on_parent_cancel // false' "$f")
        if [ "$keep" = "true" ]; then
            # Operator opted out of cascade — leave in waiting.
            continue
        fi
        _job_transition "$child_id" cancelled \
            "$(jq -nc --arg reason "$reason" --arg parent_id "$dep_id" \
                '{reason: $reason, parent_id: $parent_id}')"
    done
}

# Promote queued/waiting jobs whose dependencies are satisfied.
#
# waiting -> queued: when all deps are merge-satisfied (or no-PR succeeded).
#   - If any dep is parent_cancelled/parent_failed, cascade cancellation
#     to children that don't have keep_on_parent_cancel.
#   - "pending" deps: leave in waiting.
#
# queued -> ready: all deps are in succeeded state (legacy/backward-compat path).
#   Note: in the new flow, cmd_add writes waiting (not queued) for jobs with
#   deps. The queued path here handles any pre-existing on-disk jobs that were
#   enqueued before the waiting state existed.
_promote_ready() {
    find "$JOBS_DIR" -maxdepth 1 -name '*.json' -type f | while read -r f; do
        local state; state=$(jq -r .state "$f")
        case "$state" in
            waiting)
                local id; id=$(jq -r .id "$f")
                local deps; deps=$(jq -c '.depends_on // []' "$f")
                local all_satisfied=1 any_terminal=0 terminal_dep="" terminal_reason=""
                for dep in $(echo "$deps" | jq -r '.[]'); do
                    local dms; dms=$(_dep_merge_state "$dep")
                    case "$dms" in
                        satisfied) ;;
                        parent_cancelled)
                            any_terminal=1
                            terminal_dep="$dep"
                            terminal_reason="parent_cancelled"
                            all_satisfied=0
                            break
                            ;;
                        parent_failed)
                            any_terminal=1
                            terminal_dep="$dep"
                            terminal_reason="parent_failed"
                            all_satisfied=0
                            break
                            ;;
                        missing)
                            # Treat missing as parent_cancelled — dep is gone.
                            any_terminal=1
                            terminal_dep="$dep"
                            terminal_reason="parent_cancelled"
                            all_satisfied=0
                            break
                            ;;
                        *)
                            # pending
                            all_satisfied=0
                            ;;
                    esac
                done
                if [ "$any_terminal" -eq 1 ]; then
                    _cascade_parent_terminal "$terminal_dep" "$terminal_reason"
                elif [ "$all_satisfied" -eq 1 ]; then
                    _job_transition "$id" queued '{}'
                fi
                ;;
            queued)
                local deps; deps=$(jq -c '.depends_on' "$f")
                local id; id=$(jq -r .id "$f")
                local blocked=0
                for dep in $(echo "$deps" | jq -r '.[]'); do
                    local dep_state="missing"
                    [ -f "$(_job_path "$dep")" ] && dep_state=$(jq -r .state "$(_job_path "$dep")")
                    case "$dep_state" in succeeded) ;; *) blocked=1; break ;; esac
                done
                [ "$blocked" -eq 0 ] && _job_transition "$id" ready '{}'
                ;;
        esac
    done
}
