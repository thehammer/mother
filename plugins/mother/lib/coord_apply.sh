#!/usr/bin/env bash
# coord_apply.sh — replay a worker outbox onto the canonical state tree (cluster Phase 1, P1-2).
#
#   coord_apply.sh <canonical-root> <job> < ops.ndjson
#
# Reads the ops lib/outbox.sh wrote (`{"seq":N,"t":type,"ts":..,"data":..}`, one per line) and
# applies them in order onto <canonical-root> with today's lock and write functions, under the
# idempotency rules of docs/worker-protocol.md section 6.
#
# THIS REPLAY IS THE BOUNDARY. A worker (or an agent running inside it) can write straight into its
# outbox file, so nothing the outbox says is trusted: every op is judged here, as strictly as the P1-1
# wire protocol (broker/workerproto CheckJobSet, WorkerKeys, CoordinatorDerivedKeys, SyncDownKeys,
# keyKinds). The key tables below are copies of the Go constants; tests/state_seam.bats fails when
# they drift.
#
#   job.set        keys judged one by one: allowed keys apply, refused keys are audited. A refused
#                  `state` key (succeeded, leaving a terminal state, running after a cancel, an unknown
#                  value) refuses the WHOLE op: half a state change is unsafe. `succeeded` and every
#                  coordinator-derived key (pr_url, actual_branch, finished_at, exit_code,
#                  failure_reason) are never accepted from a worker: the coordinator derives them from
#                  its own flow (P1-5) or holds the job. Values are checked against keyKinds (type,
#                  charset, length, 64 KiB for objects/arrays). A terminal `state` triggers the
#                  canonical cost recompute (the canonical side owns cost).
#   event.append   one event object on one line, size-capped.
#   record.append  one usage row for this job, size-capped; followed by the canonical cost recompute.
#   artifact.put   offset-addressed into crew/<job>/ or checkpoints/<job>/ only; `final` needs a
#                  sha256 and is verified; per-file and per-job byte caps.
#
# Exactly-once: ops must arrive with contiguous seq. seq <= the persisted applied seq
# ($root/runner/leases/applied/<job>.seq) is a duplicate (skipped); a gap stops the replay and says so.
# There is no tail-line dedupe: a legitimately repeated identical line is applied, a duplicate seq is not.
# A crash between applying an op and persisting its seq must not double-count: before a non-idempotent op
# (event.append, record.append) is applied an inflight marker (<job>.inflight: seq and sha256 of the op line)
# is written; it is cleared once the seq is persisted. On restart, a marker for the next seq means that op may
# have landed: an event is skipped when it is already the last line of the events file, and a usage row carries
# a stable id `apply_id` = <job>:<seq>, so a row already in runs.jsonl is never appended twice (the cost
# recompute, which is idempotent, still runs). job.set and artifact.put are idempotent.
#
# No poison line: a structurally bad line (not JSON, no seq, oversize) or op (invalid value, escaping
# path, bad sha) is quarantined to runner/leases/<job>.quarantine.ndjson with an audit entry and the
# replay moves on, so the job can still reach its terminal state. A transient failure (lock timeout,
# unwritable file) is NEVER quarantined: it stops the replay (exit 1) and the next call retries the same op.
# Every such stop is counted in runner/leases/applied/<job>.retry, audited (code transient_stop), and after
# MOTHER_APPLY_STALL_ATTEMPTS (3) consecutive stops on one op the job gets a needs_attention flag
# (reason apply_stalled). Quarantine is for lines that can never apply.
#
# Per call the replay holds a per-job apply lock (two replays can never double-apply) and stops
# cleanly after MOTHER_APPLY_MAX_SECONDS (120; 0 = no limit) or MOTHER_APPLY_MAX_OPS (0 = no limit);
# call again to resume.
#
# SUCCESS IS DERIVED, NEVER REPLAYED (cluster P1-5). The protocol refuses `succeeded` from a worker (the Go
# admitter drops the frame; this replay refuses it too). The coordinator side writes it itself:
#
#   coord_apply.sh --finalize <canonical-root> <job>
#
# Called by mother-runner for a job whose lease is `released` with end_reason `succeeded` while the canonical
# job is still `running`. It never trusts the worker's claim: unless the job is `no_pr` with no PR url, the
# job's final commit (the local branch tip in the job's own repo; never one the worker reports) must be contained in
# the live head of the remote branch (`mother_remote_contains_commit`, the pr-detection-hardening helper:
# live ls-remote, then fetch, then merge-base; a hung remote is a refusal, never a success). Verified: the
# job becomes `succeeded` with the same bookkeeping a legacy success writes (failure_reason, finished_at,
# force_start, backoff fields), the completion-evidence keys (pr_url, actual_branch, exit_code) are taken from
# the worker's mirror only now and only when well formed (an `actual_branch` only for a job that declared
# expect_branch_mismatch, a `pr_url` only inside the origin's repository when that is a github.com remote),
# and the cost is recomputed. Refused: the job becomes `failed` with reason `unpushed_commit` and a
# needs_attention item, exactly as the local hardening does, plus an audit line; `succeeded` is never written.
# As in the local hardening, a check with nothing to check against (no checkout, no origin remote) is skipped
# and audited as `verify_skipped`; a remote that exists whose final commit cannot be resolved is a refusal.
# Exit: 0 finalized as succeeded, 3 refused (job failed unpushed_commit), 4 cancelled (a cancel was requested),
# 1 nothing to do (not running, not a released-succeeded lease).
#
# Prints the last applied seq on stdout. Exit: 0 all applied, 1 stopped (gap, transient failure, lock,
# unknown job: ops remain), 3 done but some op(s) were quarantined, 4 a time/op budget ended the call.
# Can also be sourced (functions only).

# --- ownership table: copies of broker/workerproto/ownership.go --------------------------------

# WorkerKeys: job keys the worker side may set or delete.
_CA_WORKER_KEYS='activity session_id worker_pid paused_reason paused_at question final_result_at started_at continuation_count resume_not_yet_acted_on gates review_wave limiter_hold live_cost_usd live_tokens current_run cost_cap_breached_at token_alert_at rwx_sandbox resume_session_id resume_kind limiter_resume_prompt attention decision attempt_run adherence_status adherence_attempts adherence_pending adherence_notes adherence_sha_runs adherence_reviewed_sha'
# CoordinatorDerivedKeys: completion evidence; refused from a worker.
_CA_DERIVED_KEYS='pr_url actual_branch finished_at exit_code failure_reason'
# SyncDownKeys: flow coordinator to worker; refused from a worker (pending_answer may be nulled).
_CA_SYNCDOWN_KEYS='cancel_requested pause_requested pending_answer max_cost_usd force_start'
# StateValues: what a worker may set `state` to ("succeeded" is the coordinator's).
_CA_STATE_VALUES='running awaiting failed cancelled'
# keyKinds: key:kind for every WorkerKey.
_CA_KEY_KINDS='activity:token session_id:id worker_pid:uint paused_reason:token paused_at:ts question:text final_result_at:ts started_at:ts continuation_count:uint resume_not_yet_acted_on:bool gates:object review_wave:object limiter_hold:object live_cost_usd:num live_tokens:uint current_run:object cost_cap_breached_at:ts token_alert_at:ts rwx_sandbox:object resume_session_id:id resume_kind:token limiter_resume_prompt:text attention:array decision:object attempt_run:object adherence_status:token adherence_attempts:uint adherence_pending:bool adherence_notes:text adherence_sha_runs:uint adherence_reviewed_sha:id'
# workerproto limits.
_CA_MAX_TEXT=8192
_CA_MAX_STRUCT=65536
_CA_MAX_KEYS=128
_CA_MAX_CHUNK=262144

