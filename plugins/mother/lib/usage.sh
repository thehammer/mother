# usage.sh — bash glue between bin/mother-usage (the Python transcript
# parser/cost engine) and Mother's bash callers (mother, mother-runner,
# mother-run-job).
#
# Sourced by all three bins. Every function here is best-effort: a missing
# python3, a missing mother-usage script, or any internal parse failure
# degrades to a no-op / null value and is never allowed to change a caller's
# job-state transition. See CLAUDE.md's cost-visibility section.
#
# Do not invoke directly. The caller owns `set -u`; this file does not set it.

: "${MOTHER_USAGE_BIN:=}"
if [ -z "$MOTHER_USAGE_BIN" ]; then
    _USAGE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    MOTHER_USAGE_BIN="$_USAGE_LIB_DIR/../bin/mother-usage"
fi

# One worker-mode predicate (lib/outbox.sh) for every caller of this file, even when state.sh is not
# loaded: a missing lib must not silently turn worker mode into the legacy path.
type mother_worker_mode_active >/dev/null 2>&1 \
    || { [ -r "${MOTHER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/outbox.sh" ] && source "${MOTHER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/outbox.sh"; }

# mother_usage_available: 0 if python3 + the mother-usage script are both
# reachable. Every function below checks this first and degrades quietly.
mother_usage_available() {
    command -v python3 >/dev/null 2>&1 && [ -r "$MOTHER_USAGE_BIN" ]
}

# ---------------------------------------------------------------------------
# self-contained job/event writers (deliberately independent of the ambient
# _job_update/_append_event conventions — mother-run-job's are 1-arg and
# operate on a global $job_file; lib/state.sh's are 2-arg. Rather than
# guessing which is in scope, usage.sh owns its own tiny, dependency-free
# read-modify-write so it behaves identically no matter which bin sources it.
# ---------------------------------------------------------------------------

_usage_iso_now() {
    # Same clock-in-bash fast path as state.sh's _iso_now (no process to exec).
    local _e="${EPOCHREALTIME:-}" _f
    case "$_e" in
        [0-9]*.[0-9]*)
            case "$_e" in *[!0-9.]*) ;; *)
                _f="${_e#*.}000"
                ( export TZ=UTC; printf '%(%Y-%m-%dT%H:%M:%S)T.%sZ\n' "${_e%.*}" "${_f:0:3}" 2>/dev/null ) && return 0 ;;
            esac ;;
    esac
    /usr/bin/perl -MTime::HiRes=gettimeofday -MPOSIX=strftime -e '
        my ($s, $us) = gettimeofday();
        my @t = gmtime($s);
        printf "%sT%s.%03dZ\n",
            strftime("%Y-%m-%d", @t),
            strftime("%H:%M:%S", @t),
            int($us / 1000);
    ' 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%S.000Z
}

# The job file is shared with other writers that hold <job>.json.lockdir (reviewers writing their slot,
# the supervisor): an unlocked read-modify-write here silently drops their update. Take the same lock
# when the caller's environment has _with_lock (state.sh / mother-run-job); never call this under it.
_usage_job_locked() {
    local jf="$1"; shift
    if type _with_lock >/dev/null 2>&1; then _with_lock "$jf" "$@"; else "$@"; fi
}

_usage_job_update() { _usage_job_locked "$1" _usage_job_update_unlocked "$@"; }

_usage_job_update_unlocked() {
    local job_file="$1" filter="$2"
    [ -f "$job_file" ] || return 1
    local merged; merged=$(jq "$filter" "$job_file" 2>/dev/null) || return 1
    [ -n "$merged" ] || return 1
    _usage_job_write "$job_file" "$merged"
}

# The one place this file writes a job document: atomic replace, then (worker mode) mirror the
# top-level diff into the outbox as job.set.
_usage_job_write() {
    local job_file="$1" merged="$2" before="" tmp="${1}.tmp.$$" jid
    type mother_outbox_enabled >/dev/null 2>&1 && mother_outbox_enabled && before=$(cat "$job_file" 2>/dev/null)
    printf '%s' "$merged" > "$tmp" && mv "$tmp" "$job_file" || return 1
    if type mother_outbox_enabled >/dev/null 2>&1 && mother_outbox_enabled; then
        jid="${job_file##*/}"; jid="${jid%.json}"
        mother_outbox_job_set "$jid" "$before" "$merged" || return 1
    fi
    return 0
}

