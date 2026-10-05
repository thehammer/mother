#!/usr/bin/env bash
# preview.sh — per-job preview stacks (`mother preview`) with guaranteed teardown.
#
# A preview stack is an RWX app run of Carefeed's preview-stack (admin-portal,
# family-portal, payments, referral-monitor on public URLs with synthetic data).
# A worker that must check a behavioural acceptance criterion launches one for
# its own pushed branch with `mother preview up`, checks it, and Mother stops it
# no matter how the worker ends:
#   - `mother preview down`                     (reason: explicit)
#   - mother-run-job after every worker exit    (reason: worker_exit)
#   - mother-run-job before a fresh attempt     (reason: attempt_start)
#   - mother-runner's orphan sweep              (reason: orphan)
#
# Everything here is best-effort where it touches the job's outcome: stops are
# watchdog-bounded, emit events only, always return 0 and never change a job's
# state or failure_reason (same contract as lib/rwx.sh).
#
# The only functions that know HOW a stack is launched or stopped are the two
# backend-seam functions (_preview_backend_up / _preview_backend_stop). Only the
# `cli` backend exists. Everything else — commands, hooks, runner — goes through
# them, and the job record stores `.preview.backend`.
#
# Sourced by bin/mother, bin/mother-run-job and bin/mother-runner (so it must
# not depend on any one of their private helpers) under `set -u`, bash 3.2.
# Job/event writes use the shared state primitives (_with_lock, _append_line,
# _atomic_write), which have the same signature in all three.

# ---------------------------------------------------------------------------
# Configuration / paths

# config.env lookups (mother_config_get); lib/config.sh is only sourced by
# bin/mother and bin/mother-runner, so pull it in for mother-run-job too.
type mother_config_get >/dev/null 2>&1 \
    || { [ -r "${MOTHER_LIB_DIR:-}/config.sh" ] && source "$MOTHER_LIB_DIR/config.sh"; }

# _preview_cfg <KEY> <default> — env var, else ~/.mother/config.env, else default.
_preview_cfg() {
    local key="$1" default="${2:-}" val=""
    val="${!key:-}"
    if [ -z "$val" ] && type mother_config_get >/dev/null 2>&1; then
        val=$(mother_config_get "$key" 2>/dev/null) || val=""
    fi
    printf '%s' "${val:-$default}"
}

_preview_root()       { printf '%s' "${MOTHER_ROOT:-$HOME/.mother}"; }
_preview_jobs_dir()   { printf '%s' "${JOBS_DIR:-$(_preview_root)/jobs}"; }
_preview_events_dir() { printf '%s' "${EVENTS_DIR:-$(_preview_root)/events}"; }
_preview_runner_dir() { printf '%s' "${RUNNER_DIR:-$(_preview_root)/runner}"; }
_preview_job_file()   { printf '%s/%s.json' "$(_preview_jobs_dir)" "$1"; }
_preview_secrets_file() { printf '%s/%s.preview-secrets.json' "$(_preview_runner_dir)" "$1"; }
_preview_now()        { date -u +%Y-%m-%dT%H:%M:%SZ; }

# _preview_stack_bin — the preview-stack CLI to run; non-zero when not found.
_preview_stack_bin() {
    local bin; bin=$(_preview_cfg MOTHER_PREVIEW_STACK_BIN "")
    if [ -z "$bin" ]; then
        if command -v preview-stack >/dev/null 2>&1; then
            bin=$(command -v preview-stack)
        else
            bin="$HOME/Code/preview-stack/bin/preview-stack"
        fi
    fi
    [ -x "$bin" ] || return 1
    printf '%s' "$bin"
}

# _preview_event <job_id> <kind> <detail-json> — append one event line.
_preview_event() {
    local jid="$1" kind="$2" detail="${3:-}" line path
    [ -n "$detail" ] || detail='{}'
    line=$(jq -nc --arg ts "$(_preview_now)" --arg kind "$kind" --argjson detail "$detail" \
        '{ts: $ts, kind: $kind, detail: $detail}' 2>/dev/null) || return 1
    path="$(_preview_events_dir)/$jid.jsonl"
    _with_lock "$path" _append_line "$path" "$line"
}

# _preview_job_update <job_id> <jq-filter> [jq args...] — atomic job-file edit.
_preview_job_update() {
    local jid="$1" filter="$2" jf merged
    shift 2
    jf=$(_preview_job_file "$jid")
    [ -f "$jf" ] || return 1
    merged=$(jq "$@" "$filter" "$jf") || return 1
    _atomic_write "$jf" "$merged"
}

# _preview_strip_tail <file...> — combined output, ANSI stripped, last 300 chars.
_preview_strip_tail() {
    local esc; esc=$(printf '\033')
    cat "$@" 2>/dev/null | tr -d '\r' | sed "s/${esc}\\[[0-9;]*[A-Za-z]//g" | tail -c 300
}

