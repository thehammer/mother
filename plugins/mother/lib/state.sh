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
