#!/usr/bin/env bash
# proc.sh — process helpers shared by lib/rwx.sh and lib/preview.sh.
# Sourced under `set -u`, bash 3.2.

# mother_kill_tree <pid> — SIGKILL a background subshell and all its
# descendants (children first). Never fails.
mother_kill_tree() {
    local pid="$1" kid
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
        mother_kill_tree "$kid"
    done
    kill -9 "$pid" 2>/dev/null
    return 0
}

# mother_watchdog_run <timeout_s> <state_prefix> <cwd> <cmd> [args...]
# Runs <cmd> as a direct background child of a subshell cd'd to <cwd>, with
# stdin from /dev/null and stdout/stderr discarded — the command (usually a
# shell function) redirects its own output to a FILE, never a pipe, so a stuck
# grandchild can't hold the caller's stdout open. The command's exit code goes
# to <state_prefix>.rc; if it outlives <timeout_s> the whole tree is killed and
# <state_prefix>.timeout is written. Sets (globals, no $(...) layer):
#   MOTHER_WD_OUTCOME   done | timeout | noresult (cd failed / killed externally)
#   MOTHER_WD_RC        the command's exit code (124 on timeout, 1 on noresult)
# Always returns 0. Cleans up its own state files.
mother_watchdog_run() {
    local timeout="$1" prefix="$2" cwd="$3"
    shift 3
    rm -f "$prefix.timeout" "$prefix.rc"

    (
        cd "$cwd" 2>/dev/null || exit 126
        "$@"
        echo $? >"$prefix.rc"
    ) >/dev/null 2>&1 </dev/null &
    local probe_pid=$!
    # Watchdog (same background-race pattern as _docker_reachable in
    # teardown.sh). Its stdio is detached so the orphaned `sleep` can't pin a
    # $(...) capture open for the full timeout after it is reaped below.
    (
        sleep "$timeout"
        : >"$prefix.timeout"
        mother_kill_tree "$probe_pid"
    ) >/dev/null 2>&1 </dev/null &
    local watchdog_pid=$!

    wait "$probe_pid" 2>/dev/null
    mother_kill_tree "$watchdog_pid"
    wait "$watchdog_pid" 2>/dev/null

    if [ -f "$prefix.timeout" ]; then
        MOTHER_WD_OUTCOME=timeout; MOTHER_WD_RC=124
    elif [ -f "$prefix.rc" ]; then
        MOTHER_WD_OUTCOME=done
        MOTHER_WD_RC=$(cat "$prefix.rc" 2>/dev/null); MOTHER_WD_RC="${MOTHER_WD_RC:-1}"
    else
        MOTHER_WD_OUTCOME=noresult; MOTHER_WD_RC=1
    fi
    rm -f "$prefix.timeout" "$prefix.rc"
    return 0
}
