#!/usr/bin/env bash
# rwx.sh — best-effort RWX cloud-sandbox lifecycle helpers.
#
# Repos that commit `.rwx/sandbox.yml` let a worker run tests in an RWX sandbox
# (`rwx sandbox exec -- <cmd>`) instead of the laptop's Docker stack. Mother
# resets that sandbox when a fresh attempt starts (so a retried job doesn't
# reconnect to stale DB state) and stops it when the worker exits (so it stops
# billing). Both are strictly best-effort: nothing here may fail, block for
# long, or change a job's outcome.
#
# These are pure helpers — no job-state writes, no events. The callers in
# bin/mother-run-job own state and events. Sourced under `set -u`, bash 3.2.
#
# proc.sh (mother_kill_tree) lives next to this file. Resolve it from this file's own
# location so it never depends on MOTHER_LIB_DIR being set; fail loudly if it's missing.
_mother_rwx_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=proc.sh
source "$_mother_rwx_lib_dir/proc.sh" || { echo "rwx.sh: cannot load $_mother_rwx_lib_dir/proc.sh" >&2; return 1 2>/dev/null || exit 1; }
unset _mother_rwx_lib_dir

# Sandbox identity is (current git branch, absolute config path), so every
# call runs in a subshell cd'd to the job's work_dir.

# mother_rwx_gate <work_dir>
# Echoes one of: ok | no_config | disabled | no_cli. Returns 0 only for ok.
# no_config is checked first so repos without .rwx/sandbox.yml stay silent
# regardless of the kill switch.
mother_rwx_gate() {
    local work_dir="${1:-}" gate=ok
    if [ -z "$work_dir" ] || [ ! -f "$work_dir/.rwx/sandbox.yml" ]; then
        gate=no_config
    elif [ "${MOTHER_RWX_SANDBOX_ENABLED:-1}" = "0" ]; then
        gate=disabled
    elif ! command -v rwx >/dev/null 2>&1; then
        gate=no_cli
    fi
    echo "$gate"
    [ "$gate" = "ok" ]
}

# _rwx_run_action <action> <outfile> — runs in the (already cd'd) cwd, writing
# combined output to <outfile>; exit status is rwx's. rwx runs as a direct child
# (no $(...) layer) so the watchdog can kill it. No `start` fallback for reset:
# rwx v3.31 `sandbox reset` starts a sandbox when none exists (live-verified).
_rwx_run_action() {
    local action="$1" outfile="$2"
    case "$action" in
        reset) rwx sandbox reset .rwx/sandbox.yml >"$outfile" 2>&1 </dev/null ;;
        stop)  rwx sandbox stop >"$outfile" 2>&1 </dev/null ;;
    esac
}

# mother_rwx_sandbox <reset|stop> <work_dir>
# Runs the action under a watchdog and echoes one compact JSON object:
#   {action, command, outcome: ok|error|timeout, exit_code, duration_s, output_tail}
# A stop that finds no sandbox (idle timeout beat us) counts as ok. Always
# returns 0.
mother_rwx_sandbox() {
    local action="${1:-}" work_dir="${2:-}"
    local timeout command_str
    case "$action" in
        reset) timeout="${MOTHER_RWX_RESET_TIMEOUT:-90}"; command_str="rwx sandbox reset .rwx/sandbox.yml" ;;
        stop)  timeout="${MOTHER_RWX_STOP_TIMEOUT:-60}";  command_str="rwx sandbox stop" ;;
        *)
            jq -nc --arg a "$action" \
                '{action: $a, command: "", outcome: "error", exit_code: 2, duration_s: 0, output_tail: "unknown action"}'
            return 0
            ;;
    esac

    local dir="${MOTHER_ROOT:-$HOME/.mother}/runner" tmp
    mkdir -p "$dir" 2>/dev/null
    tmp=$(mktemp "$dir/rwx-out.tmp.XXXXXX" 2>/dev/null) || tmp="/tmp/rwx-out.tmp.$$"
    rm -f "$tmp.timeout" "$tmp.rc"

    local started=$SECONDS
    # Probe: output to a file (never a pipe, so a stuck grandchild can't hold
    # the caller's stdout open); exit code to a side file.
    (
        cd "$work_dir" 2>/dev/null || exit 126
        _rwx_run_action "$action" "$tmp"
        echo $? >"$tmp.rc"
    ) >/dev/null 2>&1 </dev/null &
    local probe_pid=$!
    # Watchdog (same background-race pattern as _docker_reachable in
    # teardown.sh). Its stdio is detached so the orphaned `sleep` can't pin a
    # $(...) capture open for the full timeout after it is reaped below.
    (
        sleep "$timeout"
        : >"$tmp.timeout"
        mother_kill_tree "$probe_pid"
    ) >/dev/null 2>&1 </dev/null &
    local watchdog_pid=$!

    wait "$probe_pid" 2>/dev/null
    mother_kill_tree "$watchdog_pid"
    wait "$watchdog_pid" 2>/dev/null

    local duration=$((SECONDS - started)) outcome exit_code=0
    if [ -f "$tmp.timeout" ]; then
        outcome=timeout; exit_code=124
    elif [ -f "$tmp.rc" ]; then
        exit_code=$(cat "$tmp.rc" 2>/dev/null); exit_code="${exit_code:-1}"
        if [ "$exit_code" = "0" ]; then
            outcome=ok
        elif [ "$action" = "stop" ] && grep -q 'No sandbox found' "$tmp" 2>/dev/null; then
            # Already idled out (or never started): nothing left to stop.
            outcome=ok
        else
            outcome=error
        fi
    else
        outcome=error; exit_code=1
    fi

    local tail_text esc
    esc=$(printf '\033')
    tail_text=$(tr -d '\r' <"$tmp" 2>/dev/null \
        | sed "s/${esc}\\[[0-9;]*[A-Za-z]//g" \
        | grep -v -e 'A new release of rwx is available' -e '^To upgrade, run:' \
        | tail -c 300)

    rm -f "$tmp" "$tmp.timeout" "$tmp.rc"
    jq -nc --arg action "$action" --arg command "$command_str" --arg outcome "$outcome" \
        --argjson exit_code "$exit_code" --argjson duration "$duration" --arg tail "$tail_text" \
        '{action: $action, command: $command, outcome: $outcome, exit_code: $exit_code,
          duration_s: $duration, output_tail: $tail}'
    return 0
}