# _usage_with_lock <lockable-file> <cmd> [args...]
# Acquires a sibling "<lockable-file>.lockdir" mkdir-based lock (owner pid recorded; a
# live owner is never displaced; after ~10s without the lock nothing runs and it returns 1), runs <cmd> with the remaining args, then releases the lock.
# Shared by every append-under-lock call site in this file (today:
# _usage_append_event and mother_record_run_usage) so there is one
# acquire/retry/release implementation instead of hand-copied ones that could
# drift apart.
_usage_with_lock() {
    local lockable="$1"; shift
    # Same lock as every other taker of <file>.lockdir: _switch_with_lock records the owner pid,
    # never displaces a live owner and takes over a dead one. A caller that doesn't have state.sh
    # sourced gets the minimal owner-honouring equivalent below. On failure to acquire nothing runs.
    if type _switch_with_lock >/dev/null 2>&1; then
        _switch_with_lock "${lockable}.lockdir" "usage" 200 "$@"
        return $?
    fi
    local lockdir="${lockable}.lockdir" tries=0 o
    while ! mkdir "$lockdir" 2>/dev/null; do
        o=$(cat "$lockdir/owner" 2>/dev/null)
        if [ -n "$o" ] && ! kill -0 "$o" 2>/dev/null; then
            rm -f "$lockdir/owner"; rmdir "$lockdir" 2>/dev/null || true; continue
        fi
        sleep 0.05
        tries=$((tries + 1))
        [ "$tries" -gt 200 ] && { echo "mother: could not acquire the usage lock for $lockable" >&2; return 1; }
    done
    echo "$$" > "$lockdir/owner" 2>/dev/null || true
    "$@"
    local rc=$?
    rm -f "$lockdir/owner"; rmdir "$lockdir" 2>/dev/null || true
    return $rc
}

_usage_append_line() { printf '%s\n' "$2" >> "$1"; }

_usage_append_event() {
    local job_id="$1" kind="$2" detail="${3:-}"
    [ -z "$detail" ] && detail='{}'
    local events_dir="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}/events"
    mkdir -p "$events_dir" 2>/dev/null
    local events_file="$events_dir/${job_id}.jsonl"
    local ev
    ev=$(jq -nc --arg ts "$(_usage_iso_now)" --arg kind "$kind" --argjson detail "$detail" \
        '{ts: $ts, kind: $kind, detail: $detail}' 2>/dev/null) || return 0
    [ -n "$ev" ] || return 0
    _usage_with_lock "$events_file" _usage_append_line "$events_file" "$ev" || return $?
    if type mother_outbox_event >/dev/null 2>&1; then
        mother_outbox_event "$job_id" "$ev" || return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# --effort / MCP-scope argv construction
# ---------------------------------------------------------------------------

# mother_claude_extra_args <effort> [<mode>]
# Fills the global indexed array MOTHER_CLAUDE_ARGS with the extra CLI args a
# `claude` invocation should get. <mode> is currently unused by the array
# itself (worker/review/adherence all get the same flags) but accepted for
# future divergence and for readable call sites.
#
# Bash 3.2 safe: plain indexed array, no declare -A.
mother_claude_extra_args() {
    local effort="${1:-}"
    MOTHER_CLAUDE_ARGS=()

    case "$effort" in
        low|medium|high|xhigh|max)
            MOTHER_CLAUDE_ARGS+=(--effort "$effort")
            ;;
        "") ;;
        *)
            echo "mother: warning: unrecognized effort '$effort' — omitting --effort flag" >&2
            ;;
    esac

    if [ "${MOTHER_WORKER_MCP_SCOPE:-1}" = "1" ]; then
        local mcp_config="${MOTHER_WORKER_MCP_CONFIG:-}"
        if [ -z "$mcp_config" ]; then
            mcp_config="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../templates/worker-mcp.json"
        fi
        if [ -r "$mcp_config" ]; then
            MOTHER_CLAUDE_ARGS+=(--strict-mcp-config --mcp-config "$mcp_config")
        fi
    fi
}

# ---------------------------------------------------------------------------
# usage rows + cost recompute
# ---------------------------------------------------------------------------