# _preview_kill_tree <pid> — SIGKILL a background subshell and its descendants.
_preview_kill_tree() {
    local pid="$1" kid
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
        _preview_kill_tree "$kid"
    done
    kill -9 "$pid" 2>/dev/null
    return 0
}

# _preview_bounded <timeout_s> <cwd> <outfile> <errfile> <cmd> [args...]
# Runs cmd in cwd under a watchdog (output to files, never a pipe, so a stuck
# grandchild can't hold the caller open). Returns cmd's exit status, 124 on
# timeout, 126 if cwd is unusable.
_preview_bounded() {
    local timeout="$1" cwd="$2" out="$3" err="$4"; shift 4
    local flag="$out.timeout" rcf="$out.rc" rc
    rm -f "$flag" "$rcf"
    (
        cd "$cwd" 2>/dev/null || exit 126
        "$@" >"$out" 2>"$err" </dev/null
        echo $? >"$rcf"
    ) >/dev/null 2>&1 </dev/null &
    local pid=$!
    (
        sleep "$timeout"
        : >"$flag"
        _preview_kill_tree "$pid"
    ) >/dev/null 2>&1 </dev/null &
    local wd=$!
    wait "$pid" 2>/dev/null
    _preview_kill_tree "$wd"
    wait "$wd" 2>/dev/null
    if [ -f "$flag" ]; then
        rc=124
    elif [ -f "$rcf" ]; then
        rc=$(cat "$rcf" 2>/dev/null); rc="${rc:-1}"
    else
        rc=126
    fi
    rm -f "$flag" "$rcf"
    return "$rc"
}

# _preview_tmp — a private temp path under the runner dir.
_preview_tmp() {
    local dir; dir=$(_preview_runner_dir)
    mkdir -p "$dir" 2>/dev/null
    # Fall back to an unpredictable name in TMPDIR, never a fixed /tmp path.
    (umask 077; mktemp "$dir/preview-out.tmp.XXXXXX" 2>/dev/null \
        || mktemp "${TMPDIR:-/tmp}/preview-out.tmp.XXXXXX")
}

# ---------------------------------------------------------------------------
# Backend seam
#
# These two functions are the ONLY place that knows how a stack is launched or
# stopped. To add the deferred operations backend (see P4a-ops.md), add an
# `operations)` arm to each `case` below, accept the name in
# mother_preview_up's backend check, and have it print the same JSON shapes;
# the commands, the lifecycle hooks and the runner need no change.
#
# Context: _preview_backend_up reads the globals _pv_job_id and _pv_work_dir
# (set by _preview_load_job).

