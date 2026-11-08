# state.sh — shared state primitives for Mother's CLI and daemon.
#
# Sourced by bin/mother and bin/mother-runner (siblings of this lib dir).
# Do not invoke directly.
#
# All callers get the same constants and helpers so there's one source of
# truth for the on-disk state layout. The caller owns shell options (we
# don't `set -u` here — leave that to the script that sources us).

# ---------- worker mode (lib/outbox.sh) ----------
# Validated BEFORE any path is resolved or created: worker mode with no explicit root, or aimed at the
# live tree, must fail loudly and touch nothing (no mkdir, no marker file).
# shellcheck source=/dev/null
[ -r "${MOTHER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/outbox.sh" ] \
    && source "${MOTHER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/outbox.sh"
if type mother_worker_mode_validate >/dev/null 2>&1; then
    mother_worker_mode_validate || { echo "mother: refusing to start in worker mode" >&2; exit 1; }
fi

# ---------- state paths ----------

: "${MOTHER_ROOT:=${MOTHER_LIVE_ROOT:-$HOME/.mother}}"
: "${JOBS_DIR:=$MOTHER_ROOT/jobs}"
: "${EVENTS_DIR:=$MOTHER_ROOT/events}"
: "${LOGS_DIR:=$MOTHER_ROOT/logs}"
: "${DRAFTS_DIR:=$MOTHER_ROOT/drafts}"
: "${CURSORS_DIR:=$MOTHER_ROOT/cursors}"
: "${RUNNER_DIR:=$MOTHER_ROOT/runner}"
: "${ARCHIVE_DIR:=$MOTHER_ROOT/archive}"
: "${TEARDOWN_DIR:=$MOTHER_ROOT/teardown-pending}"
: "${RESIDUE_DIR:=$MOTHER_ROOT/teardown-residue}"   # unremovable worktree leftovers (see lib/teardown.sh)

mkdir -p "$JOBS_DIR" "$EVENTS_DIR" "$LOGS_DIR" "$DRAFTS_DIR" "$CURSORS_DIR" "$RUNNER_DIR" "$ARCHIVE_DIR" "$TEARDOWN_DIR"

# Live-tree marker + the guard in front of every recursive delete (lib/safe-rm.sh).
# Sourcing state.sh is how every `mother` command and the runner resolve the tree,
# so this is where the marker is ensured.
# shellcheck source=/dev/null
[ -r "${MOTHER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/safe-rm.sh" ] \
    && source "${MOTHER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/safe-rm.sh"
type mother_ensure_live_marker >/dev/null 2>&1 && mother_ensure_live_marker

type mother_ensure_worker_marker >/dev/null 2>&1 && mother_ensure_worker_marker

# ---------- primitives ----------

# Millisecond-precision RFC 3339 timestamp (e.g. 2026-05-30T09:30:56.510Z).
# Fractional seconds are always present so events emitted in the same second
# sort correctly (lexicographic order matches chronological order) and the
# hook's cursor advances past all of them. Millisecond (not microsecond)
# precision is required: Swift's JSONDecoder .iso8601 strategy — used by the
# Nostromo app to decode the mother_jobs IPC payload — rejects 6-digit
# fractional seconds, which silently breaks job display. Uses /usr/bin/perl
# (universal on macOS, Time::HiRes in core) with an absolute path so
# subshells with restricted PATH still get timestamps.
_iso_now() {
    /usr/bin/perl -MTime::HiRes=gettimeofday -MPOSIX=strftime -e '
        my ($s, $us) = gettimeofday();
        my @t = gmtime($s);
        printf "%sT%s.%03dZ\n",
            strftime("%Y-%m-%d", @t),
            strftime("%H:%M:%S", @t),
            int($us / 1000);
    '
}

