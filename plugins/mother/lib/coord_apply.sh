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
# Prints the last applied seq on stdout. Exit: 0 all applied, 1 stopped (gap, transient failure, lock,
# unknown job: ops remain), 3 done but some op(s) were quarantined, 4 a time/op budget ended the call.
# Can also be sourced (functions only).

# --- ownership table: copies of broker/workerproto/ownership.go --------------------------------

# WorkerKeys: job keys the worker side may set or delete.
_CA_WORKER_KEYS='activity session_id worker_pid paused_reason paused_at question final_result_at started_at continuation_count resume_not_yet_acted_on gates review_wave limiter_hold live_cost_usd live_tokens current_run cost_cap_breached_at token_alert_at rwx_sandbox resume_session_id resume_kind limiter_resume_prompt attention decision'
# CoordinatorDerivedKeys: completion evidence; refused from a worker.
_CA_DERIVED_KEYS='pr_url actual_branch finished_at exit_code failure_reason'
# SyncDownKeys: flow coordinator to worker; refused from a worker (pending_answer may be nulled).
_CA_SYNCDOWN_KEYS='cancel_requested pause_requested pending_answer max_cost_usd force_start'
# StateValues: what a worker may set `state` to ("succeeded" is the coordinator's).
_CA_STATE_VALUES='running awaiting failed cancelled'
# keyKinds: key:kind for every WorkerKey.
_CA_KEY_KINDS='activity:token session_id:id worker_pid:uint paused_reason:token paused_at:ts question:text final_result_at:ts started_at:ts continuation_count:uint resume_not_yet_acted_on:bool gates:object review_wave:object limiter_hold:object live_cost_usd:num live_tokens:uint current_run:object cost_cap_breached_at:ts token_alert_at:ts rwx_sandbox:object resume_session_id:id resume_kind:token limiter_resume_prompt:text attention:array decision:object'
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

_ca_bytes() { printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' '; }

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