# _preview_backend_up <backend> <stack_id> <components> <refs>
#   components: comma list (ap,fp). refs: space-separated "<c>=<ref>" tokens.
# Prints the normalised record JSON on stdout (no owner secrets: they are
# written to the 0600 secrets file here). Exit: 0 ok, 2 usage, 3 refused,
# 1 anything else; diagnostics on stderr.
_preview_backend_up() {
    local backend="$1" stack_id="$2" components="$3" refs="$4"
    case "$backend" in
        cli)
            local bin tmp stack_ref rc c ref
            bin=$(_preview_stack_bin) || {
                echo "mother preview: preview-stack CLI not found (set MOTHER_PREVIEW_STACK_BIN)" >&2
                return 1
            }
            stack_ref=$(_preview_cfg MOTHER_PREVIEW_STACK_REF main)
            local -a args
            args=(up --via dispatch --stack "$stack_ref" --purpose job --id "$stack_id" --components "$components")
            for c in $(printf '%s' "$components" | tr ',' ' '); do
                ref=$(_preview_ref_of "$refs" "$c")
                args+=("--$c" "$ref")
            done

            tmp=$(_preview_tmp)
            rc=0
            _preview_bounded 180 "${_pv_work_dir:-.}" "$tmp" "$tmp.err" "$bin" "${args[@]}" || rc=$?
            if [ "$rc" -ne 0 ]; then
                if [ "$rc" = "124" ]; then
                    echo "mother preview: preview-stack up timed out after 180s" >&2
                else
                    tail -c 600 "$tmp.err" >&2 2>/dev/null
                fi
                rm -f "$tmp" "$tmp.err"
                case "$rc" in 2|3) return "$rc" ;; *) return 1 ;; esac
            fi
            if ! jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
                echo "mother preview: preview-stack up printed no JSON object" >&2
                rm -f "$tmp" "$tmp.err"
                return 1
            fi
            # Owner secrets: straight from the CLI's JSON file to a 0600 file
            # (never argv), then dropped before anything else sees the JSON.
            if jq -e '.owner_secrets' "$tmp" >/dev/null 2>&1; then
                local sf; sf=$(_preview_secrets_file "${_pv_job_id:-unknown}")
                mkdir -p "$(dirname "$sf")" 2>/dev/null
                rm -f "$sf"
                ( umask 077; jq -c '.owner_secrets' "$tmp" >"$sf.tmp.$$" ) && mv "$sf.tmp.$$" "$sf"
            fi
            jq -c --arg backend "$backend" '
                {stack_id: .stack_id, backend: $backend, combo: .combo,
                 refs: ((.components // {}) | with_entries(.value |= {ref: .ref, sha: .sha})),
                 urls: ({stack: .url}
                        + (if .components.ap.url then {ap: .components.ap.url} else {} end)
                        + (if .components.fp.url then {fp: .components.fp.url} else {} end)),
                 run_id: .run_id, run_url: .run_url, launched_at: .launched_at,
                 logins: (.logins // null)}' "$tmp" 2>/dev/null
            rc=$?
            rm -f "$tmp" "$tmp.err"
            return "$rc"
            ;;
        *)
            echo "preview backend '$backend' is not available" >&2
            return 3
            ;;
    esac
}

# _preview_ref_of <refs> <component> — look up "<c>=<ref>" in a token list.
_preview_ref_of() {
    local tok
    for tok in $1; do
        case "$tok" in "$2="*) printf '%s' "${tok#*=}"; return 0 ;; esac
    done
    return 1
}

# _preview_backend_stop <backend> <stack_id>
# Prints {outcome: ok|error|timeout, backend, exit_code, duration_s,
# output_tail}. Always returns 0. Needs no worktree.
_preview_backend_stop() {
    local backend="$1" stack_id="$2"
    case "$backend" in
        cli)
            local bin tmp rc outcome started=$SECONDS
            bin=$(_preview_stack_bin) || {
                jq -nc --arg b "$backend" \
                    '{outcome: "error", backend: $b, exit_code: 127, duration_s: 0, output_tail: "preview-stack CLI not found"}'
                return 0
            }
            tmp=$(_preview_tmp)
            rc=0
            _preview_bounded "$(_preview_cfg MOTHER_PREVIEW_STOP_TIMEOUT 120)" "." "$tmp" "$tmp.err" \
                "$bin" down "$stack_id" || rc=$?
            case "$rc" in
                0|2) outcome=ok ;;    # 2: an id `down` doesn't know — nothing was launched
                124) outcome=timeout ;;
                *)   outcome=error ;;
            esac
            jq -nc --arg b "$backend" --arg o "$outcome" --argjson rc "$rc" \
                --argjson d "$((SECONDS - started))" --arg t "$(_preview_strip_tail "$tmp" "$tmp.err")" \
                '{outcome: $o, backend: $b, exit_code: $rc, duration_s: $d, output_tail: $t}'
            rm -f "$tmp" "$tmp.err"
            ;;
        *)
            jq -nc --arg b "$backend" \
                '{outcome: "error", backend: $b, exit_code: 3, duration_s: 0,
                  output_tail: ("preview backend " + $b + " is not available")}'
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# Stop (shared by `mother preview down`, the worker-exit/attempt-start hooks and
# the runner's orphan sweep)

# _preview_stop_run <job_id> <reason> — stops the job's stack, records it, and
# prints the preview_stop event detail (or {"outcome":"noop"}). Returns 0.
_preview_stop_run() {
    local jid="${1:-}" reason="${2:-explicit}" jf rec status backend stack_id result outcome new_status
    jf=$(_preview_job_file "$jid")
    [ -n "$jid" ] && [ -f "$jf" ] || { echo '{"outcome":"noop"}'; return 0; }
    rec=$(jq -c '.preview // empty' "$jf" 2>/dev/null) || rec=""
    status=$(printf '%s' "$rec" | jq -r '.status // empty' 2>/dev/null)
    if [ -z "$rec" ] || [ "$status" = "stopped" ]; then
        echo '{"outcome":"noop"}'
        return 0
    fi
    backend=$(printf '%s' "$rec" | jq -r '.backend // "cli"')
    stack_id=$(printf '%s' "$rec" | jq -r '.stack_id // empty')

    result=$(_preview_backend_stop "$backend" "$stack_id" 2>/dev/null) || result=""
    printf '%s' "$result" | jq -e 'type == "object"' >/dev/null 2>&1 \
        || result=$(jq -nc --arg b "$backend" \
            '{outcome: "error", backend: $b, exit_code: 1, duration_s: 0, output_tail: "no result from backend"}')
    result=$(printf '%s' "$result" | jq -c --arg r "$reason" '. + {reason: $r}')
    outcome=$(printf '%s' "$result" | jq -r '.outcome // "error"')
    new_status=stop_failed
    [ "$outcome" = "ok" ] && new_status=stopped

    _preview_job_update "$jid" '.preview.status = $s | .preview.stopped_at = $t' \
        --arg s "$new_status" --arg t "$(_preview_now)" 2>/dev/null || true
    rm -f "$(_preview_secrets_file "$jid")" 2>/dev/null
    _preview_event "$jid" preview_stop "$result" 2>/dev/null || true
    printf '%s\n' "$result"
    return 0
}

