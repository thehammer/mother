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

# True when this process mirrors its writes into an outbox.
mother_outbox_enabled() {
    [ "${MOTHER_WORKER_MODE:-0}" = "1" ] && [ -n "${MOTHER_WORKER_OUTBOX_DIR:-}" ]
}

# Runs under the <job>.ndjson lock: allocate the next seq and append one op line.
# The op's data arrives on stdin (never argv: artifact chunks exceed the per-argument limit).
_outbox_emit_locked() {
    local ndjson="$1" seqfile="$2" type="$3" ts="$4" seq line
    seq=$(cat "$seqfile" 2>/dev/null) || seq=0
    case "$seq" in ''|*[!0-9]*) seq=0 ;; esac
    seq=$((seq + 1))
    line=$(jq -c --argjson seq "$seq" --arg t "$type" --arg ts "$ts" \
        '{seq: $seq, t: $t, ts: $ts, data: .}') || return 1
    [ -n "$line" ] || return 1
    printf '%s\n' "$line" >> "$ndjson" || return 1
    printf '%s' "$seq" > "${seqfile}.tmp.$$" && mv "${seqfile}.tmp.$$" "$seqfile"
}

# mother_outbox_emit <job> <type> [<data-json>|-]
# Appends one op. Data is the 3rd argument, or stdin when it is "-" or omitted.
# No-op (returns 0) when the outbox is disabled.
mother_outbox_emit() {
    mother_outbox_enabled || return 0
    local job="$1" type="$2" data="${3:--}" dir ndjson ts
    dir="$MOTHER_WORKER_OUTBOX_DIR"
    mkdir -p "$dir" 2>/dev/null || return 1
    ndjson="$dir/$job.ndjson"
    ts=$(_iso_now)
    if [ "$data" = "-" ]; then
        _switch_with_lock "${ndjson}.lockdir" "$ndjson" 200 \
            _outbox_emit_locked "$ndjson" "$dir/$job.seq" "$type" "$ts"
    else
        printf '%s' "$data" | _switch_with_lock "${ndjson}.lockdir" "$ndjson" 200 \
            _outbox_emit_locked "$ndjson" "$dir/$job.seq" "$type" "$ts"
    fi
}

# mother_outbox_job_set <job> <before-json> <after-json>
# Emits job.set with the top-level diff between two job documents: keys whose value changed
# (including to null, and keys that are new), in the after-document's key order; keys removed
# go in `del`. Emits nothing when the diff is empty.
mother_outbox_job_set() {
    mother_outbox_enabled || return 0
    local job="$1" before="$2" after="$3" data
    data=$(printf '%s\n%s\n' "$before" "$after" | jq -cs '
        .[0] as $b | .[1] as $a
        | {set: ($a | with_entries(.key as $k | .value as $v | select(($b | has($k) | not) or ($b[$k] != $v)))),
           del: [$b | keys_unsorted[] | select(. as $k | $a | has($k) | not)]}
        | if (.set | length) == 0 and (.del | length) == 0 then empty else . end') || return 1
    [ -n "$data" ] || return 0
    mother_outbox_emit "$job" job.set "$data"
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
    ( cd "$root" && find "$rel" -type f ! -name '*.tmp.*' ! -name '.*' | LC_ALL=C sort ) | while IFS= read -r f; do
        mother_outbox_artifact "$job" "$f"
    done
}