# Runs under the job-file lock: judge the op against the current document, then apply what is allowed.
# $1 job file, $2 op-data file (the op's `data`), $3 result file (gets one JSON object:
# {status: applied|refused|structural, refused: [{key,code}], reason, terminal}).
_ca_job_set_locked() {
    local jf="$1" opf="$2" resf="$3" verdict merged skip states
    states='["running","awaiting","failed","cancelled"]'
    verdict=$(jq -c -n --argjson kinds "$(_ca_kinds_json)" --argjson states "$states" \
        --argjson maxtext "$_CA_MAX_TEXT" --argjson maxstruct "$_CA_MAX_STRUCT" --argjson maxkeys "$_CA_MAX_KEYS" \
        "$_CA_VERDICT_JQ" "$opf" "$jf") || return 2
    if [ "$(printf '%s' "$verdict" | jq -r '.structural // empty')" != "" ]; then
        printf '%s' "$verdict" | jq -c '{status: "structural", refused: [], reason: .structural, terminal: ""}' > "$resf"
        return 0
    fi
    if [ "$(printf '%s' "$verdict" | jq -r '.state_refused')" = "true" ]; then
        printf '%s' "$verdict" | jq -c '{status: "refused", refused: .refused, reason: "state change refused; the whole op is refused", terminal: ""}' > "$resf"
        return 0
    fi
    skip=$(printf '%s' "$verdict" | jq -c '[.refused[].key]')
    merged=$(jq -n --argjson skip "$skip" 'input as $op | input
        | reduce (($op.set // {}) | to_entries[] | select(.key as $k | $skip | index($k) | not)) as $e (.;
            if $e.key == "pipeline"
            then (.pipeline //= {}) | .pipeline.reviewer_findings = ($e.value.reviewer_findings // .pipeline.reviewer_findings // {})
            else .[$e.key] = $e.value end)
        | delpaths([($op.del // [])[] | select(. as $k | $skip | index($k) | not) | [.]])' "$opf" "$jf") || return 2
    _atomic_write "$jf" "$merged" || return 2
    jq -n -c --argjson v "$verdict" 'input as $op
        | {status: "applied", refused: $v.refused, reason: "",
           terminal: ((($op.set // {}).state // "") | select(. == "failed" or . == "cancelled") // "")}' "$opf" > "$resf"
}

_ca_apply_job_set() {
    local job="$1" line="$2" jf opf resf res status rc=0 terminal
    jf=$(_job_path "$job")
    [ -f "$jf" ] || { _ca_log "no such job on the canonical root: $job"; return 3; }
    opf=$(mktemp "${TMPDIR:-/tmp}/coord-apply-op.XXXXXX") || return 2
    resf=$(mktemp "${TMPDIR:-/tmp}/coord-apply-res.XXXXXX") || { rm -f "$opf"; return 2; }
    printf '%s' "$line" | jq -c '.data' > "$opf" || rc=1
    if [ "$rc" -eq 0 ]; then _with_lock "$jf" _ca_job_set_locked "$jf" "$opf" "$resf" || rc=2; fi
    res=$(cat "$resf" 2>/dev/null)
    rm -f "$opf" "$resf"
    [ "$rc" -eq 0 ] || return "$rc"
    status=$(printf '%s' "$res" | jq -r '.status // empty' 2>/dev/null)
    case "$status" in
        structural)
            _ca_log "job.set: $(printf '%s' "$res" | jq -r '.reason')"
            return 1 ;;
        refused|applied)
            local own inv
            own=$(printf '%s' "$res" | jq -c '[.refused[] | select(.code == "ownership") | .key]')
            inv=$(printf '%s' "$res" | jq -c '[.refused[] | select(.code == "invalid") | .key]')
            [ "$own" = "[]" ] || _ca_audit "$job" ownership "$own"
            [ "$inv" = "[]" ] || _ca_audit "$job" invalid "$inv"
            if [ "$status" = "refused" ]; then
                _ca_audit "$job" op_refused "$(printf '%s' "$line" | jq -c '[(.data.set // {} | keys[]), (.data.del // [])[]]')"
            else
                terminal=$(printf '%s' "$res" | jq -r '.terminal // empty')
                if [ -n "$terminal" ] && type mother_recompute_job_cost >/dev/null 2>&1; then
                    mother_recompute_job_cost "$job"
                fi
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
    printf '%s' "$line" | jq -e "$_CA_LINE_JQ" >/dev/null 2>&1 \
        || { _ca_log "event.append: line must be a single non-empty line without control characters"; return 1; }
    ev=$(printf '%s' "$line" | jq -r '.data.line')
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
    local job="$1" af applied=0 line seq rc=0 poison=0 op_rc q_rc retry_file rn rseq started max_s max_ops ops=0 torn=0
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
        seq=$(printf '%s' "$line" | jq -r 'if type == "object" and (.seq | type) == "number" and .seq >= 1 and .seq == (.seq | floor) and (.t | type) == "string" then (.seq | tostring) else empty end' 2>/dev/null)
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
        local inf inf_t inf_state
        inf=$(_ca_inflight_file "$job"); _CA_RECOVERING=""; _CA_CUR_SEQ="$seq"
        inf_t=$(printf '%s' "$line" | jq -r '.t // empty')
        case "$inf_t" in
            event.append|record.append)
                inf_state="$seq $(_ca_line_sha "$line")"
                if [ "$(cat "$inf" 2>/dev/null)" = "$inf_state" ]; then _CA_RECOVERING=1
                else printf '%s\n' "$inf_state" > "$inf" 2>/dev/null || { _ca_log "cannot write the inflight marker for seq $seq"; rc=1; break; }
                fi ;;
        esac
        _ca_apply_op "$job" "$line" </dev/null; op_rc=$?
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
    _with_lock "$af" _ca_stream_locked "$job"
}

# --- CLI ---------------------------------------------------------------------------------------

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -u
    [ $# -eq 2 ] || { echo "usage: coord_apply.sh <canonical-root> <job> < ops.ndjson" >&2; exit 2; }
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
    coord_apply_stream "$_ca_job"
    exit $?
fi
