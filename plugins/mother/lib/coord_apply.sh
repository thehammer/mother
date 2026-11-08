#!/usr/bin/env bash
# coord_apply.sh — replay a worker outbox onto the canonical state tree (cluster Phase 1, P1-2).
#
#   coord_apply.sh <canonical-root> <job> < ops.ndjson
#
# Reads the ops lib/outbox.sh wrote (`{"seq":N,"t":type,"ts":..,"data":..}`, one per line) and
# applies them in order onto <canonical-root> with today's lock and write functions, under the
# idempotency rules of docs/worker-protocol.md section 6:
#
#   job.set        value set / key delete under the job-file lock, key order preserved. Ownership
#                  violations (section 8) are skipped and audited. A terminal `state` triggers the
#                  canonical cost recompute (the canonical side owns cost).
#   event.append   skipped when the identical line is already the tail of the events file.
#   record.append  same tail rule, against the last line of the stream carrying this job's job_id;
#                  followed by the canonical cost recompute (what mother_record_run_usage does).
#   artifact.put   offset-addressed into crew/<job>/ or checkpoints/<job>/ only; atomic rename on
#                  `final`, sha256 verified.
#
# Ops with seq <= the persisted applied seq ($root/runner/leases/applied/<job>.seq) are skipped, so
# replaying an outbox twice, or in two parts, is a no-op the second time. The tail rules stay as the
# backstop for a crash between applying an op and persisting its seq (section 6).
#
# Prints the last applied seq on stdout. Exits non-zero at the first op it cannot apply and leaves
# the later ops for a retry. Can also be sourced (functions only).
#
# Ownership policy (P1-1's table, with the P1-2 inventory): see _ca_ownership_json. Until the
# coordinator derives completion evidence itself (P1-5), this replay is the stand-in for that step, so
# completion-evidence keys and `succeeded` are accepted from the outbox here.

# --- ownership table ---------------------------------------------------------------------------

# Keys the worker side may set or delete (broker/workerproto WorkerKeys).
_CA_WORKER_KEYS='activity session_id worker_pid paused_reason paused_at question final_result_at started_at continuation_count resume_not_yet_acted_on gates review_wave limiter_hold live_cost_usd live_tokens current_run cost_cap_breached_at token_alert_at rwx_sandbox resume_session_id resume_kind limiter_resume_prompt attention decision'
# Completion evidence. Refused from a worker by the wire protocol; accepted here as the stand-in
# for the coordinator's own derivation until P1-5.
_CA_EVIDENCE_KEYS='pr_url actual_branch finished_at exit_code failure_reason'
# P1-2's inventory of what mother-run-job and the in-job CLI write beyond the two lists above.
_CA_INVENTORY_KEYS='not_before backoff_count backoff_first_at failure_routed force_ignore_deps work_dir base_sha current_tier auto_resume_at preview adherence_status adherence_attempts adherence_pending adherence_notes adherence_sha_runs adherence_reviewed_sha'
# Coordinator -> worker keys: a worker may only consume (null) them, never set a value.
_CA_CLEAR_ONLY_KEYS='pending_answer pause_requested cancel_requested force_start'

_ca_words_json() { printf '%s\n' $1 | jq -Rn '[inputs]'; }

# --- helpers -----------------------------------------------------------------------------------

_ca_log() { echo "coord_apply: $*" >&2; }

_ca_audit() {
    local job="$1" code="$2" keys="$3" dir
    dir="$MOTHER_ROOT/runner/leases"
    mkdir -p "$dir" 2>/dev/null || return 1
    jq -nc --arg ts "$(_iso_now)" --arg job "$job" --arg code "$code" --argjson keys "$keys" \
        '{ts: $ts, job: $job, code: $code, keys: $keys}' >> "$dir/audit.jsonl"
}

# --- job.set -----------------------------------------------------------------------------------