# Second-precision RFC 3339 timestamp N hours in the past (UTC). Used as an
# age floor for the hook's event feed. Second precision is deliberate and
# safe: every consumer compares timestamps lexicographically, and a floor
# measured in hours never needs to discriminate within a single second.
# Uses /usr/bin/perl for the same reasons _iso_now does (universal on macOS,
# absolute path so subshells with a restricted PATH still work).
_iso_hours_ago() {
    /usr/bin/perl -MPOSIX=strftime -e '
        my @t = gmtime(time() - ($ARGV[0] * 3600));
        printf "%sT%sZ\n", strftime("%Y-%m-%d", @t), strftime("%H:%M:%S", @t);
    ' "$1"
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

# _bounded_run <timeout_secs> <stdout_file|-> <external-cmd> [args...]
# Runs an EXTERNAL command with a wall-clock bound, using the same
# background-race watchdog idiom as `_docker_reachable` (lib/teardown.sh) and
# `_maybe_archive` (bin/mother-runner): race the command against a
# `sleep N; kill -9`. The command is `exec`'d inside the background subshell
# so the killed pid IS the command (no orphaned grandchild); that means it must
# be an executable, not a shell function. stdout goes to <stdout_file> (or is
# discarded with "-"); stderr is discarded. Returns the command's exit status,
# or 137 when the watchdog killed it. Callers that must never stall a single-
# threaded loop (notifier transports, `gh` polls) go through this.
_bounded_run() {
    local secs="$1" out="$2"; shift 2
    [ "$out" = "-" ] && out=/dev/null
    ( exec "$@" >"$out" 2>/dev/null </dev/null 3>&- ) &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 3>&- &
    local wd=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    return "$rc"
}

# Portable mkdir-based mutex (macOS lacks flock).
# Usage: _with_lock <path> <command...>
# Goes through _switch_with_lock so every holder records its pid in <lockdir>/owner: a lock whose
# owner is dead is taken over, one whose owner is alive never is (10s wait, then failure).
_with_lock() {
    local target="$1"; shift
    _switch_with_lock "${target}.lockdir" "$target" 200 "$@"
}

_append_line() {
    printf '%s\n' "$2" >> "$1"
}

# Append one JSON event line to events/<id>.jsonl with mkdir-based locking.
# Usage: _append_event <id> <kind> <detail-json>
# Note: don't use ${3:-{\}} as the default — zsh parses the brace-escape
# differently than bash, which fails with `command not found: jq` when
# sourced into a zsh-run context (e.g. Claude Code's Bash tool on macOS).
_append_event() { mother_event_append "$@"; }

# Same as _append_event; the stable name for callers sourced into scripts that
# define their own job-scoped `_append_event` (mother-run-job, lib/preview.sh).
mother_event_append() {
    local id="$1" kind="$2" detail="${3:-}"
    [ -z "$detail" ] && detail='{}'
    local ev _eventpath
    ev=$(jq -nc --arg ts "$(_iso_now)" --arg kind "$kind" --argjson detail "$detail" \
        '{ts: $ts, kind: $kind, detail: $detail}') || return 1
    _eventpath=$(_events_path "$id")
    _with_lock "$_eventpath" _append_line "$_eventpath" "$ev" || return 1
    mother_outbox_event "$id" "$ev" || return 1
    return 0
}

_job_exists() { [ -f "$(_job_path "$1")" ]; }

# The ref every LOCAL diff consumer (changed files, patches, commits-ahead,
# gate `when` scopes) compares HEAD against: the job's `.base_sha` snapshot,
# else `.base_ref` (jobs enqueued before the snapshot existed), else the
# optional fallback. `base_ref` is a moving remote-tracking ref (a fix-up job
# pushes to the very branch it is based on), so a late evaluation of it sees an
# empty diff. PR targeting and worktree creation keep using `.base_ref`.
# Usage: mother_job_diff_base <job_file> [fallback]
mother_job_diff_base() {
    local job_file="${1:-}" fallback="${2:-}" v=""
    if [ -n "$job_file" ] && [ -f "$job_file" ]; then
        v=$(jq -r '.base_sha // .base_ref // empty' "$job_file" 2>/dev/null) || v=""
    fi
    printf '%s' "${v:-$fallback}"
}

# Merge a JSON patch into the job file (atomic read-modify-write).
# Usage: _job_update <id> <jq-filter> [jq args...]
_job_update() { mother_job_update "$@"; }

# Same as _job_update; stable name for the same reason as mother_event_append.
mother_job_update() {
    local id="$1" filter="$2"
    shift 2
    local _jobpath merged
    _jobpath=$(_job_path "$id")
    [ -f "$_jobpath" ] || { echo "mother: no such job: $id" >&2; return 1; }
    if mother_outbox_enabled; then
        # Read, merge, write and diff under the job lock: the op shipped is the diff against what
        # is really on disk, so a concurrent writer's change can neither be reverted nor lost.
        _with_lock "$_jobpath" _mother_job_update_locked "$_jobpath" "$filter" "$@"
        return $?
    fi
    merged=$(jq "$@" "$filter" "$_jobpath") || return 1
    _atomic_write "$_jobpath" "$merged"
}

_mother_job_update_locked() {
    local _jobpath="$1" filter="$2" merged
    shift 2
    merged=$(jq "$@" "$filter" "$_jobpath") || return 1
    mother_job_write_doc "$_jobpath" "$merged"
}

# Replace a job document that the caller already merged (typically under the job-file lock):
# atomic write, then (worker mode) the top-level diff goes to the outbox as job.set. In worker mode
# a failed emit (or an unreadable previous document) returns 1, logs, and flags the outbox degraded.
# Usage: mother_job_write_doc <job-file> <merged-json>
mother_job_write_doc() {
    local _jf="$1" _merged="$2" _before="" _jid
    mother_outbox_enabled && _before=$(cat "$_jf" 2>/dev/null)
    _atomic_write "$_jf" "$_merged" || return 1
    if mother_outbox_enabled; then
        _jid="${_jf##*/}"; _jid="${_jid%.json}"
        mother_outbox_job_set "$_jid" "$_before" "$_merged" || return 1
    fi
    return 0
}

# Typed attention on a job (`.attention[]`, `{reason, since}`; reasons are the
# contract's attention enum). Adding a reason that is already present keeps
# its original `since`. Usage: mother_job_attention_add|drop <id> <reason>
mother_job_attention_add() {
    mother_job_update "$1" '
        if ((.attention // []) | map(.reason) | index($r)) != null then .
        else .attention = ((.attention // []) + [{reason: $r, since: $ts}]) end' \
        --arg r "$2" --arg ts "$(_iso_now)"
}
mother_job_attention_drop() {
    mother_job_update "$1" 'if .attention == null then . else .attention |= map(select(.reason != $r)) end' \
        --arg r "$2"
}

# Compute the persisted `.failure_reason` literal (compact JSON, always a
# quoted string) from a failure transition's detail payload: the detail's
# `.reason` verbatim, or the literal string "unspecified" when it's missing
# or blank. Single source of truth for this normalization rule, shared by
# _job_transition below and mother-run-job's local _transition (which
# sources this file for real execution — see the fallback definition near
# mother-run-job's `_install_core_job_helpers` for the SOURCE_ONLY=1 bats
# path, which runs before this file is sourced) — so the rule can't drift
# between the two copies.
# Usage: _failure_reason_literal <detail-json>
_failure_reason_literal() {
    printf '%s' "$1" | jq -c '(.reason // "") | tostring | if . == "" then "unspecified" else . end' 2>/dev/null || echo '"unspecified"'
}

# Transition job state and emit matching event.
# Usage: _job_transition <id> <new-state> [<detail-json>]
_job_transition() {
    local id="$1" new="$2" detail="${3:-}"
    [ -z "$detail" ] && detail='{}'
    # D2 guard — mirrors mother-run-job's _transition: a `failed` transition
    # must always carry a .reason. See CLAUDE.md's structured-failures note.
    if [ "$new" = "failed" ]; then
        local _has_reason
        _has_reason=$(printf '%s' "$detail" | jq -r 'has("reason")' 2>/dev/null)
        if [ "$_has_reason" != "true" ]; then
            detail=$(printf '%s' "$detail" | jq -c '. + {reason: "unspecified"}' 2>/dev/null) || detail='{"reason":"unspecified"}'
            _append_event "$id" "failure_reason_missing" \
                "$(jq -nc --arg caller "${FUNCNAME[1]:-unknown}" '{caller: $caller}')"
        fi
    fi
    _job_update "$id" ".state = \"$new\""
    # Persist the failure reason on the job JSON so the runner can route on it
    # without replaying the events log. A new `failed` clears any prior routing
    # verdict; `succeeded` clears a stale reason.
    case "$new" in
        failed)
            local _reason_lit
            _reason_lit=$(_failure_reason_literal "$detail") || _reason_lit='"unspecified"'
            _job_update "$id" ".failure_reason = $_reason_lit | .failure_routed = null" ;;
        succeeded)
            _job_update "$id" ".failure_reason = null" ;;
    esac
    case "$new" in
        running)    _job_update "$id" ".started_at = \"$(_iso_now)\"" ;;
        succeeded|failed|cancelled)
                    _job_update "$id" ".finished_at = \"$(_iso_now)\""
                    _job_update "$id" ".force_start = null | .force_ignore_deps = null"
                    type mother_recompute_job_cost >/dev/null 2>&1 && mother_recompute_job_cost "$id" ;;
    esac
    _append_event "$id" "$new" "$detail"
}

# mother_compose_project: derive a job-scoped Docker Compose project name
# from a job id. Compose project names must match [a-z0-9][a-z0-9_-]*, but
# job ids look like `20260730T114600Z-a1b2c3d4` — uppercase T/Z must be
# lowercased or Compose rejects/normalizes the name and the two sides
# disagree. Lives here (not lib/teardown.sh) because both the producer
# (mother-run-job, exporting COMPOSE_PROJECT_NAME) and the consumer
# (lib/teardown.sh, sweeping by the same project name) need identical
# derivation, and state.sh is the one lib sourced unconditionally by
# mother, mother-runner, AND mother-run-job.
mother_compose_project() {
    local id="$1"
    printf 'mother-%s' "$(printf '%s' "$id" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -cd '[:alnum:]_-')"
}

# ---------- quota awareness ----------
#
# The gate reads the user's rolling 5h/7d quota usage from, in order:
#   1. Bishop's budget-posture file (MOTHER_BISHOP_POSTURE_FILE, default
#      ~/.claude/budget-posture.json, refreshed about every 60s). Per window
#      `used_pct` (or `used_percentage`) and `resets_at`; unusable when missing,
#      unparseable, or `stale_input: true`.
#   2. The old statusline cache (MOTHER_RATE_LIMIT_CACHE), written only while an
#      interactive Claude Code session renders (statusline/segment.sh
#      `mother_capture_rate_limits`):
#        { "five_hour": {"used_percentage": N, "resets_at": <epoch>},
#          "seven_day": {"used_percentage": N, "resets_at": <epoch>} }
# A source is only used while its file mtime is within MOTHER_QUOTA_FEED_MAX_AGE_S
# (default 1800). With no fresh source the source is `none`: the gate does not
# block on a dead feed, but the daemon raises the `quota_feed_stale` attention
# item (lib/attention.sh) so that is never silent.
#
# Caps are operator-tunable percentages. Default 90% means "Mother stops
# dispatching when either window reaches 90% of the quota."
#
# A three-state switch (on | off | off_until_reset) lives in
# $MOTHER_ROOT/quota-gate.json. `_quota_gate_set` is its only writer; the CLI
# (`mother quota`) and the broker's `quota-gate` command both call it.

: "${MOTHER_RATE_LIMIT_CACHE:=$MOTHER_ROOT/rate-limits.json}"
: "${MOTHER_BISHOP_POSTURE_FILE:=${HOME:-}/.claude/budget-posture.json}"
: "${MOTHER_QUOTA_CAP_5H_PCT:=90}"
: "${MOTHER_QUOTA_CAP_7D_PCT:=90}"
: "${MOTHER_QUOTA_FEED_MAX_AGE_S:=1800}"

_quota_gate_file() { echo "$MOTHER_ROOT/quota-gate.json"; }
_quota_audit_file() { echo "$MOTHER_ROOT/quota-gate-audit.jsonl"; }

# _file_mtime <file>: epoch mtime (BSD or GNU stat); 0 when unreadable.
# GNU first: on GNU stat `-f` means "filesystem status", so `stat -f %m FILE` prints
# filesystem info to stdout (and exits non-zero), which corrupted the value on Linux.
_file_mtime() {
    local m
    m=$(stat -c %Y "$1" 2>/dev/null) && [ -n "$m" ] && { echo "$m"; return 0; }
    m=$(stat -f %m "$1" 2>/dev/null) && [ -n "$m" ] && { echo "$m"; return 0; }
    echo 0
}

# _quota_normalize <file> <bishop|cache>: print the normalized windows as
# {five_hour:{used_pct,resets_at}, seven_day:{...}} when the file is usable,
# nothing otherwise.
_quota_normalize() {
    local f="$1" kind="$2"
    [ -r "$f" ] || return 0
    # A window with no numeric usage (string, null, missing) makes the whole
    # file unusable: it must fall through to the next source, never read as 0%.
    jq -c --arg kind "$kind" '
        def usage: (.used_pct // .used_percentage);
        def okwin: type == "object" and ((usage | type) == "number");
        def win($k): .[$k] as $w
            | {used_pct: ($w | usage),
               resets_at: ((($w.resets_at // 0) | if type == "number" then floor else 0 end))};
        if type != "object" then empty
        elif ($kind == "bishop" and .stale_input == true) then empty
        elif ((.five_hour | okwin) and (.seven_day | okwin)) | not then empty
        else {five_hour: win("five_hour"), seven_day: win("seven_day")} end
    ' "$f" 2>/dev/null
}

# _quota_int <value> [default]: truncate a possibly fractional epoch/percent to
# an integer; anything that is not a plain non-negative number becomes <default> (0).
_quota_int() {
    local v="${1:-}"
    v="${v%.*}"
    case "$v" in ''|*[!0-9]*) v="${2:-0}" ;; esac
    echo "$v"
}

# _quota_cap <5h|7d>: the configured cap as an integer percent. A trailing `%`
# is stripped; a non-numeric value falls back to 90 (see _quota_cap_invalid).
_quota_cap() {
    local v
    case "$1" in 5h) v="$MOTHER_QUOTA_CAP_5H_PCT" ;; *) v="$MOTHER_QUOTA_CAP_7D_PCT" ;; esac
    v="${v%\%}"
    _quota_int "$v" 90
}

# _quota_cap_invalid: prints true when either configured cap is not numeric.
_quota_cap_invalid() {
    local v w bad=false
    for w in "$MOTHER_QUOTA_CAP_5H_PCT" "$MOTHER_QUOTA_CAP_7D_PCT"; do
        v="${w%\%}"
        case "$v" in ''|*[!0-9.]*|.|*.*.*) bad=true ;; esac
    done
    echo "$bad"
}

# _quota_feed_json: one JSON object describing the feed the gate uses:
#   {source: bishop|cache|none, feed_age_s: N|null, stale: bool,
#    five_hour: {used_pct, resets_at}, seven_day: {...}}
# Expired windows (resets_at in the past) are reported at 0%.
_quota_feed_json() {
    local now; now=$(date +%s)
    local max="$MOTHER_QUOTA_FEED_MAX_AGE_S"
    local src="none" age="" win="" best_age="" f kind m a w
    for kind in bishop cache; do
        if [ "$kind" = bishop ]; then f="$MOTHER_BISHOP_POSTURE_FILE"; else f="$MOTHER_RATE_LIMIT_CACHE"; fi
        [ -r "$f" ] || continue
        m=$(_file_mtime "$f"); a=$((now - m))
        [ "$a" -lt 0 ] && continue   # a future mtime is not a fresh reading
        w=$(_quota_normalize "$f" "$kind")
        [ -n "$w" ] || continue
        if [ -z "$best_age" ] || [ "$a" -lt "$best_age" ]; then best_age="$a"; fi
        if [ "$a" -le "$max" ]; then src="$kind"; age="$a"; win="$w"; break; fi
    done
    [ -n "$win" ] || win='{"five_hour":{"used_pct":0,"resets_at":0},"seven_day":{"used_pct":0,"resets_at":0}}'
    [ -n "$age" ] || age="$best_age"
    printf '%s' "$win" | jq -c --arg src "$src" --arg age "$age" --argjson now "$now" '
        def eff: if .resets_at > 0 and $now > .resets_at then .used_pct = 0 else . end;
        {source: $src, feed_age_s: (if $age == "" then null else ($age | tonumber) end),
         stale: ($src == "none"),
         five_hour: (.five_hour | eff), seven_day: (.seven_day | eff)}'
}

# _quota_pct_for_window: stdout the effective integer used percentage for
# "five_hour" or "seven_day". 0 when there is no fresh feed (no signal means
# no gating) or the window has already reset.
_quota_pct_for_window() {
    local pct
    pct=$(_quota_feed_json | jq -r --arg f "$1" '.[$f].used_pct // 0' 2>/dev/null)
    _quota_int "$pct"
}

# _quota_gate_read: print the switch as {state, changed_at, changed_by, until}.
# A missing, unreadable or corrupt file (or unknown state) means `on`.
_quota_gate_read() {
    local f; f=$(_quota_gate_file)
    local out=""
    [ -r "$f" ] && out=$(jq -c '
        if (type == "object") and (.state == "off" or .state == "off_until_reset")
        then {state, changed_at: (.changed_at // null), changed_by: (.changed_by // null),
              until: (if .state == "off_until_reset" and (.until | type) == "number" then (.until | floor) else null end)}
        elif (type == "object") and .state == "on"
        then {state: "on", changed_at: (.changed_at // null), changed_by: (.changed_by // null), until: null}
        else empty end' "$f" 2>/dev/null)
    [ -n "$out" ] || out='{"state":"on","changed_at":null,"changed_by":null,"until":null}'
    printf '%s' "$out"
}

_quota_gate_write_locked() {
    local f="$1" content="$2"
    mkdir -p "$MOTHER_ROOT"
    _atomic_write "$f" "$content"
}

# _quota_with_lock <tries> <cmd...>: _with_lock for the safety switch's lockdir
# with an owner file and a stale-lock takeover. A killed `mother quota` used to
# leave `quota-gate.json.lockdir` behind and make every later change fail. The
# lock is taken over when its recorded owner pid is dead, or when it is older
# than MOTHER_QUOTA_LOCK_STALE_S (30s; an owner-less dir counts by age). The
# takeover renames the dir away first, so only one taker wins. Tries are 50ms
# apart; the daemon passes a small count (a stuck lock must not stall a tick).
_quota_with_lock() {
    _switch_with_lock "$(_quota_gate_file).lockdir" "quota-gate" "$@"
}

# _takeover_mutex_acquire <lockdir>: short-lived mkdir mutex (<lockdir>.takeover) that serializes
# stale-lock takeovers. Its own owner is recorded; a dead owner (or an owner-less dir older than 5s)
# is removed. Gives up after ~2s (returns 1); the caller just retries its main loop.
_takeover_mutex_acquire() {
    local m="$1.takeover" n=0 o
    while ! mkdir "$m" 2>/dev/null; do
        o=$(cat "$m/owner" 2>/dev/null)
        if [ -n "$o" ]; then
            kill -0 "$o" 2>/dev/null || { rm -f "$m/owner"; rmdir "$m" 2>/dev/null || true; continue; }
        elif [ -d "$m" ] && [ $(( $(date +%s) - $(_file_mtime "$m") )) -gt 5 ]; then
            rmdir "$m" 2>/dev/null || true; continue
        fi
        n=$((n + 1)); [ "$n" -gt 40 ] && return 1
        sleep 0.05
    done
    echo "$$" > "$m/owner" 2>/dev/null || true
    return 0
}

_takeover_mutex_release() { rm -f "$1.takeover/owner"; rmdir "$1.takeover" 2>/dev/null || true; }

# _takeover_stale_lockdir <lockdir> <label>: called with the takeover mutex held. Re-reads the lock's
# identity and removes it only if it is still stale (dead recorded owner, or owner-less and old).
_takeover_stale_lockdir() {
    local lockdir="$1" label="$2" ino owner mtime
    ino=$(ls -di "$lockdir" 2>/dev/null | awk '{print $1}')
    [ -n "$ino" ] || return 0
    owner=$(cat "$lockdir/owner" 2>/dev/null)
    mtime=$(_file_mtime "$lockdir")
    # Test hook (gated): widen the window between judging and removing.
    [ "${MOTHER_TEST_ROOT:-}" = "1" ] && [ -n "${MOTHER_TEST_TAKEOVER_DELAY_S:-}" ] && sleep "$MOTHER_TEST_TAKEOVER_DELAY_S"
    if [ -n "$owner" ]; then
        kill -0 "$owner" 2>/dev/null && return 0
    elif [ $(( $(date +%s) - mtime )) -le "${MOTHER_QUOTA_LOCK_STALE_S:-30}" ]; then
        return 0
    fi
    # Mutex held: nobody else renames. A live owner that took the path during the hook is caught here.
    if [ "$(ls -di "$lockdir" 2>/dev/null | awk '{print $1}')" = "$ino" ] \
       && [ "$(cat "$lockdir/owner" 2>/dev/null)" = "$owner" ]; then
        rm -f "$lockdir/owner"; rmdir "$lockdir" 2>/dev/null || true
        echo "mother: took over a stale $label lock (owner ${owner:-unknown})" >&2
    fi
}

# _switch_with_lock <lockdir> <label> <tries> <cmd...>: the lock behind _quota_with_lock,
# shared with the limiter-mode switch (lib/limiter.sh). <label> names the switch in messages.
_switch_with_lock() {
    local lockdir="$1" label="$2" tries_max="$3"; shift 3
    local tries=0 owner ino mtime stale
    # Re-entrant within one shell (and its subshells): a nested call for a lockdir this shell already
    # holds (e.g. a job transition's usage recompute under `mother cancel`) just runs. A plain shell
    # variable, never exported, so child processes (exec'd commands, `mother ... &`) still contend
    # normally; a backgrounded *function* subshell would inherit it, and none takes locks.
    case "${_MOTHER_HELD_LOCKDIRS:-}" in *"|$lockdir|"*) "$@"; return $? ;; esac
    mkdir -p "$(dirname "$lockdir")" 2>/dev/null
    while ! mkdir "$lockdir" 2>/dev/null; do
        # Identity of the lockdir we are judging: inode, owner, mtime (read in this order).
        ino=$(ls -di "$lockdir" 2>/dev/null | awk '{print $1}')
        owner=$(cat "$lockdir/owner" 2>/dev/null)
        mtime=$(_file_mtime "$lockdir")
        stale=0
        if [ -z "$ino" ]; then
            :   # vanished between mkdir and now: just retry
        elif [ -n "$owner" ]; then
            # A recorded owner decides alone: alive = never taken over, however long it holds.
            kill -0 "$owner" 2>/dev/null || stale=1
        elif [ $(( $(date +%s) - mtime )) -gt "${MOTHER_QUOTA_LOCK_STALE_S:-30}" ]; then
            stale=1   # no owner recorded (crash before the owner write, or an old holder): age rule only
        fi
        if [ "$stale" -eq 1 ]; then
            # Only one taker at a time may judge and rename: under the takeover mutex the lockdir is
            # re-judged from scratch, so a live owner that acquired the path in the meantime is seen
            # as live and left alone. No rename-then-put-back, hence no window where the path is free
            # while a live owner holds it.
            if _takeover_mutex_acquire "$lockdir"; then
                _takeover_stale_lockdir "$lockdir" "$label"
                _takeover_mutex_release "$lockdir"
            fi
            tries=$((tries + 1))
            [ "$tries" -gt "$tries_max" ] && { echo "mother: could not acquire the $label lock" >&2; return 1; }
            continue
        fi
        sleep 0.05
        tries=$((tries + 1))
        [ "$tries" -gt "$tries_max" ] && { echo "mother: could not acquire the $label lock" >&2; return 1; }
    done
    echo "$$" > "$lockdir/owner" 2>/dev/null || true
    local _outer_held="${_MOTHER_HELD_LOCKDIRS:-}"
    _MOTHER_HELD_LOCKDIRS="${_outer_held}|$lockdir|"
    "$@"
    local rc=$?
    _MOTHER_HELD_LOCKDIRS="$_outer_held"
    rm -f "$lockdir/owner"; rmdir "$lockdir" 2>/dev/null || true
    return $rc
}

# _quota_switch_feed_json: the feed used to pick the `until` of an
# off_until_reset. Feed-path overrides (MOTHER_BISHOP_POSTURE_FILE,
# MOTHER_RATE_LIMIT_CACHE) are honoured only under MOTHER_TEST_ROOT=1 (the test
# harness): otherwise an environment variable could forge the reset time that
# decides when the safety switch re-arms. Production reads the real paths.
_quota_switch_feed_json() {
    if [ "${MOTHER_TEST_ROOT:-}" = "1" ]; then _quota_feed_json; return; fi
    (
        MOTHER_BISHOP_POSTURE_FILE="${HOME:-}/.claude/budget-posture.json"
        MOTHER_RATE_LIMIT_CACHE="$MOTHER_ROOT/rate-limits.json"
        _quota_feed_json
    )
}

# Longest `until` accepted: the 7-day window plus an hour of slack.
_QUOTA_MAX_UNTIL_AHEAD_S=608400

# _quota_gate_set <on|off|off_until_reset> <changed_by> [expect_state [expect_until]]:
# THE writer of the switch. Prints a one-line human result on stdout; returns 1
# on a bad state, 3 (message `no_reset_known` on stderr) when off_until_reset is
# asked for and no usable future reset is known: that is refused, never turned
# into a plain `off`. The read, the comparison and the write all happen inside
# one lock, so concurrent callers cannot both apply the same change. Same-state
# calls change nothing (no rewrite, no audit line), except off_until_reset,
# which refreshes `until` to the earliest valid future reset (within now + 7d +
# 1h; anything further out is treated as unknown). With expect_state set (the
# automatic expiry flip) nothing is written unless the switch is still exactly
# in that state (and, when given, has that `until`).
_quota_gate_set() {
    local want="$1" by="${2:-cli}" ex_state="${3:-}" ex_until="${4:-}"
    case "$want" in on|off|off_until_reset) ;; *) echo "quota: unknown state: $want (expected on, off or off_until_reset)" >&2; return 1 ;; esac
    local until="null" now
    now=$(date +%s)
    if [ "$want" = off_until_reset ]; then
        until=$(_quota_switch_feed_json | jq -r --argjson now "$now" --argjson max "$_QUOTA_MAX_UNTIL_AHEAD_S" '
            [.five_hour.resets_at, .seven_day.resets_at
             | select(type == "number" and . > $now and . <= ($now + $max))] | min // "null"')
    fi
    _quota_with_lock "${_QUOTA_LOCK_TRIES:-200}" _quota_gate_set_locked "$want" "$by" "$until" "$now" "$ex_state" "$ex_until"
}

_quota_gate_set_locked() {
    local want="$1" by="$2" until="$3" now="$4" ex_state="$5" ex_until="$6"
    local cur from cur_until
    cur=$(_quota_gate_read)
    from=$(printf '%s' "$cur" | jq -r '.state')
    cur_until=$(printf '%s' "$cur" | jq -r '.until // "null"')
    if [ -n "$ex_state" ]; then
        if [ "$from" != "$ex_state" ] || { [ -n "$ex_until" ] && [ "$cur_until" != "$ex_until" ]; }; then
            echo "quota gate unchanged ($from)"
            return 0
        fi
    fi
    if [ "$want" = off_until_reset ] && [ "$until" = "null" ]; then
        if [ "$from" = off_until_reset ] && [ "$(_quota_int "$cur_until")" -gt "$now" ]; then
            echo "quota gate already off_until_reset"
            return 0
        fi
        echo "quota: no_reset_known: off-until-reset needs a known window reset within 7 days and none is (stale feed, expired or too-distant resets); the gate is unchanged. Use \`mother quota off\` to turn it off until you turn it back on." >&2
        return 3
    fi
    if [ "$from" = "$want" ] && { [ "$want" != off_until_reset ] || [ "$cur_until" = "$until" ]; }; then
        echo "quota gate already $want"
        return 0
    fi
    [ "$want" = off_until_reset ] || until="null"
    local iso; iso=$(_iso_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
    local content
    content=$(jq -nc --arg s "$want" --arg at "$iso" --arg by "$by" --argjson until "$until" \
        '{state: $s, changed_at: $at, changed_by: $by}
         + (if $s == "off_until_reset" then {until: $until} else {} end)')
    _quota_gate_write_locked "$(_quota_gate_file)" "$content" || return 1
    jq -nc --arg at "$iso" --arg by "$by" --arg from "$from" --arg to "$want" --argjson until "$until" \
        '{ts: $at, changed_by: $by, from: $from, to: $to, until: $until}' >> "$(_quota_audit_file)"
    echo "mother: quota gate $from -> $want (by $by)" >&2
    echo "quota gate $from -> $want"
}

# _quota_gate_open: returns 0 when the switch lets everything through (off, or
# off_until_reset before its reset); flips an expired off_until_reset back to
# `on` (logged and audited) and returns 1. The flip waits at most ~0.25s for the
# lock: if it cannot be taken the answer is still 1 (gate ON, fail closed) and a
# later tick retries, so a stuck lock cannot stall the daemon.
_quota_gate_open() {
    local cur st until now
    cur=$(_quota_gate_read)
    st=$(printf '%s' "$cur" | jq -r '.state')
    case "$st" in
        off) return 0 ;;
        off_until_reset)
            until=$(_quota_int "$(printf '%s' "$cur" | jq -r '.until // 0')")
            now=$(date +%s)
            if [ "$now" -ge "$until" ]; then
                _QUOTA_LOCK_TRIES=4 _quota_gate_set on "auto:reset" off_until_reset "$until" >/dev/null || true
                return 1
            fi
            return 0 ;;
    esac
    return 1
}

# _quota_check: returns 0 (under cap, dispatch OK) or 1 (at-or-over cap,
# hold). Both windows are checked; either tripping is enough to gate. Always
# passes while the switch is off.
_quota_check() {
    _quota_gate_open && return 0
    local p5 p7
    p5=$(_quota_pct_for_window five_hour)
    p7=$(_quota_pct_for_window seven_day)
    if [ "$p5" -ge "$(_quota_cap 5h)" ] \
        || [ "$p7" -ge "$(_quota_cap 7d)" ]; then
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
    if [ "$p5" -ge "$(_quota_cap 5h)" ]; then echo "quota_5h"; return; fi
    if [ "$p7" -ge "$(_quota_cap 7d)" ]; then echo "quota_7d"; return; fi
    echo ""
}

# _quota_resume_at_for: stdout the resets_at epoch for a given window name
# (`quota_5h` or `quota_7d`). 0 when unknown.
_quota_resume_at_for() {
    local w
    case "$1" in quota_5h) w=five_hour ;; quota_7d) w=seven_day ;; *) echo 0; return ;; esac
    _quota_int "$(_quota_feed_json | jq -r --arg w "$w" '.[$w].resets_at // 0' 2>/dev/null)"
}

# _quota_status_json: the object `mother quota status --json` prints and the
# broker snapshot carries (docs: tests/fixtures/quota_block.json).
_quota_status_json() {
    local feed gate c5 c7 bad
    feed=$(_quota_feed_json)
    gate=$(_quota_gate_read)
    c5=$(_quota_cap 5h); c7=$(_quota_cap 7d); bad=$(_quota_cap_invalid)
    jq -nc --argjson f "$feed" --argjson g "$gate" --argjson c5 "$c5" --argjson c7 "$c7" --argjson bad "$bad" '
        {gate: $g.state, until: $g.until, changed_at: $g.changed_at, changed_by: $g.changed_by,
         source: $f.source, feed_age_s: $f.feed_age_s, stale: $f.stale, cap_invalid: $bad,
         windows: {five_hour: {used_pct: $f.five_hour.used_pct, cap_pct: $c5, resets_at: ($f.five_hour.resets_at | if . > 0 then . else null end)},
                   seven_day: {used_pct: $f.seven_day.used_pct, cap_pct: $c7, resets_at: ($f.seven_day.resets_at | if . > 0 then . else null end)}}}'
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

# _normalize_posture <raw>: the single boundary between Bishop's vocabulary and
# Mother's. Bishop (since 2026-05-16, bishop 508fe2a) prints one of five labels;
# Mother's internals (_apply_posture_bias, gates, review) keep the four below:
#   Pump the brakes      -> conservative
#   Ease up              -> normal        (deliberate: Bishop's own text for it is
#                                          only "consider lighter model selection",
#                                          while conservative also clamps to tier_0,
#                                          skips non-mandatory lenses and limits
#                                          enforce gates to one attempt; to reverse,
#                                          move "ease up" into the conservative arm)
#   Cruise               -> normal
#   Push                 -> elevated
#   Put the hammer down  -> flush
#   conservative|normal|elevated|flush -> themselves (legacy labels)
# Leading/trailing whitespace is trimmed, runs of whitespace are squashed, and
# matching is case-insensitive. Empty/whitespace-only input -> normal, silently
# (bishop failed or the file is missing). Any other unrecognized value -> normal
# plus one stderr line naming it (control characters and ANSI escapes stripped,
# truncated to 40 characters).
_normalize_posture() {
    local raw="${1:-}" key shown
    key=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    case "$key" in
        "")
            echo normal
            ;;
        "pump the brakes"|conservative) echo conservative ;;
        "ease up"|cruise|normal) echo normal ;;
        push|elevated) echo elevated ;;
        "put the hammer down"|flush) echo flush ;;
        *)
            shown=$(printf '%s' "$raw" | LC_ALL=C sed -e $'s/\x1b\[[0-9;?]*[ -\/]*[@-~]//g' | LC_ALL=C tr -d '\000-\037\177' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | cut -c1-40)
            echo "mother: unrecognized bishop posture \"$shown\"; treating as normal" >&2
            echo normal
            ;;
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
    p=$(bishop get posture 2>/dev/null) || p=""
    _normalize_posture "$p"
}

