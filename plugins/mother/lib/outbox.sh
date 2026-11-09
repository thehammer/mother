# outbox.sh — worker-mode mirror of every state write (cluster Phase 1, slice P1-2).
#
# In worker mode (MOTHER_WORKER_MODE=1 and MOTHER_WORKER_OUTBOX_DIR set) mother-run-job and
# everything it calls runs against a worker root: every write still lands in that root (the
# supervisor keeps reading its own job file), and is additionally appended as a protocol op to
# $MOTHER_WORKER_OUTBOX_DIR/<job>.ndjson:
#
#     {"seq":N,"t":"<op type>","ts":"<iso>","data":{...}}
#
# Op types and their data are docs/worker-protocol.md section 4 (job.set, event.append,
# record.append, artifact.put). Lease and epoch are added by the worker daemon when it ships
# the op (P1-4), never here. lib/coord_apply.sh replays an outbox onto the canonical tree.
#
# With worker mode off (the default) every function here is a no-op, so behaviour is unchanged.
#
# Sourced by lib/state.sh (guarded, like the other optional libs). Must not set shell options.

# ---------- worker-mode predicate ----------
#
# ONE predicate answers "is this process in worker mode?": MOTHER_WORKER_MODE=1. Everything that
# branches on worker mode (the outbox mirror, the cost recompute, the live-spend baseline, the worker
# marker) calls mother_worker_mode_active, and mother_worker_mode_validate runs once at startup
# (lib/state.sh, bin/mother-run-job) so a half-configured or mis-aimed worker never gets to write.

mother_worker_mode_active() { [ "${MOTHER_WORKER_MODE:-0}" = "1" ]; }