# mother_preview_stop <job_id> <reason> — best-effort, idempotent, returns 0.
# Reasons: explicit | worker_exit | attempt_start | orphan.
mother_preview_stop() {
    _preview_stop_run "${1:-}" "${2:-explicit}" >/dev/null 2>&1 || true
    return 0
}

# ---------------------------------------------------------------------------
# Command plumbing

_preview_die() {   # _preview_die <exit> <message>
    echo "mother preview: $2" >&2
    return "$1"
}

# _preview_component_for_repo <repo> — the repo's own component, if any.
_preview_component_for_repo() {
    case "$1" in
        admin-portal)     echo ap ;;
        family-portal)    echo fp ;;
        payments)         echo payments ;;
        referral-monitor) echo rm ;;
    esac
}

# _preview_default_components <repo> — comma list, empty if the repo has none.
_preview_default_components() {
    case "$1" in
        admin-portal)     echo ap ;;
        family-portal)    echo ap,fp ;;
        payments)         echo ap,payments ;;
        referral-monitor) echo rm ;;
    esac
}

# _preview_stack_id <job_id> — job-<lowercased id, non-alnum runs -> ->.
_preview_stack_id() {
    local s
    s=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9][^a-z0-9]*/-/g')
    printf 'job-%s' "$s"
}

# _preview_load_job — resolves the job and sets _pv_job_id, _pv_job_file,
# _pv_repo, _pv_branch, _pv_work_dir, _pv_stack_id. Uses $_pv_job_arg
# (--job) or $MOTHER_JOB_ID. Exit 2 when there is none.
_preview_load_job() {
    _pv_job_id="${_pv_job_arg:-${MOTHER_JOB_ID:-}}"
    if [ -z "$_pv_job_id" ]; then
        _preview_die 2 "no job: MOTHER_JOB_ID is not set (operators: pass --job <id>)"
        return 2
    fi
    _pv_job_file=$(_preview_job_file "$_pv_job_id")
    if [ ! -f "$_pv_job_file" ]; then
        _preview_die 2 "no such job: $_pv_job_id"
        return 2
    fi
    _pv_repo=$(jq -r '.repo // empty' "$_pv_job_file")
    _pv_branch=$(jq -r '.branch // empty' "$_pv_job_file")
    _pv_work_dir=$(jq -r '.work_dir // .repo_path // empty' "$_pv_job_file")
    _pv_stack_id=$(_preview_stack_id "$_pv_job_id")
    if [ "${#_pv_stack_id}" -gt 36 ]; then
        _preview_die 2 "stack id '$_pv_stack_id' is longer than 36 characters"
        return 2
    fi
    return 0
}

# _preview_record — the job's .preview record (compact JSON), or "".
_preview_record() {
    jq -c '.preview // empty' "$_pv_job_file" 2>/dev/null
}

# _preview_need_record — loads the job and requires a .preview record with a
# URL (the launch completed). Sets _pv_rec and _pv_url.
_preview_need_record() {
    _preview_load_job || return $?
    _pv_rec=$(_preview_record)
    if [ -z "$_pv_rec" ]; then
        _preview_die 2 "no preview stack for this job (run 'mother preview up')"
        return 2
    fi
    case "$(printf '%s' "$_pv_rec" | jq -r '.status // empty')" in
        stopped|stop_failed)
            _preview_die 2 "stack was stopped; run 'mother preview up'"
            return 2
            ;;
    esac
    _pv_url=$(printf '%s' "$_pv_rec" | jq -r '.urls.stack // empty')
    if [ -z "$_pv_url" ]; then
        _preview_die 1 "the stack never finished launching: run 'mother preview up' again"
        return 1
    fi
    return 0
}

_preview_sha7() { printf '%s' "${1:-}" | cut -c1-7; }

# ---------------------------------------------------------------------------
# up

_preview_usage() {
    cat >&2 <<'EOF'
mother preview — per-job preview stacks (stopped automatically when you exit)

  mother preview up [--components c,c] [--with c,c] [--ap|--fp|--payments|--rm <ref>]
                    [--no-wait] [--json]
  mother preview wait [--timeout <s>]
  mother preview info [--live]
  mother preview verify
  mother preview call <GET|POST> <path> [--token <NAME>] [--data <json>]
  mother preview fake <scenario> [--source aidin|curaspan|careport] [--body <json>]
  mother preview down

Components: ap, fp (needs ap), payments (needs ap), rm.
Needs MOTHER_JOB_ID (or --job <id>). Exit: 0 ok, 1 failure, 2 usage/validation,
3 refused (disabled/backend), 4 still starting.
EOF
}

_preview_valid_component() {
    case "$1" in ap|fp|payments|rm) return 0 ;; esac
    return 1
}