# _resolve_cost_model: best-effort detection of the account's billing mode.
# Echoes one of: subscription | metered | unknown.
# Degrades to `unknown` if bishop is absent, the call fails, the posture
# file lacks a billing_mode key, or the value is unrecognised.
_resolve_cost_model() {
    local bm=""
    if command -v bishop >/dev/null 2>&1; then
        bm=$(bishop get billing_mode 2>/dev/null | tr -d '[:space:]')
    fi
    case "$bm" in
        subscription|metered) echo "$bm"; return 0 ;;
    esac
    local pf="${BUDGET_POSTURE_FILE:-$HOME/.claude/budget-posture.json}"
    if [ -r "$pf" ]; then
        bm=$(jq -r '.billing_mode // empty' "$pf" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$bm" in
        subscription|metered) echo "$bm"; return 0 ;;
    esac
    echo "unknown"
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

# ---------- pipeline visibility helpers ----------
#
# These helpers are pure (read-only; echo JSON/string to stdout) and are the
# single source of truth for the derived pipeline-progress data surfaced by
# `mother list`, `mother status`, and the JSON output paths.

# _agent_request_type <agent>
# Maps an agent name to its W1 request_type label. Used in both the runner
# (event payloads) and the cycles-derivation helper.
_agent_request_type() {
    case "${1:-}" in
        redd)  echo "test"    ;;
        cody)  echo "build"   ;;
        marty) echo "refactor" ;;
        *)     echo "review"  ;;
    esac
}