# The one key the replay accepts beyond the Go table (P1-3 should add it there): `pipeline`, and only its
# `reviewer_findings` object. bin/mother's _review_slot_write writes .pipeline.reviewer_findings[<r>]
# in worker mode; the whole `pipeline` object is coordinator state (cycles, caps), so only that sub-key
# is merged and everything else in the value is ignored. Typed: an object, <= 64 KiB.
_CA_EXTRA_KEYS='pipeline'

_ca_words_json() { printf '%s\n' "$1" | tr ' ' '\n' | jq -Rn '[inputs | select(length > 0)]'; }
_ca_kinds_json() {
    printf '%s\n' "$_CA_KEY_KINDS" | tr ' ' '\n' | jq -Rn '[inputs | select(length > 0) | split(":") | {key: .[0], value: .[1]}] | from_entries'
}

# --- helpers -----------------------------------------------------------------------------------

_ca_log() { echo "coord_apply: $*" >&2; }

_ca_audit() {
    local job="$1" code="$2" keys="$3" dir
    dir="$MOTHER_ROOT/runner/leases"
    mkdir -p "$dir" 2>/dev/null || return 1
    jq -nc --arg ts "$(_iso_now)" --arg job "$job" --arg code "$code" --argjson keys "$keys" \
        '{ts: $ts, job: $job, code: $code, keys: $keys}' >> "$dir/audit.jsonl"
}

# Byte length with no process spawn (the replay calls this per op): the C locale makes ${#} count bytes.
_ca_bytes() { local LC_ALL=C; printf '%s' "${#1}"; }

_ca_max_line()  { printf '%s' "${MOTHER_APPLY_MAX_LINE_BYTES:-1048576}"; }
_ca_max_event() { printf '%s' "${MOTHER_APPLY_MAX_EVENT_BYTES:-65536}"; }
_ca_max_row()   { printf '%s' "${MOTHER_APPLY_MAX_ROW_BYTES:-16384}"; }

# Return codes of the _ca_apply_* functions: 0 applied, 1 structural (the op can never apply: quarantine),
# 2 transient (retry), 3 fatal (stop, nothing to count: e.g. the job does not exist on this root).

# _ca_quarantine <job> <seq|-> <reason> <line> — returns 0 when newly quarantined, 5 when this exact line
# was already quarantined by an earlier call (a replay re-reads the same bad line every time).
_ca_quarantine() {
    local job="$1" seq="$2" reason="$3" line="$4" dir sha qf
    dir="$MOTHER_ROOT/runner/leases"
    mkdir -p "$dir" 2>/dev/null || return 1
    qf="$dir/$job.quarantine.ndjson"
    sha=$(printf '%s' "$line" | shasum -a 256 | cut -c1-64)
    if [ -f "$qf" ] && grep -qF "\"sha\":\"$sha\"" "$qf" 2>/dev/null; then return 5; fi
    jq -nc --arg ts "$(_iso_now)" --arg job "$job" --arg seq "$seq" --arg reason "$reason" --arg sha "$sha" \
        --arg line "$(printf '%s' "$line" | LC_ALL=C cut -c1-16384)" \
        '{ts: $ts, job: $job, seq: (if $seq == "-" then null else ($seq | tonumber) end), reason: $reason, sha: $sha, line: $line}' \
        >> "$qf" || return 1
    _ca_audit "$job" quarantined "$(jq -nc --arg s "$seq" --arg r "$reason" '["seq=" + $s, $r]')"
    _ca_log "quarantined op seq $seq: $reason"
}

# --- job.set -----------------------------------------------------------------------------------