# _preview_has <comma-list> <component>
_preview_has() {
    case ",$1," in *",$2,"*) return 0 ;; esac
    return 1
}

mother_preview_up() {
    local components_arg="" with_arg="" no_wait=0 json=0
    local ref_ap="" ref_fp="" ref_payments="" ref_rm=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --components) components_arg="${2:-}"; shift 2 || { _preview_die 2 "--components needs a value"; return 2; } ;;
            --with)       with_arg="${2:-}"; shift 2 || { _preview_die 2 "--with needs a value"; return 2; } ;;
            --ap)         ref_ap="${2:-}"; shift 2 || { _preview_die 2 "--ap needs a ref"; return 2; } ;;
            --fp)         ref_fp="${2:-}"; shift 2 || { _preview_die 2 "--fp needs a ref"; return 2; } ;;
            --payments)   ref_payments="${2:-}"; shift 2 || { _preview_die 2 "--payments needs a ref"; return 2; } ;;
            --rm)         ref_rm="${2:-}"; shift 2 || { _preview_die 2 "--rm needs a ref"; return 2; } ;;
            --no-wait)    no_wait=1; shift ;;
            --json)       json=1; shift ;;
            *) _preview_die 2 "unknown option for up: $1"; return 2 ;;
        esac
    done

    # Kill switch and backend (exit 3, nothing launched).
    if [ "$(_preview_cfg MOTHER_PREVIEW_ENABLED 1)" = "0" ]; then
        _preview_die 3 "preview stacks are disabled (MOTHER_PREVIEW_ENABLED=0)"
        return 3
    fi
    local backend; backend=$(_preview_cfg MOTHER_PREVIEW_BACKEND cli)
    if [ "$backend" != "cli" ]; then
        _preview_die 3 "preview backend '$backend' is not available (only cli; the operations backend is deferred)"
        return 3
    fi

    _preview_load_job || return $?

    # Components: --components (else the repo's default) plus --with, deduped in order.
    local own list="" c ref
    own=$(_preview_component_for_repo "$_pv_repo")
    if [ -z "$components_arg" ]; then
        components_arg=$(_preview_default_components "$_pv_repo")
        if [ -z "$components_arg" ]; then
            _preview_die 2 "repo '$_pv_repo' has no default components: pass --components (ap,fp,payments,rm)"
            return 2
        fi
    fi
    for c in $(printf '%s,%s' "$components_arg" "$with_arg" | tr ',' ' '); do
        if ! _preview_valid_component "$c"; then
            _preview_die 2 "unknown component '$c' (valid: ap, fp, payments, rm)"
            return 2
        fi
        _preview_has "$list" "$c" || list="${list:+$list,}$c"
    done

    # Closure is checked, never fixed.
    for c in fp payments; do
        if _preview_has "$list" "$c" && ! _preview_has "$list" ap; then
            _preview_die 2 "$c requires ap (use --components ap,$c)"
            return 2
        fi
    done
    for c in ap fp payments rm; do
        eval "ref=\${ref_$c}"
        if [ -n "$ref" ] && ! _preview_has "$list" "$c"; then
            _preview_die 2 "--$c given but $c is not in the components ($list)"
            return 2
        fi
    done

    # Refs: the job's own component defaults to the (pushed) job branch, the rest to main.
    local refs="" expected_c="" expected_sha=""
    for c in $(printf '%s' "$list" | tr ',' ' '); do
        eval "ref=\${ref_$c}"
        if [ -z "$ref" ]; then
            if [ "$c" = "$own" ] && [ -n "$_pv_branch" ]; then
                ref="$_pv_branch"
                expected_c="$c"
            else
                ref=main
            fi
        fi
        refs="${refs:+$refs }$c=$ref"
    done
    if [ -n "$expected_c" ]; then
        local remote_sha head_sha
        remote_sha=$(git -C "$_pv_work_dir" ls-remote origin "refs/heads/$_pv_branch" 2>/dev/null | awk 'NR==1{print $1}')
        head_sha=$(git -C "$_pv_work_dir" rev-parse HEAD 2>/dev/null)
        if [ -z "$head_sha" ] || [ "$remote_sha" != "$head_sha" ]; then
            local origin_has=nothing
            [ -z "$remote_sha" ] || origin_has=$(_preview_sha7 "$remote_sha")
            _preview_die 2 "push first: previews build pushed refs (origin has $origin_has, HEAD is $(_preview_sha7 "$head_sha"))"
            return 2
        fi
        expected_sha="$head_sha"
    fi

    # Launch through the backend seam.
    # A provisional record goes down first: a launch that times out or fails
    # after the run was dispatched must still be stopped by the hooks (`down`
    # on an id the CLI doesn't know counts as ok).
    local rec rc=0 launches prior
    prior=$(jq -c '.preview // empty' "$_pv_job_file" 2>/dev/null)
    launches=$(( $(jq -r '.preview.launches // 0' "$_pv_job_file" 2>/dev/null) + 1 ))
    _preview_job_update "$_pv_job_id" '.preview = {stack_id: $s, backend: $b, components: ($l | split(",")),
        status: "launching", urls: {}, expected_sha: {}, launches: $n, stopped_at: null}' \
        --arg s "$_pv_stack_id" --arg b "$backend" --arg l "$list" --argjson n "$launches" 2>/dev/null || true
    rec=$(_preview_backend_up "$backend" "$_pv_stack_id" "$list" "$refs") || rc=$?
    if [ "$rc" -ne 0 ]; then
        if [ "$rc" -eq 2 ] || [ "$rc" -eq 3 ]; then
            # The CLI refused: nothing launched, so put the old record back.
            if [ -n "$prior" ]; then
                _preview_job_update "$_pv_job_id" '.preview = $p' --argjson p "$prior" 2>/dev/null || true
            else
                _preview_job_update "$_pv_job_id" 'del(.preview)' 2>/dev/null || true
            fi
        else
            rc=1
        fi
        return "$rc"
    fi

    # Record on the job, and as an event.
    # Published logins are shown once in the human summary; never stored.
    _pv_logins=$(printf '%s' "$rec" | jq -c '.logins // null')
    rec=$(printf '%s' "$rec" | jq -c \
        --arg list "$list" --arg ec "$expected_c" --arg es "$expected_sha" --argjson launches "$launches" '
        del(.logins) + {components: ($list | split(",")), status: "launching",
             expected_sha: (if $ec != "" and $es != "" then {($ec): $es} else {} end),
             launches: $launches, stopped_at: null}')
    _preview_job_update "$_pv_job_id" '.preview = $rec' --argjson rec "$rec" 2>/dev/null || true
    _preview_event "$_pv_job_id" preview_up "$rec" 2>/dev/null || true

    if [ "$no_wait" -eq 0 ]; then
        local wrc=0
        _preview_wait_loop "$(_preview_cfg MOTHER_PREVIEW_WAIT_TIMEOUT 540)" || wrc=$?
        if [ "$wrc" -ne 0 ]; then
            return "$wrc"
        fi
    fi
    _preview_print_record "$json"
    return 0
}