# mother_usage_rows_total <job_id>
# Echoes "<cost_usd> <tokens>" summed over the runs.jsonl rows of this root for the job. Worker
# mode uses it for the live-spend baseline: the mirror has no actual_cost_usd (the canonical side
# owns it), so the baseline is the mirror's own rows (this lease's runs).
mother_usage_rows_total() {
    local job_id="$1" f agg cost=0 tokens=0
    f="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}/metrics/runs.jsonl"
    if [ -f "$f" ]; then
        agg=$(grep -F "\"job_id\":\"${job_id}\"" "$f" 2>/dev/null \
            | jq -rs '[([.[] | (.cost_usd // 0)] | add // 0), ([.[] | ((.tokens_in // 0) + (.tokens_out // 0))] | add // 0)] | @tsv' 2>/dev/null)
        [ -n "$agg" ] && { cost="${agg%%$'\t'*}"; tokens="${agg##*$'\t'}"; }
    fi
    case "$cost" in ''|*[!0-9.eE+-]*) cost=0 ;; esac
    case "$tokens" in ''|*[!0-9]*) tokens=0 ;; esac
    printf '%s %s\n' "$cost" "$tokens"
}

# mother_recompute_job_cost <job_id>
# Sets .actual_cost_usd (sum of every runs.jsonl row's cost_usd for this job;
# 0, never null, when there are no rows), .actual_tokens (sum of tokens_in +
# tokens_out across those rows), and .actual_cost_complete. Grep-prefilters
# runs.jsonl by job_id before handing candidate lines to jq so a large file
# isn't fully parsed on every call.
mother_recompute_job_cost() {
    local job_id="$1"
    # Worker mode: the mirror only holds this lease's rows, so a recompute would ship a partial
    # sum. The canonical side owns cost (coord_apply.sh recomputes when a terminal state lands).
    mother_worker_mode_active && return 0
    local job_file="${JOBS_DIR:-${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}/jobs}/${job_id}.json"
    [ -f "$job_file" ] || return 0

    local metrics_file="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}/metrics/runs.jsonl"
    local cost="0" tokens="0" complete="true"
    if [ -f "$metrics_file" ]; then
        local agg
        agg=$(grep -F "\"job_id\":\"${job_id}\"" "$metrics_file" 2>/dev/null \
            | jq -s '{
                cost: ([.[] | (.cost_usd // 0)] | add // 0),
                tokens: ([.[] | ((.tokens_in // 0) + (.tokens_out // 0))] | add // 0),
                complete: ([.[] | (.cost_complete // true)] | all)
            }' 2>/dev/null)
        if [ -n "$agg" ]; then
            cost=$(printf '%s' "$agg" | jq -r '.cost' 2>/dev/null); : "${cost:=0}"
            tokens=$(printf '%s' "$agg" | jq -r '.tokens' 2>/dev/null); : "${tokens:=0}"
            complete=$(printf '%s' "$agg" | jq -r '.complete' 2>/dev/null); : "${complete:=true}"
        fi
    fi

    # Validate before handing to jq --argjson: a malformed/unexpected value
    # here must never propagate into the job file as broken JSON.
    case "$cost" in ''|*[!0-9.]*|*.*.*) cost=0 ;; esac
    case "$tokens" in ''|*[!0-9]*) tokens=0 ;; esac
    case "$complete" in true|false) ;; *) complete=true ;; esac

    _usage_job_update_argjson "$job_file" "$cost" "$tokens" "$complete"
}

# _usage_job_update_argjson <job_file> <cost> <tokens> <complete>
# Same read-modify-write as _usage_job_update, but passes cost/tokens/complete
# through jq --argjson (typed) instead of interpolating them into the filter
# string.
_usage_job_update_argjson() { _usage_job_locked "$1" _usage_job_update_argjson_unlocked "$@"; }

_usage_job_update_argjson_unlocked() {
    local job_file="$1" cost="$2" tokens="$3" complete="$4"
    [ -f "$job_file" ] || return 1
    local merged
    merged=$(jq --argjson cost "$cost" --argjson tokens "$tokens" --argjson complete "$complete" \
        '.actual_cost_usd = $cost | .actual_tokens = $tokens | .actual_cost_complete = $complete' \
        "$job_file" 2>/dev/null) || return 1
    [ -n "$merged" ] || return 1
    _usage_job_write "$job_file" "$merged"
}

# mother_maybe_token_alert <job_id>
# Emits token_alert (once — sticky .token_alert_at) when the job's cumulative
# actual_tokens crosses MOTHER_TOKEN_ALERT_THRESHOLD (default 100,000,000).
mother_maybe_token_alert() {
    local job_id="$1"
    local job_file="${JOBS_DIR:-${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}/jobs}/${job_id}.json"
    [ -f "$job_file" ] || return 0

    local already; already=$(jq -r '.token_alert_at // empty' "$job_file" 2>/dev/null)
    [ -z "$already" ] || return 0

    local threshold="${MOTHER_TOKEN_ALERT_THRESHOLD:-100000000}"
    local tokens; tokens=$(jq -r '.actual_tokens // 0' "$job_file" 2>/dev/null)
    case "$tokens" in ''|*[!0-9]*) tokens=0 ;; esac
    [ "$tokens" -gt "$threshold" ] || return 0

    local cost; cost=$(jq -r '.actual_cost_usd // 0' "$job_file" 2>/dev/null)
    _usage_job_update "$job_file" ".token_alert_at = \"$(_usage_iso_now)\""
    _usage_append_event "$job_id" "token_alert" \
        "$(jq -nc --argjson tokens "${tokens:-0}" --arg cost "${cost:-0}" --argjson threshold "${threshold:-0}" \
            '{tokens: $tokens, cost_usd: ($cost | tonumber), threshold: $threshold}' 2>/dev/null)"
    echo "job $job_id: TOKEN ALERT — ${tokens} tokens (threshold ${threshold}), cumulative cost \$${cost}"
}

# mother_record_run_usage <job_id> <outcome> <log_path> <offset> <end|""> <stage> <actor_main> <run_kind> <extra-json>
# Parses [offset,end) of <log_path> via `mother-usage parse`, merges the
# result with <extra-json> (the pre-existing row fields: model, effort,
# tier, retry/escalation counts, wall_time_seconds, log_size_bytes, pr_url,
# posture fields, failure_reason, ...) and appends ONE schema-2 row to
# $MOTHER_ROOT/metrics/runs.jsonl. Then recomputes the job's cumulative
# actual_cost_usd/actual_tokens and checks the token-alert threshold.
#
# Never fails the caller: any error along the way is swallowed (a warning is
# echoed to stderr) and no row is written for that call.
mother_record_run_usage() {
    local job_id="$1" outcome="$2" log_path="$3" offset="${4:-0}" end="${5:-}" \
          stage="$6" actor_main="${7:-cody-main}" run_kind="${8:-worker}" extra_json="${9:-}"
    [ -z "$extra_json" ] && extra_json='{}'

    local metrics_dir="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}/metrics"
    mkdir -p "$metrics_dir" 2>/dev/null
    local metrics_file="$metrics_dir/runs.jsonl"

    local parsed=""
    if mother_usage_available; then
        local parse_args=(parse --log "$log_path" --offset "${offset:-0}" --main-actor "$actor_main")
        [ -n "$end" ] && parse_args=(parse --log "$log_path" --offset "${offset:-0}" --end "$end" --main-actor "$actor_main")
        parsed=$(python3 "$MOTHER_USAGE_BIN" "${parse_args[@]}" 2>/dev/null) || parsed=""
    fi
    [ -n "$parsed" ] || parsed='{"usage_available": false}'

    local row
    row=$(jq -nc \
        --arg ts "$(_usage_iso_now)" \
        --arg job_id "$job_id" \
        --arg outcome "$outcome" \
        --arg run_kind "$run_kind" \
        --arg stage "$stage" \
        --arg actor "$actor_main" \
        --argjson parsed "$parsed" \
        --argjson extra "$extra_json" \
        '
        ($parsed | if type == "object" then . else {} end) as $p |
        {
            ts: $ts,
            job_id: $job_id,
            stage: $stage,
            outcome: $outcome,
            schema: 2,
            run_kind: $run_kind,
            actor: $actor,
            tokens_in: ($p.tokens_in // null),
            tokens_out: ($p.tokens_out // null),
            model_ids: (($p.by_model // {}) | keys),
            tokens: ($p.tokens // null),
            by_model: ($p.by_model // {}),
            by_actor: ($p.by_actor // {}),
            turns_main: ($p.turns_main // null),
            ctx_per_turn: ($p.ctx_per_turn // null),
            cost_usd: ($p.cost_usd // 0),
            cost_complete: ($p.cost_complete // true),
            cli_cost_usd: ($p.cli_cost_usd // null),
            rates_version: ($p.rates_version // null),
            init_tools: ($p.init.tools // null),
            init_mcp_servers: ($p.init.mcp_servers // null),
            log_bytes: ($p.log_bytes // null)
        } + $extra
        # Every failed row carries failure_reason consistently (not just the
        # ad hoc `reason` field individual callers happen to set) — derive it
        # from whatever the caller already supplied (failure_reason, else
        # reason, else "unspecified") rather than requiring every call site
        # to remember to set it explicitly.
        | if $outcome == "failed" then
            . + {failure_reason: (.failure_reason // .reason // "unspecified")}
          else . end
        ' 2>/dev/null)

    if [ -z "$row" ]; then
        echo "mother: usage: failed to build usage row for $job_id — skipping" >&2
        return 0
    fi

    _usage_with_lock "$metrics_file" _usage_append_line "$metrics_file" "$row"
    if type mother_outbox_record >/dev/null 2>&1; then
        mother_outbox_record "$job_id" "metrics/runs.jsonl" "$row" || echo "mother: usage row for $job_id not shipped (outbox degraded)" >&2
    fi

    mother_recompute_job_cost "$job_id"
    mother_maybe_token_alert "$job_id"
}

# mother_usage_check_live <job_id> <log_path> <spawn_offset> <state_file> <prior_cost> <prior_tokens> [<actor_main>]
# Runs an incremental parse (via --state) and echoes:
#   "<job_spend_usd> <job_tokens> <run_cost_usd> <run_tokens>"
# job_spend/job_tokens are prior (already-recorded, cumulative) + this run's
# spend-so-far. Best-effort: degrades to echoing the priors unchanged with
# zero deltas when python3/mother-usage/the log are unavailable.
mother_usage_check_live() {
    local job_id="$1" log_path="$2" spawn_offset="$3" state_file="$4" \
          prior_cost="${5:-0}" prior_tokens="${6:-0}" actor_main="${7:-cody-main}"
    : "${prior_cost:=0}" "${prior_tokens:=0}"

    if ! mother_usage_available || [ ! -f "$log_path" ]; then
        echo "$prior_cost $prior_tokens 0 0"
        return 0
    fi

    local parsed
    parsed=$(python3 "$MOTHER_USAGE_BIN" parse --log "$log_path" --offset "$spawn_offset" \
        --state "$state_file" --main-actor "$actor_main" 2>/dev/null) || parsed=""
    if [ -z "$parsed" ]; then
        echo "$prior_cost $prior_tokens 0 0"
        return 0
    fi

    local run_cost run_tokens_in run_tokens_out
    run_cost=$(printf '%s' "$parsed" | jq -r '.cost_usd // 0' 2>/dev/null); : "${run_cost:=0}"
    run_tokens_in=$(printf '%s' "$parsed" | jq -r '.tokens_in // 0' 2>/dev/null); : "${run_tokens_in:=0}"
    run_tokens_out=$(printf '%s' "$parsed" | jq -r '.tokens_out // 0' 2>/dev/null); : "${run_tokens_out:=0}"
    case "$run_tokens_in" in ''|*[!0-9]*) run_tokens_in=0 ;; esac
    case "$run_tokens_out" in ''|*[!0-9]*) run_tokens_out=0 ;; esac
    local run_tokens=$((run_tokens_in + run_tokens_out))

    # Validate before arithmetic — these feed a computed value straight into
    # job JSON and (via the caller) a --settings-driven hook comparison, so
    # a malformed number must degrade to 0 rather than propagate.
    case "$prior_cost" in ''|*[!0-9.]*|*.*.*) prior_cost=0 ;; esac
    case "$run_cost" in ''|*[!0-9.]*|*.*.*) run_cost=0 ;; esac

    local job_spend
    job_spend=$(awk -v a="$prior_cost" -v b="$run_cost" 'BEGIN { printf "%.6f", a + b }')
    local job_tokens=$((prior_tokens + run_tokens))

    echo "$job_spend $job_tokens $run_cost $run_tokens"
}

# mother_publish_rates: best-effort call into `mother-usage publish-rates`.
# Never fails the caller.
mother_publish_rates() {
    mother_usage_available || return 0
    python3 "$MOTHER_USAGE_BIN" publish-rates >/dev/null 2>&1 || true
}

# mother_classify_exit <log_path> <offset> <exit_code>
# Echoes the classify-exit JSON, or a claude_exit_nonzero fallback if
# python3/mother-usage is unavailable.
mother_classify_exit() {
    local log_path="$1" offset="${2:-0}" exit_code="${3:-1}"
    if mother_usage_available; then
        local out
        out=$(python3 "$MOTHER_USAGE_BIN" classify-exit --log "$log_path" --offset "$offset" --exit-code "$exit_code" 2>/dev/null)
        [ -n "$out" ] && { echo "$out"; return 0; }
    fi
    jq -nc --argjson code "$exit_code" '{reason: "claude_exit_nonzero", exit_code: $code}'
}