# The verdict, as jq. Inputs: the op's `data`, then the current job document. Output (one JSON object):
#   structural    null, or why the op's shape can never apply
#   refused       [{key, code}]   (code: ownership | invalid)
#   state_refused true when `state` is among them (then the whole op is refused)
_CA_VERDICT_JQ='
input as $op | input as $cur
| ($states | map(select(. != null))) as $sv
| def terminal: . == "succeeded" or . == "failed" or . == "cancelled";
  def badcp: . < 9 or (. > 10 and . < 32) or (. >= 127 and . <= 159) or . == 8206 or . == 8207
             or (. >= 8234 and . <= 8238) or (. >= 8294 and . <= 8297);
  def textok($max): type == "string" and utf8bytelength <= $max and ((explode | any(.[]; badcp)) | not);
  def idok: type == "string" and test("\\A[A-Za-z0-9._:-]{1,128}\\z") and (contains("..") | not);
  def tokenok: type == "string" and test("\\A[A-Za-z0-9._:-]{1,64}\\z");
  def tsok: type == "string" and . != "" and textok(64);
  def uintok: type == "number" and . >= 0 and . == floor and . <= 9223372036854775807;
  def sizeok: (tojson | utf8bytelength) <= $maxstruct;
  def kindok($kind):
      if . == null then true
      elif $kind == "text" then textok($maxtext)
      elif $kind == "token" then tokenok
      elif $kind == "id" then idok
      elif $kind == "ts" then tsok
      elif $kind == "uint" then uintok
      elif $kind == "num" then (type == "number" and . >= 0)
      elif $kind == "bool" then type == "boolean"
      elif $kind == "object" then (type == "object" and sizeok)
      elif $kind == "array" then (type == "array" and sizeok)
      else false end;
  def set_code($k; $v):
      if $k == "state" then
          if (($v | type) == "string") and ($sv | index($v)) then
              if (($cur.state // "") | terminal) and ($cur.state != $v) then "ownership"
              elif $v == "running" and (($cur.cancel_requested == true) or ($cur.state == "cancelled")) then "ownership"
              else "" end
          else "ownership" end
      elif $k == "pending_answer" then (if $v == null then "" else "ownership" end)
      elif $k == "pipeline" then
          (if ($v | type) == "object" and (($v.reviewer_findings // {}) | type) == "object"
                and (($v.reviewer_findings // {}) | sizeok) then "" else "invalid" end)
      elif ($kinds | has($k)) then (if ($v | kindok($kinds[$k])) then "" else "invalid" end)
      else "ownership" end;
  def del_code($k):
      if $k == "state" then "ownership"
      elif $k == "pending_answer" then ""
      elif ($kinds | has($k)) then ""
      else "ownership" end;
  if ($op | type) != "object" then {structural: "data is not an object", refused: [], state_refused: false}
  elif (($op.set // {}) | type) != "object" then {structural: "set is not an object", refused: [], state_refused: false}
  elif (($op.del // []) | (type == "array" and all(.[]; type == "string"))) | not then
      {structural: "del is not a list of strings", refused: [], state_refused: false}
  elif (($op.set // {}) | length) > $maxkeys or (($op.del // []) | length) > 256 then
      {structural: "too many keys", refused: [], state_refused: false}
  else
      ([($op.set // {}) | to_entries[] | {key, code: set_code(.key; .value)} | select(.code != "")]
       + [($op.del // [])[] | {key: ., code: del_code(.)} | select(.code != "")]) as $r
      | {structural: null, refused: $r, state_refused: ($r | any(.[]; .key == "state"))}
  end'

# Runs under the job-file lock (in this shell: _with_lock runs its command in-process): judge the op against
# the current document, then apply what is allowed. $1 job file; the op's `data` is in $_CA_OP. Sets $_CA_RES
# to one line `status US own US inv US terminal US reason` (US = 0x1f) (status: applied|refused|structural; own/inv:
# JSON key lists refused as ownership/invalid; terminal: failed|cancelled|""). The replay runs this for every
# job.set of every batch, so it spends few processes: the verdict, one parse of it, the merge.
_ca_job_set_locked() {
    local jf="$1" verdict merged skip parsed structural state_refused own inv terminal
    : "${_CA_KINDS_JSON:=$(_ca_kinds_json)}"
    _CA_RES=""
    verdict=$(jq -c -n --argjson op "$_CA_OP" --argjson kinds "$_CA_KINDS_JSON" \
        --argjson states '["running","awaiting","failed","cancelled"]' \
        --argjson maxtext "$_CA_MAX_TEXT" --argjson maxstruct "$_CA_MAX_STRUCT" --argjson maxkeys "$_CA_MAX_KEYS" \
        "${_CA_VERDICT_JQ/input as \$op | input as \$cur/input as \$cur}" "$jf") || return 2
    parsed=$(printf '%s' "$verdict" | jq -r --argjson op "$_CA_OP" '
        [(.structural // ""), (.state_refused | tostring),
         ([.refused[] | select(.code == "ownership") | .key] | tojson),
         ([.refused[] | select(.code == "invalid") | .key] | tojson),
         ((if ($op | type) == "object" and (($op.set // {}) | type) == "object" then ($op.set // {}).state else null end // "")
            | select(. == "failed" or . == "cancelled") // ""),
         ([.refused[].key] | tojson)] | join("\u001f")') || return 2
    # US (0x1f) is not IFS whitespace, so empty fields survive the split.
    IFS=$'\037' read -r structural state_refused own inv terminal skip <<EOF_PARSED
$parsed
EOF_PARSED
    if [ -n "$structural" ]; then
        _CA_RES="structural"$'\037'"[]"$'\037'"[]"$'\037'$'\037'"$structural"
        return 0
    fi
    if [ "$state_refused" = "true" ]; then
        _CA_RES="refused"$'\037'"$own"$'\037'"$inv"$'\037'$'\037'"state change refused; the whole op is refused"
        return 0
    fi
    merged=$(jq -n --argjson skip "$skip" --argjson op "$_CA_OP" '
        input as $cur | reduce (($op.set // {}) | to_entries[] | select(.key as $k | $skip | index($k) | not)) as $e ($cur;
            if $e.key == "pipeline"
            then (.pipeline //= {}) | .pipeline.reviewer_findings = ($e.value.reviewer_findings // .pipeline.reviewer_findings // {})
            else .[$e.key] = $e.value end)
        | delpaths([($op.del // [])[] | select(. as $k | $skip | index($k) | not) | [.]])' "$jf") || return 2
    _atomic_write "$jf" "$merged" || return 2
    _CA_RES="applied"$'\037'"$own"$'\037'"$inv"$'\037'"$terminal"$'\037'
}

_ca_apply_job_set() {
    local job="$1" line="$2" jf rc=0 status own inv terminal reason
    jf=$(_job_path "$job")
    [ -f "$jf" ] || { _ca_log "no such job on the canonical root: $job"; return 3; }
    _CA_OP=$(printf '%s' "$line" | jq -c '.data') || return 1
    _CA_RES=""
    _with_lock "$jf" _ca_job_set_locked "$jf" || rc=2
    [ "$rc" -eq 0 ] || return "$rc"
    IFS=$'\037' read -r status own inv terminal reason <<EOF_RES
$_CA_RES
EOF_RES
    case "$status" in
        structural)
            _ca_log "job.set: $reason"
            return 1 ;;
        refused|applied)
            [ "$own" = "[]" ] || _ca_audit "$job" ownership "$own"
            [ "$inv" = "[]" ] || _ca_audit "$job" invalid "$inv"
            if [ "$status" = "refused" ]; then
                _ca_audit "$job" op_refused "$(printf '%s' "$line" | jq -c '[(.data.set // {} | keys[]), (.data.del // [])[]]')"
            elif [ -n "$terminal" ] && type mother_recompute_job_cost >/dev/null 2>&1; then
                mother_recompute_job_cost "$job"
            fi ;;
        *) return 2 ;;
    esac
    return 0
}

# --- event.append / record.append --------------------------------------------------------------

# A single non-empty line: valid UTF-8, no newline, no C0 controls other than tab (workerproto lineOK).
_CA_LINE_JQ='def badcp: . < 9 or (. > 10 and . < 32) or . == 127;
    (.data.line // "") as $l | ($l | type) == "string" and $l != "" and (($l | explode | any(.[]; badcp or . == 10)) | not)'

_ca_apply_event() {
    local job="$1" line="$2" ev ef
    ev=$(printf '%s' "$line" | jq -r "if ($_CA_LINE_JQ) then .data.line else empty end" 2>/dev/null)
    [ -n "$ev" ] || { _ca_log "event.append: line must be a single non-empty line without control characters"; return 1; }
    [ "$(_ca_bytes "$ev")" -le "$(_ca_max_event)" ] || { _ca_log "event.append: line over MOTHER_APPLY_MAX_EVENT_BYTES"; return 1; }
    # One JSON object with a kind: a worker's line never becomes anything but a single event line.
    printf '%s' "$ev" | jq -e 'type == "object" and (.kind | type) == "string"' >/dev/null 2>&1 \
        || { _ca_log "event.append: line is not a single event object"; return 1; }
    ef=$(_events_path "$job")
    # Crash recovery: the inflight marker for this very seq (set by the driver) says this op may already be
    # the last line of the events file. Only then is the tail compared, so a genuinely repeated line is kept.
    if [ -n "${_CA_RECOVERING:-}" ] && [ "$(tail -n 1 "$ef" 2>/dev/null)" = "$ev" ]; then return 0; fi
    _with_lock "$ef" _append_line "$ef" "$ev" || return 2
}

_ca_apply_record() {
    local job="$1" line="$2" stream row file
    stream=$(printf '%s' "$line" | jq -r '.data.stream // empty')
    case "$stream" in
        metrics/runs.jsonl) ;;
        *) _ca_log "record.append: unknown stream '$stream'"; return 1 ;;
    esac
    printf '%s' "$line" | jq -e "$_CA_LINE_JQ" >/dev/null 2>&1 \
        || { _ca_log "record.append: line must be a single non-empty line without control characters"; return 1; }
    row=$(printf '%s' "$line" | jq -r '.data.line')
    [ "$(_ca_bytes "$row")" -le "$(_ca_max_row)" ] || { _ca_log "record.append: row over MOTHER_APPLY_MAX_ROW_BYTES"; return 1; }
    # A usage row feeds cost totals and the cost cap: it must be one object for this job, with
    # non-negative numeric cost/tokens.
    printf '%s' "$row" | jq -e --arg j "$job" '
        type == "object" and .job_id == $j
        and all(.cost_usd, .tokens_in, .tokens_out; . == null or (type == "number" and . >= 0))' \
        >/dev/null 2>&1 || { _ca_log "record.append: row is not a valid usage row for $job"; return 1; }
    file="$MOTHER_ROOT/$stream"
    mkdir -p "$(dirname "$file")" 2>/dev/null || return 2
    # Stable row id from (job, seq): a row that already landed (crash before the seq was persisted) is not
    # appended again. The id is only added when the op carries a seq (always, via the replay driver).
    local aid="${_CA_CUR_SEQ:+$job:$_CA_CUR_SEQ}"
    if [ -n "$aid" ]; then
        row=$(printf '%s' "$row" | jq -c --arg a "$aid" '.apply_id = $a') || return 1
        # grep only prefilters: the match is on the parsed top-level field, so a worker cannot fake it
        # by putting the id text inside another field of some other row.
        if ! { grep -F "\"apply_id\":\"$aid\"" "$file" 2>/dev/null || true; } \
                | jq -e --arg a "$aid" 'select(type == "object" and .apply_id == $a)' >/dev/null 2>&1; then
            _with_lock "$file" _append_line "$file" "$row" || return 2
        fi
    else
        _with_lock "$file" _append_line "$file" "$row" || return 2
    fi
    # What mother_record_run_usage does after appending a row, on the canonical side.
    type mother_recompute_job_cost >/dev/null 2>&1 && mother_recompute_job_cost "$job"
    type mother_maybe_token_alert >/dev/null 2>&1 && mother_maybe_token_alert "$job" >/dev/null
    return 0
}

# --- artifact.put ------------------------------------------------------------------------------

# Relative, clean, confined to crew/<job>/ or checkpoints/<job>/ (workerproto ArtifactPathOK).
_ca_artifact_path_ok() {
    local job="$1" p="$2" part rest
    [ "${#p}" -le 1024 ] || return 1
    case "$p" in
        ''|/*|*'\'*) return 1 ;;
        crew/"$job"/?*|checkpoints/"$job"/?*) ;;
        *) return 1 ;;
    esac
    case "$p" in *[[:cntrl:]]*) return 1 ;; esac
    rest="$p"
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        case "$part" in ''|.|..) return 1 ;; esac
        case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
    done
    case "$p" in */) return 1 ;; esac
    return 0
}

_ca_b64_decode() {
    if printf 'YQ==' | base64 -d >/dev/null 2>&1; then base64 -d; else base64 -D; fi
}

_ca_dir_bytes() { # <dir...> — total bytes under existing dirs
    local d total=0 k
    for d in "$@"; do
        [ -d "$d" ] || continue
        k=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
        total=$((total + ${k:-0} * 1024))
    done
    echo "$total"
}

# Runs under the lock on the .part file. $1 job, $2 rel, $3 off, $4 final, $5 sha, $6 chunk file.
_ca_artifact_write_locked() {
    local job="$1" rel="$2" off="$3" final="$4" sha="$5" tmp="$6" dest part size skip got chunk total
    dest="$MOTHER_ROOT/$rel"; part="$dest.part"
    chunk=$(wc -c < "$tmp" | tr -d ' ')
    if [ "$off" -eq 0 ]; then
        : > "$part" || return 2
    fi
    size=$(wc -c < "$part" 2>/dev/null | tr -d ' ')
    [ -n "$size" ] || size=0
    if [ "$off" -gt "$size" ]; then
        _ca_log "artifact.put: gap at offset $off (have $size)"; return 1
    fi
    skip=$((size - off))     # bytes of this chunk already present (a resend)
    if [ "$skip" -lt "$chunk" ]; then
        if [ $((size + chunk - skip)) -gt "${MOTHER_APPLY_MAX_FILE_BYTES:-268435456}" ]; then
            rm -f "$part"; _ca_log "artifact.put: $rel over MOTHER_APPLY_MAX_FILE_BYTES"; return 1
        fi
        total=$(_ca_dir_bytes "$MOTHER_ROOT/crew/$job" "$MOTHER_ROOT/checkpoints/$job")
        if [ $((total + chunk)) -gt "${MOTHER_APPLY_MAX_ARTIFACT_BYTES:-1073741824}" ]; then
            rm -f "$part"; _ca_log "artifact.put: job $job over MOTHER_APPLY_MAX_ARTIFACT_BYTES"; return 1
        fi
        tail -c +$((skip + 1)) "$tmp" >> "$part" || return 2
    fi
    if [ "$final" = "true" ]; then
        got=$(shasum -a 256 "$part" | cut -d' ' -f1)
        if [ "$got" != "$sha" ]; then
            _ca_log "artifact.put: sha256 mismatch for $rel"
            rm -f "$part"
            return 1
        fi
        mv "$part" "$dest" || return 2
    fi
    return 0
}

_ca_apply_artifact() {
    local job="$1" line="$2" rel off b64len final sha dest tmp rc raw
    rel=$(printf '%s' "$line" | jq -r '.data.path // empty')
    off=$(printf '%s' "$line" | jq -r 'if (.data.offset | type) == "number" and .data.offset >= 0 and .data.offset == (.data.offset | floor) then .data.offset else empty end')
    final=$(printf '%s' "$line" | jq -r 'if .data.final == true then "true" else "false" end')
    sha=$(printf '%s' "$line" | jq -r '.data.sha256 // empty')
    _ca_artifact_path_ok "$job" "$rel" || { _ca_log "artifact.put: path not allowed: '$rel'"; return 1; }
    case "$off" in ''|*[!0-9]*) _ca_log "artifact.put: bad offset"; return 1 ;; esac
    [ "${#off}" -le 15 ] || { _ca_log "artifact.put: bad offset"; return 1; }
    if [ "$final" = "true" ]; then
        case "$sha" in
            '') _ca_log "artifact.put: a final chunk needs a sha256 ($rel)"; return 1 ;;
            *[!0-9a-f]*) _ca_log "artifact.put: malformed sha256 ($rel)"; return 1 ;;
        esac
        [ "${#sha}" -eq 64 ] || { _ca_log "artifact.put: malformed sha256 ($rel)"; return 1; }
    fi
    printf '%s' "$line" | jq -e '(.data.b64 // "") | type == "string"' >/dev/null 2>&1 || { _ca_log "artifact.put: bad base64"; return 1; }
    dest="$MOTHER_ROOT/$rel"
    mkdir -p "$(dirname "$dest")" || return 2
    tmp=$(mktemp "${TMPDIR:-/tmp}/coord-apply-chunk.XXXXXX") || return 2
    printf '%s' "$line" | jq -j '.data.b64 // ""' | _ca_b64_decode > "$tmp" 2>/dev/null \
        || { rm -f "$tmp"; _ca_log "artifact.put: bad base64"; return 1; }
    raw=$(wc -c < "$tmp" | tr -d ' ')
    if [ "$raw" -gt "$_CA_MAX_CHUNK" ]; then
        rm -f "$tmp"; _ca_log "artifact.put: chunk over $_CA_MAX_CHUNK bytes"; return 1
    fi
    _with_lock "$dest.part" _ca_artifact_write_locked "$job" "$rel" "$off" "$final" "$sha" "$tmp"
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

# Unfinished .part files nobody has resumed for MOTHER_APPLY_PART_MAX_AGE_MIN (1440) minutes.
_ca_sweep_parts() {
    local job="$1" d
    for d in "$MOTHER_ROOT/crew/$job" "$MOTHER_ROOT/checkpoints/$job"; do
        [ -d "$d" ] && find "$d" -type f -name '*.part' -mmin +"${MOTHER_APPLY_PART_MAX_AGE_MIN:-1440}" -exec rm -f {} + 2>/dev/null
    done
    return 0
}

# --- driver ------------------------------------------------------------------------------------

_ca_applied_file() { printf '%s/runner/leases/applied/%s.seq' "$MOTHER_ROOT" "$1"; }

# _ca_apply_op <job> <op-line> — apply one op (return codes above).
_ca_apply_op() {
    local job="$1" line="$2" t="${3:-}"
    [ -n "$t" ] || t=$(printf '%s' "$line" | jq -r '.t // empty') || return 1
    case "$t" in
        job.set)       _ca_apply_job_set "$job" "$line" ;;
        event.append)  _ca_apply_event "$job" "$line" ;;
        record.append) _ca_apply_record "$job" "$line" ;;
        artifact.put)  _ca_apply_artifact "$job" "$line" ;;
        *) _ca_log "cannot apply op type '$t'"; return 1 ;;
    esac
}

_ca_inflight_file() { printf '%s/runner/leases/applied/%s.inflight' "$MOTHER_ROOT" "$1"; }

_ca_line_sha() { printf '%s' "$1" | shasum -a 256 | cut -c1-64; }

_ca_stall_flag() { # <job-file> <seq> <rn> — under the job lock
    local doc
    doc=$(jq -c --arg s "$2" --arg n "$3" --arg t "$(_iso_now)" \
        '.needs_attention = {reason: "apply_stalled", note: ("outbox op seq " + $s + " failed transiently " + $n + " times in a row; it stays pending and is retried on the next replay"), since: (.needs_attention.since // $t)}' "$1") \
        && _atomic_write "$1" "$doc"
}

# _ca_stall <job> <seq> <rn> — a transient stop: audit it, and flag the job after N consecutive ones.
_ca_stall() {
    local job="$1" seq="$2" rn="$3" jf
    _ca_audit "$job" transient_stop "$(jq -nc --arg s "$seq" --argjson n "$rn" '["seq=" + $s, "attempt=" + ($n | tostring)]')"
    if [ "$rn" -ge "${MOTHER_APPLY_STALL_ATTEMPTS:-3}" ]; then
        jf=$(_job_path "$job")
        [ -f "$jf" ] || return 0
        # Short lock wait (about 0.1 s): the stall is often a job-lock timeout, so wait long for that same
        # lock would be pointless. No lock, no flag; the next stalled call tries again.
        _switch_with_lock "$jf.lockdir" "$jf" 2 _ca_stall_flag "$jf" "$seq" "$rn" 2>/dev/null || true
    fi
    return 0
}

_ca_persist_seq() { # <file> <seq>
    printf '%s' "$2" > "${1}.tmp.$$" && mv "${1}.tmp.$$" "$1"
}

# Runs under the per-job apply lock; ops on stdin.
_ca_stream_locked() {
    local job="$1" af applied=0 line seq rc=0 poison=0 op_rc q_rc retry_file rn rseq started max_s max_ops ops=0 torn=0 inf_t
    af=$(_ca_applied_file "$job")
    retry_file="${af%.seq}.retry"
    applied=$(cat "$af" 2>/dev/null)
    case "$applied" in ''|*[!0-9]*) applied=0 ;; esac
    started=$SECONDS
    max_s="${MOTHER_APPLY_MAX_SECONDS:-120}"; max_ops="${MOTHER_APPLY_MAX_OPS:-0}"
    _ca_sweep_parts "$job"
    while :; do
        torn=0
        if ! IFS= read -r line; then
            [ -n "$line" ] || break
            torn=1   # a last line with no newline: possibly still being written
        fi
        [ -n "$line" ] || continue
        if { [ "$max_s" -gt 0 ] && [ $((SECONDS - started)) -ge "$max_s" ]; } || { [ "$max_ops" -gt 0 ] && [ "$ops" -ge "$max_ops" ]; }; then
            _ca_log "replay budget reached after seq $applied; call again to resume"
            rc=4; break
        fi
        if [ "$(_ca_bytes "$line")" -gt "$(_ca_max_line)" ]; then
            _ca_quarantine "$job" - "line over MOTHER_APPLY_MAX_LINE_BYTES" "$line"; q_rc=$?
            [ "$q_rc" -le 5 ] && [ "$q_rc" -ne 1 ] || { rc=1; break; }
            [ "$q_rc" -eq 0 ] && rc=3
            poison=$((poison + 1)); continue
        fi
        # One jq for both the seq and the op type (this runs for every op of every batch).
        inf_t=""
        seq=$(printf '%s' "$line" | jq -r 'if type == "object" and (.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor) and (.t | type) == "string" then "\(.seq)\t\(.t)" else empty end' 2>/dev/null)
        inf_t="${seq#*$'\t'}"; seq="${seq%%$'\t'*}"
        case "$seq" in
            ''|*[!0-9]*)
                if [ "$torn" -eq 1 ]; then _ca_log "unterminated last line is not a complete op yet; stopping"; rc=1; break; fi
                _ca_quarantine "$job" - "not a JSON op with a numeric seq and type" "$line"; q_rc=$?
                [ "$q_rc" -le 5 ] && [ "$q_rc" -ne 1 ] || { rc=1; break; }
                [ "$q_rc" -eq 0 ] && rc=3
                poison=$((poison + 1)); continue ;;
        esac
        [ "$seq" -gt "$applied" ] || continue                       # duplicate: already applied
        if [ "$seq" -ne $((applied + 1)) ]; then
            if [ "$poison" -gt 0 ] && [ "$seq" -le $((applied + 1 + poison)) ]; then
                # Quarantined lines took the missing slots. Bounded caveat: this lets one garbage line mask
                # one genuinely lost seq (a garbage line cannot be told from a lost op); it never masks more
                # than the number of lines quarantined since the last applied seq.
                :
            else
                _ca_log "gap in the outbox: applied through seq $applied, next op is seq $seq; stopping"
                rc=1; break
            fi
        fi
        # Inflight marker before a non-idempotent op (see the header); an existing one for this seq and line
        # means a previous call died between apply and persist.
        local inf inf_state
        inf=$(_ca_inflight_file "$job"); _CA_RECOVERING=""; _CA_CUR_SEQ="$seq"
        case "$inf_t" in
            event.append|record.append)
                inf_state="$seq $(_ca_line_sha "$line")"
                if [ "$(cat "$inf" 2>/dev/null)" = "$inf_state" ]; then _CA_RECOVERING=1
                else printf '%s\n' "$inf_state" > "$inf" 2>/dev/null || { _ca_log "cannot write the inflight marker for seq $seq"; rc=1; break; }
                fi ;;
        esac
        _ca_apply_op "$job" "$line" "$inf_t" </dev/null; op_rc=$?
        _CA_RECOVERING=""
        case "$op_rc" in
            0) ;;
            1) _ca_quarantine "$job" "$seq" "op cannot be applied (see the log line above)" "$line"; q_rc=$?
               [ "$q_rc" -le 5 ] && [ "$q_rc" -ne 1 ] || { rc=1; break; }
               [ "$q_rc" -eq 0 ] && rc=3 ;;
            3) _ca_log "op seq $seq: cannot apply to this root; stopping"; rc=1; break ;;
            *) rn=0
               if read -r rseq rn < "$retry_file" 2>/dev/null && [ "$rseq" = "$seq" ]; then :; else rn=0; fi
               rn=$((rn + 1))
               printf '%s %s\n' "$seq" "$rn" > "$retry_file" 2>/dev/null
               _ca_log "op seq $seq failed transiently (attempt $rn); stopping, it stays pending"
               _ca_stall "$job" "$seq" "$rn"
               rc=1; break ;;
        esac
        rm -f "$retry_file"
        if [ -n "${MOTHER_TEST_CRASH_AFTER_APPLY:-}" ] && [ "${MOTHER_TEST_ROOT:-}" = "1" ] \
            && [ "$MOTHER_TEST_CRASH_AFTER_APPLY" = "$seq" ]; then
            kill -9 $$   # test seam: die between apply and persist (MOTHER_TEST_ROOT only)
        fi
        _ca_persist_seq "$af" "$seq" || { _ca_log "cannot persist applied seq $seq"; rc=1; break; }
        rm -f "$(_ca_inflight_file "$job")"
        applied="$seq"; poison=0; ops=$((ops + 1))
    done
    printf '%s\n' "$applied"
    return "$rc"
}

# coord_apply_stream <job> — ops on stdin; prints the last applied seq. Exit codes: see the header.
coord_apply_stream() {
    local job="$1" af
    af=$(_ca_applied_file "$job")
    mkdir -p "$(dirname "$af")" 2>/dev/null || return 1
    # Per-job apply lock (owner pid recorded by _switch_with_lock): two replays can never double-apply.
    # A lock timeout prints its own message and returns 1.
    local rc=0
    _with_lock "$af" _ca_stream_locked "$job" || rc=$?
    # The coordinator, not the worker, writes the keys a worker may not (pr_url, work_dir): derived from the
    # worker's mirror and checked here, on every replay, so the canonical job shows what a legacy job shows
    # while it runs, gates, awaits or fails.
    _ca_derive_midrun "$job" || true
    return "$rc"
}

# --- success derivation (cluster P1-5) -----------------------------------------------------------

# _ca_lease_field <job> <key> — a field of runner/leases/<job>.json ("" when absent).
_ca_lease_field() {
    jq -r --arg k "$2" '.[$k] // empty' "$MOTHER_ROOT/runner/leases/$1.json" 2>/dev/null
}

# _ca_mirror_doc <worker-id> <job> — path of the worker's mirror document for a LOCAL worker ("" otherwise).
_ca_mirror_doc() {
    local wid="$1" job="$2" base="${MOTHER_WORKER_ROOT:-${HOME:-}/.mother-worker}" f
    case "$wid" in ''|*[!A-Za-z0-9._-]*|*..*) return 0 ;; esac
    f="$base/$wid/jobs/$job.json"
    [ -f "$f" ] && printf '%s' "$f"
    return 0
}

# _ca_verify_success <job> <remote-branch> — 0 verified (or the check cannot apply, audited), 1 refused.
# Reads the canonical job; never writes it.
_ca_verify_success() {
    local job="$1" rbranch="$2" jf repo branch iso wd final rc
    jf=$(_job_path "$job")
    repo=$(jq -r '.repo_path // empty' "$jf" 2>/dev/null)
    branch=$(jq -r '.branch // empty' "$jf" 2>/dev/null)
    iso=$(jq -r '.isolation // "worktree"' "$jf" 2>/dev/null)
    wd=$(jq -r '.work_dir // empty' "$jf" 2>/dev/null)
    # Nothing to check against when the job's checkout or its origin remote does not exist (the local
    # hardening skips the same case); a remote that exists is always checked.
    if [ -z "$repo" ] || [ ! -d "$repo" ] || ! (cd "$repo" && git remote get-url origin >/dev/null 2>&1); then
        _ca_audit "$job" verify_skipped '["no checkout or no origin remote"]'
        return 0
    fi
    final=""
    [ -n "$branch" ] && final=$(cd "$repo" && git rev-parse --verify -q "refs/heads/$branch" 2>/dev/null)
    if [ -z "$final" ] && [ "$iso" != "main-dir" ] && [ -n "$wd" ] && [ -d "$wd" ]; then
        final=$(cd "$wd" && git rev-parse --verify -q HEAD 2>/dev/null)
    fi
    # The commit comes from the canonical checkout only, never from what the worker reports. A remote that
    # exists but a final commit that cannot be resolved here is a refusal, not a skip.
    case "$final" in
        '') _ca_audit "$job" verify_refused '["final commit not resolvable in the canonical checkout"]'; return 1 ;;
        *[!0-9a-f]*) _ca_audit "$job" verify_refused '["final commit not resolvable in the canonical checkout"]'; return 1 ;;
    esac
    declare -F mother_remote_contains_commit >/dev/null || return 1
    mother_remote_contains_commit "$repo" "$rbranch" "$final"; rc=$?
    _CA_FINAL="$final"
    return "$rc"
}

# _ca_claims_json <mirror-doc> — the completion-evidence claims in the worker's mirror, well formed or dropped.
_ca_claims_json() {
    [ -n "$1" ] && [ -f "$1" ] || { echo '{}'; return 0; }
    jq -c '{pr_url: (.pr_url // null), actual_branch: (.actual_branch // null), exit_code: (.exit_code // null)}
        | (if (.pr_url | type) == "string" and (.pr_url | test("\\Ahttps://[A-Za-z0-9._:-]+/[A-Za-z0-9._/-]+/pull/[0-9]+\\z")) then . else del(.pr_url) end)
        | (if (.actual_branch | type) == "string" and (.actual_branch | test("\\A[A-Za-z0-9._/-]{1,200}\\z")) and (.actual_branch | contains("..") | not) then . else del(.actual_branch) end)
        | (if (.exit_code | type) == "number" and .exit_code >= 0 and .exit_code == (.exit_code | floor) then . else del(.exit_code) end)' "$1" 2>/dev/null || echo '{}'
}

# _ca_pr_url_matches_origin <job-file> <pr-url> — 0 when the url is empty, when the origin is not a github.com
# remote (nothing to compare with), or when the url's owner/repo is the origin's; 1 otherwise.
_ca_pr_url_matches_origin() {
    local jf="$1" url="$2" repo origin slug
    [ -n "$url" ] || return 0
    repo=$(jq -r '.repo_path // empty' "$jf" 2>/dev/null)
    [ -n "$repo" ] && [ -d "$repo" ] || return 0
    origin=$(cd "$repo" && git remote get-url origin 2>/dev/null) || return 0
    case "$origin" in
        *github.com[:/]*) slug="${origin#*github.com[:/]}"; slug="${slug%.git}"; slug="${slug%/}" ;;
        *) return 0 ;;
    esac
    case "$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')" in
        "https://github.com/$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')/pull/"*) return 0 ;;
    esac
    return 1
}

# _ca_need_prdetect — source prdetect.sh once (mother_remote_contains_commit, prd_pr_contains_sha).
_ca_need_prdetect() {
    declare -F mother_remote_contains_commit >/dev/null || [ ! -r "$MOTHER_LIB_DIR/prdetect.sh" ] \
        || source "$MOTHER_LIB_DIR/prdetect.sh"
}

# _ca_accept_pr_url <job-file> <pr-url> — the mother #117 adoption rule, applied by the coordinator to a PR url
# the worker's mirror claims. Accepted only on GitHub-side evidence it is the job's own: it is in the origin's
# repository, not a fork (isCrossRepository), and its head branch is the job's branch; an
# expect_branch_mismatch job also accepts a PR created since this attempt began or one containing the job's own
# commit. Returns 0 accepted (_CA_PR_HEAD = the PR's head branch), 1 refused (_CA_PR_REASON), 2 indeterminate
# (gh missing or failing: nothing is written, the next replay tries again).
_ca_accept_pr_url() {
    local jf="$1" url="$2" row state head cross created branch started ce se repo final rc
    _CA_PR_REASON=""; _CA_PR_HEAD=""
    _ca_pr_url_matches_origin "$jf" "$url" || { _CA_PR_REASON="foreign_repository"; return 1; }
    command -v gh >/dev/null 2>&1 || { _CA_PR_REASON="gh_unavailable"; return 2; }
    row=$(gh pr view "$url" --json state,headRefName,createdAt,isCrossRepository \
        --jq '[.state, .headRefName, ((.isCrossRepository // false) | tostring), (.createdAt // "-")] | join("\t")' 2>/dev/null || true)
    [ -n "$row" ] || { _CA_PR_REASON="pr_unresolved"; return 2; }
    IFS=$'\t' read -r state head cross created <<CA_PRV_EOF
$row
CA_PRV_EOF
    [ -n "$state" ] && [ -n "$head" ] || { _CA_PR_REASON="pr_unresolved"; return 2; }
    [ "$cross" != "true" ] || { _CA_PR_REASON="cross_repository"; return 1; }
    branch=$(jq -r '.branch // empty' "$jf" 2>/dev/null)
    if [ "$head" = "$branch" ]; then _CA_PR_HEAD="$head"; return 0; fi
    if [ "$(jq -r '.expect_branch_mismatch // false' "$jf" 2>/dev/null)" != "true" ]; then
        _CA_PR_REASON="head_branch_mismatch"; return 1
    fi
    started=$(jq -r '.attempt_run.started_at // .current_run.spawned_at // empty' "$jf" 2>/dev/null)
    if [ -n "$created" ] && [ "$created" != "-" ] && [ -n "$started" ]; then
        ce=$(_iso_to_epoch "$created"); se=$(_iso_to_epoch "$started")
        if [ "${ce:-0}" -gt 0 ] && [ "${se:-0}" -gt 0 ] && [ "$ce" -ge "$se" ]; then _CA_PR_HEAD="$head"; return 0; fi
    fi
    _ca_need_prdetect
    repo=$(jq -r '.repo_path // empty' "$jf" 2>/dev/null)
    final=""
    [ -n "$repo" ] && [ -n "$branch" ] && final=$(cd "$repo" 2>/dev/null && git rev-parse --verify -q "refs/heads/$branch" 2>/dev/null)
    if [ -n "$final" ] && declare -F prd_pr_contains_sha >/dev/null; then
        prd_pr_contains_sha "$url" "$final"; rc=$?
        case "$rc" in
            0) _CA_PR_HEAD="$head"; return 0 ;;
            2) _CA_PR_REASON="evidence_indeterminate"; return 2 ;;
        esac
    fi
    _CA_PR_REASON="pr_predates_run"
    return 1
}

# _ca_derive_midrun <job> — coordinator-derived keys taken from the worker's mirror while the job is not terminal:
#   pr_url   only when _ca_accept_pr_url accepts it (a refusal is audited once per url, `pr_url_refused`; a
#            transient failure is retried after 30 s); `actual_branch` is set when the PR's head differs from the job's branch.
#   work_dir the canonical checkout (repo_path) for a main-dir job, never a path the worker names; for a
#            worktree job the mirror's path only when it lies under the local worker's root.
# A no-op (no jq, no gh) unless the mirror shows something new.
_ca_derive_midrun() {
    local job="$1" jf wid mirror row murl mwd cur_url cur_wd iso marker mu me now_s ok rc
    jf=$(_job_path "$job")
    [ -f "$jf" ] || return 0
    wid=$(_ca_lease_field "$job" worker_id)
    mirror=$(_ca_mirror_doc "$wid" "$job")
    [ -n "$mirror" ] || return 0
    # Unit separator, not tab: a tab is IFS whitespace, so an empty pr_url would swallow the field and shift work_dir.
    row=$(jq -r '"\(.pr_url // "")\u001f\(.work_dir // "")"' "$mirror" 2>/dev/null) || return 0
    IFS=$'\037' read -r murl mwd <<CA_MR_EOF
$row
CA_MR_EOF
    # --- work_dir
    cur_wd=$(jq -r '.work_dir // empty' "$jf" 2>/dev/null)
    if [ -z "$cur_wd" ] && [ -n "$mwd" ]; then
        iso=$(jq -r '.isolation // "worktree"' "$jf" 2>/dev/null)
        if [ "$iso" = "main-dir" ]; then
            mwd=$(jq -r '.repo_path // empty' "$jf" 2>/dev/null)
        else
            # A path the worker names is taken only when it resolves (symlinks and `..` included) to a directory
            # under the local worker's own root; anything else is dropped.
            local wroot; wroot=$(cd -P "${MOTHER_WORKER_ROOT:-${HOME:-}/.mother-worker}/$wid" 2>/dev/null && pwd -P) || wroot=""
            case "$mwd" in */../*|*/..|*/./*|*//*) mwd="" ;; esac
            [ -z "$mwd" ] || mwd=$(cd -P "$mwd" 2>/dev/null && pwd -P) || mwd=""
            case "$mwd" in
                "$wroot"/*) [ -n "$wroot" ] || mwd="" ;;
                *) mwd="" ;;
            esac
        fi
        [ -z "$mwd" ] || _job_update "$job" ".work_dir = $(jq -nc --arg v "$mwd" '$v')" || return 0
    fi
    # --- pr_url
    [ -n "$murl" ] || return 0
    printf '%s' "$murl" | jq -Re 'test("\\Ahttps://[A-Za-z0-9._:-]+/[A-Za-z0-9._/-]+/pull/[0-9]+\\z")' >/dev/null 2>&1 || return 0
    cur_url=$(jq -r '.pr_url // empty' "$jf" 2>/dev/null)
    [ "$murl" != "$cur_url" ] || return 0
    marker="$MOTHER_ROOT/runner/leases/$job.pr-check"
    read -r mu me ok 2>/dev/null < "$marker" || mu=""
    now_s=$(date +%s)
    if [ "$mu" = "$murl" ]; then
        [ "$ok" = "refused" ] && return 0
        [ $((now_s - ${me:-0})) -ge 30 ] || return 0
    fi
    _ca_need_prdetect
    rc=0; _ca_accept_pr_url "$jf" "$murl" || rc=$?
    case "$rc" in
        0)
            printf '%s %s ok\n' "$murl" "$now_s" > "$marker" 2>/dev/null
            _job_update "$job" ".pr_url = $(jq -nc --arg v "$murl" '$v')
                | (if $(jq -nc --arg h "$_CA_PR_HEAD" '$h') != (.branch // \"\") then .actual_branch = $(jq -nc --arg h "$_CA_PR_HEAD" '$h') else . end)" ;;
        1)
            printf '%s %s refused\n' "$murl" "$now_s" > "$marker" 2>/dev/null
            _ca_audit "$job" pr_url_refused "$(jq -nc --arg r "$_CA_PR_REASON" '["pr_url: " + $r]')" ;;
        *)
            printf '%s %s retry\n' "$murl" "$now_s" > "$marker" 2>/dev/null ;;
    esac
    return 0
}

# coord_apply_finalize <job> — see the header. Prints nothing; exit codes: 0 succeeded, 3 refused, 1 nothing to do.
coord_apply_finalize() {
    local job="$1" jf st lstate lreason wid mirror claims rbranch claimed_branch pr_url no_pr note now fin_filter claim_url rc
    jf=$(_job_path "$job")
    [ -f "$jf" ] || return 1
    [ "$(jq -r '.state // empty' "$jf" 2>/dev/null)" = "running" ] || return 1
    lstate=$(_ca_lease_field "$job" state); lreason=$(_ca_lease_field "$job" end_reason)
    [ "$lstate" = "released" ] && [ "$lreason" = "succeeded" ] || return 1
    if [ "$(jq -r '.cancel_requested // false' "$jf" 2>/dev/null)" = "true" ]; then
        # The operator cancelled while the worker was finishing: the job ends `cancelled`, exactly as a legacy
        # supervisor leaves it (never succeeded, never left running with a released lease). The lease drops
        # out of the runner's active index so nothing waits on it.
        _job_transition "$job" cancelled '{"reason":"user"}' || return 2
        rm -f "$MOTHER_ROOT/runner/leases/active/$job"
        type mother_recompute_job_cost >/dev/null 2>&1 && mother_recompute_job_cost "$job"
        return 4
    fi
    wid=$(_ca_lease_field "$job" worker_id)
    mirror=$(_ca_mirror_doc "$wid" "$job")
    claims=$(_ca_claims_json "$mirror")
    # The remote branch to check is the canonical job's. The worker's claim of another branch is honoured
    # only for a job that declared it (expect_branch_mismatch); otherwise it is dropped, never verified.
    rbranch=$(jq -r '.actual_branch // .branch // empty' "$jf")
    claimed_branch=$(printf '%s' "$claims" | jq -r '.actual_branch // empty')
    if [ -n "$claimed_branch" ] && [ "$claimed_branch" != "$rbranch" ] \
        && [ "$(jq -r '.expect_branch_mismatch // false' "$jf")" = "true" ]; then
        rbranch="$claimed_branch"
    else
        claims=$(printf '%s' "$claims" | jq -c 'del(.actual_branch)')
    fi
    # A claimed PR url is taken only under the #117 rule (same repository, not a fork, the job's head branch or
    # evidence it is the job's own); one the canonical job already carries was derived under it mid-run.
    claim_url=$(printf '%s' "$claims" | jq -r '.pr_url // empty')
    if [ -n "$claim_url" ] && [ "$claim_url" != "$(jq -r '.pr_url // empty' "$jf")" ]; then
        _ca_need_prdetect
        rc=0; _ca_accept_pr_url "$jf" "$claim_url" || rc=$?
        if [ "$rc" -ne 0 ]; then
            _ca_audit "$job" claim_dropped "$(jq -nc --arg r "${_CA_PR_REASON:-unverified}" '["pr_url: " + $r]')"
            claims=$(printf '%s' "$claims" | jq -c 'del(.pr_url)')
        fi
    fi
    pr_url=$(printf '%s' "$claims" | jq -r '.pr_url // empty')
    [ -n "$pr_url" ] || pr_url=$(jq -r '.pr_url // empty' "$jf")
    no_pr=$(jq -r '.no_pr // false' "$jf")
    _CA_FINAL=""
    declare -F mother_remote_contains_commit >/dev/null || [ ! -r "$MOTHER_LIB_DIR/prdetect.sh" ] \
        || source "$MOTHER_LIB_DIR/prdetect.sh"
    if [ "$no_pr" = "true" ] && [ -z "$pr_url" ]; then
        :   # commits-on-branch was enforced by the worker's supervisor; nothing on a remote to check
    elif ! _ca_verify_success "$job" "$rbranch"; then
        note="the job's final commit is not on origin's $rbranch; the worker reported success but the coordinator could not verify it"
        _ca_audit "$job" finalize_refused "$(jq -nc --arg b "$rbranch" --arg f "${_CA_FINAL:-}" '["branch=" + $b, "final=" + $f]')"
        _job_update "$job" ".needs_attention = $(jq -nc --arg note "$note" --arg since "$(_iso_now)" \
            '{reason: "unpushed_commit", note: $note, since: $since}')" || return 2
        _job_transition "$job" failed "$(jq -nc --arg pr "$pr_url" --arg b "$rbranch" --arg fin "${_CA_FINAL:-}" \
            '{reason: "unpushed_commit", pr_url: $pr, branch: $b, final_commit: $fin, source: "coordinator",
              note: "run ended with a PR but its final commit is not on the remote branch"}')"
        return 3
    fi
    now=$(_iso_now)
    fin_filter=$(jq -nr --argjson c "$claims" --arg now "$now" '
        ".state = \"succeeded\" | .failure_reason = null | .not_before = null | .backoff_count = null | .backoff_first_at = null"
        + " | (if ((.needs_attention | objects | .reason) // \"\") == \"unpushed_commit\" then .needs_attention = null else . end)"
        + " | .finished_at = " + ($now | tojson) + " | .force_start = null | .force_ignore_deps = null"
        + ($c | to_entries | map(" | ." + .key + " = " + (.value | tojson)) | join(""))')
    _job_update "$job" "$fin_filter" || return 2
    type mother_recompute_job_cost >/dev/null 2>&1 && mother_recompute_job_cost "$job"
    return 0
}

# --- CLI ---------------------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -u
    _ca_finalize=0
    if [ "${1:-}" = "--finalize" ]; then _ca_finalize=1; shift; fi
    [ $# -eq 2 ] || { echo "usage: coord_apply.sh [--finalize] <canonical-root> <job> < ops.ndjson" >&2; exit 2; }
    _ca_root="$1"; _ca_job="$2"
    [ -d "$_ca_root" ] || { echo "coord_apply: no such canonical root: $_ca_root" >&2; exit 2; }
    case "$_ca_job" in
        ''|.|..|*[!A-Za-z0-9._:-]*|*..*) echo "coord_apply: bad job id" >&2; exit 2 ;;
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
    if [ "$_ca_finalize" -eq 1 ]; then
        coord_apply_finalize "$_ca_job"
        exit $?
    fi
    coord_apply_stream "$_ca_job"
    exit $?
fi