# _preview_print_record <json:0|1> — print the job's current record.
_preview_print_record() {
    local json="$1" rec
    rec=$(jq -c '.preview // empty' "$_pv_job_file" 2>/dev/null)
    if [ "$json" = "1" ]; then
        printf '%s\n' "$rec" | jq .
        return 0
    fi
    echo "Preview stack $(printf '%s' "$rec" | jq -r '.stack_id') ($(printf '%s' "$rec" | jq -r '.combo // "?"'), $(printf '%s' "$rec" | jq -r '.status'))"
    printf '%s' "$rec" | jq -r '.urls | to_entries[] | "  \(.key): \(.value)"'
    printf '%s' "${_pv_logins:-null}" | jq -r '
        (. // {}) | to_entries[] | .key as $k
        | (.value | if type == "array" then .[] else . end) | select(type == "object")
        | "  login (\($k)): \(.user // .email // "?") / \(.password // "?")"' 2>/dev/null
    echo "  stop with: mother preview down"
}

# ---------------------------------------------------------------------------
# HTTP (all requests go through $MOTHER_PREVIEW_CURL, a test seam)

# _preview_http <METHOD> <url> <token-name|""> <data|""> — sets _pv_http_code
# and _pv_http_body. A bearer token is handed to curl on stdin (-K -), never on
# the command line.
_preview_http() {
    local method="$1" url="$2" token_name="${3:-}" data="${4:-}"
    local curl_bin; curl_bin=$(_preview_cfg MOTHER_PREVIEW_CURL curl)
    local -a args
    args=(-sS --max-time 30 -w '\n%{http_code}' -X "$method")
    [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data "$data")
    local out
    if [ -n "$token_name" ]; then
        local tok
        tok=$(jq -r --arg n "$token_name" '.tokens[$n] // empty' "$(_preview_secrets_file "$_pv_job_id")" 2>/dev/null)
        out=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" | "$curl_bin" "${args[@]}" -K - "$url" 2>/dev/null)
        tok=""
    else
        out=$("$curl_bin" "${args[@]}" "$url" 2>/dev/null </dev/null)
    fi
    _pv_http_code=$(printf '%s' "$out" | tail -n 1)
    case "$_pv_http_code" in [0-9][0-9][0-9]) ;; *) _pv_http_code=000 ;; esac
    _pv_http_body=$(printf '%s' "$out" | sed '$d')
}

# ---------------------------------------------------------------------------
# wait