# _pipeline_list_label <job_file>
# Returns a compact pipeline-status string for the `list` table state column.
# Examples: "cycle 0 · Redd", "review · 2 findings", "blocked · 1 finding",
# "shipped", "shipped · 2 advisories".
# Pure function — reads job file, echoes string.
_pipeline_list_label() {
    local job_file="${1:-}"
    [ -f "$job_file" ] || return 0
    local phase cycle findings_count adv_count
    phase=$(jq -r '.pipeline.phase // ""' "$job_file" 2>/dev/null) || phase=""
    cycle=$(jq -r '.pipeline.review_cycle // 0' "$job_file" 2>/dev/null) || cycle=0
    findings_count=$(jq -r '.pipeline.findings // [] | length' "$job_file" 2>/dev/null) || findings_count=0
    adv_count=$(jq -r '.pipeline.advisories // [] | length' "$job_file" 2>/dev/null) || adv_count=0

    case "${phase:-}" in
        review)
            printf 'review · %s finding(s)\n' "${findings_count:-0}"
            ;;
        blocked)
            printf 'blocked · %s finding(s)\n' "${findings_count:-0}"
            ;;
        done)
            if [ "${adv_count:-0}" -gt 0 ]; then
                if [ "${adv_count:-0}" -eq 1 ]; then
                    printf 'shipped · 1 advisory\n'
                else
                    printf 'shipped · %s advisories\n' "${adv_count:-0}"
                fi
            else
                printf 'shipped\n'
            fi
            ;;
        redd|cody|marty)
            # Title-case the agent name (bash 3.2 safe — no arrays or printf %q tricks).
            local first rest
            first=$(printf '%s' "${phase:0:1}" | tr '[:lower:]' '[:upper:]')
            rest="${phase:1}"
            printf 'cycle %s · %s%s\n' "${cycle:-0}" "$first" "$rest"
            ;;
        *)
            printf '%s\n' "${phase:-unknown}"
            ;;
    esac
}