# Physical path of an existing directory (symlinks resolved), else the input.
_outbox_phys() { (cd -P "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }

# mother_worker_mode_validate — 0 when worker mode is off, or on and safely configured; otherwise 1
# with a message on stderr. Worker mode REQUIRES:
#   * an explicit root (MOTHER_ROOT, or MOTHER_LIVE_ROOT as the in-agent view of the same mirror);
#     when both are set they must agree;
#   * that root is not $HOME/.mother and does not carry the canonical .mother-live marker;
#   * MOTHER_WORKER_OUTBOX_DIR set, creatable and writable.
# Pure checks plus mkdir of the outbox dir: nothing is written into the root itself.
mother_worker_mode_validate() {
    mother_worker_mode_active || return 0
    local root="${MOTHER_ROOT:-}" live="${MOTHER_LIVE_ROOT:-}" real home_root outbox="${MOTHER_WORKER_OUTBOX_DIR:-}"
    if [ -z "$root" ] && [ -z "$live" ]; then
        echo "mother: worker mode (MOTHER_WORKER_MODE=1) requires an explicit MOTHER_ROOT; refusing to default to the live tree" >&2
        return 1
    fi
    if [ -n "$root" ] && [ -n "$live" ] && [ "$(_outbox_phys "$root")" != "$(_outbox_phys "$live")" ]; then
        echo "mother: worker mode: MOTHER_ROOT ($root) and MOTHER_LIVE_ROOT ($live) disagree; refusing" >&2
        return 1
    fi
    [ -n "$root" ] || root="$live"
    real=$(_outbox_phys "$root")
    home_root=$(_outbox_phys "${HOME:-/nonexistent}/.mother")
    if [ "$real" = "$home_root" ] || [ -e "$real/.mother-live" ]; then
        echo "mother: worker mode: $root is the live Mother tree; a worker root must be its own directory" >&2
        return 1
    fi
    if [ -z "$outbox" ]; then
        echo "mother: worker mode requires MOTHER_WORKER_OUTBOX_DIR" >&2
        return 1
    fi
    if ! mkdir -p "$outbox" 2>/dev/null || [ ! -d "$outbox" ] || [ ! -w "$outbox" ]; then
        echo "mother: worker mode: outbox dir $outbox is not a writable directory" >&2
        return 1
    fi
    return 0
}

# True when this process mirrors its writes into an outbox (worker mode, validated at startup).
mother_outbox_enabled() {
    mother_worker_mode_active && [ -n "${MOTHER_WORKER_OUTBOX_DIR:-}" ]
}

# ---------- degraded flag ----------

# $RUNNER/<job>.outbox-degraded = {at, op, why}: an op could not be shipped. Persisted in the root (not
# the outbox dir, which may be the thing that is broken); the supervisor holds the job on it.
_outbox_degraded_file() { printf '%s/%s.outbox-degraded' "${RUNNER_DIR:-${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}/runner}" "$1"; }

mother_outbox_degraded() { [ -f "$(_outbox_degraded_file "$1")" ]; }

# _outbox_fail <job> <op-type> <why> — loud: stderr, persisted flag; always returns 1.
_outbox_fail() {
    local job="$1" type="$2" why="$3" f
    echo "mother: OUTBOX DEGRADED for $job: cannot ship $type op: $why" >&2
    f=$(_outbox_degraded_file "$job")
    if [ ! -f "$f" ]; then
        mkdir -p "$(dirname "$f")" 2>/dev/null
        printf '{"at":"%s","op":"%s","why":"%s"}\n' "$(_iso_now 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "$type" "$(printf '%s' "$why" | tr -d '"\\' | tr '\n' ' ' | cut -c1-200)" > "$f" 2>/dev/null
    fi
    return 1
}

# Size caps (bytes): one op line, and the whole outbox file. An op over the cap is refused here rather
# than shipped, because the replay side refuses it too.
_outbox_max_op() { printf '%s' "${MOTHER_OUTBOX_MAX_OP_BYTES:-1048576}"; }
_outbox_max_file() { printf '%s' "${MOTHER_OUTBOX_MAX_BYTES:-536870912}"; }

# Runs under the <job>.ndjson lock: allocate the next seq FROM THE FILE (last complete, parseable
# line + 1: the file is the one source of truth, so a failed side write can never reuse a seq) and
# append one op line. A file whose last byte is not a newline (a torn earlier append) is terminated
# first so the new op never shares a line with the wreckage.
# The op's data arrives on stdin (never argv: artifact chunks exceed the per-argument limit), or, for
# the callers that built it with `jq -c` themselves (job.set, event.append, record.append), in
# $_OUTBOX_DATA with $_OUTBOX_TRUSTED=1: one compact line of valid JSON, so the op line is assembled by
# string concatenation instead of one more jq. This runs on every state write of a worker-mode job, so
# it spends as few processes as it can (worker-mode dispatch latency, cluster P1-5).
_outbox_emit_locked() {
    local ndjson="$1" seqfile="$2" type="$3" ts="$4" seq=0 line size last repaired=0
    if [ -s "$ndjson" ]; then
        # $(...) strips the newline: anything left means the last byte was not one.
        if [ -n "$(tail -c 1 "$ndjson")" ]; then
            printf '\n' >> "$ndjson" || { echo "cannot repair torn outbox tail" >&2; return 1; }
            repaired=1
        fi
        # Our own lines start {"seq":N, — trust the last line unless a torn tail was just terminated.
        if [ "$repaired" -eq 0 ]; then
            last=$(tail -n 1 "$ndjson")
            case "$last" in
                '{"seq":'[0-9]*,*) seq="${last#\{\"seq\":}"; seq="${seq%%,*}" ;;
            esac
            case "$seq" in ''|*[!0-9]*) seq="" ;; esac
        else
            seq=""
        fi
        if [ -z "$seq" ]; then
            seq=$(tail -n 50 "$ndjson" | jq -Rr 'fromjson? | select(type == "object") | .seq | select(type == "number")' 2>/dev/null | tail -n 1)
            if [ -z "$seq" ]; then
                seq=$(jq -Rr 'fromjson? | select(type == "object") | .seq | select(type == "number")' "$ndjson" 2>/dev/null | tail -n 1)
            fi
        fi
        case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    fi
    seq=$((seq + 1))
    if [ "${_OUTBOX_TRUSTED:-0}" = "1" ]; then
        line="{\"seq\":$seq,\"t\":\"$type\",\"ts\":\"$ts\",\"data\":$_OUTBOX_DATA}"
    else
        line=$(jq -c --argjson seq "$seq" --arg t "$type" --arg ts "$ts" \
            '{seq: $seq, t: $t, ts: $ts, data: .}') || { echo "jq could not build the op" >&2; return 1; }
    fi
    [ -n "$line" ] || { echo "empty op" >&2; return 1; }
    if [ "$(_outbox_bytes "$line")" -gt "$(_outbox_max_op)" ]; then
        echo "op larger than MOTHER_OUTBOX_MAX_OP_BYTES" >&2; return 1
    fi
    size=$(wc -c < "$ndjson" 2>/dev/null | tr -d ' ')
    if [ $(( ${size:-0} + ${#line} + 1 )) -gt "$(_outbox_max_file)" ]; then
        echo "outbox larger than MOTHER_OUTBOX_MAX_BYTES" >&2; return 1
    fi
    printf '%s\n' "$line" >> "$ndjson" || { echo "append to the outbox failed" >&2; return 1; }
    # Informational only (last seq written); the ndjson is authoritative.
    { printf '%s' "$seq" > "${seqfile}.tmp.$$" && mv "${seqfile}.tmp.$$" "$seqfile"; } 2>/dev/null || true
    return 0
}

# Byte length of a string with no process: the C locale makes ${#} count bytes.
_outbox_bytes() { local LC_ALL=C; printf '%s' "${#1}"; }

# mother_outbox_emit <job> <type> [<data-json>|-]
# Appends one op. Data is the 3rd argument, or stdin when it is "-" or omitted.
# No-op (returns 0) when the outbox is disabled. Any failure is loud (stderr + the degraded flag) and
# returns 1; it never returns success for an op that was not shipped.
mother_outbox_emit() {
    mother_outbox_enabled || return 0
    local job="$1" type="$2" data="${3:--}" dir ndjson ts err rc
    dir="$MOTHER_WORKER_OUTBOX_DIR"
    # Once degraded, always degraded until an operator clears the flag: fail fast, don't retry a broken dir.
    if mother_outbox_degraded "$job"; then
        echo "mother: outbox for $job is degraded; not shipping $type op" >&2
        return 1
    fi
    { [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null; } && [ -d "$dir" ] && [ -w "$dir" ] \
        || { _outbox_fail "$job" "$type" "outbox dir $dir is not a writable directory"; return 1; }
    ndjson="$dir/$job.ndjson"
    ts=$(_iso_now)
    # The locked step's stderr is captured by the substitution (no temp file to make and remove).
    if [ "$data" = "-" ]; then
        err=$(_switch_with_lock "${ndjson}.lockdir" "$ndjson" 200 \
            _outbox_emit_locked "$ndjson" "$dir/$job.seq" "$type" "$ts" 2>&1)
    elif [ "${_OUTBOX_TRUSTED:-0}" = "1" ]; then
        err=$(_OUTBOX_DATA="$data" _switch_with_lock "${ndjson}.lockdir" "$ndjson" 200 \
            _outbox_emit_locked "$ndjson" "$dir/$job.seq" "$type" "$ts" 2>&1)
    else
        err=$(printf '%s' "$data" | _switch_with_lock "${ndjson}.lockdir" "$ndjson" 200 \
            _outbox_emit_locked "$ndjson" "$dir/$job.seq" "$type" "$ts" 2>&1)
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
        _outbox_fail "$job" "$type" "$(printf '%s' "$err" | head -c 200 | tr '\n' ' ')"
        return 1
    fi
    return 0
}

# mother_outbox_event <job> <event-line> — event.append for one events-file line. Loud on failure.
mother_outbox_event() {
    mother_outbox_enabled || return 0
    local job="$1" data
    data=$(jq -nc --arg l "$2" '{line: $l}') || { _outbox_fail "$job" event.append "jq could not build the op"; return 1; }
    _OUTBOX_TRUSTED=1 mother_outbox_emit "$job" event.append "$data"
}

# mother_outbox_record <job> <stream> <row-line> — record.append for one usage-stream row.
mother_outbox_record() {
    mother_outbox_enabled || return 0
    local job="$1" data
    data=$(jq -nc --arg s "$2" --arg l "$3" '{stream: $s, line: $l}') || { _outbox_fail "$job" record.append "jq could not build the op"; return 1; }
    _OUTBOX_TRUSTED=1 mother_outbox_emit "$job" record.append "$data"
}

# mother_outbox_job_set <job> <before-json> <after-json>
# Emits job.set with the top-level diff between two job documents: keys whose value changed
# (including to null, and keys that are new), in the after-document's key order; keys removed
# go in `del`. Emits nothing when the diff is empty.
mother_outbox_job_set() {
    mother_outbox_enabled || return 0
    local job="$1" before="$2" after="$3" data
    [ -n "$before" ] || { _outbox_fail "$job" job.set "no previous document to diff against"; return 1; }
    data=$(printf '%s\n%s\n' "$before" "$after" | jq -cs '
        .[0] as $b | .[1] as $a
        | {set: ($a | with_entries(.key as $k | .value as $v | select(($b | has($k) | not) or ($b[$k] != $v)))),
           del: [$b | keys_unsorted[] | select(. as $k | $a | has($k) | not)]}
        | if (.set | length) == 0 and (.del | length) == 0 then empty else . end') \
        || { _outbox_fail "$job" job.set "jq could not diff the job documents"; return 1; }
    [ -n "$data" ] || return 0
    _OUTBOX_TRUSTED=1 mother_outbox_emit "$job" job.set "$data"
}

# mother_outbox_artifact <job> <relpath>
# Emits artifact.put chunks (<= 256 KiB raw each, base64, offset-addressed, `final` and the
# whole-file sha256 on the last one) for the file at $MOTHER_ROOT/<relpath>. Call it after the
# artifact is finalised. <relpath> is relative to the root, e.g. crew/<job>/wave/c1/tests.json.
mother_outbox_artifact() {
    mother_outbox_enabled || return 0
    local job="$1" rel="$2" file size offset=0 chunk=262144 sha b64 final idx=0
    file="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}/$rel"
    [ -f "$file" ] || return 0
    size=$(wc -c < "$file" | tr -d ' ')
    sha=$(shasum -a 256 "$file" 2>/dev/null | cut -d' ' -f1)
    while :; do
        if [ $((offset + chunk)) -ge "$size" ]; then final=true; else final=false; fi
        b64=$(dd if="$file" bs="$chunk" skip="$idx" count=1 2>/dev/null | base64 | tr -d '\n')
        printf '%s' "$b64" | jq -Rsc --arg path "$rel" --argjson offset "$offset" \
            --argjson final "$final" --arg sha "$sha" \
            '{path: $path, offset: $offset, b64: ., final: $final}
             + (if $final then {sha256: $sha} else {} end)' \
            | mother_outbox_emit "$job" artifact.put - || return 1
        [ "$final" = true ] && break
        offset=$((offset + chunk)); idx=$((idx + 1))
    done
}

# mother_outbox_artifact_tree <job> <dir-relpath>
# Emits every regular file under $MOTHER_ROOT/<dir-relpath> (sorted), for a writer that
# finalises a whole directory (gate run logs and excerpts, a wave cycle).
mother_outbox_artifact_tree() {
    mother_outbox_enabled || return 0
    local job="$1" rel="${2%/}" root f
    root="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
    [ -d "$root/$rel" ] || return 0
    local rc=0
    while IFS= read -r f; do
        mother_outbox_artifact "$job" "$f" || rc=1
    done < <( cd "$root" && find "$rel" -type f ! -name '*.tmp.*' ! -name '.*' | LC_ALL=C sort )
    return "$rc"
}