# _preview_run_failed <run_id> — 0 when `rwx results` says the run failed.
_preview_run_failed() {
    local run_id="$1" tmp res
    [ -n "$run_id" ] && command -v rwx >/dev/null 2>&1 || return 1
    tmp=$(_preview_tmp)
    # rwx exits 1 for a failed run but still prints its JSON.
    _preview_bounded 30 "." "$tmp" "$tmp.err" rwx results "$run_id" --json || true
    res=$(jq -r '(.Status // .RunStatus // {}) | .Result // empty' "$tmp" 2>/dev/null)
    rm -f "$tmp" "$tmp.err"
    [ "$res" = "failed" ]
}

# _preview_wait_loop <timeout_s> — requires _pv_* loaded. Exit: 0 ready,
# 1 sha mismatch / run failed, 4 timeout.
_preview_wait_loop() {
    local timeout="$1" interval started=$SECONDS elapsed
    interval=$(_preview_cfg MOTHER_PREVIEW_POLL_INTERVAL 10)
    _preview_need_record || return $?
    local launched_at run_id run_url own expected
    launched_at=$(printf '%s' "$_pv_rec" | jq -r '.launched_at // empty')
    run_id=$(printf '%s' "$_pv_rec" | jq -r '.run_id // empty')
    run_url=$(printf '%s' "$_pv_rec" | jq -r '.run_url // empty')
    own=$(printf '%s' "$_pv_rec" | jq -r '.expected_sha // {} | keys | .[0] // empty')
    expected=$(printf '%s' "$_pv_rec" | jq -r '.expected_sha // {} | to_entries | .[0].value // empty')

    while :; do
        _preview_http GET "$_pv_url/__stack/health" "" ""
        if [ "$_pv_http_code" = "200" ] && printf '%s' "$_pv_http_body" \
            | jq -e --arg l "$launched_at" '.launched_at == $l' >/dev/null 2>&1; then
            if [ -z "$own" ]; then
                _preview_mark_ready "$((SECONDS - started))"
                return 0
            fi
            _preview_http GET "$_pv_url/__stack/info" "" ""
            if [ "$_pv_http_code" = "200" ]; then
                local got
                got=$(printf '%s' "$_pv_http_body" | jq -r --arg c "$own" '.components[$c].sha // empty' 2>/dev/null)
                if [ -n "$got" ]; then
                    if ! _preview_sha_match "$got" "$expected"; then
                        _preview_die 1 "stack is running the wrong code: $own is at $got, expected $expected"
                        return 1
                    fi
                    _preview_mark_ready "$((SECONDS - started))"
                    return 0
                fi
            fi
        fi
        if _preview_run_failed "$run_id"; then
            _preview_die 1 "the stack's RWX run failed: ${run_url:-$run_id}"
            return 1
        fi
        elapsed=$((SECONDS - started))
        if [ "$elapsed" -ge "$timeout" ]; then
            _preview_die 4 "still starting after ${elapsed}s: run 'mother preview wait' again (cold launches take ~3-4 min)"
            return 4
        fi
        sleep "$interval"
    done
}

# _preview_sha_match <a> <b> — equal, or one is an abbreviation of the other.
_preview_sha_match() {
    case "$1" in "$2"*) return 0 ;; esac
    case "$2" in "$1"*) return 0 ;; esac
    return 1
}

_preview_mark_ready() {
    _preview_job_update "$_pv_job_id" '.preview.status = "ready"' 2>/dev/null || true
    _preview_event "$_pv_job_id" preview_ready "$(jq -nc --argjson w "$1" '{wait_s: $w}')" 2>/dev/null || true
}

mother_preview_wait() {
    local timeout=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout) timeout="${2:-}"; shift 2 || { _preview_die 2 "--timeout needs seconds"; return 2; } ;;
            --json)    shift ;;
            *) _preview_die 2 "unknown option for wait: $1"; return 2 ;;
        esac
    done
    case "$timeout" in
        *[!0-9]*) _preview_die 2 "--timeout must be a number of seconds"; return 2 ;;
    esac
    local rc=0
    _preview_wait_loop "${timeout:-$(_preview_cfg MOTHER_PREVIEW_WAIT_TIMEOUT 540)}" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    _preview_print_record 1
}

# ---------------------------------------------------------------------------
# info / verify / call / fake / down

mother_preview_info() {
    local live=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --live) live=1; shift ;;
            *) _preview_die 2 "unknown option for info: $1"; return 2 ;;
        esac
    done
    _preview_need_record || return $?
    printf '%s\n' "$_pv_rec" | jq .
    if [ "$live" -eq 1 ]; then
        _preview_http GET "$_pv_url/__stack/info" "" ""
        echo "HTTP $_pv_http_code" >&2
        printf '%s\n' "$_pv_http_body"
        [ "${_pv_http_code#2}" != "$_pv_http_code" ] || return 1
    fi
    return 0
}