# Runs under the job-file lock: judge the op against the current document, then apply it.
# $1 job file, $2 op-data file (the op's `data`), $3 job id, $4 result file (gets "applied" or
# "refused:<keys-json>").
_ca_job_set_locked() {
    local jf="$1" opf="$2" job="$3" resf="$4" verdict bad merged
    local worker clear_only
    worker=$(_ca_words_json "$_CA_WORKER_KEYS $_CA_EVIDENCE_KEYS $_CA_INVENTORY_KEYS")
    clear_only=$(_ca_words_json "$_CA_CLEAR_ONLY_KEYS")
    verdict=$(jq -c -n --argjson worker "$worker" --argjson clear "$clear_only" '
        input as $op | input as $cur
        | ["running", "awaiting", "failed", "cancelled", "succeeded"] as $states
        | def terminal: . == "succeeded" or . == "failed" or . == "cancelled";
          def bad_set($k; $v):
              if $clear | index($k) then $v != null
              elif $k == "state" then
                  (($v | type) != "string") or (($states | index($v)) == null)
                  or (($cur.state // "") as $c | ($c | terminal) and $c != $v)
                  or ($v == "running" and ($cur.cancel_requested == true))
              else ($worker | index($k)) == null end;
          def bad_del($k): ($k == "state") or (($worker + $clear) | index($k)) == null;
          [($op.set // {}) | to_entries[] | select(bad_set(.key; .value)) | .key]
          + [($op.del // [])[] | select(bad_del(.))] ' "$opf" "$jf") || return 1
    bad="$verdict"
    if [ "$bad" != "[]" ]; then
        printf 'refused:%s' "$bad" > "$resf"
        return 0
    fi
    merged=$(jq -n 'input as $op | input
        | reduce (($op.set // {}) | to_entries[]) as $e (.; .[$e.key] = $e.value)
        | delpaths([($op.del // [])[] | [.]])' "$opf" "$jf") || return 1
    _atomic_write "$jf" "$merged" || return 1
    printf 'applied' > "$resf"
}

_ca_apply_job_set() {
    local job="$1" line="$2" jf opf resf res rc=0 terminal
    jf=$(_job_path "$job")
    [ -f "$jf" ] || { _ca_log "no such job on the canonical root: $job"; return 1; }
    opf=$(mktemp "${TMPDIR:-/tmp}/coord-apply-op.XXXXXX") || return 1
    resf=$(mktemp "${TMPDIR:-/tmp}/coord-apply-res.XXXXXX") || { rm -f "$opf"; return 1; }
    printf '%s' "$line" | jq -c '.data' > "$opf" || rc=1
    [ "$rc" -eq 0 ] && { _with_lock "$jf" _ca_job_set_locked "$jf" "$opf" "$job" "$resf" || rc=1; }
    res=$(cat "$resf" 2>/dev/null)
    terminal=$(jq -r '(.set.state // "") | select(. == "succeeded" or . == "failed" or . == "cancelled")' "$opf" 2>/dev/null)
    rm -f "$opf" "$resf"
    [ "$rc" -eq 0 ] || return 1
    case "$res" in
        refused:*)
            _ca_audit "$job" ownership "${res#refused:}" ;;
        applied)
            if [ -n "$terminal" ] && type mother_recompute_job_cost >/dev/null 2>&1; then
                mother_recompute_job_cost "$job"
            fi ;;
        *) return 1 ;;
    esac
    return 0
}

# --- event.append / record.append --------------------------------------------------------------

_ca_apply_event() {
    local job="$1" line="$2" ev ef tail
    ev=$(printf '%s' "$line" | jq -r '.data.line // empty') || return 1
    [ -n "$ev" ] || { _ca_log "event.append without a line"; return 1; }
    # One JSON object with a kind: a worker's line never becomes anything but a single event line.
    printf '%s' "$ev" | jq -e 'type == "object" and (.kind | type) == "string"' >/dev/null 2>&1 \
        || { _ca_log "event.append: line is not a single event object"; return 1; }
    ef=$(_events_path "$job")
    tail=$(tail -n 1 "$ef" 2>/dev/null)
    [ "$tail" = "$ev" ] && return 0
    _with_lock "$ef" _append_line "$ef" "$ev"
}

_ca_apply_record() {
    local job="$1" line="$2" stream row dir file tail
    stream=$(printf '%s' "$line" | jq -r '.data.stream // empty')
    row=$(printf '%s' "$line" | jq -r '.data.line // empty')
    case "$stream" in
        metrics/runs.jsonl) ;;
        *) _ca_log "record.append: unknown stream '$stream'"; return 1 ;;
    esac
    [ -n "$row" ] || { _ca_log "record.append without a line"; return 1; }
    # A usage row feeds cost totals and the cost cap: it must be one object for this job, with
    # non-negative numeric cost/tokens.
    printf '%s' "$row" | jq -e --arg j "$job" '
        type == "object" and .job_id == $j
        and all(.cost_usd, .tokens_in, .tokens_out; . == null or (type == "number" and . >= 0))' \
        >/dev/null 2>&1 || { _ca_log "record.append: row is not a valid usage row for $job"; return 1; }
    file="$MOTHER_ROOT/$stream"
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
    tail=$(grep -F "\"job_id\":\"${job}\"" "$file" 2>/dev/null | tail -n 1)
    if [ "$tail" != "$row" ]; then
        _with_lock "$file" _append_line "$file" "$row" || return 1
    fi
    # What mother_record_run_usage does after appending a row, on the canonical side.
    type mother_recompute_job_cost >/dev/null 2>&1 && mother_recompute_job_cost "$job"
    type mother_maybe_token_alert >/dev/null 2>&1 && mother_maybe_token_alert "$job" >/dev/null
    return 0
}

# --- artifact.put ------------------------------------------------------------------------------

# Relative, clean, and confined to crew/<job>/ or checkpoints/<job>/.
_ca_artifact_path_ok() {
    local job="$1" p="$2" part rest
    case "$p" in
        ''|/*) return 1 ;;
        crew/"$job"/*|checkpoints/"$job"/*) ;;
        *) return 1 ;;
    esac
    rest="$p"
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        case "$part" in ''|.|..) return 1 ;; esac
        case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    done
    return 0
}

_ca_b64_decode() {
    if printf 'YQ==' | base64 -d >/dev/null 2>&1; then base64 -d; else base64 -D; fi
}

_ca_apply_artifact() {
    local job="$1" line="$2" rel off b64 final sha dest part size tmp skip want got
    rel=$(printf '%s' "$line" | jq -r '.data.path // empty')
    off=$(printf '%s' "$line" | jq -r '.data.offset // empty')
    final=$(printf '%s' "$line" | jq -r '.data.final // false')
    sha=$(printf '%s' "$line" | jq -r '.data.sha256 // empty')
    _ca_artifact_path_ok "$job" "$rel" || { _ca_log "artifact.put: path not allowed: '$rel'"; return 1; }
    case "$off" in ''|*[!0-9]*) _ca_log "artifact.put: bad offset"; return 1 ;; esac
    dest="$MOTHER_ROOT/$rel"
    part="$dest.part"
    mkdir -p "$(dirname "$dest")" || return 1
    tmp=$(mktemp "${TMPDIR:-/tmp}/coord-apply-chunk.XXXXXX") || return 1
    printf '%s' "$line" | jq -j '.data.b64 // ""' | _ca_b64_decode > "$tmp" || { rm -f "$tmp"; _ca_log "artifact.put: bad base64"; return 1; }
    if [ "$off" -eq 0 ]; then
        : > "$part" || { rm -f "$tmp"; return 1; }
    fi
    size=$(wc -c < "$part" 2>/dev/null | tr -d ' ')
    [ -n "$size" ] || size=0
    if [ "$off" -gt "$size" ]; then
        rm -f "$tmp"; _ca_log "artifact.put: gap at offset $off (have $size)"; return 1
    fi
    skip=$((size - off))     # bytes of this chunk already present (a resend)
    if [ "$skip" -lt "$(wc -c < "$tmp" | tr -d ' ')" ]; then
        tail -c +$((skip + 1)) "$tmp" >> "$part" || { rm -f "$tmp"; return 1; }
    fi
    rm -f "$tmp"
    if [ "$final" = "true" ]; then
        if [ -n "$sha" ]; then
            got=$(shasum -a 256 "$part" | cut -d' ' -f1)
            want="$sha"
            if [ "$got" != "$want" ]; then
                _ca_log "artifact.put: sha256 mismatch for $rel"
                rm -f "$part"
                return 1
            fi
        fi
        mv "$part" "$dest" || return 1
    fi
    return 0
}

# --- driver ------------------------------------------------------------------------------------

_ca_applied_file() { printf '%s/runner/leases/applied/%s.seq' "$MOTHER_ROOT" "$1"; }

# _ca_apply_op <job> <op-line> — apply one op; non-zero if it cannot be applied.
_ca_apply_op() {
    local job="$1" line="$2" t
    t=$(printf '%s' "$line" | jq -r '.t // empty') || return 1
    case "$t" in
        job.set)       _ca_apply_job_set "$job" "$line" ;;
        event.append)  _ca_apply_event "$job" "$line" ;;
        record.append) _ca_apply_record "$job" "$line" ;;
        artifact.put)  _ca_apply_artifact "$job" "$line" ;;
        *) _ca_log "cannot apply op type '$t'"; return 1 ;;
    esac
}

# coord_apply_stream <job> — ops on stdin; prints the last applied seq.
coord_apply_stream() {
    local job="$1" af applied=0 line seq rc=0
    af=$(_ca_applied_file "$job")
    mkdir -p "$(dirname "$af")" 2>/dev/null || return 1
    applied=$(cat "$af" 2>/dev/null)
    case "$applied" in ''|*[!0-9]*) applied=0 ;; esac
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        seq=$(printf '%s' "$line" | jq -r 'if (.seq | type) == "number" then .seq else empty end' 2>/dev/null)
        case "$seq" in ''|*[!0-9]*) _ca_log "op without a numeric seq"; rc=1; break ;; esac
        [ "$seq" -gt "$applied" ] || continue
        if ! _ca_apply_op "$job" "$line"; then
            _ca_log "op seq $seq could not be applied; stopping"
            rc=1; break
        fi
        printf '%s' "$seq" > "${af}.tmp.$$" && mv "${af}.tmp.$$" "$af"
        applied="$seq"
    done
    printf '%s\n' "$applied"
    return "$rc"
}

# --- CLI ---------------------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -u
    [ $# -eq 2 ] || { echo "usage: coord_apply.sh <canonical-root> <job> < ops.ndjson" >&2; exit 2; }
    _ca_root="$1"; _ca_job="$2"
    [ -d "$_ca_root" ] || { echo "coord_apply: no such canonical root: $_ca_root" >&2; exit 2; }
    case "$_ca_job" in
        ''|*[!A-Za-z0-9._:-]*|*..*) echo "coord_apply: bad job id" >&2; exit 2 ;;
    esac
    # Canonical side: never inherit worker-mode or another tree's paths.
    unset MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR MOTHER_LIVE_ROOT \
        JOBS_DIR EVENTS_DIR LOGS_DIR DRAFTS_DIR CURSORS_DIR RUNNER_DIR ARCHIVE_DIR TEARDOWN_DIR RESIDUE_DIR
    MOTHER_ROOT=$(cd "$_ca_root" && pwd -P); export MOTHER_ROOT
    MOTHER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; export MOTHER_LIB_DIR
    # shellcheck source=/dev/null
    source "$MOTHER_LIB_DIR/state.sh"
    # shellcheck source=/dev/null
    [ -r "$MOTHER_LIB_DIR/usage.sh" ] && source "$MOTHER_LIB_DIR/usage.sh"
    coord_apply_stream "$_ca_job"
    exit $?
fi