# _pipeline_cycles_json <job_file>
# Derives the FR2 `cycles` array for a pipeline job from its pipeline.* fields
# and the events log.  Echoes a JSON array to stdout.  Echoes nothing (empty)
# for non-pipeline jobs so callers can test with [ -n "$output" ].
#
# Schema: [{cycle: N, phases: [{agent, request_type, state,
#           [started_at], [finished_at], [findings]}]}]
#
# Cycle numbers are 1-indexed in the output (cycle 0 internally → "cycle": 1).
# Timestamps come from phase_started / phase_completed / review_cycle_started /
# review_cycle_completed events emitted by W5's runner changes; absent → omitted.
_pipeline_cycles_json() {
    local job_file="${1:-}"
    [ -f "$job_file" ] || return 0
    local kind
    kind=$(jq -r '.kind // ""' "$job_file" 2>/dev/null) || return 0
    [ "$kind" = "pipeline" ] || return 0

    local id job_json events_json events_file
    id=$(jq -r '.id' "$job_file" 2>/dev/null) || return 0
    job_json=$(jq -c '.' "$job_file" 2>/dev/null) || return 0
    events_file=$(_events_path "$id")
    if [ -f "$events_file" ]; then
        events_json=$(jq -cs '.' "$events_file" 2>/dev/null) || events_json="[]"
    else
        events_json="[]"
    fi
    [ -n "$events_json" ] || events_json="[]"

    jq -n --argjson job "$job_json" --argjson events "$events_json" '
      ($job.pipeline.review_cycle // 0) as $cur_cycle |
      ($job.pipeline.phase // "") as $cur_phase |
      ($job.pipeline.reviewers // []) as $reviewers |
      ($job.pipeline.pending_agents // []) as $pending_agents |
      ($job.pipeline.findings_history // []) as $findings_history |
      ($job.pipeline.reviewer_findings // {}) as $reviewer_findings |
      ($job.state // "") as $job_state |
      ($job.activity // "") as $activity |

      ["redd", "cody", "marty"] as $build_order |

      def req_type:
        if . == "redd" then "test"
        elif . == "cody" then "build"
        elif . == "marty" then "refactor"
        else "review"
        end;

      def find_ts_agent($kind; $cycle; $agent):
        ($events | map(select(
          .kind == $kind and
          .detail.cycle == $cycle and
          .detail.agent == $agent
        )) | first) | .ts;

      def find_ts_cycle($kind; $cycle):
        ($events | map(select(
          .kind == $kind and
          .detail.cycle == $cycle
        )) | first) | .ts;

      def build_state($agent; $is_active; $is_current):
        if ($is_active | not) then "skipped"
        elif ($is_current | not) then "completed"
        elif ($cur_phase == "review" or $cur_phase == "done" or $cur_phase == "blocked") then "completed"
        elif $cur_phase == $agent then
          (if $job_state == "running" then "running" else "pending" end)
        else
          (($build_order | index($agent)) as $ai |
           ($build_order | index($cur_phase)) as $pi |
           if ($pi >= 0 and $ai < $pi) then "completed" else "pending" end)
        end;

      [range($cur_cycle + 1)] | map(
        . as $icycle |
        ($icycle == $cur_cycle) as $is_current |

        # Active build agents: all on cycle 0; only pending_agents on re-run cycles.
        (if ($is_current and $icycle > 0 and ($pending_agents | length) > 0)
         then ($build_order | map(. as $a | select($pending_agents | index($a) != null)))
         else $build_order
         end) as $active |

        # Build phase entries.
        ($build_order | map(
          . as $agent |
          ($active | index($agent) != null) as $is_active |
          build_state($agent; $is_active; $is_current) as $state |
          (find_ts_agent("phase_started"; $icycle; $agent)) as $t0 |
          (find_ts_agent("phase_completed"; $icycle; $agent)) as $t1 |
          {agent: $agent, request_type: ($agent | req_type), state: $state}
          | if $t0 != null then . + {started_at: $t0} else . end
          | if $t1 != null then . + {finished_at: $t1} else . end
        )) as $build_phases |

        # Review phase entries (one per reviewer).
        ($reviewers | map(
          . as $reviewer |
          (if $icycle < $cur_cycle then
            (($findings_history
              | map(select(.cycle == $icycle))
              | first // {findings: []})
            | .findings | map(select(.reviewer == $reviewer)) | length)
          else
            ($reviewer_findings[$reviewer] // [] | length)
          end) as $fc |
          (if $icycle < $cur_cycle then "completed"
           elif $activity == "pipeline_review" then "running"
           elif ($cur_phase == "done" or $cur_phase == "blocked") then "completed"
           else "pending"
           end) as $state |
          (find_ts_cycle("review_cycle_started"; $icycle)) as $t0 |
          (find_ts_cycle("review_cycle_completed"; $icycle)) as $t1 |
          {agent: $reviewer, request_type: "review", state: $state, findings: $fc}
          | if $t0 != null then . + {started_at: $t0} else . end
          | if $t1 != null then . + {finished_at: $t1} else . end
        )) as $review_phases |

        {cycle: ($icycle + 1), phases: ($build_phases + $review_phases)}
      )
    ' 2>/dev/null
}

# ---------- resume continuity ----------
#
# An operator's `mother resume <id> "<answer>"` reply to a `mother await`
# question is a live amendment to the plan document. These helpers are the
# single source of truth for surfacing that amendment to the two downstream
# consumers that otherwise never see it: the idle-timeout auto-continuation
# preamble (mother-run-job's _attempt_continuation) and the adherence-review
# prompt (mother's cmd_adherence_review). See the resolved bug report for the
# full failure mode this closes.

# _iso_to_epoch <iso8601>
# Parses Mother's millisecond RFC 3339 timestamps (e.g.
# 2026-09-09T21:05:31.456Z) or second-precision ones (2026-09-09T21:05:31Z)
# to a Unix epoch. Echoes 0 if empty/unparseable. Same idiom as the
# started_epoch conversion in mother-run-job's _append_metrics.
_iso_to_epoch() {
    local iso="${1:-}"
    [ -n "$iso" ] || { echo 0; return 0; }
    local sec="${iso%%.*}"
    case "$sec" in *Z) ;; *) sec="${sec}Z" ;; esac
    local epoch
    epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$sec" +%s 2>/dev/null \
        || date -u -d "$sec" +%s 2>/dev/null || echo 0)
    case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac
    echo "$epoch"
}

# _resume_qa_history <job-id>
# Renders every operator awaiting_input/resumed Q&A pair from a job's event
# log, in chronological order, as a markdown block. Deliberately ignores
# resumed_from_input events (fired on every spawn that consumes a
# pending_answer, including machine-generated continuation preambles —
# not operator-authored text).
#
# stdout: the markdown block, or nothing.
# Exit 0 when at least one pair was rendered; exit 1 (no output) otherwise.
_resume_qa_history() {
    local id="$1"
    local events_file; events_file=$(_events_path "$id")
    [ -s "$events_file" ] || return 1

    local out
    out=$(jq -s -r '
        (reduce .[] as $ev (
            {pending: null, pairs: []};
            if $ev.kind == "awaiting_input" then
                .pending = {
                    question: ($ev.detail.question // $ev.detail.notes // ""),
                    asked_at: $ev.ts
                }
            elif $ev.kind == "resumed" then
                .pairs += [{
                    question: ((.pending.question) // "_(no question recorded)_"),
                    asked_at: ((.pending.asked_at) // ""),
                    answer: ($ev.detail.answer // ""),
                    answered_at: $ev.ts
                }]
                | .pending = null
            else
                .
            end
        ) | .pairs) as $pairs |
        if ($pairs | length) == 0 then "" else
            "## Operator Answers (live amendments to the plan)\n\n" +
            "The operator answered one or more questions on this job while it was running.\n" +
            "Each answer below is an authoritative amendment to the plan document: where an\n" +
            "answer conflicts with the plan, THE ANSWER WINS. Do not assume an answer has\n" +
            "already been acted on — verify against the actual code before concluding it\n" +
            "was. This is a verbatim excerpt of this job\u0027s own event history, not a new\n" +
            "question being asked of you now.\n\n" +
            (
                $pairs | length as $total |
                to_entries | map(
                    (.key + 1) as $n |
                    (if $n == $total then "Q&A \($n) (most recent)" else "Q&A \($n)" end) as $label |
                    "### \($label) — asked \(.value.asked_at), answered \(.value.answered_at)\n\n" +
                    "**Question:**\n\n\(.value.question)\n\n" +
                    "**Operator\u0027s answer:**\n\n\(.value.answer)\n\n"
                ) | join("")
            )
        end
    ' "$events_file" 2>/dev/null)

    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# _resume_not_yet_acted_on <job-id> <work_dir>
# Detects "operator resumed, but no commit postdates the resume" — a strong
# signal the previous worker ran out of time before acting on the answer.
#
# exit 0 = detected (a resume answer is probably unapplied)
# exit 1 = not detected (or the job was never resumed — never guess)
# stdout: "<last_commit_epoch> <last_commit_sha>" (0 and empty sha when there
#         are no commits or work_dir is unusable)
_resume_not_yet_acted_on() {
    local id="$1" work_dir="${2:-}"
    local job_file; job_file=$(_job_path "$id")
    [ -f "$job_file" ] || return 1

    local resumed_at; resumed_at=$(jq -r '.resumed_at // empty' "$job_file" 2>/dev/null)
    [ -n "$resumed_at" ] || return 1

    local resumed_epoch; resumed_epoch=$(_iso_to_epoch "$resumed_at")
    [ "${resumed_epoch:-0}" -gt 0 ] || return 1

    if [ ! -d "$work_dir" ]; then
        echo "0 "
        return 0
    fi

    local last_epoch
    last_epoch=$(git -C "$work_dir" log -1 --format=%ct 2>/dev/null)
    if [ -z "$last_epoch" ]; then
        echo "0 "
        return 0
    fi
    local last_sha; last_sha=$(git -C "$work_dir" log -1 --format=%h 2>/dev/null)

    echo "$last_epoch $last_sha"
    [ "$last_epoch" -le "$resumed_epoch" ]
}

# _continuation_preamble <job-id> <attempt> <max> <reason> <git_log_summary> <not_acted_flag>
# Builds the idle-timeout continuation prompt preamble. Extracted out of
# mother-run-job's _attempt_continuation so it's unit-testable via `source`.
# <not_acted_flag> is "1" or "0" — see _resume_not_yet_acted_on.
_continuation_preamble() {
    local id="$1" attempt="$2" max="$3" reason="$4" git_log_summary="$5" not_acted="${6:-0}"

    local job_file; job_file=$(_job_path "$id")
    local branch=""
    [ -f "$job_file" ] && branch=$(jq -r '.branch // ""' "$job_file" 2>/dev/null)

    local preamble
    preamble=$(printf '%s\n%s\n\n%s\n\n%s\n\n%s\n\n%s\n' \
        "# Continuation (attempt ${attempt} of ${max})" \
        "" \
        "A previous worker on this job was interrupted before it could finish (reason: ${reason})." \
        "The following commits are already on branch \`${branch}\` — **do not redo this work**:" \
        "\`\`\`" \
        "${git_log_summary}" \
    )
    preamble="${preamble}
\`\`\`
"

    local qa_history
    if qa_history=$(_resume_qa_history "$id"); then
        preamble="${preamble}
${qa_history}
"
        if [ "$not_acted" = "1" ]; then
            preamble="${preamble}
### ⚠️ The operator's answer may not have been implemented yet

No commit on this branch postdates the operator's answer above. The previous
worker very likely ran out of time before acting on it. **Before continuing
with anything else, read the current code and determine whether that answer
is actually reflected in it. If it is not, implementing it is your first
task** — it takes precedence over any remaining step in the plan below.
"
        fi
    fi

    preamble="${preamble}
Resume from the first uncommitted step in the original plan below. Skip any steps whose work is already committed above. Run \`git log --oneline\` first to orient yourself.

## Original Plan

"
    printf '%s' "$preamble"
}

# Path of a dependency job's JSON record: $JOBS_DIR first, falling back to
# ARCHIVE_DIR/*/<id>.json — a dependency job is very often archived (terminal
# + old + PR no longer open) by the time a dependent job's own dependencies
# get re-checked, and a job whose dependency has vanished from JOBS_DIR must
# not be read as unmet forever. Without this fallback, any --depends-on job
# that outlives its dependency's archival sweep gets stuck in "queued"
# permanently, with no error or event to signal it. Prints nothing when the
# record exists in neither place.
_dep_record() {
    local dep="$1" f
    f="$(_job_path "$dep")"
    if [ -f "$f" ]; then
        echo "$f"
        return 0
    fi
    f=$(find "$ARCHIVE_DIR" -maxdepth 2 -name "${dep}.json" -type f -print -quit 2>/dev/null)
    if [ -n "$f" ] && [ -f "$f" ]; then
        echo "$f"
    fi
    return 0
}

# Look up a dependency's state (see _dep_record for the archive fallback).
_dep_state() {
    local f
    f=$(_dep_record "$1")
    if [ -n "$f" ]; then
        jq -r .state "$f"
        return
    fi
    echo "missing"
}

: "${MOTHER_DEP_PR_POLL_INTERVAL:=120}"

# _dep_pr_merge_state <pr_url> — echoes merged|open|closed|unknown.
#
# `_promote_ready` runs every daemon tick (MOTHER_POLL_INTERVAL, 2s), so an
# uncached `gh` call per queued dependent per tick would hammer the API and
# slow dispatch. Results are cached in $RUNNER_DIR/dep-pr-cache/<sha1 of
# url>.json as {state, checked_at}: `merged` and `closed` are final and cached
# permanently; `open` and `unknown` are re-queried once they're older than
# MOTHER_DEP_PR_POLL_INTERVAL. The gh call is time-bounded. An inconclusive
# gh (offline, unauthenticated, timeout) yields `unknown` — callers must never
# release a dependent on it.
_dep_pr_merge_state() {
    local url="$1"
    local cache_dir="$RUNNER_DIR/dep-pr-cache" key cache cstate cat_epoch now
    key=$(printf '%s' "$url" | shasum 2>/dev/null | cut -d' ' -f1)
    [ -n "$key" ] || key=$(printf '%s' "$url" | cksum | tr ' ' '_')
    cache="$cache_dir/$key.json"
    now=$(date +%s)

    if [ -f "$cache" ]; then
        cstate=$(jq -r '.state // ""' "$cache" 2>/dev/null)
        case "$cstate" in
            merged|closed) echo "$cstate"; return 0 ;;
        esac
        cat_epoch=$(_iso_to_epoch "$(jq -r '.checked_at // ""' "$cache" 2>/dev/null)")
        if [ -n "$cstate" ] && [ $((now - cat_epoch)) -lt "${MOTHER_DEP_PR_POLL_INTERVAL:-120}" ]; then
            echo "$cstate"
            return 0
        fi
    fi

    local out state="unknown" raw
    out=$(mktemp "${TMPDIR:-/tmp}/mother-deppr.XXXXXX") || { echo "unknown"; return 0; }
    if _bounded_run "${MOTHER_GH_TIMEOUT:-10}" "$out" gh pr view "$url" --json state -q .state; then
        raw=$(tr -d '[:space:]' < "$out" | tr '[:upper:]' '[:lower:]')
        case "$raw" in merged|open|closed) state="$raw" ;; esac
    fi
    rm -f "$out"

    mkdir -p "$cache_dir"
    _atomic_write "$cache" "$(jq -nc --arg s "$state" --arg t "$(_iso_now)" '{state: $s, checked_at: $t}')"
    echo "$state"
}

# _dep_gate <dep_id> — echoes `satisfied`, `wait:<reason>` or `blocked:<reason>`.
#
# A dependency is satisfied when it is `succeeded` AND its PR has merged (or it
# is a no_pr job, which has nothing to merge). A job reaches `succeeded` as
# soon as it OPENS a PR, so gating on state alone started dependents from a
# base that didn't yet contain their parent's work.
#   wait:*    will resolve on its own (dependency still running, PR open, gh
#             inconclusive)
#   blocked:* needs the operator (mother force-start / cancel); the dependent
#             stays `queued` and is NEVER auto-cancelled. Re-evaluated every
#             tick, so e.g. an escalation re-queueing a failed dependency
#             turns blocked:dep_failed back into wait.
_dep_gate() {
    local dep="$1" rec
    rec=$(_dep_record "$dep")
    [ -n "$rec" ] || { echo "blocked:dep_missing"; return 0; }

    local state no_pr pr_url
    state=$(jq -r '.state // ""' "$rec" 2>/dev/null)
    case "$state" in
        queued|ready|running|awaiting) echo "wait:dep_not_finished"; return 0 ;;
        failed)    echo "blocked:dep_failed"; return 0 ;;
        cancelled) echo "blocked:dep_cancelled"; return 0 ;;
        succeeded) ;;
        *)         echo "wait:dep_not_finished"; return 0 ;;
    esac

    no_pr=$(jq -r '.no_pr // false' "$rec" 2>/dev/null)
    [ "$no_pr" = "true" ] && { echo "satisfied"; return 0; }
    pr_url=$(jq -r '.pr_url // ""' "$rec" 2>/dev/null)
    [ -n "$pr_url" ] || { echo "blocked:dep_no_pr_url"; return 0; }

    case "$(_dep_pr_merge_state "$pr_url")" in
        merged) echo "satisfied" ;;
        open)   echo "wait:pr_open" ;;
        closed) echo "blocked:pr_closed_unmerged" ;;
        *)      echo "wait:pr_state_unknown" ;;
    esac
}

# Promote queued jobs to ready once every dependency's gate is `satisfied`.
# Otherwise record the FIRST unsatisfied dependency on the job as `dep_wait`
# ({dep_id, status: wait|blocked, reason, pr_url, checked_at}). dep_wait and
# its dependency_waiting / dependency_blocked event are written only when
# dep_id/status/reason change — never every tick. Never cancels anything.
_promote_ready() {
    find "$JOBS_DIR" -maxdepth 1 -name '*.json' -type f | while read -r f; do
        local state; state=$(jq -r .state "$f")
        [ "$state" = "queued" ] || continue
        local deps; deps=$(jq -c '.depends_on' "$f")
        local id; id=$(jq -r .id "$f")
        local blocked=0 first_dep="" first_gate="" forced=0
        # `mother force-start <id>` alone is a quota override and does NOT skip
        # the dependency gate. Only `mother force-start <id> --ignore-deps`
        # (which also sets force_ignore_deps) skips it: the job is promoted on
        # this tick, and force_start then carries through dispatch as usual.
        [ "$(jq -r '.force_ignore_deps // false' "$f")" = "true" ] && forced=1
        if [ "$forced" -eq 0 ]; then
            for dep in $(echo "$deps" | jq -r '.[]'); do
                local gate; gate=$(_dep_gate "$dep")
                if [ "$gate" != "satisfied" ]; then
                    blocked=1; first_dep="$dep"; first_gate="$gate"
                    break
                fi
            done
        fi
        if [ "$blocked" -eq 1 ]; then
            local g_status="${first_gate%%:*}" g_reason="${first_gate#*:}"
            local cur
            cur=$(jq -r '(.dep_wait // {}) | [.dep_id // "", .status // "", .reason // ""] | join("|")' "$f")
            if [ "$cur" != "$first_dep|$g_status|$g_reason" ]; then
                local dep_pr_url="" drec
                drec=$(_dep_record "$first_dep")
                [ -n "$drec" ] && dep_pr_url=$(jq -r '.pr_url // ""' "$drec" 2>/dev/null)
                local wait_obj
                wait_obj=$(jq -nc --arg d "$first_dep" --arg s "$g_status" --arg r "$g_reason" \
                    --arg pr "$dep_pr_url" --arg t "$(_iso_now)" \
                    '{dep_id: $d, status: $s, reason: $r, pr_url: $pr, checked_at: $t}')
                _job_update "$id" ".dep_wait = $wait_obj"
                if [ "$g_status" = "blocked" ]; then
                    _append_event "$id" "dependency_blocked" "$wait_obj"
                else
                    _append_event "$id" "dependency_waiting" "$wait_obj"
                fi
            fi
            continue
        fi
        if [ "$blocked" -eq 0 ]; then
            local had_deps; had_deps=$(echo "$deps" | jq 'length')
            _job_update "$id" 'del(.dep_wait)'
            _job_transition "$id" ready '{}'
            if [ "$forced" -eq 1 ]; then
                _append_event "$id" "dependency_gate_bypassed" \
                    "$(jq -nc --argjson d "$deps" '{dep_ids: $d, by: "force_start_ignore_deps"}')"
            elif [ "${had_deps:-0}" -gt 0 ]; then
                _append_event "$id" "dependency_satisfied" \
                    "$(jq -nc --argjson d "$deps" '{dep_ids: $d}')"
            fi
            # W5: emit the cycle-0 phase_started for the first build agent. The runner
            # only emits phase_started on phase *advance* (cycle >= the first advance)
            # and on new review cycles, so without this the initial Redd phase has no
            # started_at in the derived cycles array.
            local kind; kind=$(jq -r '.kind // ""' "$f" 2>/dev/null) || kind=""
            if [ "$kind" = "pipeline" ]; then
                local ph cyc
                ph=$(jq -r '.pipeline.phase // ""' "$f" 2>/dev/null) || ph=""
                cyc=$(jq -r '.pipeline.review_cycle // 0' "$f" 2>/dev/null) || cyc=0
                case "$ph" in
                    redd|cody|marty)
                        if [ "${cyc:-0}" = "0" ]; then
                            _append_event "$id" "phase_started" \
                                "$(jq -nc \
                                    --argjson cycle 0 \
                                    --arg agent "$ph" \
                                    --arg rt "$(_agent_request_type "$ph")" \
                                    '{cycle: $cycle, agent: $agent, request_type: $rt}')"
                        fi
                        ;;
                esac
            fi
        fi
    done
}