mother_preview_verify() {
    _preview_need_record || return $?
    local bin
    bin=$(_preview_stack_bin) || { _preview_die 1 "preview-stack CLI not found (set MOTHER_PREVIEW_STACK_BIN)"; return 1; }
    "$bin" verify "$_pv_url" </dev/null
}

mother_preview_call() {
    local method="${1:-}" path="${2:-}" token="" data=""
    [ $# -ge 2 ] || { _preview_usage; return 2; }
    shift 2
    while [ $# -gt 0 ]; do
        case "$1" in
            --token) token="${2:-}"; shift 2 || { _preview_die 2 "--token needs a name"; return 2; } ;;
            --data)  data="${2:-}"; shift 2 || { _preview_die 2 "--data needs a value"; return 2; } ;;
            *) _preview_die 2 "unknown option for call: $1"; return 2 ;;
        esac
    done
    case "$method" in GET|POST) ;; *) _preview_die 2 "method must be GET or POST"; return 2 ;; esac
    case "$path" in /*) ;; *) _preview_die 2 "path must start with /"; return 2 ;; esac
    _preview_need_record || return $?
    if [ -n "$token" ]; then
        local sf; sf=$(_preview_secrets_file "$_pv_job_id")
        if [ ! -f "$sf" ]; then
            _preview_die 2 "this stack has no owner secrets (only rm stacks do)"
            return 2
        fi
        if ! jq -e --arg n "$token" '.tokens[$n] // empty' "$sf" >/dev/null 2>&1; then
            _preview_die 2 "unknown token '$token' (known: $(jq -r '.tokens | keys | join(", ")' "$sf" 2>/dev/null))"
            return 2
        fi
    fi
    _preview_http "$method" "$_pv_url$path" "$token" "$data"
    echo "HTTP $_pv_http_code" >&2
    printf '%s\n' "$_pv_http_body"
    case "$_pv_http_code" in 2??) return 0 ;; esac
    return 1
}

mother_preview_fake() {
    local scenario="${1:-}" source="" body="{}"
    [ -n "$scenario" ] || { _preview_usage; return 2; }
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
            --source) source="${2:-}"; shift 2 || { _preview_die 2 "--source needs a value"; return 2; } ;;
            --body)   body="${2:-}"; shift 2 || { _preview_die 2 "--body needs JSON"; return 2; } ;;
            *) _preview_die 2 "unknown option for fake: $1"; return 2 ;;
        esac
    done
    case "$source" in ''|aidin|curaspan|careport) ;; *) _preview_die 2 "unknown source '$source' (aidin, curaspan, careport)"; return 2 ;; esac
    _preview_need_record || return $?
    if ! _preview_has "$(printf '%s' "$_pv_rec" | jq -r '.components // [] | join(",")')" rm; then
        _preview_die 2 "fake scenarios need rm in the stack (launch with --components rm)"
        return 2
    fi
    if ! printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
        _preview_die 2 "--body must be a JSON object"
        return 2
    fi
    [ -z "$source" ] || body=$(printf '%s' "$body" | jq -c --arg s "$source" '. + {source: $s}')
    body=$(printf '%s' "$body" | jq -c .)
    mother_preview_call POST "/__fake/scenarios/$scenario" --token FAKEPARTNERS_CONTROL_TOKEN --data "$body"
}

mother_preview_down() {
    _preview_load_job || return $?
    local res outcome
    res=$(_preview_stop_run "$_pv_job_id" explicit)
    outcome=$(printf '%s' "$res" | jq -r '.outcome // "error"')
    case "$outcome" in
        noop) echo "no running preview stack for this job" >&2; return 0 ;;
        ok)   echo "preview stack $_pv_stack_id stopped" >&2; return 0 ;;
        *) _preview_die 1 "stop $outcome: $(printf '%s' "$res" | jq -r '.output_tail // ""')"; return 1 ;;
    esac
}

# mother_preview_main <args...> — the `mother preview` dispatcher.
mother_preview_main() {
    local sub="${1:-}"
    case "$sub" in ''|-h|--help|help) _preview_usage; return 2 ;; esac
    shift
    # --job <id> (operators) may appear anywhere.
    _pv_job_arg=""
    _pv_logins=""
    local -a rest
    rest=()
    while [ $# -gt 0 ]; do
        if [ "$1" = "--job" ]; then
            _pv_job_arg="${2:-}"
            shift 2 || break
        else
            rest+=("$1")
            shift
        fi
    done
    set -- ${rest[@]+"${rest[@]}"}
    case "$sub" in
        up)     mother_preview_up "$@" ;;
        wait)   mother_preview_wait "$@" ;;
        info)   mother_preview_info "$@" ;;
        verify) mother_preview_verify "$@" ;;
        call)   mother_preview_call "$@" ;;
        fake)   mother_preview_fake "$@" ;;
        down)   mother_preview_down "$@" ;;
        *)      _preview_die 2 "unknown subcommand: $sub"; _preview_usage; return 2 ;;
    esac
}
